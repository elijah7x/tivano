import AppKit
import SwiftUI

/// Streamed text arrives the way zeron draws it (`crates/ui/src/markdown/veil.rs`, itself a
/// port of mugen-markdown's `FadePainter`): every flush is committed to layout at once, and a
/// purely cosmetic veil over the characters that just arrived dissolves over the next beat.
/// Nothing moves and nothing resizes; a token that fades in exactly where it will stay is
/// what reads as text being written, where a token that popped in whole read as a glitch.
///
/// - Each append registers the new tail as a chunk with its arrival time. A fast stream
///   keeps several chunks fading at once (a rolling veil); a chunk fades exactly once, and
///   text already faded never animates again.
/// - The fade's length follows the stream's cadence: an EMA of the gaps between flushes,
///   `duration = clamp(ema × 3, 120ms, 400ms)`, so a fast stream dissolves quickly and a
///   slow one lingers. Three or more chunks in flight speed each other up by 30% a chunk.
/// - The dissolve eases as `(1 − p)^1.6`, so the text shows through at `1 − veil`.
/// - Only opacity changes, and only the paint: every consumer keeps its layout byte for byte.
/// - What is already on screen when a veil attaches (a row scrolled back into view, a thread
///   switched back to mid-reply) is adopted as the baseline and never fades; only later
///   appends do. A rewrite that is not an append (the parser re-deriving a block once
///   `**bold` closes) keeps the common prefix's fades and re-veils only the changed tail.
///
/// Offsets are in characters of the plain text the consumer hands over, so a SwiftUI
/// `AttributedString` and an AppKit text storage each map them into their own ranges.
@MainActor
final class StreamVeil {
    struct Span: Equatable {
        let range: Range<Int>
        /// The text's opacity over `range`, 0 to 1.
        let alpha: Double
    }

    private struct Chunk {
        var range: Range<Int>
        let started: Date
        /// Fixed at arrival from the cadence in force then.
        let duration: TimeInterval
    }

    static let shortestFade: TimeInterval = 0.12
    static let longestFade: TimeInterval = 0.40
    private static let curve = 1.6
    private static let cadenceSeed: TimeInterval = 0.16
    private static let gapCeiling: TimeInterval = 1.0

    private var characterCount = 0
    private var lastCharacter: Character?
    private var sourceText: String?
    private var chunks: [Chunk] = []
    private var cadence = cadenceSeed
    private var lastAppend: Date?

    /// Registers whatever `text` appends to the last text seen and drops chunks that have
    /// settled. The first call adopts the text as the baseline without fading it. Idempotent
    /// for unchanged text, so a body may call it on every evaluation.
    func advance(_ text: String, at now: Date) {
        guard sourceText != text else { return }
        let previous = sourceText
        sourceText = text
        guard let previous else {
            characterCount = text.count
            lastCharacter = text.last
            return
        }
        let prefix: Int
        let count: Int
        if text.utf8.starts(with: previous.utf8) {
            // An append may join the old final grapheme (combining mark, CRLF or ZWJ).
            // Re-segment that grapheme with the tail rather than expanding the history.
            let suffix = String(decoding: text.utf8.dropFirst(previous.utf8.count), as: UTF8.self)
            if let lastCharacter {
                let tail = String(lastCharacter) + suffix
                prefix = characterCount - (tail.first == lastCharacter ? 0 : 1)
                count = characterCount - 1 + tail.count
            } else {
                prefix = 0
                count = suffix.count
            }
        } else {
            prefix = Self.commonPrefix(previous, text)
            count = text.count
        }
        if prefix != characterCount || count != characterCount {
            // A rewrite shorter than a chunk's start (a delegation block leaving the reply,
            // say) drops that chunk whole: a range built with its upper bound below its
            // lower one traps.
            chunks = chunks.compactMap { chunk in
                let upper = min(chunk.range.upperBound, prefix)
                guard upper > chunk.range.lowerBound else { return nil }
                var kept = chunk
                kept.range = chunk.range.lowerBound..<upper
                return kept
            }
            if count > prefix {
                if let lastAppend {
                    let gap = min(now.timeIntervalSince(lastAppend), Self.gapCeiling)
                    cadence = cadence * 0.7 + gap * 0.3
                }
                lastAppend = now
                let duration = min(max(cadence * 3, Self.shortestFade), Self.longestFade)
                chunks.append(Chunk(range: prefix..<count, started: now, duration: duration))
            }
        }
        characterCount = count
        lastCharacter = text.last
        prune(at: now)
    }

