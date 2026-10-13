import AppKit
import SwiftUI

/// One tick in the conversation outline. Titles come from the block's own
/// content (user prompt, reply preview, tool verb, "Worked for …"), so the
/// rail reads as a miniature table of contents for the thread.
struct TimelineMinimapEntry: Identifiable, Hashable {
    let id: String
    let title: String
    let snippet: String
    /// 0…1, drives the tick width. Long replies read wide, short notices narrow.
    let weight: Double
}

enum TimelineMinimap {
    @MainActor
    static func entries(for blocks: [DisplayBlock]) -> [TimelineMinimapEntry] {
        blocks.compactMap(entry(for:))
    }

    /// One tick per message the user sent — prompts, follow-ups, attachments.
    /// Replies, tool runs, notices and summaries never get ticks.
    @MainActor
    private static func entry(for block: DisplayBlock) -> TimelineMinimapEntry? {
        switch block {
        case .turn(let id, _, let entries, _, _):
            guard let message = entries.compactMap({ userMessage(of: $0) }).first else { return nil }
            return userEntry(id: id, message: message)
        case .group(.single(let entry), _, _):
            guard case .user(let message) = entry.item.content else { return nil }
            return userEntry(id: entry.id, message: message)
        case .group(.work, _, _), .group(.heads, _, _), .working, .merging, .headsWorking, .backgroundTasks:
            return nil
        }
    }

    /// Titles by block id. A sent message never changes, so its title and snippet are cut
    /// once per thread rather than on every pass over the outline.
    @MainActor private static var entryCache = RecentCache<String, TimelineMinimapEntry>(limit: 400)

    @MainActor
    private static func userEntry(id: String, message: UserMessage) -> TimelineMinimapEntry {
        if let cached = entryCache.value(for: id) { return cached }
        let title = userTitle(for: message)
        let snippet = preview(message.text)
        let entry = TimelineMinimapEntry(
            id: id,
            title: title,
            snippet: snippet.isEmpty || snippet == title ? "" : snippet,
            weight: weight(of: message.text)
        )
        entryCache.insert(entry, for: id)
        return entry
    }

    private static func userTitle(for message: UserMessage) -> String {
        let title = firstWords(message.text, limit: 8)
        if !title.isEmpty { return title }
        let images = message.attachments.filter(\.isImage).count
        if images == 1 { return Chrome.localized("1 image") }
        if images > 1 { return String(format: Chrome.localized("%d images"), images) }
        return message.attachments.first?.name ?? Chrome.localized("Message")
    }

    @MainActor
    private static func userMessage(of entry: TimelineEntry) -> UserMessage? {
        guard case .user(let message) = entry.item.content else { return nil }
        return message
    }

    private static func firstWords(_ text: String, limit: Int) -> String {
        let words = text.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return "" }
        let head = words.prefix(limit).joined(separator: " ")
        return words.count > limit ? head + "…" : head
    }

    private static func preview(_ text: String, limit: Int = 160) -> String {
        let flat = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard flat.count > limit else { return flat }
        return String(flat.prefix(limit)) + "…"
    }

    private static func weight(of text: String) -> Double {
        min(1, max(0.15, Double(text.count) / 420))
    }
}

/// Builds the outline in its own body. The titles read message text, so building them in the
/// timeline's body made the whole conversation re-render on every streamed token; here only
/// the rail does. Equal blocks build an equal outline, so a timeline pass that changed no
/// block skips this entirely.
struct TimelineMinimapColumn: View, Equatable {
    let blocks: [DisplayBlock]
    /// Which blocks are on screen and whether the timeline follows new text. Scrolling
    /// writes here, and only the selection below reads it.
    let tracking: TimelineScrollTracking
    /// Full chat-column height. Ticks centre in this, not in the timeline, so the
    /// composer and queue tab growing never shifts them.
    var centerHeight: CGFloat
    var onNavigate: (String, Bool) -> Void

    nonisolated static func == (lhs: TimelineMinimapColumn, rhs: TimelineMinimapColumn) -> Bool {
        lhs.blocks == rhs.blocks && lhs.tracking === rhs.tracking && lhs.centerHeight == rhs.centerHeight
    }

