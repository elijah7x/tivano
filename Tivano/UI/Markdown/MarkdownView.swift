import AppKit
import SwiftUI

enum MarkdownSegment: Equatable {
    case prose([MarkdownBlock])
    case block(MarkdownBlock)
}

@MainActor
@Observable
private final class StreamingParseCoordinator {
    @ObservationIgnored private var result: (text: String, parse: MarkdownParser.Parse)?
    /// Bumped only when a parse finished off the main thread lands, so the view redraws
    /// with it even if no more text arrives; the synchronous path writes nothing observed.
    private var landed = 0
    @ObservationIgnored private var requested: String?
    @ObservationIgnored private var pending: String?
    @ObservationIgnored private var running = false
    @ObservationIgnored private var generation = 0

    func parse(_ text: String) -> (blocks: [MarkdownBlock], stable: Int, generation: Int) {
        _ = landed
        if requested != text {
            if let requested, !text.utf8.starts(with: requested.utf8) {
                generation &+= 1
                result = nil
            }
            requested = text
            let tailSize = text.utf8.count - (result?.parse.restart ?? 0)
            if tailSize <= 4096 {
                pending = nil
                let parsed = MarkdownParser.parse(text, extending: result)
                result = (text, parsed)
                MarkdownView.rememberStreamingParse(text, parsed)
            } else {
                pending = text
                startNext()
            }
        }
        return (result?.parse.blocks ?? [], result?.parse.stable ?? 0, generation)
    }

    private func startNext() {
        guard !running, let text = pending else { return }
        pending = nil
        guard text != result?.text else { return }
        running = true
        let previous = result
        let generation = generation
        Task { [weak self] in
            let parsed = await Task.detached(priority: .userInitiated) {
                MarkdownParser.parse(text, extending: previous)
            }.value
            guard let self else { return }
            self.running = false
            // Append-only streams may outpace parsing indefinitely. Publish a completed
            // prefix, but never overwrite a newer synchronous parse or another text generation.
            if self.generation == generation,
               let requested = self.requested, requested.utf8.starts(with: text.utf8),
               self.result == nil || text.utf8.count > (self.result?.text.utf8.count ?? 0) {
                self.result = (text, parsed)
                MarkdownView.rememberStreamingParse(text, parsed)
                self.landed &+= 1
            }
            self.startNext()
        }
    }
}

private enum StreamingMarkdownSegment: Identifiable {
    case paragraphs(start: Int, end: Int, texts: [String])
    case block(index: Int, block: MarkdownBlock)

    var id: String {
        switch self {
        case .paragraphs(let start, _, _): "p-\(start)"
        case .block(let index, _): "b-\(index)"
        }
    }
}

@MainActor
private enum MarkdownMemoryPressure {
    private static var observer: (any NSObjectProtocol)?

    static func armIfNeeded() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: .memoryPressure, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                MarkdownView.clearCaches()
                RichLink.clearCaches()
                ProseRunRepresentable.clearCache()
                LinkParagraphView.clearCache()
                TableBlock.clearCache()
            }
        }
    }
}

struct MarkdownView: View, Equatable {
    let text: String
    static let warmCandidateLimit = 96
    /// True while the text is still arriving. A streaming message parses through a slot of
    /// its own instead of the shared cache: it changes on every flush, and each of those
    /// would otherwise take a cache entry away from a finished message that scrolling back
    /// through the thread will ask for again.
    var isStreaming = false
    @Environment(\.markdownPointSize) private var pointSize
    @Environment(\.markdownProseRuns) private var proseRuns
    @State private var sawStreaming = false
    @State private var streamingCoordinator = StreamingParseCoordinator()

    /// Equal text renders equally, so finished replies are skipped entirely while a
    /// new reply streams or the timeline rebuilds around them.
    nonisolated static func == (lhs: MarkdownView, rhs: MarkdownView) -> Bool {
        lhs.text == rhs.text && lhs.isStreaming == rhs.isStreaming
    }

    static func canMergeIntoProseRun(_ block: MarkdownBlock) -> Bool {
        switch block {
        case .heading, .paragraph:
            true
        case .list(_, _, let items):
            items.allSatisfy { $0.children.allSatisfy(canMergeIntoProseRun) }
        case .quote, .code, .table, .image, .rule:
            false
        }
    }

    static func segments(_ blocks: [MarkdownBlock]) -> [MarkdownSegment] {
        var out: [MarkdownSegment] = []
        var run: [MarkdownBlock] = []
        func close() {
            if !run.isEmpty {
                out.append(.prose(run))
                run = []
            }
        }
        for block in blocks {
            if canMergeIntoProseRun(block) {
                run.append(block)
            } else {
                close()
                out.append(.block(block))
            }
        }
        close()
        return out
    }

    static func interBlockGap(after previous: MarkdownBlock, before next: MarkdownBlock, pointSize: CGFloat) -> CGFloat {
        var total: CGFloat
        if case .heading(let level, _) = previous {
            total = TypeScale.proseHeadingBottomSpacing(pointSize, level: level)
        } else {
            total = TypeScale.proseParagraphSpacing(pointSize)
        }
        if case .heading(let nextLevel, _) = next {
            total += TypeScale.proseHeadingTopExtra(pointSize, level: nextLevel)
        }
        return total
    }

    private static func firstBlock(in segment: MarkdownSegment) -> MarkdownBlock? {
        switch segment {
        case .prose(let run): run.first
        case .block(let block): block
        }
    }

    private static func lastBlock(in segment: MarkdownSegment) -> MarkdownBlock? {
        switch segment {
        case .prose(let run): run.last
        case .block(let block): block
        }
    }

    private static func firstBlock(in segment: StreamingMarkdownSegment, blocks: [MarkdownBlock]) -> MarkdownBlock? {
        switch segment {
        case .paragraphs(let start, _, _): blocks.indices.contains(start) ? blocks[start] : nil
        case .block(_, let block): block
        }
    }

    private static func lastBlock(in segment: StreamingMarkdownSegment, blocks: [MarkdownBlock]) -> MarkdownBlock? {
        switch segment {
        case .paragraphs(_, let end, _): blocks.indices.contains(end) ? blocks[end] : nil
        case .block(_, let block): block
        }
    }

    private static func streamingSegments(_ blocks: [MarkdownBlock], mergeParagraphs: Bool) -> [StreamingMarkdownSegment] {
        var out: [StreamingMarkdownSegment] = []
        var runStart = 0
        var runTexts: [String] = []
        func close(at end: Int) {
            if !runTexts.isEmpty {
                out.append(.paragraphs(start: runStart, end: end, texts: runTexts))
                runTexts = []
            }
        }
        for (index, block) in blocks.enumerated() {
            if case .paragraph(let text) = block {
                if mergeParagraphs {
                    if runTexts.isEmpty { runStart = index }
                    runTexts.append(text)
                } else {
                    out.append(.paragraphs(start: index, end: index, texts: [text]))
                }
            } else {
                close(at: index - 1)
                out.append(.block(index: index, block: block))
            }
        }
        close(at: blocks.count - 1)
        return out
    }

    /// The lead's delegation card has faded out in place by the time its block leaves the
    /// reply (see `ThreadRuntime.holdSentDelegationBlock`), so it goes without a transition
    /// of its own and only the text below animates closing up: a removal that glided the
    /// card over that text drew it as a ghost. Every other block comes and goes with the soft appear.
    private static func transition(for block: MarkdownBlock) -> AnyTransition {
        if case .code(let language, _) = block, let info = language?.lowercased(), Self.isDelegationInfo(info) {
            return .asymmetric(insertion: .softAppear, removal: .identity)
        }
        return .softAppear
    }

    /// The info strings the delegation card wears: streaming or read, sent, and fading out.
    static func isDelegationInfo(_ info: String) -> Bool {
        info == "hydra" || info == "hydra-sent" || info == "hydra-leaving"
    }