    /// The chunks still dissolving at `now`, with the text's opacity over each.
    func spans(at now: Date) -> [Span] {
        prune(at: now)
        let boost = Self.boost(chunks.count)
        return chunks.map { chunk in
            let progress = min(1, max(0, now.timeIntervalSince(chunk.started) * boost / chunk.duration))
            return Span(range: chunk.range, alpha: 1 - pow(1 - progress, Self.curve))
        }
    }

    func isFading(at now: Date) -> Bool {
        prune(at: now)
        return !chunks.isEmpty
    }

    /// One frame of a consumer's update: feeds `text` while `active`, and says whether
    /// anything is still dissolving afterwards.
    func step(_ text: @autoclosure () -> String, active: Bool, at now: Date) -> Bool {
        if active { advance(text(), at: now) }
        return isFading(at: now)
    }

    /// When the last chunk in flight settles, so a frame clock knows when to stop.
    var settlesAt: Date? {
        let boost = Self.boost(chunks.count)
        return chunks.map { $0.started.addingTimeInterval($0.duration / boost) }.max()
    }

    /// Forgets the text and every chunk, so a settled paragraph holds nothing; the next
    /// `advance` attaches afresh.
    func reset() {
        characterCount = 0
        lastCharacter = nil
        sourceText = nil
        chunks = []
        lastAppend = nil
        cadence = Self.cadenceSeed
    }

    private func prune(at now: Date) {
        let boost = Self.boost(chunks.count)
        chunks.removeAll { now.timeIntervalSince($0.started) * boost >= $0.duration }
    }

    /// A backed-up stream (three or more chunks fading at once) dissolves faster.
    private static func boost(_ active: Int) -> Double {
        1 + 0.3 * Double(max(0, active - 2))
    }

    private static func commonPrefix(_ a: String, _ b: String) -> Int {
        var count = 0
        for (left, right) in zip(a, b) {
            guard left == right else { break }
            count += 1
        }
        return count
    }
}

/// Whether the text under this view belongs to a reply that is still arriving, so its
/// paragraphs veil what streams in. Set once per message, on every block of it, so a
/// paragraph that stops being the last block keeps dissolving instead of snapping.
private struct MarkdownVeiledKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var markdownVeiled: Bool {
        get { self[MarkdownVeiledKey.self] }
        set { self[MarkdownVeiledKey.self] = newValue }
    }
}

/// One display-rate clock for the veils of one render scope: every chat column hosts
/// its own (see `VeilRenderScope`); markdown outside a column shares `shared`. A veiled
/// `Text` reads `now` only while it dissolves, so each tick re-renders exactly the
/// paragraphs still fading and nothing else; the link is torn down the moment the last
/// of them has settled. The `Text` itself stays a bare `Text` in its stack (no
/// `TimelineView` around it), so a list marker keeps its first-baseline alignment with
/// the paragraph mid-stream.
@MainActor
@Observable
final class VeilClock {
    static let shared = VeilClock()

    private(set) var now = Date.now
    @ObservationIgnored private var link: CADisplayLink?
    @ObservationIgnored private var deadline: Date?
    @ObservationIgnored private var isSuspended = false

    /// Keeps the clock ticking until `date`, or later if it already runs past it.
    func run(until date: Date) {
        deadline = max(deadline ?? date, date)
        arm()
    }