    @Environment(WindowLiveResize.self) private var liveResize
    /// The outline as last built. Mid-resize the track scales in place and new user
    /// messages wait for the settle, so a height-only pass never rebuilds the ticks.
    @State private var lastEntries: [TimelineMinimapEntry] = []

    var body: some View {
        MinimapSelection(
            entries: liveResize.isActive ? lastEntries : TimelineMinimap.entries(for: blocks),
            outline: blocks.map { MinimapOutlineBlock(id: $0.id, hasUserMessage: $0.hasUserMessage) },
            tracking: tracking,
            centerHeight: centerHeight,
            onNavigate: onNavigate
        )
        // Rebuilt once the resize settles, so the ticks land correct after scaling in place.
        .onChange(of: liveResize.isActive) { _, active in
            guard !active else { return }
            lastEntries = TimelineMinimap.entries(for: blocks)
        }
        .onAppear { lastEntries = TimelineMinimap.entries(for: blocks) }
        .onChange(of: blocks) { _, blocks in
            guard !liveResize.isActive else { return }
            lastEntries = TimelineMinimap.entries(for: blocks)
        }
    }
}

/// A block's place in the outline: its id and whether it earns a tick.
private struct MinimapOutlineBlock: Equatable {
    let id: String
    let hasUserMessage: Bool
}

/// Lights the tick for the block the reader is on. This is the only view that observes the
/// scroll tracking, so every visibility change while scrolling re-runs just this small body.
private struct MinimapSelection: View {
    let entries: [TimelineMinimapEntry]
    let outline: [MinimapOutlineBlock]
    let tracking: TimelineScrollTracking
    let centerHeight: CGFloat
    let onNavigate: (String, Bool) -> Void

    var body: some View {
        TimelineMinimapRail(
            entries: entries,
            centerHeight: centerHeight,
            selectedID: activeID,
            onNavigate: onNavigate
        )
        .equatable()
    }

    /// The block the reader is on, resolved by the timeline from its scroll geometry.
    private var activeID: String? {
        tracking.activeBlockID ?? outline.last(where: \.hasUserMessage)?.id
    }
}

/// Slim rail on the left edge of the chat: one tick per message the user sent,
/// a preview bubble on hover, tap or drag to jump. Mounted for the whole
/// life of a thread, so it costs nothing at rest: no timers, no continuous
/// animation, plain rects only, and the bubble mounts solely while hovering.
struct TimelineMinimapRail: View, Equatable {
    let entries: [TimelineMinimapEntry]
    /// Full chat-column height. Ticks centre in this, so composer and queue
    /// growth never moves them; the container stays timeline-height, so hit
    /// testing, scrubbing and the preview card never reach into the composer.
    var centerHeight: CGFloat
    var selectedID: String?
    /// Live scrub reports `animated: false` (the timeline tracks 1:1);
    /// release reports `true` (one glide to the landing block).
    var onNavigate: (String, Bool) -> Void