    var body: some View {
        // While the text streams, the parse also says how many of its leading blocks are
        // final; those are the ones a flush cannot change, and the views for them are
        // compared by that fact alone (see `MarkdownBlockView.settled`).
        let parse = isStreaming ? streamingCoordinator.parse(text) : (blocks: Self.blocks(for: text), stable: 0, generation: 0)
        let blocks = parse.blocks
        let stable = parse.stable
        let last = blocks.count - 1
        let resolvedSize = pointSize == 0 ? TypeScale.shared.content(13) : pointSize
        if !isStreaming && !sawStreaming && proseRuns {
            let segments = Self.cachedSegments(for: text, blocks: blocks)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                    let topGap: CGFloat = {
                        guard index > 0,
                              let prevLastBlock = Self.lastBlock(in: segments[index - 1]),
                              let currFirstBlock = Self.firstBlock(in: segment) else { return 0 }
                        return Self.interBlockGap(after: prevLastBlock, before: currFirstBlock, pointSize: resolvedSize)
                    }()
                    Group {
                        switch segment {
                        case .prose(let run):
                            ProseRunView(blocks: run)
                                .equatable()
                        case .block(let block):
                            MarkdownBlockView(block: block)
                                .equatable()
                                .transition(Self.transition(for: block))
                        }
                    }
                    .padding(.top, topGap)
                }
            }
            .environment(\.markdownVeiled, isStreaming)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onChange(of: isStreaming) { _, streaming in if streaming { sawStreaming = true } }
        } else if isStreaming || sawStreaming {
            let streamSegments = Self.streamingSegments(blocks, mergeParagraphs: proseRuns)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(streamSegments.enumerated()), id: \.element.id) { index, segment in
                    let topGap: CGFloat = {
                        guard index > 0,
                              let prevLastBlock = Self.lastBlock(in: streamSegments[index - 1], blocks: blocks),
                              let currFirstBlock = Self.firstBlock(in: segment, blocks: blocks) else { return 0 }
                        return Self.interBlockGap(after: prevLastBlock, before: currFirstBlock, pointSize: resolvedSize)
                    }()
                    Group {
                        switch segment {
                        case .paragraphs(_, let end, let texts):
                            StreamingProseRunView(
                                paragraphs: texts,
                                isStreamingTail: isStreaming && end == last,
                                settled: end < stable,
                                generation: parse.generation
                            )
                            .equatable()
                            .transition(.softAppear)
                        case .block(let index, let block):
                            MarkdownBlockView(block: block, settled: index < stable, generation: parse.generation)
                                .equatable()
                                // Only the block still being written is streaming; the ones above it are
                                // settled and cache like any finished text.
                                .environment(\.markdownStreaming, isStreaming && index == last)
                                .transition(Self.transition(for: block))
                        }
                    }
                    .padding(.top, topGap)
                }
            }
            // Every block of a streaming reply veils what arrives (see `StreamVeil`), not only
            // the last: a paragraph that just closed keeps dissolving its tail instead of
            // snapping the moment the next block starts.
            .environment(\.markdownVeiled, isStreaming)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onAppear { if isStreaming { sawStreaming = true } }
            .onChange(of: isStreaming) { _, streaming in if streaming { sawStreaming = true } }
            .onDisappear { sawStreaming = false }
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                    MarkdownBlockView(block: block)
                        .equatable()
                        .transition(Self.transition(for: block))
                        .padding(.top, index == 0 ? 0 : Self.interBlockGap(after: blocks[index - 1], before: block, pointSize: resolvedSize))
                }
            }
            .environment(\.markdownVeiled, false)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onChange(of: isStreaming) { _, streaming in if streaming { sawStreaming = true } }
        }
    }

    /// Parsed blocks by source. Rows are rebuilt as they scroll into view, but a finished
    /// message parses to the same blocks, so each distinct text parses once.
    @MainActor private static var blockCache = RecentCache<String, [MarkdownBlock]>(limit: 800, costLimit: 24 * 1024 * 1024, entryCostLimit: 3 * 1024 * 1024)
    @MainActor private static var segmentCache = RecentCache<String, [MarkdownSegment]>(limit: 800, costLimit: 12 * 1024 * 1024, entryCostLimit: 2 * 1024 * 1024)
    /// Latest parses supplied by streaming coordinators, newest last, for reuse when
    /// streaming ends. Slots let a lead and its heads retain their parses together.
    @MainActor private static var streamingParses: [(text: String, parse: MarkdownParser.Parse)] = []
    /// Enough for a lead and a whole team of heads streaming in its panel at once. With
    /// four slots, twenty heads evicted each other's parse on every flush and every
    /// render parsed its reply from the start again, on the main thread.
    nonisolated fileprivate static let streamingSlots = 48

    @MainActor
    fileprivate static func clearCaches() {
        blockCache = RecentCache<String, [MarkdownBlock]>(limit: 800, costLimit: 24 * 1024 * 1024, entryCostLimit: 3 * 1024 * 1024)
        segmentCache = RecentCache<String, [MarkdownSegment]>(limit: 800, costLimit: 12 * 1024 * 1024, entryCostLimit: 2 * 1024 * 1024)
        streamingParses.removeAll()
    }

    @MainActor
    private static func cachedSegments(for text: String, blocks: [MarkdownBlock]) -> [MarkdownSegment] {
        if let hit = segmentCache.value(for: text) { return hit }
        let built = segments(blocks)
        segmentCache.insert(built, for: text, cost: max(64, text.utf8.count * 2))
        return built
    }

    /// Pre-builds AppKit prose attributed strings for finished messages off the scroll path,
    /// pausing whenever the reader is scrolling so background warmups never drop a frame.
    @MainActor
    static func warmProseRuns(_ texts: some Sequence<String>, mentions: [HydraPersona], targets: [String: HydraMentionTarget]) async {
        MarkdownMemoryPressure.armIfNeeded()
        let pointSize = (TypeScale.shared.content(13) * 2).rounded() / 2
        var seen = Set<String>()
        var processed = 0
        for text in texts.prefix(warmCandidateLimit) {
            guard !Task.isCancelled else { return }
            guard seen.insert(text).inserted else { continue }
            while ScrollActivity.shared.isScrolling {
                try? await Task.sleep(for: .milliseconds(30))
                guard !Task.isCancelled else { return }
            }
            guard let blocks = blockCache.value(for: text) else { continue }
            for segment in cachedSegments(for: text, blocks: blocks) {
                guard !Task.isCancelled else { return }
                if case .prose(let run) = segment {
                    _ = ProseRunRepresentable.prepare(
                        blocks: run,
                        pointSize: pointSize,
                        dimmed: false,
                        mentions: mentions,
                        targets: targets
                    )
                }
            }
            processed += 1
            if processed % 3 == 0 {
                await Task.yield()
            }
        }
    }

    @MainActor
    fileprivate static func rememberStreamingParse(_ text: String, _ parse: MarkdownParser.Parse) {
        MarkdownMemoryPressure.armIfNeeded()
        if let slot = streamingParses.lastIndex(where: { $0.text == text }) {
            streamingParses[slot] = (text, parse)
            return
        }
        let slot = streamingParses.lastIndex { extends($0.text, to: text) }
        if let slot { streamingParses.remove(at: slot) } else if streamingParses.count == streamingSlots { streamingParses.removeFirst() }
        streamingParses.append((text, parse))
    }

    /// Reuses a coordinator's completed streaming parse before caching finished blocks.
    @MainActor
    static func blocks(for text: String) -> [MarkdownBlock] {
        MarkdownMemoryPressure.armIfNeeded()
        if let cached = blockCache.value(for: text) { return cached }
        // A message that just finished streaming is already parsed; keep that parse.
        let parsed: [MarkdownBlock]
        if let slot = streamingParses.lastIndex(where: { $0.text == text }) {
            parsed = streamingParses.remove(at: slot).parse.blocks
        } else if let slot = streamingParses.lastIndex(where: { extends($0.text, to: text) }) {
            let previous = streamingParses.remove(at: slot)
            parsed = MarkdownParser.parse(text, extending: (previous.text, previous.parse)).blocks
        } else {
            parsed = MarkdownParser.parse(text)
        }
        blockCache.insert(parsed, for: text, cost: text.utf8.count * 3)
        return parsed
    }

    /// Whether `text` is `earlier` with more streamed onto its end. A streamed reply only
    /// ever grows, so the head and the tail of the earlier text are compared where they
    /// sit in the new one, rather than every byte of a reply that runs to tens of
    /// kilobytes on every render.
    private static func extends(_ earlier: String, to text: String) -> Bool {
        let earlierCount = earlier.utf8.count
        let count = text.utf8.count
        guard earlierCount > 0, earlierCount < count else { return false }
        let probe = 64
        if earlierCount <= probe * 2 { return text.utf8.starts(with: earlier.utf8) }
        let earlierBytes = earlier.utf8
        let bytes = text.utf8
        if !bytes.prefix(probe).elementsEqual(earlierBytes.prefix(probe)) { return false }
        let earlierTail = earlierBytes.suffix(probe)
        let tailStart = bytes.index(bytes.startIndex, offsetBy: earlierCount - probe)
        let tailEnd = bytes.index(tailStart, offsetBy: probe)
        return bytes[tailStart..<tailEnd].elementsEqual(earlierTail)
    }

    /// Parses finished messages before their rows are built, off the main thread, so a row
    /// scrolling into view finds its blocks and its paragraphs' runs already made instead of
    /// parsing them on the frame. Texts already cached cost nothing.
    @MainActor
    static func warm(_ texts: some Sequence<String>) async throws {
        MarkdownMemoryPressure.armIfNeeded()
        try Task.checkCancellation()
        let missing = warmTexts(texts)
        guard !missing.isEmpty else { return }
        let parsed = try await parseWarm(missing)
        try Task.checkCancellation()
        for (text, blocks, inline) in parsed {
            try Task.checkCancellation()
            if !blockCache.contains(text) { blockCache.insert(blocks, for: text, cost: text.utf8.count * 3) }
            for (source, pretty) in inline {
                try Task.checkCancellation()
                RichLink.warm(source, with: pretty)
            }
        }
    }

    @MainActor
    static func isCached(_ text: String) -> Bool {
        blockCache.contains(text)
    }

    @MainActor
    static func warmTexts(_ texts: some Sequence<String>) -> [String] {
        var missing: [String] = []
        var seen: Set<String> = []
        var remainingBytes = 1_048_576
        for text in texts.prefix(warmCandidateLimit) {
            let bytes = text.utf8.prefix(262_145).count
            guard bytes <= 262_144, bytes <= remainingBytes,
                  !blockCache.contains(text), seen.insert(text).inserted else { continue }
            missing.append(text)
            remainingBytes -= bytes
            if missing.count == 24 { break }
        }
        return missing
    }

    @concurrent
    private nonisolated static func parseWarm(_ texts: [String]) async throws -> [(String, [MarkdownBlock], [(String, AttributedString)])] {
        var parsed: [(String, [MarkdownBlock], [(String, AttributedString)])] = []
        var seenInline: Set<String> = []
        for text in texts {
            try Task.checkCancellation()
            let blocks = MarkdownParser.parse(text)
            var sources: Set<String> = []
            try inlineSources(of: blocks, into: &sources)
            var inline: [(String, AttributedString)] = []
            for source in sources where seenInline.insert(source).inserted {
                try Task.checkCancellation()
                inline.append((source, RichLink.build(source)))
            }
            parsed.append((text, blocks, inline))
        }
        try Task.checkCancellation()
        return parsed
    }

    nonisolated private static func inlineSources(of blocks: [MarkdownBlock], into sources: inout Set<String>) throws {
        for block in blocks {
            try Task.checkCancellation()
            switch block {
            case .paragraph(let text), .heading(_, let text):
                sources.insert(text)
            case .list(_, _, let items):
                for item in items {
                    try Task.checkCancellation()
                    if !item.text.isEmpty { sources.insert(item.text) }
                    try inlineSources(of: item.children, into: &sources)
                }
            case .quote(let inner):
                try inlineSources(of: inner, into: &sources)
            case .code, .table, .image, .rule:
                break
            }
        }
    }
}

struct MarkdownBlockView: View, Equatable {
    let block: MarkdownBlock
    /// The parser said this block is final: no later flush of the same streaming reply can
    /// change it (see `MarkdownParser.Parse.stable`). Two settled views in the same slot
    /// are therefore the same block, and comparing their content -- every byte of every
    /// earlier block of the reply, on every flush -- is work the flush does not need.
    var settled = false
    var generation = 0
    @Environment(\.markdownPointSize) private var pointSize
    @Environment(\.markdownDimmed) private var dimmed
    @Environment(\.markdownListDepth) private var listDepth
    @Environment(\.markdownStreaming) private var streaming
    @Environment(\.hydraMentionPersonas) private var hydraMentionPersonas
    @Environment(\.hydraMentionTargets) private var hydraMentionTargets