    /// Stops the display link outright, deadline and all kept. A scope whose column
    /// went invisible suspends its clock rather than muting the tick: an early return
    /// in `tick` would keep the callbacks coming and the deadline from expiring.
    func suspend() {
        isSuspended = true
        link?.invalidate()
        link = nil
    }

    /// Picks the tick back up after a suspension, while anything is still dissolving.
    /// A deadline that passed in the meantime is dropped: that work has settled.
    func resume() {
        isSuspended = false
        now = .now
        guard let deadline else { return }
        guard Date.now < deadline else {
            self.deadline = nil
            return
        }
        arm()
    }

    private func arm() {
        guard !isSuspended, link == nil, deadline != nil, let screen = NSScreen.main else { return }
        let link = screen.displayLink(target: self, selector: #selector(tick))
        // A veil is a short opacity ramp, not motion: 18 fps is indistinguishable here
        // and cuts the per-frame `Text` rebuilds for every paragraph of a reply that is still dissolving.
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 24, preferred: 18)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func tick() {
        // The clock holds its last frame through a scroll, so the veiled paragraphs are
        // not rebuilt for frames the reader never sees; the ramp resumes when the scroll
        // ends.
        guard !ScrollActivity.shared.isScrolling, NSApp.isActive else { return }
        now = .now
        guard let deadline, now >= deadline else { return }
        link?.invalidate()
        link = nil
        self.deadline = nil
    }
}

/// The veil render scope of one chat column: the column's own clock, and whether the
/// column's pane is actually drawn. `ThreadColumns` in the App layer hosts each chat
/// column with its own scope and puts it in the environment; markdown outside any
/// column keeps the shared clock and always-visible semantics, exactly as before.
///
/// A scope that goes invisible tears its clock's display link down (not merely the
/// tick) and stops its AppKit veils, so nothing repaints for a column the reader cannot
/// see; arriving text still records its real times. Turning visible again repaints at
/// the real time before the pane can show, so the first frame back carries the
/// wall-clock-correct alpha, an unfinished fade keeps dissolving where it stands, and
/// one that settled unseen stays settled.
@MainActor
@Observable
final class VeilRenderScope {
    private(set) var isVisible = true

    let clock = VeilClock()

    /// The AppKit veils of this column, held weakly: a paragraph that went away
    /// unsubscribes at detach, and one that did not is simply gone from here.
    @ObservationIgnored private var linkVeils = NSHashTable<LinkTextVeil>(options: [.weakMemory, .objectPersonality])

    /// Whether the column's pane is drawn right now. The App layer calls this at the
    /// moment its column actually hides or right before it shows again, never for a
    /// mere change of interactivity.
    func setVisible(_ visible: Bool) {
        guard visible != isVisible else { return }
        isVisible = visible
        if visible { clock.resume() } else { clock.suspend() }
        for veil in linkVeils.allObjects { veil.scopeDidChangeVisibility(visible) }
    }

    func add(_ veil: LinkTextVeil) { linkVeils.add(veil) }
    func remove(_ veil: LinkTextVeil) { linkVeils.remove(veil) }
}

/// The veil render scope of the chat column this markdown sits in.
extension EnvironmentValues {
    @Entry var veilRenderScope: VeilRenderScope? = nil
}

/// A `Text` whose newly streamed characters fade in through a `StreamVeil`. While the
/// reply streams (and until the last chunk has settled after it) the veil clock repaints
/// the text with the veil's opacities multiplied into the foreground colour of the
/// arriving runs; a finished paragraph is one plain `Text` again and holds no veil at all.
struct VeiledText: View {
    /// Prose comes styled; code comes as the string it is, and is only made attributed
    /// for the frames that veil it, so a finished dump costs a hover nothing new.
    private enum Source: Equatable {
        case attributed(AttributedString)
        case plain(String)

