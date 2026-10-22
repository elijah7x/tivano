import AppKit
import SwiftUI

/// How far a head has got, as one bar filling in from the left: a stave for each thing it
/// did, in order, the taller the more it changed. A read, a search or a lookup is short and
/// faint, a command taller, an edit taller still, and a reply stands full height in the
/// head's own colour. Under it, what that amounts to; how long the head has been at it
/// sits in the strip's pill (see `HydraElapsedTime`). The steps themselves are the
/// sidebar's to show; here the shape of the work is enough, and a stave under the pointer
/// names the step it stands for on a card above the bar, as the timeline rail previews
/// the message under the pointer.
///
/// The staves live in Core Animation layers: a new stave rises over 0.45 s from the
/// moment its entry arrived, and a soft highlight crosses the filled staves over 2.6 s
/// with 3.4 s of rest between passes. Their motion stays on the render server, held
/// still while the reader scrolls or the bar has no window. A stave is always one step:
/// past what the width holds, the oldest steps slide off the left and the bar shows the
/// latest ones, so it always fits and keeps moving.
struct HydraProgressBar: View {
    let runtime: ThreadRuntime
    let startedAt: Date
    let finishedAt: Date?
    let status: HydraHeadInfo.Status
    /// The head's persona colour.
    let tint: Color
    /// The entries to draw, the runtime's whole list when nil.
    var entries: [TimelineEntry]? = nil

    @State private var width: CGFloat = 0
    /// The stave under the pointer, whose step the card names.
    @State private var hoveredIndex: Int?
    /// The last events, staves and counts, so an evaluation where nothing changed
    /// redraws without walking every entry again.
    @State private var cache = StaveCache()
    @State private var sweepRegistration = UUID()
    @State private var isMounted = false
    @Environment(\.chatColumnIsShown) private var chatColumnIsShown
    @Environment(\.isOnGlassPanel) private var isOnGlassPanel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(AppModel.self) private var model
    @AppStorage("performanceMode", store: CaptureRun.defaults ?? .standard) private var performanceMode = false

    fileprivate static let height: CGFloat = 28
    fileprivate static let staveWidth: CGFloat = 3
    fileprivate static let gap: CGFloat = 3
    fileprivate static let pitch = staveWidth + gap
    /// How long a new stave takes to rise to its height.
    fileprivate static let rise: TimeInterval = 0.45
    /// One pass of the highlight across the filled staves.
    fileprivate static let sweep: TimeInterval = 2.6
    /// The rest between two passes, so the bar mostly stands still.
    fileprivate static let sweepRest: TimeInterval = 3.4
    private static let cardWidth: CGFloat = 260
    /// How many bars sweep at once. Each band adds a render pass on the GPU; keeping
    /// the budget avoids twenty heads filling the GPU queue at once. The first few
    /// running heads keep the sweep, the rest stand still between staves, and a bar
    /// takes a slot as soon as one frees up.
    static let sweepSlots = 3

    /// The last events, staves and counts, keyed by entry identity plus each tool
    /// row's status, since a status flip rewrites the step's verb. A hit skips the
    /// walk over every entry when a hover or animation setting changes.
    @MainActor
    private final class StaveCache {
        private struct Key: Hashable {
            let id: ObjectIdentifier
            let status: ToolCall.Status?
            /// The title streams in for a row that has already arrived, and the step's
            /// label reads it.
            let title: String?
        }

        private var key: [Key] = []
        private var capacity = 0
        private var events: [Stave] = []
        private var staves: [Stave] = []
        private var counts = Counts(of: [])

        var snapshot: (events: [Stave], staves: [Stave], counts: Counts) {
            (events, staves, counts)
        }

        func resolve(entries: [TimelineEntry], capacity: Int) -> (events: [Stave], staves: [Stave], counts: Counts) {
            // Compared against the stored keys in place, not against an array built first:
            // the pointer crossing the staves re-evaluates this body once per slot, and
            // each of those passes would otherwise allocate one key per row of the head's
            // whole timeline only to throw it away again.
            if capacity == self.capacity, matches(entries) {
                return (events, staves, counts)
            }
            self.key = entries.map(Self.key(of:))
            self.capacity = capacity
            let events = HydraProgressBar.events(in: entries)
            let staves = HydraProgressBar.staves(for: events, capacity: capacity)
            let counts = Counts(of: events)
            self.events = events
            self.staves = staves
            self.counts = counts
            return (events, staves, counts)
        }

        /// Whether `entries` is the list the keys were taken from, walked against them
        /// without allocating and out at the first row that differs: the same answer
        /// `key == self.key` gave, for a fraction of the work on a hit.
        private func matches(_ entries: [TimelineEntry]) -> Bool {
            guard entries.count == key.count else { return false }
            for (index, entry) in entries.enumerated() {
                let cached = key[index]
                guard ObjectIdentifier(entry) == cached.id else { return false }
                if entry.kind == .tool, case .tool(let call) = entry.item.content, call.status != cached.status || call.title != cached.title {
                    return false
                }
            }
            return true
        }