    /// Blocks compare by content, so a finished block is skipped while the reply keeps streaming.
    /// A settled pair skips that comparison: the position and the parser's own word are
    /// enough (see `settled`). Anything not settled -- the block still being written, and
    /// every block of a finished message -- compares as it always has.
    nonisolated static func == (lhs: MarkdownBlockView, rhs: MarkdownBlockView) -> Bool {
        if lhs.settled, rhs.settled, lhs.generation == rhs.generation { return true }
        return lhs.block == rhs.block
    }

    var body: some View {
        let resolvedSize = pointSize == 0 ? TypeScale.shared.content(13) : pointSize
        Group {
            switch block {
            case .heading(let level, let text):
                let size = TypeScale.proseHeadingPointSize(resolvedSize, level: level)
                InlineText(text, lineSpacingOverride: TypeScale.proseHeadingLineSpacing(size))
                    .font(Self.proseFont(pointSize: size, weight: .semibold))
                    .environment(\.markdownPointSize, size)
            case .paragraph(let text):
                // Every head named anywhere in the paragraph is decorated inline: glyph +
                // coloured bold name inside one flowing Text, with only the prose veiled.
                // Only the AppKit paragraph can say what is under the pointer, so a finished
                // paragraph naming a head takes that path; while streaming the SwiftUI path
                // keeps its veil and still opens the chat on click.
                if RichLink.containsLinks(in: text, streaming: streaming) {
                    InlineText(text, hasLinks: true)
                } else if !streaming, listDepth == 0, mentionsTarget(in: text) {
                    InlineText(text, hasLinks: true)
                } else if listDepth == 0, let segments = mentionSegments(in: text) {
                    VeiledText(segments: segments)
                        .lineSpacing(TypeScale.proseLineSpacing(resolvedSize))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    InlineText(text, hasLinks: false)
                }
            case .code(let language, let code):
                // The lead's delegation block (info string `hydra`) is a brief for the team, not
                // code: it reads as a card while it streams and whenever it stays in the reply.
                if let info = language?.lowercased(), MarkdownView.isDelegationInfo(info), let delegationRenderer = MarkdownDelegationCard.render {
                    // `hydra-leaving`: the card fades where it stands, still taking up its room,
                    // before the block leaves the reply and the text below closes up.
                    delegationRenderer(code, info != "hydra")
                        .opacity(info == "hydra-leaving" ? 0 : 1)
                        .scaleEffect(info == "hydra-leaving" ? 0.98 : 1, anchor: .top)
                        .allowsHitTesting(info != "hydra-leaving")
                } else {
                    CodeBlock(language: language, code: code)
                }
            case .list(let ordered, let start, let items):
                let metrics = TypeScale.proseListMetrics(pointSize: resolvedSize, ordered: ordered, start: start, count: items.count)
                let childGap = TypeScale.proseListChildSpacing(resolvedSize)
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                        HStack(alignment: .firstTextBaseline, spacing: metrics.gap) {
                            marker(ordered: ordered, number: start + index, checked: item.checked, pointSize: resolvedSize)
                                .frame(minWidth: metrics.slotWidth, alignment: ordered && item.checked == nil ? .trailing : .center)
                            VStack(alignment: .leading, spacing: childGap) {
                                if !item.text.isEmpty { InlineText(item.text, hasLinks: RichLink.containsLinks(in: item.text, streaming: streaming)) }
                                ForEach(Array(item.children.enumerated()), id: \.offset) { _, child in
                                    MarkdownBlockView(block: child)
                                        .equatable()
                                }
                            }
                            // Nested lists read one level deeper, so their dots turn into rings.
                            .environment(\.markdownListDepth, listDepth + 1)
                        }
                        .padding(.bottom, index == items.count - 1 ? 0 : (listDepth == 0 && !item.children.isEmpty ? TypeScale.proseListGroupSpacing(resolvedSize) : TypeScale.proseListItemSpacing(resolvedSize, depth: listDepth)))
                    }
                }
            case .quote(let blocks):
                let quoteGap = TypeScale.proseQuoteSpacing(resolvedSize)
                let barWidth = max(2.5, (resolvedSize * 0.2).rounded())
                HStack(alignment: .top, spacing: quoteGap) {
                    Capsule().fill(.quaternary).frame(width: barWidth)
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(blocks.enumerated()), id: \.offset) { idx, child in
                            MarkdownBlockView(block: child)
                                .equatable()
                                .padding(.top, idx == 0 ? 0 : (Self.isHeading(blocks[idx - 1]) || Self.isHeading(child) ? MarkdownView.interBlockGap(after: blocks[idx - 1], before: child, pointSize: resolvedSize) : quoteGap))
                        }
                    }
                    .padding(.vertical, 2)
                }
                .foregroundStyle(Chrome.secondaryText)
                .environment(\.markdownDimmed, true)
            case .table(let header, let rows):
                TableBlock(header: header, rows: rows)
            case .image(let alt, let source):
                MarkdownImageBlock(alt: alt, source: source)
            case .rule:
                Rectangle()
                    .fill(.quaternary)
                    .frame(height: 1)
                    .padding(.vertical, (resolvedSize * 0.35).rounded())
            }
        }
        .font(Self.proseFont(pointSize: pointSize))
    }

    fileprivate static func proseFont(pointSize: CGFloat, weight: Font.Weight = .regular) -> Font {
        let resolved = pointSize == 0 ? TypeScale.shared.content(13) : pointSize
        guard TypeScale.shared.serif else { return .system(size: resolved, weight: weight) }
        let scaled = (resolved * 2).rounded() / 2
        return Font(ThemeTypeface.nsFont(size: scaled, weight: ThemeTypeface.weight(weight)) as CTFont)
    }

    private static func isHeading(_ block: MarkdownBlock) -> Bool {
        if case .heading = block { return true }
        return false
    }

    /// The glyph's size and drop: the font's own line, from its descender up, the same
    /// box the AppKit paragraph gives it (`LinkParagraphView.appendProse`), so the line
    /// it sits on is no taller than the others and nothing moves when streaming ends.
    private static func mentionGlyphMetrics(pointSize: CGFloat) -> (size: CGFloat, offset: CGFloat) {
        let font = ThemeTypeface.nsFont(size: pointSize)
        return ((font.ascender - font.descender).rounded(.down), font.descender)
    }

    /// The head's dragon as a template image small enough to sit in a Text run.
    /// Redrawn once per (asset, size), then kept; tinted like the name.
    @MainActor
    static func mentionGlyph(_ persona: HydraPersona, size: CGFloat) -> Image {
        let key = persona.asset + "@\(size)"
        if let cached = glyphCache[key] { return cached }
        // Drawn on demand rather than into fixed pixels, so it stays crisp on any display.
        let source = NSImage(named: persona.asset)
        let out = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            source?.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
            return true
        }
        out.isTemplate = true
        let image = Image(nsImage: out).renderingMode(.template)
        glyphCache[key] = image
        return image
    }

    @MainActor private static var glyphCache: [String: Image] = [:]

    private struct MentionTargetKey: Hashable {
        let text: String
        let names: [String]
    }

    private struct MentionSegmentsKey: Hashable {
        let text: String
        let personas: [HydraPersona]
        let targetURLs: [String: URL]
        let pointSize: CGFloat
        let codePointSize: CGFloat
    }

    @MainActor private static var mentionTargetCache = RecentCache<MentionTargetKey, Bool>(limit: 512)
    @MainActor private static var mentionSegmentsCache = RecentCache<MentionSegmentsKey, [VeiledText.Segment]?>(limit: 512)

    /// Every head name mentioned anywhere in the paragraph, as prose/fixed segments so
    /// each renders as glyph + coloured bold name inline in one flowing Text. Matches are
    /// word-bounded (never another letter) and longest-name-first, so 'Hank 2' beats 'Hank'.
    private func mentionsTarget(in text: String) -> Bool {
        guard !hydraMentionTargets.isEmpty else { return false }
        let names = hydraMentionTargets.keys.sorted()
        let key = MentionTargetKey(text: text, names: names)
        if let hit = Self.mentionTargetCache.value(for: key) { return hit }
        let result = !Self.mentionRanges(in: text, names: names).isEmpty
        Self.mentionTargetCache.insert(result, for: key)
        return result
    }

    /// Word-bounded ranges of any of `names` in `text`, longest-name-first, so
    /// 'Hank 2' beats 'Hank'.
    nonisolated static func mentionRanges(in text: String, names: [String]) -> [Range<String.Index>] {
        MentionScanner.matches(in: text, candidates: names, name: { $0 }).map(\.range)
    }
    private func mentionSegments(in text: String) -> [VeiledText.Segment]? {
        guard !hydraMentionPersonas.isEmpty else { return nil }
        let resolvedPointSize = pointSize == 0 ? TypeScale.shared.content(13) : pointSize
        let codePointSize = TypeScale.shared.code(12)
        let key: MentionSegmentsKey?
        if !streaming {
            let candidate = MentionSegmentsKey(
                text: text,
                personas: hydraMentionPersonas,
                targetURLs: hydraMentionTargets.mapValues(\.url),
                pointSize: resolvedPointSize,
                codePointSize: codePointSize
            )
            if let hit = Self.mentionSegmentsCache.value(for: candidate) { return hit }
            key = candidate
        } else {
            key = nil
        }
        let pretty = RichLink.scaledPrettyAttributed(text, codePointSize: codePointSize, streaming: streaming)
        let chars = String(pretty.characters)
        let matches = MentionScanner.matches(in: chars, candidates: hydraMentionPersonas, name: \.name)
        let segments: [VeiledText.Segment]?
        if matches.isEmpty {
            segments = nil
        } else {
            func prettyRange(_ r: Range<String.Index>) -> Range<AttributedString.Index> {
                let lo = chars.distance(from: chars.startIndex, to: r.lowerBound)
                let hi = chars.distance(from: chars.startIndex, to: r.upperBound)
                let base = pretty.characters
                return base.index(base.startIndex, offsetBy: lo)..<base.index(base.startIndex, offsetBy: hi)
            }
            var built: [VeiledText.Segment] = []
            var cursor = chars.startIndex
            for match in matches {
                if cursor < match.range.lowerBound {
                    built.append(.prose(AttributedString(pretty[prettyRange(cursor..<match.range.lowerBound)])))
                }
                built.append(.fixed(mentionText(match.value, pointSize: resolvedPointSize)))
                cursor = match.range.upperBound
            }
            if cursor < chars.endIndex {
                built.append(.prose(AttributedString(pretty[prettyRange(cursor..<chars.endIndex)])))
            }
            segments = built
        }
        if let key {
            Self.mentionSegmentsCache.insert(segments, for: key)
        }
        return segments
    }

    private func mentionText(_ persona: HydraPersona, pointSize resolvedPointSize: CGFloat) -> Text {
        let metrics = Self.mentionGlyphMetrics(pointSize: resolvedPointSize)
        let glyph = Text(Self.mentionGlyph(persona, size: metrics.size))
            .foregroundColor(persona.color)
            .baselineOffset(metrics.offset)
        // A link in a Text keeps the colour the attribute sets and opens through the environment.
        if let target = hydraMentionTargets[persona.name] {
            var name = AttributedString(persona.name)
            name.link = target.url
            name.foregroundColor = persona.color
            name.inlinePresentationIntent = .stronglyEmphasized
            return Text("\(glyph) \(Text(name))")
        }
        let name = Text(verbatim: persona.name).fontWeight(.bold).foregroundColor(persona.color)
        return Text("\(glyph) \(name)")
    }

    @ViewBuilder
    private func marker(ordered: Bool, number: Int, checked: Bool?, pointSize: CGFloat) -> some View {
        if let checked {
            Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                .font(.system(size: (pointSize * 0.92).rounded(), weight: .medium))
                .foregroundStyle(checked ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
        } else if ordered {
            Text("\(number).")
                .monospacedDigit()
                .fontWeight(.medium)
                .foregroundStyle(markerColor)
        } else {
            // A hidden bullet glyph keeps the text baseline; the dot drawn over it is the
            // marker, in the theme accent. Nested levels get a ring instead of a fill.
            Text("•")
                .hidden()
                .overlay {
                    if listDepth == 0 {
                        let diameter = TypeScale.proseBulletDiameter(pointSize, hollow: false)
                        Circle()
                            .fill(markerColor)
                            .frame(width: diameter, height: diameter)
                    } else {
                        let diameter = TypeScale.proseBulletDiameter(pointSize, hollow: true)
                        Circle()
                            .strokeBorder(markerColor, lineWidth: max(1.1, (pointSize * 0.085 * 10).rounded() / 10))
                            .frame(width: diameter, height: diameter)
                    }
                }
        }
    }

    private var markerColor: Color {
        Chrome.accent.opacity(dimmed ? 0.55 : 0.9)
    }
}