        var characters: String {
            switch self {
            case .attributed(let attributed): String(attributed.characters)
            case .plain(let string): string
            }
        }

        var styled: AttributedString {
            switch self {
            case .attributed(let attributed): attributed
            case .plain(let string): AttributedString(string)
            }
        }

        var text: Text {
            switch self {
            case .attributed(let attributed): Text(attributed)
            case .plain(let string): Text(verbatim: string)
            }
        }
    }

    private let source: Source
    enum Segment {
        case prose(AttributedString)
        case fixed(Text)
    }
    /// Fixed runs (head-name glyph + coloured name) interleaved with the veiled prose,
    /// in order: every head named anywhere in a paragraph renders decorated, inline in
    /// the same flowing `Text`, and only the prose runs veil.
    private let segments: [Segment]?
    /// Where each prose run ends, in characters of the JOINED string's own clustering:
    /// a grapheme that spans a join (a combining mark, a ZWJ emoji) is one character of
    /// the join but two of the runs' own counts, so slicing by those traps past endIndex.
    let proseEnds: [Int]

    @Environment(\.markdownVeiled) private var veiled
    @Environment(\.markdownDimmed) private var dimmed
    @Environment(\.veilRenderScope) private var renderScope
    @State private var veil = StreamVeil()
    @State private var mapping = VeilMapping()

    init(_ attributed: AttributedString) {
        source = .attributed(attributed)
        segments = nil
        proseEnds = []
    }

    init(segments: [Segment]) {
        var joined = AttributedString()
        var ends: [Int] = []
        for segment in segments {
            if case .prose(let a) = segment {
                joined.append(a)
                ends.append(joined.characters.count)
            }
        }
        source = .attributed(joined)
        self.segments = segments
        proseEnds = ends
    }

    init(verbatim string: String) {
        source = .plain(string)
        segments = nil
        proseEnds = []
    }

    var body: some View {
        let _ = ingest()
        let fading = veil.isFading(at: .now)
        let rendered = fading ? fadingText() : settledText()
        rendered.modifier(MarkdownBlockSelection(isLive: fading))
    }

    private func ingest() {
        guard mapping.source != source || mapping.active != veiled else { return }
        let changed = mapping.source != source
        mapping.active = veiled
        mapping.source = source
        if veiled {
            mapping.styled = source.styled
            var characters = source.characters
            characters.makeContiguousUTF8()
            var offset = 0
            if !mapping.utf8Offsets.isEmpty, characters.utf8.starts(with: mapping.characters.utf8) {
                // The old final grapheme may absorb the append; earlier boundaries stay valid.
                if mapping.utf8Offsets.count > 1 {
                    mapping.utf8Offsets.removeLast()
                    offset = mapping.utf8Offsets.last!
                }
            } else {
                mapping.utf8Offsets = [0]
            }
            let tail = String(decoding: characters.utf8.dropFirst(offset), as: UTF8.self)
            for character in tail {
                offset += String(character).utf8.count
                mapping.utf8Offsets.append(offset)
            }
            mapping.characters = characters
            veil.advance(characters, at: .now)
        } else if changed {
            // Static text needs no character map. An unchanged streaming tail keeps its
            // map until the last fade settles; rewritten text must not reuse its ranges.
            mapping.styled = AttributedString()
            mapping.characters = ""
            mapping.utf8Offsets = []
            veil.reset()
        }
    }

    @MainActor
    private final class VeilMapping {
        var source: Source?
        var active = false
        var styled = AttributedString()
        var characters = ""
        var utf8Offsets: [Int] = []

        func index(at offset: Int, in styled: AttributedString) -> AttributedString.Index {
            // AttributedString indices belong to a particular value; only byte offsets survive reparsing.
            let position = characters.utf8.index(characters.utf8.startIndex, offsetBy: utf8Offsets[offset])
            return AttributedString.Index(position, within: styled)
                ?? styled.characters.index(styled.startIndex, offsetBy: min(offset, styled.characters.count))
        }
    }