        private static func key(of entry: TimelineEntry) -> Key {
            guard entry.kind == .tool, case .tool(let call) = entry.item.content else {
                return Key(id: ObjectIdentifier(entry), status: nil, title: nil)
            }
            return Key(id: ObjectIdentifier(entry), status: call.status, title: call.title)
        }
    }

    var body: some View {
        let capacity = max(1, Int(((width + Self.gap) / Self.pitch).rounded(.down)))
        let resolved = chatColumnIsShown
            ? cache.resolve(entries: entries ?? runtime.entries, capacity: capacity)
            : cache.snapshot
        let staves = resolved.staves
        let counts = resolved.counts
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let isRunning = status == .running
        let elapsed = RelativeTime.duration((isRunning ? Date.now : finishedAt ?? .now).timeIntervalSince(startedAt))
        let sweepRuntime = chatColumnIsShown && isRunning ? ObjectIdentifier(runtime) : nil
        let sweeps = chatColumnIsShown && isRunning && !reduceMotion && !performanceMode && SweepBudget.shared.sweeps(ObjectIdentifier(runtime))
        let isScrolling = chatColumnIsShown && ScrollActivity.shared.isScrolling
        let colors = HydraStaveColors(tint: tint, colorScheme: colorScheme)
        VStack(alignment: .leading, spacing: 6) {
            HydraStaves(
                staves: staves,
                capacity: capacity,
                colors: colors,
                status: status,
                hoveredIndex: chatColumnIsShown ? hoveredIndex : nil,
                isSweeping: sweeps,
                reduceMotion: reduceMotion || performanceMode,
                isScrolling: isScrolling,
                isColumnShown: chatColumnIsShown
            )
            .frame(height: Self.height)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            // The pointer picks the stave whose slot it is over; the slots past the
            // filled ones name nothing.
            .onContinuousHover(coordinateSpace: .local) { phase in
                guard chatColumnIsShown else { return }
                let index: Int? = switch phase {
                case .active(let point):
                    point.x >= 0 && point.y >= 0 && point.y <= Self.height
                        ? Int((point.x / Self.pitch).rounded(.down)) : nil
                case .ended: nil
                }
                let picked = index.map { $0 < staves.count ? $0 : nil } ?? nil
                if picked != hoveredIndex {
                    hoveredIndex = picked
                    if picked != nil {
                        switch model.settings.timelineHapticStyle {
                        case .soft: Haptics.perform(.generic)
                        case .strong: Haptics.perform(.alignment)
                        case .none: break
                        }
                    }
                }
            }
            .overlay(alignment: .topLeading) {
                if chatColumnIsShown, let hoveredIndex, hoveredIndex < staves.count {
                    stepsCard(for: staves[hoveredIndex], at: hoveredIndex)
                }
            }
            .animation(.smooth(duration: 0.15), value: hoveredIndex)
            if !counts.line.isEmpty {
                Text(verbatim: counts.line)
                    .font(.ui(.subheadline))
                    .foregroundStyle(Chrome.secondaryText)
                    .frame(maxWidth: .infinity)
            }
        }
        // Each mounted copy owns its registration, while slots remain per runtime.
        .onAppear {
            isMounted = true
            updateSweepRegistration(sweepRuntime)
        }
        .onChange(of: sweepRuntime) { _, runtimeID in
            guard isMounted else { return }
            updateSweepRegistration(runtimeID)
        }
        .onChange(of: chatColumnIsShown) { _, shown in
            if !shown { hoveredIndex = nil }
        }
        .onDisappear {
            isMounted = false
            hoveredIndex = nil
            SweepBudget.shared.leave(registration: sweepRegistration)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: String(format: Chrome.localized(isRunning ? "%@, %@ so far" : "%@, %@"), counts.sentence, elapsed)))
    }

    private func updateSweepRegistration(_ runtimeID: ObjectIdentifier?) {
        if let runtimeID {
            SweepBudget.shared.join(runtimeID, registration: sweepRegistration)
        } else {
            SweepBudget.shared.leave(registration: sweepRegistration)
        }
    }

    /// The step a stave stands for, on the rail's card. Sits just above the bar, centred on
    /// the stave as far as the bar's width allows, and never takes the pointer.
    private func stepsCard(for stave: Stave, at index: Int) -> some View {
        let centre = CGFloat(index) * Self.pitch + Self.staveWidth / 2
        let x = min(max(0, centre - Self.cardWidth / 2), max(0, width - Self.cardWidth))
        return HStack(spacing: 8) {
            if let entry = stave.mcp {
                MCPGlyph(entry: entry, size: 14)
            } else if let name = stave.symbol {
                Image(systemName: name)
                    .font(.ui(.callout, weight: .semibold))
                    .foregroundStyle(Chrome.secondaryText)
                    .frame(width: 14)
            }
            Text(verbatim: stave.step)
                .font(.ui(.body, weight: .semibold))
                .foregroundStyle(Chrome.primaryText)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(width: Self.cardWidth, alignment: .leading)
        .modifier(ProgressCardSurface(isOnGlassPanel: isOnGlassPanel, isDark: colorScheme == .dark))
        // Hung from a zero-height frame at the bar's top edge, so the card's bottom sits 8
        // points above the bar whatever its height: an alignment guide on the overlay
        // was not honoured and left the card over the staves.
        .padding(.bottom, 8)
        .frame(height: 0, alignment: .bottom)
        .offset(x: x)
        .allowsHitTesting(false)
        .transition(.opacity)
    }

    // MARK: - Steps

    /// One thing the head did, as the bar shows it.
    fileprivate struct Stave {
        enum Kind: Hashable {
            /// A read, a search, the web, an MCP tool, a helper: looking, not changing.
            case lookup
            case command
            case edit
            case reply
        }

        let id: ObjectIdentifier
        let kind: Kind
        let arrivedAt: Date
        /// What the stave stands for, for the card under the pointer.
        let step: String

        /// The step's own mark, where it has one: an MCP server's brand icon, or the
        /// kind's SF Symbol. Nil never happens; a reply wears a bubble.
        let mcp: MCPCatalogEntry?
        let symbol: String?

        /// The stave's share of the bar's height.
        var height: CGFloat {
            switch kind {
            case .lookup: 0.45
            case .command: 0.65
            case .edit: 0.85
            case .reply: 1
            }
        }
    }

    /// What the bar counts, for the line under it and the accessibility label.
    private struct Counts {
        var edits = 0
        var commands = 0
        var reads = 0

        init(of events: [Stave]) {
            for event in events {
                switch event.kind {
                case .edit: edits += 1
                case .command: commands += 1
                case .lookup: reads += 1
                case .reply: break
                }
            }
        }

        private var parts: [String] {
            var parts: [String] = []
            if edits > 0 { parts.append(edits == 1 ? Chrome.localized("1 edit") : String(format: Chrome.localized("%d edits"), edits)) }
            if commands > 0 { parts.append(commands == 1 ? Chrome.localized("1 command") : String(format: Chrome.localized("%d commands"), commands)) }
            if reads > 0 { parts.append(reads == 1 ? Chrome.localized("1 read") : String(format: Chrome.localized("%d reads"), reads)) }
            return parts
        }

        /// "3 edits · 2 commands · 5 reads", the zero parts left out.
        var line: String { parts.joined(separator: " · ") }

        var sentence: String {
            parts.isEmpty ? Chrome.localized("Nothing done yet") : parts.joined(separator: Chrome.localized(", "))
        }
    }

    /// One stave per tool call and per reply, in the order they happened.
    private static func events(in entries: [TimelineEntry]) -> [Stave] {
        entries.compactMap { entry in
            switch entry.kind {
            case .tool:
                guard case .tool(let call) = entry.item.content else { return nil }
                // A command that wrote files (a heredoc, a script over the source) is an
                // edit, the way its row already counts it, not one more command.
                let kind: Stave.Kind = switch call.kind {
                case .edit: .edit
                case .command: call.edits.isEmpty ? .command : .edit
                default: call.edits.isEmpty ? .lookup : .edit
                }
                let mcp = ToolPresentation.mcpParts(call)?.entry
                let symbol = mcp == nil ? ToolPresentation.symbol(for: call.kind) : nil
                return Stave(id: ObjectIdentifier(entry), kind: kind, arrivedAt: entry.item.date, step: ToolPresentation.label(for: call), mcp: mcp, symbol: symbol)
            case .assistant:
                guard case .assistant(let message) = entry.item.content else { return nil }
                // The first line of the reply is all the stave shows, so only the head of the
                // text is split, not the whole reply on every streamed flush.
                let words = TextCleanup.singleLine(String(message.text.prefix(600)), limit: 60)
                return Stave(id: ObjectIdentifier(entry), kind: .reply, arrivedAt: entry.item.date, step: words.isEmpty ? Chrome.localized("Replied") : String(format: Chrome.localized("Replied: %@"), words), mcp: nil, symbol: "bubble.left")
            default:
                return nil
            }
        }
    }

    /// The staves the bar draws, one per event: all of them while they fit, else the
    /// latest `capacity` of them, the oldest having slid off the left.
    private static func staves(for events: [Stave], capacity: Int) -> [Stave] {
        events.count > capacity ? Array(events.suffix(capacity)) : events
    }

}