/// How many lists the block sits inside; the marker style follows it.
private struct MarkdownListDepthKey: EnvironmentKey {
    static let defaultValue = 0
}

/// Draws a `hydra` delegation block. The card is an App view that UI can't name, so the
/// app sets this at launch; until then the block reads as code.
enum MarkdownDelegationCard {
    @MainActor static var render: ((String, Bool) -> AnyView)?
}

extension EnvironmentValues {
    @Entry var hydraMentionPersonas: [HydraPersona] = []
    /// The heads this chat sent out, by persona name, for the hover card and the click.
    @Entry var hydraMentionTargets: [String: HydraMentionTarget] = [:]
    var markdownListDepth: Int {
        get { self[MarkdownListDepthKey.self] }
        set { self[MarkdownListDepthKey.self] = newValue }
    }
}

/// Pretty link titles plus favicons for chat markdown.
///
/// Bare URLs (`https://…`) used to fill the row. The rule: show the title
/// (an explicit `[title](url)` or the host and path without a scheme) with the
/// favicon in front.
enum RichLink {
    private struct ScaledKey: Hashable {
        let source: String
        let codePointSize: CGFloat
    }

    @MainActor private static var prettyCache = RecentCache<String, AttributedString>(limit: 1200, costLimit: 16 * 1024 * 1024, entryCostLimit: 2 * 1024 * 1024)
    @MainActor private static var scaledCache = RecentCache<ScaledKey, AttributedString>(limit: 1200, costLimit: 16 * 1024 * 1024, entryCostLimit: 2 * 1024 * 1024)
    @MainActor private static var scaledSizes: Set<CGFloat> = []
    /// The paragraphs still being streamed, kept apart so their every flush leaves the
    /// cache alone. Extending a source reuses its slot instead of retaining every prefix
    /// or evicting another stream; independent streams share `MarkdownView`'s parse-slot budget.
    @MainActor private static var streamingPretty: [(source: String, value: AttributedString)] = []
    @MainActor private static var streamingScaled: [(source: String, codePointSize: CGFloat, value: AttributedString)] = []
    private static let streamingSlots = MarkdownView.streamingSlots

    @MainActor static private(set) var assetGeneration = 0

    @MainActor
    static func bumpAssetGeneration() {
        assetGeneration &+= 1
    }

    @MainActor
    static func armMemoryPressure() {
        MarkdownMemoryPressure.armIfNeeded()
    }

    @MainActor
    fileprivate static func clearCaches() {
        prettyCache = RecentCache<String, AttributedString>(limit: 1200, costLimit: 16 * 1024 * 1024, entryCostLimit: 2 * 1024 * 1024)
        streamingPretty.removeAll()
        assetGeneration &+= 1
    }

    @MainActor
    static func prettyAttributed(_ source: String, streaming: Bool = false) -> AttributedString {
        MarkdownMemoryPressure.armIfNeeded()
        if streaming {
            if let pretty = streamingPretty.last(where: { $0.source == source }) { return pretty.value }
            // Synthetic closers affect display only, never the source or cache key.
            let value = build(StreamMend.mended(source))
            if let slot = streamingPretty.lastIndex(where: { source.hasPrefix($0.source) }) {
                streamingPretty[slot] = (source, value)
            } else {
                if streamingPretty.count == streamingSlots { streamingPretty.removeFirst() }
                streamingPretty.append((source, value))
            }
            return value
        }
        if let hit = prettyCache.value(for: source) { return hit }
        let value: AttributedString
        if let slot = streamingPretty.lastIndex(where: { $0.source == source }) {
            let streamed = streamingPretty.remove(at: slot).value
            // Truly unclosed markup must settle as written, not as its streamed preview.
            value = StreamMend.mended(source) == source ? streamed : build(source)
        } else {
            value = build(source)
        }
        prettyCache.insert(value, for: source, cost: source.utf8.count * 3)
        return value
    }

    @MainActor
    static func scaledPrettyAttributed(_ source: String, pretty: AttributedString? = nil, codePointSize: CGFloat, streaming: Bool = false) -> AttributedString {
        if streaming {
            if let hit = streamingScaled.last(where: { $0.source == source && $0.codePointSize == codePointSize }) {
                return hit.value
            }
            let base = pretty ?? prettyAttributed(source, streaming: true)
            let scaled = InlineText.scaledInlineCode(base, pointSize: codePointSize)
            if let slot = streamingScaled.lastIndex(where: {
                $0.codePointSize == codePointSize && source.hasPrefix($0.source)
            }) {
                streamingScaled[slot] = (source, codePointSize, scaled)
            } else {
                if streamingScaled.count == streamingSlots { streamingScaled.removeFirst() }
                streamingScaled.append((source, codePointSize, scaled))
            }
            return scaled
        }
        let key = ScaledKey(source: source, codePointSize: codePointSize)
        if let hit = scaledCache.value(for: key) { return hit }
        let base = pretty ?? prettyAttributed(source, streaming: false)
        let scaled = InlineText.scaledInlineCode(base, pointSize: codePointSize)
        if scaledSizes.count >= 32 {
            scaledSizes.removeAll(keepingCapacity: true)
            scaledCache = RecentCache<ScaledKey, AttributedString>(limit: 1200, costLimit: 16 * 1024 * 1024, entryCostLimit: 2 * 1024 * 1024)
        }
        scaledSizes.insert(codePointSize)
        scaledCache.insert(scaled, for: key, cost: source.utf8.count * 3)
        return scaled
    }

    /// Stores a run built off the main thread (see `MarkdownView.warm`).
    @MainActor
    static func warm(_ source: String, with pretty: AttributedString) {
        if !prettyCache.contains(source) { prettyCache.insert(pretty, for: source, cost: source.utf8.count * 3) }
    }

    nonisolated static func build(_ source: String) -> AttributedString {
        let base = baseAttributed(source)
        guard base.runs.contains(where: { $0.link != nil }) else { return base }
        var result = AttributedString()
        for run in base.runs {
            let slice = AttributedString(base[run.range])
            guard let url = run.link else {
                result.append(slice)
                continue
            }
            let display = String(slice.characters)
            var linkSlice: AttributedString
            if isBareDisplay(display, url: url) {
                linkSlice = AttributedString(prettyTitle(for: url))
                linkSlice.link = url
            } else {
                linkSlice = slice
            }
            // Every link renders bold, whether the author titled it or the
            // URL was bare. Other intent bits (italic, code) are preserved.
            var intent = run.inlinePresentationIntent ?? []
            intent.insert(.stronglyEmphasized)
            linkSlice.inlinePresentationIntent = intent
            result.append(linkSlice)
        }
        return result
    }

    @MainActor
    private static func collectLinkAssets(
        from source: String,
        streaming: Bool,
        hosts: inout [String],
        seenHosts: inout Set<String>,
        videos: inout [String],
        seenVideos: inout Set<String>
    ) {
        guard !source.isEmpty else { return }
        let pretty = prettyAttributed(source, streaming: streaming)
        for run in pretty.runs {
            guard let link = run.link else { continue }
            if let host = link.host?.lowercased(), !host.isEmpty, seenHosts.insert(host).inserted {
                hosts.append(host)
            }
            if let id = LinkTitles.videoID(for: link), seenVideos.insert(id).inserted {
                videos.append(id)
            }
        }
    }

    @MainActor
    static func linkAssets(for source: String, streaming: Bool = false) -> (hosts: [String], videos: [String]) {
        var hosts: [String] = []
        var seenHosts = Set<String>()
        var videos: [String] = []
        var seenVideos = Set<String>()
        collectLinkAssets(from: source, streaming: streaming, hosts: &hosts, seenHosts: &seenHosts, videos: &videos, seenVideos: &seenVideos)
        return (hosts, videos)
    }

    @MainActor
    static func linkHosts(for source: String, streaming: Bool = false) -> [String] {
        let pretty = prettyAttributed(source, streaming: streaming)
        var hosts: [String] = []
        var seen = Set<String>()
        for run in pretty.runs {
            if let host = run.link?.host?.lowercased(), !host.isEmpty, seen.insert(host).inserted {
                hosts.append(host)
            }
        }
        return hosts
    }