    /// This frame of the dissolve, and the clock kept running to the last chunk's settle.
    /// Reading the clock is what re-renders this text on the next tick; the frame itself
    /// is painted at the real time, so the first frame after a flush is never a stale one.
    private func fadingText() -> Text {
        // A column whose pane is hidden draws nothing: this paragraph still ingests and
        // still builds its frame at the real time (so the first frame back is current)
        // but subscribes to no clock and arms none. Reading `isVisible` is what returns
        // it to the clock the moment the column shows again.
        if let renderScope, !renderScope.isVisible {
            return text(at: .now)
        }
        let clock = renderScope?.clock ?? .shared
        if let settlesAt = veil.settlesAt { clock.run(until: settlesAt) }
        _ = clock.now
        return text(at: .now)
    }

    /// The plain text. Once the reply has finished the veil is emptied too, so a settled
    /// paragraph keeps no copy of itself; while it still streams the baseline stays, or a
    /// quiet beat between two flushes would make the next one arrive unveiled.
    private func settledText() -> Text {
        if !veiled { veil.reset() }
        if let segments {
            var out = Text(verbatim: "")
            for segment in segments {
                switch segment {
                case .fixed(let t): out = Text("\(out)\(t)")
                case .prose(let a): out = Text("\(out)\(Text(a))")
                }
            }
            return out
        }
        return source.text
    }

    private func text(at now: Date) -> Text {
        var styled = mapping.styled
        let base = dimmed ? Color.primary.opacity(0.7) : Color.primary
        let count = max(0, mapping.utf8Offsets.count - 1)
        for span in veil.spans(at: now) where span.alpha < 1 {
            let range = span.range.clamped(to: 0..<count)
            guard !range.isEmpty else { continue }
            let lower = mapping.index(at: range.lowerBound, in: styled)
            let upper = mapping.index(at: range.upperBound, in: styled)
            styled[lower..<upper].foregroundColor = base.opacity(span.alpha)
        }
        if let segments {
            var out = Text(verbatim: "")
            var cursor = styled.startIndex
            var prose = 0
            for segment in segments {
                switch segment {
                case .fixed(let t): out = Text("\(out)\(t)")
                case .prose:
                    let end = mapping.index(at: proseEnds[prose], in: styled)
                    out = Text("\(out)\(Text(AttributedString(styled[cursor..<end])))")
                    cursor = end
                    prose += 1
                }
            }
            return out
        }
        return Text(styled)
    }
}

/// The AppKit side of the veil, for `LinkTextView`: the same chunks, painted as temporary
/// foreground colours on the layout manager, which change no glyph and no line. A display
/// link repaints while anything is dissolving and is torn down the moment nothing is.
@MainActor
final class LinkTextVeil {
    private let veil = StreamVeil()
    private var displayLink: CADisplayLink?
    /// The widest character range temporary colours were laid over, cleared before each
    /// repaint and once the veil settles.
    private var painted = NSRange(location: 0, length: 0)
    private var source: String?
    private var utf16Offsets: [Int] = []

    private weak var tickTarget: NSTextView?
    /// The render scope of the column this paragraph sits in, subscribed for its
    /// visibility. Weak, so a scope discarded with its column is not held by a view
    /// that is only retiring.
    private weak var scope: VeilRenderScope?

    /// Feeds the text view's current text. `active` while the reply streams; afterwards
    /// the chunks in flight finish and the veil forgets the text.
    func update(_ view: NSTextView, active: Bool, scope: VeilRenderScope?) {
        subscribe(to: scope)
        let now = Date.now
        if source != view.string {
            source = view.string
            var offset = 0
            utf16Offsets = [0]
            for character in view.string {
                offset += String(character).utf16.count
                utf16Offsets.append(offset)
            }
            if active { veil.advance(view.string, at: now) }
        }
        if veil.isFading(at: now) {
            tickTarget = view
            // A hidden column records its arrivals but paints nothing and arms no
            // link: the scope repaints at the real time the moment it shows again.
            guard self.scope?.isVisible != false else { return }
            paint(view, at: now)
            if displayLink == nil { arm() }
        } else {
            settle(view, keepText: active)
        }
    }