/// Layers hold their colours, so SwiftUI resolves the same fills again when its scheme
/// or the head's tint changes instead of relying on AppKit's window appearance.
private struct HydraStaveColors: Equatable {
    let tint: CGColor
    let lookup: CGColor
    let command: CGColor
    let failed: CGColor
    let stopped: CGColor
    let empty: CGColor

    init(tint: Color, colorScheme: ColorScheme) {
        var environment = EnvironmentValues()
        environment.colorScheme = colorScheme
        self.tint = tint.resolve(in: environment).cgColor
        lookup = tint.opacity(0.4).resolve(in: environment).cgColor
        command = tint.opacity(0.7).resolve(in: environment).cgColor
        failed = Chrome.danger.resolve(in: environment).cgColor
        stopped = Chrome.secondaryText.resolve(in: environment).cgColor
        empty = Chrome.overlay(0.06).resolve(in: environment).cgColor
    }
}

private struct HydraStaves: NSViewRepresentable {
    let staves: [HydraProgressBar.Stave]
    let capacity: Int
    let colors: HydraStaveColors
    let status: HydraHeadInfo.Status
    let hoveredIndex: Int?
    /// A running bar holding one of `SweepBudget`'s slots may sweep.
    let isSweeping: Bool
    let reduceMotion: Bool
    /// The reader is scrolling somewhere: the sweep holds still until it lands.
    let isScrolling: Bool
    let isColumnShown: Bool