    /// The video ids a paragraph's links carry, first-seen order, each once.
    @MainActor
    static func videoIDs(for source: String, streaming: Bool = false) -> [String] {
        let pretty = prettyAttributed(source, streaming: streaming)
        var ids: [String] = []
        var seen = Set<String>()
        for run in pretty.runs {
            guard let link = run.link, let id = LinkTitles.videoID(for: link), seen.insert(id).inserted else { continue }
            ids.append(id)
        }
        return ids
    }

    /// What keys the paragraph's link work: hosts and video ids together, empty when
    /// there is neither, so a caller's `isEmpty` test still means something.
    @MainActor
    static func linkAssetKey(for source: String, streaming: Bool = false) -> String {
        let (hosts, videos) = linkAssets(for: source, streaming: streaming)
        guard !(hosts.isEmpty && videos.isEmpty) else { return "" }
        return hosts.joined(separator: ",") + "|" + videos.joined(separator: ",")
    }

    /// Collects unique hosts and video IDs across individual block strings so multi-paragraph
    /// runs hit `prettyCache` per paragraph instead of re-parsing a joined string.
    @MainActor
    static func linkAssetKey(forEach sources: [String], streamingLast: Bool = false) -> String {
        linkAssetDetails(forEach: sources, streamingLast: streamingLast).key
    }

    @MainActor
    static func linkAssetPlan(for source: String, streaming: Bool = false) -> (key: String, needsFetch: Bool) {
        let (hosts, videos) = linkAssets(for: source, streaming: streaming)
        guard !(hosts.isEmpty && videos.isEmpty) else { return ("", false) }
        let needsFetch = hosts.contains(where: { FaviconCache.needsFetch(host: $0) })
            || videos.contains(where: { LinkTitles.needsFetch(videoID: $0) })
        return (hosts.joined(separator: ",") + "|" + videos.joined(separator: ","), needsFetch)
    }

    @MainActor
    static func linkAssetPlan(forEach sources: [String], streamingLast: Bool = false) -> (key: String, needsFetch: Bool) {
        let details = linkAssetDetails(forEach: sources, streamingLast: streamingLast)
        return (details.key, details.needsFetch)
    }

    @MainActor
    static func linkAssetDetails(forEach sources: [String], streamingLast: Bool = false) -> (key: String, hosts: [String], videos: [String], needsFetch: Bool) {
        var hosts: [String] = []
        var seenHosts = Set<String>()
        var videos: [String] = []
        var seenVideos = Set<String>()
        let lastIndex = sources.count - 1
        for (index, source) in sources.enumerated() {
            collectLinkAssets(
                from: source,
                streaming: streamingLast && index == lastIndex,
                hosts: &hosts,
                seenHosts: &seenHosts,
                videos: &videos,
                seenVideos: &seenVideos
            )
        }
        guard !(hosts.isEmpty && videos.isEmpty) else { return ("", [], [], false) }
        let needsFetch = hosts.contains(where: { FaviconCache.needsFetch(host: $0) })
            || videos.contains(where: { LinkTitles.needsFetch(videoID: $0) })
        return (hosts.joined(separator: ",") + "|" + videos.joined(separator: ","), hosts, videos, needsFetch)
    }

    /// Drops a paragraph's warmed pretty strings, so a landed video title shows.
    @MainActor
    static func invalidate(_ source: String) {
        prettyCache.removeValue(for: source)
        streamingPretty.removeAll { $0.source == source }
        for size in scaledSizes {
            scaledCache.removeValue(for: ScaledKey(source: source, codePointSize: size))
        }
        streamingScaled.removeAll { $0.source == source }
        assetGeneration &+= 1
    }

    /// Short display title for a bare URL. Forge links collapse to their
    /// native reference (`!3190`, `#123`); a video link reads as the video's
    /// own title once it has been fetched; everything else keeps the host
    /// plus the last path segment, so a deep path never spills into chat.
    static func prettyTitle(for url: URL) -> String {
        if let reference = forgeReference(for: url) { return reference }
        if let title = LinkTitles.cached(for: url) { return capped(title, at: 48) }
        guard var host = url.host?.lowercased(), !host.isEmpty else {
            return compactFallback(url.absoluteString)
        }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        let segments = (url.path.removingPercentEncoding ?? url.path)
            .split(separator: "/")
            .map(String.init)
            .filter { !$0.isEmpty }
        guard let last = segments.last else { return host }
        if namelessSegments.contains(last.lowercased()) { return host }
        let tail = last.count > 24 ? String(last.prefix(21)) + "…" : last
        let title = segments.count == 1 ? host + "/" + tail : host + "/…/" + tail
        if title.count > 40 {
            return String(title.prefix(19)) + "…" + String(title.suffix(18))
        }
        return title
    }

    /// Path tails that carry no name of their own, so a URL ending in one shows its host alone.
    private static let namelessSegments: Set<String> = [
        "watch", "view", "index", "index.html", "index.php", "home", "default", "page"
    ]

    /// Titles past the limit keep their head and end in a single ellipsis.
    private static func capped(_ title: String, at limit: Int) -> String {
        guard title.count > limit else { return title }
        return String(title.prefix(limit - 3)) + "…"
    }

    /// `!3190` for merge requests, `#123` for issues and pull requests.
    /// Matches GitLab (`/-/merge_requests/`, `/-/issues/`) and GitHub-style
    /// (`/pull/`, `/issues/`) paths on any host.
    static func forgeReference(for url: URL) -> String? {
        let segments = url.path.split(separator: "/").map(String.init)
        // GitLab nests the kind behind /-/: /group/project/-/merge_requests/3190
        if let dash = segments.firstIndex(of: "-"),
           dash + 2 < segments.count,
           let id = Int(segments[dash + 2]) {
            switch segments[dash + 1] {
            case "merge_requests": return "!\(id)"
            case "issues": return "#\(id)"
            default: break
            }
        }
        // GitHub style: /owner/repo/pull/123 or /owner/repo/issues/123
        if segments.count >= 2, let id = Int(segments.last ?? "") {
            let kind = segments[segments.count - 2]
            if kind == "pull" || kind == "issues" { return "#\(id)" }
        }
        return nil
    }

    /// Hostless URLs (mailto:, custom schemes) have no host to lean on, so
    /// they only get the length cap.
    static func compactFallback(_ absolute: String) -> String {
        guard absolute.count > 40 else { return absolute }
        return String(absolute.prefix(19)) + "…" + String(absolute.suffix(18))
    }

    @MainActor
    static func containsLinks(in source: String, streaming: Bool = false) -> Bool {
        prettyAttributed(source, streaming: streaming).runs.contains { $0.link != nil }
    }

    static func isBareDisplay(_ display: String, url: URL) -> Bool {
        var d = display.trimmed
        if d.hasPrefix("<"), d.hasSuffix(">"), d.count >= 2 {
            d = String(d.dropFirst().dropLast())
        }
        while let last = d.last, ".,;:!?)]}>".contains(last) { d.removeLast() }
        if d == url.absoluteString { return true }
        if (d.hasPrefix("http://") || d.hasPrefix("https://")) && !d.contains(" ") && !d.contains("\n") {
            return true
        }
        return false
    }

    /// A bare domain as people type it in chat: tivano.app, www.tivano.app/pricing?a=1.
    /// The lookbehind is not supported by Swift's `Regex`, so this stays on
    /// `NSRegularExpression`.
    private static let bareDomainPattern = try? NSRegularExpression(
        pattern: "(?<![A-Za-z0-9@._/-])((?:[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?\\.)+[A-Za-z]{2,24})(/[^\\s<>()]*)?",
        options: [.caseInsensitive])

    /// TLDs a chat linkifier is sure of. Curated, not every TLD: a file name
    /// (MarkdownView.swift, index.html, package.json) has a bare domain's shape.
    private static let bareDomainTLDs: Set<String> = [
        "com", "org", "net", "edu", "gov", "mil", "info", "biz", "io", "ai", "app", "dev", "co", "me",
        "xyz", "site", "online", "store", "shop", "tech", "cloud", "tools", "blog", "fm", "gg", "so", "tv",
        "live", "news", "studio", "design", "social", "works", "codes", "run", "page", "link", "chat", "bot",
        "art", "fun", "space", "world", "email", "group", "team", "digital", "agency", "solutions", "software",
        "systems", "network", "media", "photo", "video", "games", "zone", "city", "life", "one", "plus", "pro",
        "nl", "de", "be", "uk", "fr", "es", "it", "se", "no", "dk", "fi", "is", "ch", "at", "pl", "ie", "eu",
        "ca", "us", "au", "nz", "jp", "cn", "in", "br", "mx", "za", "pt", "gr", "cz", "ro", "hu", "sk", "kr",
        "sg", "hk", "tw", "th", "my", "id", "ph", "vn", "tr", "il", "ae", "sa", "cl", "ar", "pe"
    ]

    /// Links the bare domains Foundation leaves alone: `tivano.app` typed in chat
    /// reads as a link with its favicon, the same as a full URL does.
    private static func autolinkedBareDomains(_ parsed: AttributedString) -> AttributedString {
        var out = AttributedString()
        for run in parsed.runs {
            let slice = parsed[run.range]
            if run.link != nil || (run.inlinePresentationIntent ?? []).contains(.code) {
                out.append(AttributedString(slice))
                continue
            }
            let text = String(slice.characters)
            var afterDot = false
            let mayContainDomain = text.utf8.contains { byte in
                defer { afterDot = byte == 46 }
                // ICU case folding can also match non-ASCII letters to [A-Za-z].
                return afterDot && ((65...90).contains(byte) || (97...122).contains(byte) || byte >= 128)
            }
            guard mayContainDomain, let pattern = bareDomainPattern else {
                out.append(AttributedString(slice))
                continue
            }
            let ns = text as NSString
            let matches = pattern.matches(in: text, options: [], range: NSRange(location: 0, length: ns.length))
            let trimSet = ".,;:!?'\""
            func candidate(_ match: NSTextCheckingResult) -> (text: String, url: URL?)? {
                guard let range = Range(match.range, in: text) else { return nil }
                var matchText = String(text[range])
                // Trailing punctuation belongs to the sentence, not the link.
                while let last = matchText.last, trimSet.contains(last) { matchText.removeLast() }
                let slash = matchText.firstIndex(of: "/")
                let domainPart = slash.map { String(matchText[..<$0]) } ?? matchText
                let lastLabel = domainPart.split(separator: ".").last.map(String.init)?.lowercased() ?? ""
                let url = bareDomainTLDs.contains(lastLabel) ? URL(string: "https://" + matchText) : nil
                return (matchText, url)
            }
            guard matches.contains(where: { candidate($0)?.url != nil }) else {
                out.append(AttributedString(slice))
                continue
            }
            // Offsets are Characters throughout: the regex reports UTF-16 ranges, and
            // `Range(_:in:)` turns one back into the text's own indices, so a sentence with
            // an emoji or an accent before the domain still links the domain itself.
            var cursor = 0
            var pieceIndex = slice.characters.startIndex
            var pieceOffset = 0
            var textIndex = text.startIndex
            var textOffset = 0
            func piece(_ span: Range<Int>) -> AttributedString {
                let lo = slice.characters.index(pieceIndex, offsetBy: span.lowerBound - pieceOffset)
                let hi = slice.characters.index(lo, offsetBy: span.count)
                pieceIndex = hi
                pieceOffset = span.upperBound
                return AttributedString(slice[lo..<hi])
            }
            for match in matches {
                guard let range = Range(match.range, in: text) else { continue }
                let distance = text.distance(from: textIndex, to: range.lowerBound)
                let start = textOffset + distance
                textIndex = text.index(textIndex, offsetBy: distance)
                textOffset = start
                guard start >= cursor else { continue }
                guard let candidate = candidate(match) else { continue }
                let end = start + candidate.text.count
                if start > cursor { out.append(piece(cursor..<start)) }
                if let url = candidate.url {
                    var linkSlice = piece(start..<end)
                    linkSlice.link = url
                    out.append(linkSlice)
                } else if end > cursor {
                    out.append(piece(start..<end))
                }
                cursor = end
            }
            let count = textOffset + text.distance(from: textIndex, to: text.endIndex)
            if cursor < count { out.append(piece(cursor..<count)) }
        }
        return out
    }