    /// Stops the clock and leaves the scope; the view is leaving its column.
    func detach(_ view: NSTextView) {
        settle(view, keepText: false)
        scope?.remove(self)
        scope = nil
    }

    private func subscribe(to newScope: VeilRenderScope?) {
        guard newScope !== scope else { return }
        scope?.remove(self)
        scope = newScope
        newScope?.add(self)
        if newScope?.isVisible == false { scopeDidChangeVisibility(false) }
    }

    /// From the scope: the column's pane hid, or is about to show again. Hiding tears
    /// the link down; showing repaints at the real time before the pane can display, so
    /// no stale alpha is ever seen — and a fade that settled while hidden, whose paint
    /// was skipped, is cleared rather than left half-faded.
    func scopeDidChangeVisibility(_ visible: Bool) {
        if visible {
            guard let view = tickTarget else { return }
            if veil.isFading(at: .now) {
                paint(view, at: .now)
                if displayLink == nil { arm() }
            } else if painted.length > 0 {
                clear(view)
            }
        } else {
            displayLink?.invalidate()
            displayLink = nil
        }
    }

    private func arm() {
        guard scope?.isVisible != false, let view = tickTarget else { return }
        let link = view.displayLink(target: self, selector: #selector(tick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 24, preferred: 18)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @objc private func tick() {
        // The clock holds its last frame through a scroll, so the layout-manager repaint
        // does not run for frames the reader never sees; the ramp resumes when the scroll
        // ends.
        guard !ScrollActivity.shared.isScrolling, NSApp.isActive else { return }
        guard let view = tickTarget else {
            displayLink?.invalidate()
            displayLink = nil
            return
        }
        let now = Date.now
        if veil.isFading(at: now) {
            paint(view, at: now)
        } else {
            settle(view, keepText: true)
        }
    }

    private func settle(_ view: NSTextView, keepText: Bool) {
        displayLink?.invalidate()
        displayLink = nil
        clear(view)
        if !keepText { veil.reset(); source = nil; utf16Offsets = [] }
    }

    private func clear(_ view: NSTextView) {
        guard painted.length > 0, let layout = view.layoutManager else { return }
        let length = view.textStorage?.length ?? 0
        let range = NSIntersectionRange(painted, NSRange(location: 0, length: length))
        if range.length > 0 { layout.removeTemporaryAttribute(.foregroundColor, forCharacterRange: range) }
        painted = NSRange(location: 0, length: 0)
    }

    private func paint(_ view: NSTextView, at now: Date) {
        guard let layout = view.layoutManager, let storage = view.textStorage else { return }
        clear(view)
        let accent = Chrome.accentNSColor
        for span in veil.spans(at: now) where span.alpha < 1 {
            let range = span.range.clamped(to: 0..<max(0, utf16Offsets.count - 1))
            guard !range.isEmpty else { continue }
            let lower = utf16Offsets[range.lowerBound]
            let nsRange = NSRange(location: lower, length: utf16Offsets[range.upperBound] - lower)
            // Each run keeps its own colour, only thinner: prose its label colour, a link
            // the accent it is drawn in.
            storage.enumerateAttributes(in: nsRange) { attributes, runRange, _ in
                let color: NSColor = attributes[.link] != nil
                    ? accent
                    : (attributes[.foregroundColor] as? NSColor ?? .labelColor)
                layout.addTemporaryAttribute(.foregroundColor, value: color.withAlphaComponent(span.alpha), forCharacterRange: runRange)
            }
            painted = painted.length == 0 ? nsRange : NSUnionRange(painted, nsRange)
        }
    }
}