    func makeNSView(context: Context) -> HydraStavesLayerView {
        let view = HydraStavesLayerView()
        view.configure(
            staves: staves,
            capacity: capacity,
            colors: colors,
            status: status,
            hoveredIndex: hoveredIndex,
            isSweeping: isSweeping,
            reduceMotion: reduceMotion,
            isScrolling: isScrolling,
            isColumnShown: isColumnShown
        )
        return view
    }

    func updateNSView(_ view: HydraStavesLayerView, context: Context) {
        view.configure(
            staves: staves,
            capacity: capacity,
            colors: colors,
            status: status,
            hoveredIndex: hoveredIndex,
            isSweeping: isSweeping,
            reduceMotion: reduceMotion,
            isScrolling: isScrolling,
            isColumnShown: isColumnShown
        )
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: HydraStavesLayerView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }
}

private final class HydraStavesLayerView: NSView {
    /// One visible stave: its capsule, the entry it holds and the height it was last drawn at.
    private final class Slot {
        let shape = CAShapeLayer()
        let mask = CAShapeLayer()
        /// The entry the slot stands for. A different one raises the stave afresh.
        var key: ObjectIdentifier?
        var height: CGFloat = 0
        var fill: CGColor?
    }

    /// The empty slots past the filled ones.
    private let slotLayer = CAShapeLayer()
    /// Everything filled, one `Slot` each.
    private let stavesLayer = CALayer()
    /// The stave under the pointer, lifted towards white.
    private let hoverLayer = CAShapeLayer()
    /// The sweep's band, clipped to the filled staves by `sweepMask` on `sweepClip`.
    private let sweepClip = CALayer()
    private let sweepMask = CALayer()
    private let sweep = CAGradientLayer()

    private var staveSlots: [Slot] = []
    private var staves: [HydraProgressBar.Stave] = []
    private var capacity = 0
    private var colors: HydraStaveColors?
    private var status: HydraHeadInfo.Status = .running
    private var hoveredIndex: Int?
    private var isSweeping = false
    private var reduceMotion = false
    private var isScrolling = false
    private var isColumnShown = false
    private var filledWidth: CGFloat = 0
    private var band: CGFloat = 24
    private var lastContentBounds: CGRect?

    private static let riseKey = "rise"
    private static let sweepKey = "sweep"
    /// Never implicitly animated: geometry, paths and colours are set outright, and the
    /// two things that move belong to the explicit keyframes.
    private static let stillActions: [String: CAAction] = [
        "bounds": NSNull(), "position": NSNull(), "anchorPoint": NSNull(), "path": NSNull(),
        "fillColor": NSNull(), "transform": NSNull(), "opacity": NSNull(), "hidden": NSNull(),
        "colors": NSNull(), "locations": NSNull(), "startPoint": NSNull(), "endPoint": NSNull(),
        "frame": NSNull(),
    ]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        layer?.masksToBounds = false

        slotLayer.fillColor = nil
        hoverLayer.fillColor = NSColor.white.withAlphaComponent(0.4).cgColor
        sweepClip.mask = sweepMask

        sweep.type = .axial
        sweep.startPoint = CGPoint(x: 0, y: 0.5)
        sweep.endPoint = CGPoint(x: 1, y: 0.5)
        sweep.colors = [
            NSColor.white.withAlphaComponent(0).cgColor,
            NSColor.white.withAlphaComponent(0.55).cgColor,
            NSColor.white.withAlphaComponent(0).cgColor,
        ]
        sweepClip.addSublayer(sweep)