    private static func baseAttributed(_ source: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        return autolinkedBareDomains((try? AttributedString(markdown: source, options: options)) ?? AttributedString(source))
    }
}

/// Base point size for link paragraphs. SwiftUI's `.font` environment is
/// opaque, so non-default contexts set this explicitly; zero resolves to the current
/// Content size in the view body, where Observation can track it.
private struct MarkdownPointSizeKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

/// Whether the paragraph renders in secondary styling (quotes, thinking).
/// Threaded explicitly for the same reason as the point size above.
private struct MarkdownDimmedKey: EnvironmentKey {
    static let defaultValue = false
}

/// Whether the paragraph's text is still arriving, so its parses bypass the shared caches.
private struct MarkdownStreamingKey: EnvironmentKey {
    static let defaultValue = false
}

/// Whether each block selects its own text. On everywhere, replies included: a
/// finished reply's blocks are copyable at all times, one paragraph at a time. Whole
/// replies go to the clipboard as markdown through the row menu's Copy (`MessageText`).
private struct MarkdownBlockSelectionKey: EnvironmentKey {
    static let defaultValue = true
}

private struct MarkdownProseRunsKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var markdownPointSize: CGFloat {
        get { self[MarkdownPointSizeKey.self] }
        set { self[MarkdownPointSizeKey.self] = newValue }
    }
    var markdownDimmed: Bool {
        get { self[MarkdownDimmedKey.self] }
        set { self[MarkdownDimmedKey.self] = newValue }
    }
    var markdownStreaming: Bool {
        get { self[MarkdownStreamingKey.self] }
        set { self[MarkdownStreamingKey.self] = newValue }
    }
    var markdownBlockSelection: Bool {
        get { self[MarkdownBlockSelectionKey.self] }
        set { self[MarkdownBlockSelectionKey.self] = newValue }
    }
    var markdownProseRuns: Bool {
        get { self[MarkdownProseRunsKey.self] }
        set { self[MarkdownProseRunsKey.self] = newValue }
    }
}

/// `.textSelection(.enabled)` only for idle blocks whose environment allows selection.
struct MarkdownBlockSelection: ViewModifier {
    var isLive = false
    @Environment(\.markdownBlockSelection) private var enabled
    @Environment(\.markdownStreaming) private var streaming
    func body(content: Content) -> some View {
        // SwiftUI rebuilds the whole TextKit layout for selectable text on every content change.
        if enabled && !streaming && !isLive {
            content.textSelection(.enabled)
        } else {
            content.textSelection(.disabled)
        }
    }
}

@MainActor
enum FaviconCache {
    private static var memory: [String: NSImage] = [:]

    static func cached(host: String) -> NSImage? {
        memory[host.lowercased()]
    }

    static func needsFetch(host: String) -> Bool {
        let key = host.lowercased()
        if memory[key] != nil || failed.contains(key) { return false }
        guard isPublic(host: key) else {
            failed.insert(key)
            return false
        }
        return true
    }

    /// Hosts with no icon are remembered too, and concurrent asks share one request: a streaming
    /// reply restarts its row's task on every token, and scrolling re-runs it on every appear.
    private static var failed: Set<String> = []
    private static var inFlight: [String: Task<NSImage?, Never>] = [:]

    static func image(for host: String) async -> NSImage? {
        let key = host.lowercased()
        if let hit = memory[key] { return hit }
        guard !failed.contains(key) else { return nil }
        // Icons come from a service on the web, so the host is told to it. Tool output is
        // full of names that belong to this machine and this network; those never leave.
        guard isPublic(host: key) else {
            failed.insert(key)
            return nil
        }
        if let task = inFlight[key] { return await task.value }
        let task = Task { () -> NSImage? in
            guard let data = await iconData(for: key) else { return nil }
            let processed = await Task.detached(priority: .utility) {
                processedIconData(data)
            }.value
            guard let processed, let image = NSImage(data: processed) else { return nil }
            image.size = NSSize(width: 14, height: 14)
            return image
        }
        inFlight[key] = task
        let image = await task.value
        inFlight[key] = nil
        if let image {
            if memory.count >= 300 { memory.removeAll(keepingCapacity: true) }
            memory[key] = image
            RichLink.bumpAssetGeneration()
        } else {
            failed.insert(key)
        }
        return image
    }

    /// The icon the host itself serves. Fetching `/favicon.ico` from the host keeps the
    /// hosts a reply links to away from a third-party favicon service; a host that serves
    /// nothing gets no icon, and a private host is refused before this is reached (see
    /// `isPublic(host:)`).
    private static func iconData(for host: String) async -> Data? {
        guard let url = URL(string: "https://\(host)/favicon.ico") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              NSImage(data: data) != nil else { return nil }
        return data
    }

    nonisolated private static func processedIconData(_ data: Data) -> Data? {
        guard let clean = cleaned(data) else { return nil }
        return resizedIcon(clean).tiffRepresentation
    }

    nonisolated private static func cleaned(_ data: Data) -> NSImage? {
        guard let image = NSImage(data: data), image.size.width > 0, image.size.height > 0 else { return nil }
        let long = max(image.size.width, image.size.height)
        let scale = long > 64 ? 64 / long : 1
        let width = max(1, Int((image.size.width * scale).rounded()))
        let height = max(1, Int((image.size.height * scale).rounded()))
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(x: 0, y: 0, width: width, height: height),
                   from: NSRect(origin: .zero, size: image.size),
                   operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        removeWhitePlate(in: rep)
        let out = NSImage(size: NSSize(width: width, height: height))
        out.addRepresentation(rep)
        return out
    }

    nonisolated private static func removeWhitePlate(in rep: NSBitmapImageRep) {
        let width = rep.pixelsWide
        let height = rep.pixelsHigh
        guard width > 0, height > 0 else { return }
        func channels(_ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int, a: Int)? {
            guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return nil }
            return (Int((c.redComponent * 255).rounded()), Int((c.greenComponent * 255).rounded()),
                    Int((c.blueComponent * 255).rounded()), Int((c.alphaComponent * 255).rounded()))
        }
        func isWhite(_ p: (r: Int, g: Int, b: Int, a: Int)) -> Bool {
            guard p.a > 200 else { return false }
            let lo = min(p.r, min(p.g, p.b))
            let hi = max(p.r, max(p.g, p.b))
            return lo >= 236 && hi - lo <= 20
        }
        var plate = [Bool](repeating: false, count: width * height)
        var stack: [Int] = []
        for x in 0..<width {
            for y in [0, height - 1] {
                if let p = channels(x, y), isWhite(p), !plate[y * width + x] {
                    plate[y * width + x] = true
                    stack.append(y * width + x)
                }
            }
        }
        for y in 0..<height {
            for x in [0, width - 1] {
                if let p = channels(x, y), isWhite(p), !plate[y * width + x] {
                    plate[y * width + x] = true
                    stack.append(y * width + x)
                }
            }
        }
        while let idx = stack.popLast() {
            let x = idx % width
            let y = idx / width
            let neighbours = [(x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)]
            for (nx, ny) in neighbours {
                guard nx >= 0, nx < width, ny >= 0, ny < height, !plate[ny * width + nx] else { continue }
                guard let p = channels(nx, ny), isWhite(p) else { continue }
                plate[ny * width + nx] = true
                stack.append(ny * width + nx)
            }
        }
        for y in 0..<height {
            for x in 0..<width {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                let r = Int((c.redComponent * 255).rounded())
                let g = Int((c.greenComponent * 255).rounded())
                let b = Int((c.blueComponent * 255).rounded())
                let lo = min(r, min(g, b))
                if plate[y * width + x] {
                    rep.setColor(NSColor(deviceRed: c.redComponent, green: c.greenComponent, blue: c.blueComponent, alpha: 0), atX: x, y: y)
                    continue
                }
                let hasPlateNeighbour = (x + 1 < width && plate[y * width + x + 1])
                    || (x - 1 >= 0 && plate[y * width + x - 1])
                    || (y + 1 < height && plate[(y + 1) * width + x])
                    || (y - 1 >= 0 && plate[(y - 1) * width + x])
                guard hasPlateNeighbour, lo >= 160 else { continue }
                let alpha = 1 - Double(lo) / 255
                guard alpha > 0.02 else {
                    rep.setColor(NSColor(deviceRed: c.redComponent, green: c.greenComponent, blue: c.blueComponent, alpha: 0), atX: x, y: y)
                    continue
                }
                func unpremult(_ v: Double) -> Double {
                    min(1, max(0, (v / 255 - (1 - alpha)) / alpha))
                }
                rep.setColor(NSColor(deviceRed: unpremult(Double(r)), green: unpremult(Double(g)), blue: unpremult(Double(b)), alpha: alpha), atX: x, y: y)
            }
        }
    }

    /// Suffixes that only ever name something inside a network, never a site on the web.
    private static let privateSuffixes = [
        ".local", ".localhost", ".localdomain", ".internal", ".intranet",
        ".lan", ".home", ".home.arpa", ".test", ".invalid", ".corp",
    ]

    /// Whether a host is one a public favicon service could possibly know: not the loopback,
    /// not a bare machine name, not one of the private suffixes, and not an address in the
    /// ranges that never leave a network. A host that fails any of these is never asked about.
    static func isPublic(host: String) -> Bool {
        guard !host.isEmpty, host != "localhost" else { return false }
        // An IPv6 literal (no brackets by the time it comes off a URL) has no favicon worth
        // the request, and half of them are link-local or unique-local addresses.
        guard !host.contains(":") else { return false }
        for suffix in privateSuffixes where host.hasSuffix(suffix) { return false }
        // A single label with no dot in it is a machine on this network, not a site.
        guard host.contains(".") else { return false }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        var octets: [Int] = []
        for label in labels {
            guard let value = Int(label), (0...255).contains(value) else { break }
            octets.append(value)
        }
        guard octets.count == 4, octets.count == labels.count else { return true }
        switch (octets[0], octets[1]) {
        case (0, _), (10, _), (127, _): return false
        case (169, 254), (192, 168): return false
        case (172, 16...31): return false
        // Carrier-grade NAT, which tunnels and VPNs hand out.
        case (100, 64...127): return false
        default: return true
        }
    }

    nonisolated private static func resizedIcon(_ image: NSImage) -> NSImage {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 28, pixelsHigh: 28,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return image }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(x: 0, y: 0, width: 28, height: 28),
                   from: NSRect(origin: .zero, size: image.size),
                   operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        let out = NSImage(size: NSSize(width: 14, height: 14))
        out.addRepresentation(rep)
        return out
    }
}