    /// The same outline with the same tick lit draws the same rail, so a visibility change
    /// that moved nothing is skipped here.
    nonisolated static func == (lhs: TimelineMinimapRail, rhs: TimelineMinimapRail) -> Bool {
        lhs.entries == rhs.entries && lhs.centerHeight == rhs.centerHeight && lhs.selectedID == rhs.selectedID
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(WindowLiveResize.self) private var liveResize
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("performanceMode", store: CaptureRun.defaults ?? .standard) private var performanceMode = false

    /// Tick under the pointer, nil once the pointer leaves the rail.
    @State private var hoveredID: String?
    /// True while a press is down on the rail (tap or scrub).
    @State private var isPressing = false

    private var isExpanded: Bool { hoveredID != nil || isPressing }
    private var baseOpacity: Double { isExpanded ? 0.4 : 0.25 }
    private var hoverAnimation: Animation? {
        // Held mid-resize: a hover curve restarted every frame lagged the whole rail.
        if liveResize.isActive || reduceMotion || performanceMode { return nil }
        return .smooth(duration: 0.22)
    }

    var body: some View {
        GeometryReader { proxy in
            let metrics = MinimapRailMetrics(
                centeringHeight: centerHeight,
                clickableHeight: proxy.size.height,
                count: entries.count
            )
            ZStack(alignment: .leading) {
                // The pointer only counts over the tick stack itself. The rest of the column is
                // left to whatever else is there: the window buttons sit over its top with the
                // sidebar hidden, and a full-height area took their hover and their clicks.
                // Within the stack the area is solid, so a scrub never drops between ticks.
                Color.clear
                    .contentShape(RailHitArea(rect: metrics.hitRect(count: entries.count, railSize: proxy.size)))
                    .pointerStyle(.link)
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            // Hovering alone previews the tick under the pointer; only a press jumps.
                            let id = metrics.entryID(at: location.y, entries: entries)
                            if hoveredID != id {
                                hoveredID = id
                                if id != nil {
                                    switch model.settings.timelineHapticStyle {
                                    case .soft: Haptics.perform(.generic)
                                    case .strong: Haptics.perform(.alignment)
                                    case .none: break
                                    }
                                }
                            }
                        case .ended:
                            hoveredID = nil
                        }
                    }
                    .gesture(scrubGesture(metrics: metrics))

                ticks(metrics: metrics)
                    .allowsHitTesting(false)

                if let hovered = hoveredEntry {
                    previewCard(for: hovered, metrics: metrics, railHeight: proxy.size.height)
                        .allowsHitTesting(false)
                        .transition(.opacity.combined(with: .offset(x: reduceMotion ? 0 : -6)))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        .animation(hoverAnimation, value: hoveredID)
        .animation(hoverAnimation, value: isPressing)
        .animation(hoverAnimation, value: selectedID)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Conversation outline")
    }

    @ViewBuilder
    private func ticks(metrics: MinimapRailMetrics) -> some View {
        VStack(alignment: .leading, spacing: metrics.spacing) {
            ForEach(entries) { entry in
                tick(for: entry)
            }
        }
        .padding(.top, metrics.topInset)
        // The ticks re-centre without a slide when the column's height is what changed:
        // its first measurement (the rail lays out at height 0 first, ticks at the top)
        // and a window resize. Otherwise the tick that lit up animated the whole stack
        // down from the top on every thread opened.
        .animation(nil, value: centerHeight)
        .animation(nil, value: metrics.spacing)
        .animation(nil, value: metrics.topInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func tick(for entry: TimelineMinimapEntry) -> some View {
        let isSelected = entry.id == selectedID
        let isHovered = entry.id == hoveredID
        RoundedRectangle(cornerRadius: 1, style: .continuous)
            // The block the reader is on burns in the accent — the same "this is the live one"
            // the effort track and an active chip use. Hover previews in plain ink.
            .fill(isSelected && !isHovered
                ? AnyShapeStyle(Chrome.accent)
                : AnyShapeStyle(.primary.opacity(isHovered ? 0.95 : baseOpacity)))
            .frame(width: tickWidth(for: entry, isHovered: isHovered, isSelected: isSelected), height: MinimapRailMetrics.tickHeight)
            .padding(.leading, 8)
            .accessibilityElement()
            .accessibilityLabel(entry.title)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { onNavigate(entry.id, true) }
    }

    private func tickWidth(for entry: TimelineMinimapEntry, isHovered: Bool, isSelected: Bool) -> CGFloat {
        // 10 pt narrowest, 26 pt widest. Hovered and selected ticks punch
        // out to full width so the eye finds them while scrubbing.
        let base = 10 + CGFloat(entry.weight) * 12
        if isHovered || isSelected { return 26 }
        return isExpanded ? min(26, base + 2) : base
    }

    private var hoveredEntry: TimelineMinimapEntry? {
        guard let hoveredID else { return nil }
        return entries.first { $0.id == hoveredID }
    }

    /// The card that follows the pointer: the same Liquid Glass surface, corner radius and type
    /// scale as the app's other floating cards, so the rail reads as part of Tivano.
    @ViewBuilder
    private func previewCard(
        for entry: TimelineMinimapEntry,
        metrics: MinimapRailMetrics,
        railHeight: CGFloat
    ) -> some View {
        let tickCenterY = metrics.centerY(for: indexOf(entry))
        // Estimated half height keeps the card inside the chat area without a measurement
        // loop (measuring would re-lay-out on every hover change).
        let half = estimatedCardHeight(entry) / 2
        let top = half + 2
        let bottom = max(top, railHeight - half - 2)
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.title)
                    .font(.ui(.body, weight: .semibold))
                    .foregroundStyle(Chrome.primaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .contentTransition(.opacity)
                if !entry.snippet.isEmpty {
                    Text(entry.snippet)
                        .font(.ui(.callout))
                        .foregroundStyle(Chrome.secondaryText)
                        .lineLimit(3)
                        .truncationMode(.tail)
                        .multilineTextAlignment(.leading)
                        .contentTransition(.opacity)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(width: Self.cardWidth, alignment: .leading)
            .modifier(MinimapCardSurface(isDark: colorScheme == .dark))
            Spacer(minLength: 0)
        }
        .padding(.leading, 34)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .offset(y: min(max(tickCenterY, top), bottom) - railHeight / 2)
    }

    /// A one-line title plus up to three snippet lines, wrapped at the card's width.
    private func estimatedCardHeight(_ entry: TimelineMinimapEntry) -> CGFloat {
        let title: CGFloat = 17
        let padding: CGFloat = 20
        guard !entry.snippet.isEmpty else { return title + padding }
        let glyphsPerLine = max(1, (Int(Self.cardWidth) - 24) / 7)
        let lines = min(3, max(1, (entry.snippet.count + glyphsPerLine - 1) / glyphsPerLine))
        return title + 3 + CGFloat(lines) * 15 + padding
    }

    private static let cardWidth: CGFloat = 300

    private func indexOf(_ entry: TimelineMinimapEntry) -> Int {
        entries.firstIndex(of: entry) ?? 0
    }

    private func scrubGesture(metrics: MinimapRailMetrics) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                isPressing = true
                guard let id = metrics.entryID(at: value.location.y, entries: entries) else { return }
                if hoveredID != id {
                    hoveredID = id
                    onNavigate(id, false)
                }
            }
            .onEnded { value in
                isPressing = false
                if let id = metrics.entryID(at: value.location.y, entries: entries) {
                    hoveredID = id
                    onNavigate(id, true)
                }
            }
    }
}

/// Pure rail geometry, shared by the gesture and the card so Y always maps
/// to the same entry. Ticks stay centred on the full column height while that
/// strip fits in the clickable rail, so a short thread does not jump when the
/// composer or the queue tab grows. A strip that would cross the composer
/// tightens toward `tightestSpacing`, then packs into the clickable band so
/// the last tick stays above the composer.
private struct MinimapRailMetrics {
    static let tickHeight: CGFloat = 2
    private static let roomySpacing: CGFloat = 8
    private static let tightestSpacing: CGFloat = 2

    let spacing: CGFloat
    /// Distance from the rail's top to the first tick.
    let topInset: CGFloat

    init(centeringHeight: CGFloat, clickableHeight: CGFloat, count: Int) {
        let center = centeringHeight
        guard count > 0, center > 0 else {
            spacing = Self.roomySpacing
            topInset = 0
            return
        }
        let ticks = CGFloat(count) * Self.tickHeight
        let gaps = CGFloat(max(0, count - 1))
        let bandTop = Self.chromeClearance
        let bandBottom = clickableHeight
        let band = bandBottom - bandTop

        func content(for gap: CGFloat) -> CGFloat { ticks + gaps * gap }
        func centeredTop(for gap: CGFloat) -> CGFloat { (center - content(for: gap)) / 2 }
        func centeredFits(_ gap: CGFloat) -> Bool {
            let top = centeredTop(for: gap)
            return top >= bandTop && top + content(for: gap) <= bandBottom
        }
        // The rail lays out at height 0 before it has a band. Keep the old
        // centred placement for that pass so the first real layout is not a slide.
        guard band > Self.tickHeight else {
            let gap = ticks + gaps * Self.roomySpacing <= center
                ? Self.roomySpacing
                : max(Self.tightestSpacing, (center - ticks) / max(1, gaps))
            spacing = gap
            topInset = centeredTop(for: gap)
            return
        }
        if centeredFits(Self.roomySpacing) {
            spacing = Self.roomySpacing
            topInset = centeredTop(for: Self.roomySpacing)
            return
        }
        // Largest gap in [tightest, roomy] whose centred strip still sits in the band.
        let centeredLimit = min(center - 2 * bandTop, 2 * bandBottom - center, band)
        if gaps > 0, centeredLimit >= ticks {
            let fitted = (centeredLimit - ticks) / gaps
            if fitted >= Self.tightestSpacing {
                let gap = min(Self.roomySpacing, fitted)
                spacing = gap
                topInset = centeredTop(for: gap)
                return
            }
        }
        let tightContent = content(for: Self.tightestSpacing)
        if tightContent <= band {
            spacing = Self.tightestSpacing
            let ideal = centeredTop(for: Self.tightestSpacing)
            topInset = min(max(ideal, bandTop), bandBottom - tightContent)
            return
        }
        // Still too tall at the spacing floor: overlap ticks so the whole strip,
        // including the last one, is inside the clickable band.
        guard gaps > 0 else {
            spacing = Self.tightestSpacing
            topInset = min(max(centeredTop(for: Self.tightestSpacing), bandTop), bandBottom - Self.tickHeight)
            return
        }
        spacing = (band - ticks) / gaps
        topInset = bandTop
    }

    private var pitch: CGFloat { Self.tickHeight + spacing }

    func centerY(for index: Int) -> CGFloat {
        topInset + CGFloat(index) * pitch + Self.tickHeight / 2
    }

    func entryID(at y: CGFloat, entries: [TimelineMinimapEntry]) -> String? {
        guard !entries.isEmpty else { return nil }
        guard pitch > 0.0001 else { return entries[entries.count - 1].id }
        let raw = (y - topInset - Self.tickHeight / 2 + pitch / 2) / pitch
        let clamped = min(max(Int(raw.rounded(.down)), 0), entries.count - 1)
        return entries[clamped].id
    }

    /// The chrome row floats over the top of the column; ticks under it are veiled and take no pointer.
    private static var chromeClearance: CGFloat { Chrome.chromeTopPadding + Chrome.capsuleHeight }

    /// Where the rail takes the pointer: the tick stack, reaching half a pitch past its first
    /// and last tick (as far as `entryID(at:)` gives them), kept out from under the chrome row
    /// and inside the rail. The column above and below stays clear for whatever is there.
    func hitRect(count: Int, railSize: CGSize) -> CGRect {
        guard count > 0 else { return .zero }
        let top = max(centerY(for: 0) - pitch / 2, Self.chromeClearance)
        let bottom = min(centerY(for: count - 1) + pitch / 2, railSize.height)
        guard bottom > top else { return .zero }
        return CGRect(x: 0, y: top, width: railSize.width, height: bottom - top)
    }
}

/// A fixed rectangle in the rail's own space, for its hit test. The rail fills its column, so
/// the shape's path is the rect as computed, not stretched to the bounds it is asked about.
private struct RailHitArea: Shape {
    let rect: CGRect

    func path(in _: CGRect) -> Path {
        Path(rect)
    }
}

/// The rail's hover card surface: glass on, a flat panel fill in performance mode.
private struct MinimapCardSurface: ViewModifier {
    let isDark: Bool
    @AppStorage("performanceMode", store: CaptureRun.defaults ?? .standard) private var performanceMode = false

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Chrome.cardCornerRadius, style: .continuous)
        if !performanceMode {
            content
                .glassEffect(.regular, in: shape)
                .background {
                    shape
                        .fill(Color(nsColor: .controlBackgroundColor).opacity(0.92))
                        .background(shape.fill(Color(nsColor: .windowBackgroundColor)))
                }
                .clipShape(shape)
        } else {
            content
                .background(shape.fill(Color(nsColor: .controlBackgroundColor)))
                .clipShape(shape)
                .overlay {
                    shape.strokeBorder(Chrome.overlay(isDark ? 0.14 : 0.08), lineWidth: 1)
                }
        }
    }
}