        for sublayer in [slotLayer, stavesLayer, hoverLayer, sweepClip, sweepMask, sweep] as [CALayer] {
            sublayer.actions = Self.stillActions
        }
        layer?.addSublayer(slotLayer)
        layer?.addSublayer(stavesLayer)
        layer?.addSublayer(sweepClip)

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(appHiddenDidChange), name: NSApplication.didHideNotification, object: nil)
        center.addObserver(self, selector: #selector(appHiddenDidChange), name: NSApplication.didUnhideNotification, object: nil)
        center.addObserver(self, selector: #selector(windowDidChangeOcclusionState(_:)), name: NSWindow.didChangeOcclusionStateNotification, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(
        staves: [HydraProgressBar.Stave],
        capacity: Int,
        colors: HydraStaveColors,
        status: HydraHeadInfo.Status,
        hoveredIndex: Int?,
        isSweeping: Bool,
        reduceMotion: Bool,
        isScrolling: Bool,
        isColumnShown: Bool
    ) {
        guard isColumnShown else {
            suspendColumn()
            return
        }
        let resumed = !self.isColumnShown
        self.isColumnShown = true
        let stavesChanged = !matches(staves)
        let colorsChanged = colors != self.colors
        let statusChanged = status != self.status
        let capacityChanged = capacity != self.capacity
        let hoverChanged = hoveredIndex != self.hoveredIndex
        let sweepChanged = isSweeping != self.isSweeping || reduceMotion != self.reduceMotion || isScrolling != self.isScrolling

        if stavesChanged { self.staves = staves }
        self.capacity = capacity
        self.colors = colors
        self.status = status
        self.hoveredIndex = hoveredIndex
        self.isSweeping = isSweeping
        self.reduceMotion = reduceMotion
        self.isScrolling = isScrolling

        // A hover move, a scroll flip or a slot freeing up changes nothing about the
        // staves: only what they affect is looked at again.
        if resumed || stavesChanged || colorsChanged || statusChanged || capacityChanged {
            applyContent()
        } else if hoverChanged {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            applyHoverLayer()
            CATransaction.commit()
        }
        if resumed || sweepChanged || stavesChanged || capacityChanged { refreshAnimations() }
    }

    private func suspendColumn() {
        guard isColumnShown else { return }
        isColumnShown = false
        hoveredIndex = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        setPaused(true, on: stavesLayer)
        setPaused(true, on: sweepClip)
        hoverLayer.path = nil
        hoverLayer.removeFromSuperlayer()
        sweep.removeAnimation(forKey: Self.sweepKey)
        sweepClip.isHidden = true
        // A column can stay mounted indefinitely. Rebuild rises from arrival time
        // when it returns, rather than resuming an old presentation-layer clock.
        for slot in staveSlots {
            slot.shape.removeAnimation(forKey: Self.riseKey)
            slot.mask.removeAnimation(forKey: Self.riseKey)
        }
        CATransaction.commit()
    }

    /// Whether `staves` is the list the layers were last built for, walked in place and
    /// out at the first stave that differs. A streamed title rewrites a row's step text
    /// but not a stave's shape, so it is not one of these.
    private func matches(_ new: [HydraProgressBar.Stave]) -> Bool {
        guard new.count == staves.count else { return false }
        for (index, stave) in new.enumerated() {
            let cached = staves[index]
            guard stave.id == cached.id, stave.kind == cached.kind, stave.arrivedAt == cached.arrivedAt else { return false }
        }
        return true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // A detached bar holds its local clock, just as it does during a scroll.
        if window != nil { applyContent() }
        refreshAnimations()
    }

    @objc private func appHiddenDidChange() {
        refreshAnimations()
    }

    @objc private func windowDidChangeOcclusionState(_ note: Notification) {
        // Every window ordered in posts this, popovers and tooltips included: only this
        // view's own window coming back into view concerns it.
        guard let window, (note.object as? NSWindow) === window else { return }
        refreshAnimations()
    }

    override func layout() {
        super.layout()
        guard lastContentBounds != bounds else { return }
        applyContent()
        refreshAnimations()
    }

    /// Everything but the sweep's own state: the staves, the empty slots, the highlight
    /// and the sweep's geometry, all set with actions off so a re-render moves nothing.
    private func applyContent() {
        guard isColumnShown, bounds.width > 0, bounds.height > 0 else { return }
        lastContentBounds = bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        slotLayer.frame = bounds
        stavesLayer.frame = bounds
        applyStaveLayers()
        applyEmptySlots()
        applyHoverLayer()
        applySweepGeometry()
        CATransaction.commit()
    }

    private func applyStaveLayers() {
        let height = bounds.height
        while staveSlots.count < staves.count {
            let slot = Slot()
            // The baseline is the anchor, so a rise grows upward from it, and nothing on
            // the layer is implicitly animated.
            slot.shape.anchorPoint = CGPoint(x: 0.5, y: 0)
            slot.shape.actions = Self.stillActions
            slot.mask.anchorPoint = slot.shape.anchorPoint
            slot.mask.actions = Self.stillActions
            slot.mask.fillColor = NSColor.black.cgColor
            stavesLayer.addSublayer(slot.shape)
            sweepMask.addSublayer(slot.mask)
            staveSlots.append(slot)
        }
        for (index, slot) in staveSlots.enumerated() {
            guard index < staves.count else {
                // Past the filled ones: the layer stays for reuse, drawn empty.
                slot.key = nil
                slot.height = 0
                slot.fill = nil
                slot.shape.path = nil
                slot.mask.path = nil
                slot.shape.removeAnimation(forKey: Self.riseKey)
                slot.mask.removeAnimation(forKey: Self.riseKey)
                continue
            }
            let stave = staves[index]
            if slot.key != stave.id {
                // A different entry in this slot: it arrives from the baseline.
                slot.key = stave.id
                slot.height = 0
                slot.shape.removeAnimation(forKey: Self.riseKey)
                slot.mask.removeAnimation(forKey: Self.riseKey)
                slot.shape.transform = CATransform3DIdentity
                slot.mask.transform = CATransform3DIdentity
            }
            let staveHeight = height * stave.height
            if slot.height != staveHeight {
                slot.height = staveHeight
                slot.shape.bounds = CGRect(x: 0, y: 0, width: HydraProgressBar.staveWidth, height: staveHeight)
                slot.shape.path = CGPath(
                    roundedRect: CGRect(x: 0, y: 0, width: HydraProgressBar.staveWidth, height: staveHeight),
                    cornerWidth: HydraProgressBar.staveWidth / 2,
                    cornerHeight: HydraProgressBar.staveWidth / 2,
                    transform: nil
                )
                slot.mask.bounds = slot.shape.bounds
                slot.mask.path = slot.shape.path
            }
            // The layer's y runs upward from the bar's baseline, as the canvas drew from
            // the bottom of its frame.
            slot.shape.position = CGPoint(
                x: CGFloat(index) * HydraProgressBar.pitch + HydraProgressBar.staveWidth / 2,
                y: 0
            )
            slot.mask.position = slot.shape.position
            let fill = fillColor(for: stave, at: index)
            if slot.fill != fill {
                slot.fill = fill
                slot.shape.fillColor = fill
            }
        }
    }

    /// The faint slots where the bar has yet to fill, all in one path.
    private func applyEmptySlots() {
        let height = bounds.height * 0.45
        guard staves.count < capacity else {
            slotLayer.path = nil
            return
        }
        let path = CGMutablePath()
        for slot in staves.count..<capacity {
            path.addRoundedRect(
                in: CGRect(x: CGFloat(slot) * HydraProgressBar.pitch, y: 0, width: HydraProgressBar.staveWidth, height: height),
                cornerWidth: HydraProgressBar.staveWidth / 2,
                cornerHeight: HydraProgressBar.staveWidth / 2
            )
        }
        slotLayer.path = path
        slotLayer.fillColor = colors?.empty
    }

    private func applyHoverLayer() {
        guard let index = hoveredIndex, staves.indices.contains(index) else {
            hoverLayer.path = nil
            hoverLayer.removeFromSuperlayer()
            return
        }
        let shape = staveSlots[index].shape
        if hoverLayer.superlayer !== shape {
            hoverLayer.removeFromSuperlayer()
            shape.addSublayer(hoverLayer)
        }
        hoverLayer.frame = shape.bounds
        hoverLayer.path = shape.path
    }

    private func applySweepGeometry() {
        let height = bounds.height
        let filled = staves.isEmpty ? 0 : CGFloat(staves.count) * HydraProgressBar.pitch - HydraProgressBar.gap
        let newBand = max(24, filled / 3)
        // The band's travel is baked into its animation, so a change to the width it
        // crosses has to put the animation back with the new values.
        if filled != filledWidth || newBand != band {
            sweep.removeAnimation(forKey: Self.sweepKey)
        }
        filledWidth = filled
        band = newBand
        sweepClip.frame = CGRect(x: 0, y: 0, width: filled, height: height)
        sweepMask.frame = sweepClip.bounds
        sweep.bounds = CGRect(x: 0, y: 0, width: band, height: height)
        // Off the left edge when it is not running: masked away, and where the keyframe
        // starts from.
        sweep.position = CGPoint(x: -band / 2, y: height / 2)
    }

    /// A stave's colour: the kind's share of the head's tint, except the last stave of a
    /// head that failed or was stopped, which wears the status colour instead.
    private func fillColor(for stave: HydraProgressBar.Stave, at index: Int) -> CGColor {
        guard let colors else { return NSColor.clear.cgColor }
        if index == staves.count - 1 {
            if status == .failed { return colors.failed }
            if status == .stopped { return colors.stopped }
        }
        switch stave.kind {
        case .lookup: return colors.lookup
        case .command: return colors.command
        case .edit, .reply: return colors.tint
        }
    }

    /// The launch of a stave's rise, from the moment its entry arrived. Put on once per
    /// arrival: a re-render, a theme change or the sweep's state changing never replays it.
    /// The parent layer's local clock holds an unfinished rise through a scroll or detach.
    private func refreshRise(on slot: Slot, for stave: HydraProgressBar.Stave) {
        guard !reduceMotion else {
            slot.shape.removeAnimation(forKey: Self.riseKey)
            slot.mask.removeAnimation(forKey: Self.riseKey)
            return
        }
        guard slot.shape.animation(forKey: Self.riseKey) == nil else { return }
        let age = Date.now.timeIntervalSince(stave.arrivedAt)
        guard age < HydraProgressBar.rise, age >= 0 else {
            slot.shape.removeAnimation(forKey: Self.riseKey)
            slot.mask.removeAnimation(forKey: Self.riseKey)
            return
        }
        let animation = CABasicAnimation(keyPath: "transform.scale.y")
        animation.fromValue = 0
        animation.toValue = 1
        animation.timingFunction = CAMediaTimingFunction(controlPoints: 1.0 / 3.0, 1, 2.0 / 3.0, 1)
        animation.duration = HydraProgressBar.rise
        animation.beginTime = slot.shape.convertTime(CACurrentMediaTime(), from: nil) - age
        slot.shape.add(animation, forKey: Self.riseKey)
        animation.beginTime = slot.mask.convertTime(CACurrentMediaTime(), from: nil) - age
        slot.mask.add(animation, forKey: Self.riseKey)
    }

    /// The sweep on or off, frozen or running. The animation is put on with one fixed
    /// phase when it starts, then its parent holds that phase through scrolling and
    /// time away from the window.
    private func refreshAnimations() {
        guard isColumnShown else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let paused = isScrolling || !isVisibleInWindow
        setPaused(paused, on: stavesLayer)
        setPaused(paused, on: sweepClip)
        if !paused || reduceMotion {
            for (index, slot) in staveSlots.enumerated() where index < staves.count {
                refreshRise(on: slot, for: staves[index])
            }
        }
        guard isSweeping, !reduceMotion, !staves.isEmpty else {
            sweep.removeAnimation(forKey: Self.sweepKey)
            sweepClip.isHidden = true
            return
        }
        sweepClip.isHidden = false
        if !paused, sweep.animation(forKey: Self.sweepKey) == nil {
            installSweep()
        }
    }

    private func setPaused(_ paused: Bool, on layer: CALayer) {
        guard paused != (layer.speed == 0) else { return }
        if paused {
            let time = layer.convertTime(CACurrentMediaTime(), from: nil)
            layer.speed = 0
            layer.timeOffset = time
        } else {
            // Keep the local clock's place so a scroll never consumes the rest of a rise.
            let time = layer.timeOffset
            layer.speed = 1
            layer.timeOffset = 0
            layer.beginTime = 0
            layer.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) - time
        }
    }

    private var isVisibleInWindow: Bool {
        guard !NSApp.isHidden, let window, window.isVisible, !window.isMiniaturized,
              window.occlusionState.contains(.visible) else { return false }
        return true
    }

    /// One pass of the band in `sweep` seconds, then a `sweepRest` rest past the right
    /// edge, repeating. Both ends lie outside the filled staves, so the mask hides the
    /// band at rest. The model position stays off the left edge.
    private func installSweep() {
        guard filledWidth > 0 else { return }
        let start = -band / 2
        let end = filledWidth + band / 2
        let animation = CAKeyframeAnimation(keyPath: "position.x")
        animation.values = [start, end, end]
        animation.keyTimes = [
            0,
            NSNumber(value: HydraProgressBar.sweep / (HydraProgressBar.sweep + HydraProgressBar.sweepRest)),
            1,
        ]
        animation.duration = HydraProgressBar.sweep + HydraProgressBar.sweepRest
        animation.repeatCount = .infinity
        animation.calculationMode = .linear
        animation.isRemovedOnCompletion = false
        let within = Date.now.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: animation.duration)
        animation.beginTime = sweep.convertTime(CACurrentMediaTime(), from: nil) - within
        sweep.position = CGPoint(x: start, y: sweep.position.y)
        sweep.add(animation, forKey: Self.sweepKey)
    }

}