struct InlineText: View {
    let source: String
    /// Set when the caller already branched on containsLinks, so the check runs once.
    let hasLinks: Bool?
    /// The caller is a bubble that hugs its text: no full-width frame.
    var hugsContent = false
    var lineSpacingOverride: CGFloat? = nil
    @Environment(\.markdownPointSize) private var pointSize
    @Environment(\.markdownDimmed) private var dimmed
    @Environment(\.markdownStreaming) private var streaming
    @Environment(\.hydraMentionPersonas) private var hydraMentionPersonas
    @Environment(\.hydraMentionTargets) private var hydraMentionTargets
    @Environment(\.markdownLinkBase) private var markdownLinkBase
    @Environment(\.openURL) private var openURL
    @State private var faviconRevision = 0
    /// The link paragraph's text view, for the hover that sets the cursor.
    @State private var linkView = WeakView()
    /// Whether the pointing hand is up over a link, so hover only sets the cursor on change.
    @State private var showsHand = false
    /// The head whose card is up, so hover only re-shows the card on change.
    @State private var hoveredHeadID: UUID?

    init(_ source: String, hasLinks: Bool? = nil, hugsContent: Bool = false, lineSpacingOverride: CGFloat? = nil) {
        self.source = source
        self.hasLinks = hasLinks
        self.hugsContent = hugsContent
        self.lineSpacingOverride = lineSpacingOverride
    }

    var body: some View {
        // faviconRevision read so loaded favicons rebuild the text.
        let _ = faviconRevision
        let resolvedSize = pointSize == 0 ? TypeScale.shared.content(13) : pointSize
        let scaled = (resolvedSize * 2).rounded() / 2
        let codeSize = TypeScale.shared.code(max(9, scaled - CGFloat(TypeScale.shared.content - TypeScale.stockContent) - 1))
        // Local file links have no host, but still need the native link opener.
        let pretty: AttributedString? = hasLinks == nil ? RichLink.prettyAttributed(source, streaming: streaming) : nil
        let hasLinkText = hasLinks ?? pretty!.runs.contains { $0.link != nil }
        if hasLinkText {
            // An AppKit view has no text baseline of its own, so a list's marker sat on the
            // paragraph's top edge and the text started a line below it. The first line's
            // baseline is the base font's ascender from the top; the last is one line up
            // from the bottom. Measured once per size and kept: the alignment guides run
            // off the main actor, so they take the two numbers rather than the font.
            let metrics = Self.metrics(pointSize: scaled)
            let ascender = metrics.ascender
            let lineHeight = metrics.lineHeight
            // Stable hosts and video ids key the link work, so a streamed token with no
            // new link leaves the task alone.
            let assetPlan = RichLink.linkAssetPlan(for: source, streaming: streaming)
            // The hover and the host callback keep only the text view's weak box and the
            // hand binding: the hover responder and the representable must not keep this
            // paragraph (and its styled text) alive after it scrolls away.
            let linkBox = linkView
            let targets = hydraMentionTargets
            LinkParagraphView(source: source, pointSize: scaled, codePointSize: codeSize, lineSpacingOverride: lineSpacingOverride, dimmed: dimmed, streaming: streaming, revision: faviconRevision, mentions: hydraMentionPersonas, targets: hydraMentionTargets, linkBase: markdownLinkBase, hugsContent: hugsContent, onOpenHead: { url in openURL(url) }, onHost: { [weak linkBox] view in linkBox?.value = view })
                .frame(maxWidth: hugsContent ? nil : .infinity, alignment: .leading)
                .alignmentGuide(.firstTextBaseline) { _ in ascender }
                .alignmentGuide(.lastTextBaseline) { $0.height - lineHeight + ascender }
                // The pointing hand over links and the head card over a mention, from here
                // rather than the text view's own tracking (see `LinkHoverModifier`).
                .modifier(LinkHoverModifier(linkView: linkBox, showsHand: $showsHand, hoveredHeadID: $hoveredHeadID, personas: hydraMentionPersonas, targets: targets))
                // Stable hosts and video ids key the link work, so a streamed token with no
                // new link leaves the task alone.
                .task(id: assetPlan.needsFetch ? assetPlan.key : "") { [source, streaming, needsFetch = assetPlan.needsFetch, revision = $faviconRevision] in
                    guard needsFetch else { return }
                    await Self.fetchLinkAssets(source: source, streaming: streaming, revision: revision)
                }
        } else {
            // Link-free, so the attributed string renders as one Text; bold, italic and
            // code come through as inline presentation intents. Streamed characters fade
            // in through the veil.
            VeiledText(RichLink.scaledPrettyAttributed(source, pretty: pretty, codePointSize: codeSize, streaming: streaming))
                .lineSpacing(lineSpacingOverride ?? TypeScale.proseLineSpacing(scaled))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: hugsContent ? nil : .infinity, alignment: .leading)
        }
    }

    @MainActor
    static func scaledInlineCode(_ source: AttributedString, pointSize: CGFloat) -> AttributedString {
        guard source.runs.contains(where: { $0.inlinePresentationIntent?.contains(.code) == true }) else { return source }
        var result = source
        for run in source.runs where run.inlinePresentationIntent?.contains(.code) == true {
            result[run.range].font = .system(size: pointSize, design: .monospaced)
        }
        return result
    }

    private struct MetricsKey: Hashable {
        let pointSize: CGFloat
        let serif: Bool
    }

    /// The base font's baseline numbers, measured once per point size and typeface. Asking AppKit for a
    /// font and its metrics on every render of every link paragraph is work with one answer.
    @MainActor private static var metricsBySize: [MetricsKey: (ascender: CGFloat, lineHeight: CGFloat)] = [:]

    @MainActor
    private static func metrics(pointSize: CGFloat) -> (ascender: CGFloat, lineHeight: CGFloat) {
        let key = MetricsKey(pointSize: pointSize, serif: TypeScale.shared.serif)
        if let known = metricsBySize[key] { return known }
        let font = ThemeTypeface.nsFont(size: pointSize)
        let measured = (ceil(font.ascender), ceil(font.ascender - font.descender + font.leading))
        metricsBySize[key] = measured
        return measured
    }

    /// Static so the `.task` above keeps only the paragraph's source and the refresh
    /// binding, never the whole view value (and its styled text) after it goes away.
    /// Fetches favicons for each link host and video titles for each video link.
    static func fetchLinkAssets(source: String, streaming: Bool, revision: Binding<Int>) async {
        await fetchLinkAssets(sources: [source], streamingLast: streaming, revision: revision)
    }

    static func fetchLinkAssets(sources: [String], streamingLast: Bool = false, revision: Binding<Int>) async {
        guard !sources.isEmpty else { return }
        let lastIndex = sources.count - 1
        let extracted = await MainActor.run {
            sources.enumerated().compactMap { index, source -> (source: String, hosts: [String], videos: [String])? in
                guard !source.isEmpty else { return nil }
                let (hosts, videos) = RichLink.linkAssets(for: source, streaming: streamingLast && index == lastIndex)
                guard !(hosts.isEmpty && videos.isEmpty) else { return nil }
                return (source, hosts, videos)
            }
        }
        var anyChanged = false
        var toInvalidate: [String] = []
        for item in extracted {
            var changed = false
            for host in item.hosts where FaviconCache.cached(host: host) == nil {
                if await FaviconCache.image(for: host) != nil { changed = true }
            }
            for id in item.videos {
                if await LinkTitles.title(forVideo: id) != nil { changed = true }
            }
            if changed {
                anyChanged = true
                toInvalidate.append(item.source)
            }
        }
        if anyChanged {
            await MainActor.run {
                for source in toInvalidate { RichLink.invalidate(source) }
                revision.wrappedValue += 1
            }
        }
    }

    @MainActor
    static func attributed(_ source: String, streaming: Bool = false) -> AttributedString {
        RichLink.prettyAttributed(source, streaming: streaming)
    }
}

/// A hover flag kept in an object instead of view state. A code block's body holds its whole
/// text, counts its lines and cuts its head off; running all of that again because the
/// pointer crossed the block is what made the copy control feel sticky over a big dump.
/// Only the control reads this, so only the control re-renders.
@MainActor
@Observable
private final class BlockHover {
    var isHovering = false
}

/// The copy control on a code block's header, in a view of its own so the hover that
/// reveals it never reaches the block's text.
private struct CodeBlockCopyButton: View {
    let text: String
    let hover: BlockHover

    var body: some View {
        CopyButton(text: text)
            .opacity(hover.isHovering ? 1 : 0)
    }
}

@MainActor
private final class CodeMetrics {
    private var source = ""
    private var count = 1
    private(set) var prefix = ""
    private var prefixComplete = false

    func update(_ code: String, limit: Int) -> Int {
        guard source != code else { return count }
        let append = code.utf8.starts(with: source.utf8)
        let offset = append ? source.utf8.count : 0
        if !append { count = 1; prefix = ""; prefixComplete = false }
        let start = code.utf8.index(code.utf8.startIndex, offsetBy: offset)
        var prefixBytes: [UInt8] = []
        for byte in code.utf8[start...] {
            if byte == 10 { count += 1 }
            if !prefixComplete {
                if count > limit { prefixComplete = true }
                else { prefixBytes.append(byte) }
            }
        }
        prefix += String(decoding: prefixBytes, as: UTF8.self)
        source = code
        return count
    }
}

struct CodeBlock: View {
    let language: String?
    let code: String

    @State private var hover = BlockHover()
    @State private var showsAll = false
    @State private var metrics = CodeMetrics()

    /// Long dumps render collapsed: materializing thousands of lines at once is what
    /// makes expanding feel laggy. The full text is one instant tap away.
    private static let collapsedLineLimit = 120

    var body: some View {
        // A count of newlines, not a split: hovering re-runs this body, and a big dump split
        // into an array of lines on every hover is what made the copy button feel sticky.
        let lineCount = metrics.update(code, limit: Self.collapsedLineLimit)
        let truncated = !showsAll && lineCount > Self.collapsedLineLimit
        let visible = truncated ? metrics.prefix : code
        // The box alone: the hover handler must not keep this block (and its whole
        // text) alive after it scrolls away.
        let hoverBox = hover
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(verbatim: language ?? Chrome.localized("code"))
                    .font(.chat(.caption))
                    .foregroundStyle(Chrome.secondaryText)
                Spacer()
                CodeBlockCopyButton(text: code, hover: hover)
            }
            .padding(.leading, 14)
            .padding(.trailing, 8)
            .padding(.top, 7)
            ScrollView(.horizontal, showsIndicators: false) {
                // Code streams line by line and veils in like prose.
                VeiledText(verbatim: visible)
                    .font(.code(.callout))
                    .lineSpacing(TypeScale.codeLineSpacing(TypeScale.shared.code(12)))
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 13)
                    .padding(.top, 6)
            }
            if lineCount > Self.collapsedLineLimit {
                Button(showsAll ? Chrome.localized("Show less") : String(format: Chrome.localized("Show all %lld lines"), lineCount)) {
                    showsAll.toggle()
                }
                .buttonStyle(.link)
                .font(.chat(.caption))
                .foregroundStyle(Chrome.secondaryText)
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
            }
        }
        .background(.quaternary.opacity(0.45), in: .rect(cornerRadius: 12))
        .onHover { [weak hoverBox] in hoverBox?.isHovering = $0 }
    }


}

struct MarkdownImageBlock: View {
    let alt: String
    let source: String

    var body: some View {
        if let path = PreviewImages.localImagePath(source) {
            AttachmentStrip(attachments: [PreviewImages.attachment(for: path)], medium: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 2)
        } else {
            InlineText(alt.isEmpty ? source : alt, hasLinks: false)
        }
    }
}

struct TableBlock: View {
    let header: [String]
    let rows: [[String]]

    @Environment(\.markdownPointSize) private var pointSize
    @State private var showsAll = false
    /// The table card's width, rounded to whole points so sub-point jitter does not
    /// relayout the grid. Zero until the first layout reports it.
    @State private var availableWidth: CGFloat = 0

    private static let collapsedRowLimit = 30

    private struct CellKey: Hashable {
        let source: String
        let codePointSize: CGFloat
    }

    /// Cell runs by source text, so a re-layout joins cached runs instead of re-parsing.
    @MainActor private static var cellCache = RecentCache<CellKey, AttributedString>(limit: 1200, costLimit: 8 * 1024 * 1024, entryCostLimit: 1024 * 1024)

    @MainActor
    fileprivate static func clearCache() {
        cellCache = RecentCache<CellKey, AttributedString>(limit: 1200, costLimit: 8 * 1024 * 1024, entryCostLimit: 1024 * 1024)
    }

    @MainActor
    private static func cell(_ source: String, codePointSize: CGFloat) -> AttributedString {
        MarkdownMemoryPressure.armIfNeeded()
        let key = CellKey(source: source, codePointSize: codePointSize)
        if let hit = cellCache.value(for: key) { return hit }
        let value = InlineText.scaledInlineCode(InlineText.attributed(source), pointSize: codePointSize)
        cellCache.insert(value, for: key, cost: source.utf8.count * 3)
        return value
    }

    var body: some View {
        let resolvedSize = pointSize == 0 ? TypeScale.shared.content(13) : pointSize
        let codeSize = TypeScale.shared.code(max(9, resolvedSize - CGFloat(TypeScale.shared.content - TypeScale.stockContent) - 1))
        let visible = showsAll ? rows : Array(rows.prefix(Self.collapsedRowLimit))
        let head = header.map { Self.cell($0, codePointSize: codeSize) }
        let cells = visible.map { $0.map { Self.cell($0, codePointSize: codeSize) } }
        let columnSpacing = (resolvedSize * 1.35).rounded()
        let horizontalPadding = (resolvedSize * 0.95).rounded()
        // Cells wrap to fit the card; only a table whose columns would each fall below
        // this width keeps scrolling sideways.
        let minimumWidth = CGFloat(head.count) * (resolvedSize * 7).rounded()
            + CGFloat(max(0, head.count - 1)) * columnSpacing
        let gridWidth: CGFloat? = availableWidth > 0
            ? max(availableWidth - horizontalPadding * 2, minimumWidth)
            : nil
        return VStack(alignment: .leading, spacing: 0) {
            ScrollView(.horizontal) {
                // Cells go through the shared cache even while the table streams: only its
                // last row changes between flushes, and the rest hit.
                Grid(alignment: .leading, horizontalSpacing: columnSpacing, verticalSpacing: (resolvedSize * 0.6).rounded()) {
                    GridRow {
                        ForEach(head.indices, id: \.self) { column in
                            Text(head[column])
                                .fontWeight(.semibold)
                        }
                    }
                    if !cells.isEmpty {
                        Divider()
                            .opacity(0.45)
                            .gridCellUnsizedAxes(.horizontal)
                    }
                    ForEach(cells.indices, id: \.self) { row in
                        GridRow {
                            ForEach(head.indices, id: \.self) { column in
                                Text(column < cells[row].count ? cells[row][column] : AttributedString(""))
                                    .foregroundStyle(.primary.opacity(0.9))
                            }
                        }
                    }
                }
                .font(MarkdownBlockView.proseFont(pointSize: resolvedSize))
                .lineSpacing((TypeScale.proseLineSpacing(resolvedSize) * 0.65).rounded())
                .modifier(MarkdownBlockSelection())
                // The scroll view proposes no width, so give the grid the card's width:
                // short columns keep their natural width and long ones wrap. Before the
                // width is known (nil) the grid takes its single-line intrinsic size.
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: gridWidth, alignment: .leading)
                .padding(.horizontal, horizontalPadding)
                .padding(.vertical, (resolvedSize * 0.8).rounded())
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width.rounded() } action: { width in
                if width != availableWidth { availableWidth = width }
            }
            // The timeline hides its own vertical indicator. That environment value also
            // reaches nested scroll views, so opt the table's horizontal indicator back in.
            .scrollIndicators(.visible, axes: .horizontal)
            if !showsAll, rows.count > Self.collapsedRowLimit {
                Button(String(format: Chrome.localized("Show all %lld rows"), rows.count)) {
                    showsAll.toggle()
                }
                .buttonStyle(.link)
                .font(.chat(.caption))
                .foregroundStyle(Chrome.secondaryText)
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
            }
        }
        .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 12))
    }
}

/// Unwraps prose that the model hard-wrapped at a fixed column before the text
/// reaches the pasteboard. Anything that could be code is left untouched.
enum ProseReflow {
    static func reflowed(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        var output: [String] = []
        var paragraph: [String] = []
        var fenceOpen = false
        var fenceLanguage = ""

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            let trimmed = paragraph.map { $0.trimmingCharacters(in: .whitespaces) }
            let canReflow = trimmed.count >= 2
                && fenceLanguage.isEmpty
                && zip(paragraph, trimmed).allSatisfy { raw, trimmedLine in
                    !trimmedLine.isEmpty && raw.first?.isWhitespace != true
                }
                && trimmed.allSatisfy { line in
                    guard let first = line.first else { return false }
                    if "#>-*+|".contains(first) { return false }
                    if let d = first.wholeNumberValue, d >= 0, line.count > 1,
                       line[line.index(after: line.startIndex)] == "." || line[line.index(after: line.startIndex)] == ")" {
                        return false
                    }
                    return true
                }
                && trimmed.dropLast().allSatisfy { $0.count >= 45 }
                && trimmed.dropLast().allSatisfy { line in
                    if let last1 = line.last {
                        if "{};:=([\\|".contains(last1) { return false }
                        if line.hasSuffix("->") || line.hasSuffix("=>") { return false }
                    }
                    return true
                }
                && trimmed.allSatisfy { !$0.contains("  ") && !$0.contains("\t") }
                && trimmed.joined(separator: " ").range(of: #"[.!?] "#, options: .regularExpression) != nil
            if canReflow {
                output.append(trimmed.joined(separator: " "))
            } else {
                output.append(contentsOf: paragraph)
            }
            paragraph = []
        }

        for line in lines {
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            if trimmedLine.hasPrefix("```") {
                flushParagraph()
                output.append(line)
                if fenceOpen {
                    fenceOpen = false
                    fenceLanguage = ""
                } else {
                    fenceOpen = true
                    fenceLanguage = String(trimmedLine.dropFirst(3)).lowercased()
                }
            } else if trimmedLine.isEmpty {
                flushParagraph()
                output.append(line)
            } else if fenceOpen {
                flushParagraph()
                output.append(line)
            } else {
                paragraph.append(line)
            }
        }
        flushParagraph()
        return output.joined(separator: "\n")
    }
}

struct CopyButton: View {
    let text: String
    var label = "Copy"

    @State private var didCopy = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(ProseReflow.reflowed(text), forType: .string)
            didCopy = true
            // The binding alone: the delayed reset must not keep this button (and its
            // whole text) alive.
            Task { [copied = $didCopy] in
                try? await Task.sleep(for: .seconds(1.4))
                copied.wrappedValue = false
            }
        } label: {
            Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 22, height: 22)
                .contentShape(.rect)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(Chrome.secondaryText)
        .help(Text(verbatim: Chrome.localized(label)))
    }
}