/// A head's panel with "Show what heads are doing" off: what it was sent to do, centred on
/// one row, and the progress bar under it, centred where the transcript would be. How long
/// the head has been at it sits in the strip's pill beside its name.
struct HydraHeadProgress: View {
    let head: ChatThread
    let runtime: ThreadRuntime

    var body: some View {
        let info = head.hydra
        let task = info?.task.trimmed ?? ""
        let status = info?.status ?? .running
        let startedAt = info?.startedAt ?? head.createdAt
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            HydraWorkingTitle(text: task.isEmpty ? head.title : task, isRunning: status == .running)
                .frame(maxWidth: .infinity)
            HydraProgressBar(
                runtime: runtime,
                startedAt: startedAt,
                finishedAt: info?.finishedAt,
                status: status,
                tint: (info?.persona ?? HydraRoster.persona(at: 0)).color
            )
            .padding(.top, 10)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        // The strip overlays the top of the panel and the chat box is an inset at the
        // bottom: the room under the strip is what the task and the bar centre in.
        .padding(.top, HydraPanel.stripHeight)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The head's task. While the head works the text breathes, so a bar with nothing on
/// it yet still reads as a head at work. Done, or with reduced motion, it is plain text.
struct HydraWorkingTitle: View {
    let text: String
    let isRunning: Bool
    var alignment: TextAlignment = .center
    @Environment(\.chatColumnIsShown) private var chatColumnIsShown
    @AppStorage("performanceMode", store: CaptureRun.defaults ?? .standard) private var performanceMode = false

    /// One breath, in and out.
    private static let breath: TimeInterval = 3.2

    var body: some View {
        let animates = chatColumnIsShown && isRunning && FrontMonitor.shared.isVisible && !performanceMode && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let title = Text(verbatim: text)
            .font(.ui(.body, weight: .medium))
            .foregroundStyle(Chrome.primaryText)
        TimelineView(.animation(minimumInterval: 1.0 / 12.0, paused: !animates || ScrollActivity.shared.isScrolling)) { context in
            let now = context.date.timeIntervalSinceReferenceDate
            let breath = animates ? 0.5 + 0.5 * sin(now / Self.breath * 2 * .pi) : 1.0
            title
                .opacity(0.72 + 0.28 * breath)
        }
        .lineLimit(2)
        .multilineTextAlignment(alignment)
    }
}

/// How long the head has been at it, ticking every second while it works. Only this text
/// follows the clock: whatever holds it is drawn once.
struct HydraElapsedTime: View {
    let startedAt: Date
    let finishedAt: Date?
    let isRunning: Bool
    @Environment(\.chatColumnIsShown) private var chatColumnIsShown

    var body: some View {
        Group {
            if isRunning && chatColumnIsShown && FrontMonitor.shared.isVisible {
                TimelineView(.periodic(from: startedAt, by: 1)) { context in
                    Text(verbatim: RelativeTime.duration(context.date.timeIntervalSince(startedAt)))
                }
            } else {
                Text(verbatim: RelativeTime.duration((finishedAt ?? .now).timeIntervalSince(startedAt)))
            }
        }
        .font(.ui(.subheadline))
        .monospacedDigit()
        .foregroundStyle(Chrome.secondaryText)
    }
}

/// The card's surface: glass, unless it floats inside a glass panel already, where a
/// second glass over the first would sample the same pixels twice; there it is a flat
/// fill of the panel's control colour.
private struct ProgressCardSurface: ViewModifier {
    let isOnGlassPanel: Bool
    let isDark: Bool
    @AppStorage("performanceMode", store: CaptureRun.defaults ?? .standard) private var performanceMode = false

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Chrome.cardCornerRadius, style: .continuous)
        if isOnGlassPanel {
            content.background(shape.fill(Chrome.panelControlFill(isDark: isDark)))
        } else if performanceMode {
            content
                .background(shape.fill(Color(nsColor: .controlBackgroundColor)))
                .clipShape(shape)
                .overlay {
                    shape.strokeBorder(Chrome.overlay(isDark ? 0.14 : 0.08), lineWidth: 1)
                }
        } else {
            content
                .glassEffect(.regular, in: shape)
                .background {
                    shape
                        .fill(Color(nsColor: .controlBackgroundColor).opacity(0.92))
                        .background(shape.fill(Color(nsColor: .windowBackgroundColor)))
                }
                .clipShape(shape)
        }
    }
}

/// Which bars sweep: the first `HydraProgressBar.sweepSlots` running bars to ask, in the
/// order they asked. Observed, so a bar next in line redraws with the sweep the moment a
/// slot frees up, and a bar losing its slot stops its clock on the same change.
@MainActor
@Observable
final class SweepBudget {
    static let shared = SweepBudget()
    private(set) var sweepers: [ObjectIdentifier] = []
    @ObservationIgnored private var registrations: [UUID: ObjectIdentifier] = [:]

    func join(_ id: ObjectIdentifier, registration: UUID) {
        guard registrations[registration] != id else { return }
        leave(registration: registration)
        registrations[registration] = id
        guard !sweepers.contains(id) else { return }
        sweepers.append(id)
    }

    func leave(registration: UUID) {
        guard let id = registrations.removeValue(forKey: registration),
              !registrations.values.contains(id) else { return }
        guard let index = sweepers.firstIndex(of: id) else { return }
        sweepers.remove(at: index)
    }

    func sweeps(_ id: ObjectIdentifier) -> Bool {
        sweepers.prefix(HydraProgressBar.sweepSlots).contains(id)
    }
}
