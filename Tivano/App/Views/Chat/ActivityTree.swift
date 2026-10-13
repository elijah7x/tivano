import SwiftUI

/// The geometry of a turn's work, drawn flat on the conversation: a quiet summary line
/// with its chevron, and under it a thin tree whose trunk runs down the chevron's centre
/// and rounds off into a short branch for every step. The step's icon sits at the branch
/// tip and its words follow, so every step, thought and narrated line shares one column.
enum ActivityMetrics {
    /// The trunk's x, on a half point so a one-point line lands on whole pixels.
    static let trunkX: CGFloat = 12.5
    static let bendRadius: CGFloat = 6
    /// Where a branch stops, four points short of the step's icon.
    static let branchEndX: CGFloat = 28
    /// The gutter before a step's own icon column.
    static let gutterWidth: CGFloat = 32
    /// A step's first line, centred in a 32-point band: the branch meets it at the middle.
    static let stepPadding: CGFloat = 8
    static let branchY: CGFloat = 16
    static let headerHeight: CGFloat = 26
    /// The chevron's slot: the chevron's centre sits on the trunk.
    static let chevronSlot: CGFloat = 22
    static let chevronSize: CGFloat = 14
    static let headerSpacing: CGFloat = 6
    static let bodyTopPadding: CGFloat = 2
    static let lineOpacity = 0.12
    /// Past this many steps the oldest wait behind a paging row.
    static let stepPage = 60

    /// The fold, both ways.
    static let fold = Animation.easeOut(duration: 0.14)
    /// A step arriving: its words fade up from four points below.
    static let rowReveal = Animation.timingCurve(0.16, 1, 0.3, 1, duration: 0.36)
    static let revealLift: CGFloat = 4
    /// The branch drawing to a new step: brisk, then easing into the tip.
    static let connectorDuration: TimeInterval = 0.48
    static func connector(duration: TimeInterval) -> Animation {
        .timingCurve(0.22, 1, 0.36, 1, duration: duration)
    }
    /// The share of the connector's time the step above spends growing its trunk down to
    /// the new step, before the new step's own leg starts.
    static let continuationShare = 0.45
    /// A new group's first step waits for the header to land.
    static let firstStepDelay: TimeInterval = 0.09
}

/// The steps that already drew themselves in, so a step scrolling back into view, or a
/// block rebuilt by the lazy stack, never plays its arrival again.
@MainActor
enum ActivityReveal {
    private static var seen: Set<String> = []

    /// True the first time `id` is asked about, false every time after.
    static func claim(_ id: String) -> Bool {
        if seen.count > 20_000 { seen.removeAll(keepingCapacity: true) }
        return seen.insert(id).inserted
    }
}

/// The summary line over a group: "Thought 2 times · Ran 2 commands · Edited 3 files".
/// Counted from the steps' kinds only, so a step's streaming output never reworded it.
@MainActor
enum ActivitySummary {
    static func text(for entries: [TimelineEntry]) -> String {
        var thoughts = 0
        var commands = 0
        var edited: Set<String> = []
        var reads = 0
        var searches = 0
        var fetches = 0
        var tools = 0
        var failed = 0
        for entry in entries {
            switch entry.item.content {
            case .reasoning:
                thoughts += 1
            case .tool(let call):
                if call.status == .failed { failed += 1 }
                switch call.kind {
                case .command:
                    commands += 1
                    // A command that changed files edited them, as its edit lines show.
                    for edit in call.edits where !edit.path.isEmpty { edited.insert(edit.path) }
                case .edit:
                    let paths = call.edits.map(\.path).filter { !$0.isEmpty }
                    if paths.isEmpty { edited.insert(call.title) } else { edited.formUnion(paths) }
                case .read: reads += 1
                case .search: searches += 1
                case .web: fetches += 1
                case .mcp, .agent, .other: tools += 1
                }
            default:
                break
            }
        }
        var parts: [String] = []
        if thoughts == 1 { parts.append(Chrome.localized("Thought process")) }
        if thoughts > 1 { parts.append(String(format: Chrome.localized("Thought %d times"), thoughts)) }
        if commands > 0 { parts.append(count(commands, "Ran 1 command", "Ran %d commands")) }
        if !edited.isEmpty { parts.append(count(edited.count, "Edited 1 file", "Edited %d files")) }
        if reads > 0 { parts.append(count(reads, "Read 1 file", "Read %d files")) }
        if searches > 0 { parts.append(count(searches, "Searched once", "Searched %d times")) }
        if fetches > 0 { parts.append(count(fetches, "Fetched 1 page", "Fetched %d pages")) }
        if tools > 0 { parts.append(count(tools, "Called 1 tool", "Called %d tools")) }
        if failed > 0 { parts.append(String(format: Chrome.localized("%d failed"), failed)) }
        return parts.isEmpty ? Chrome.localized("Worked") : parts.joined(separator: " · ")
    }

    private static func count(_ n: Int, _ one: String, _ many: String) -> String {
        n == 1 ? Chrome.localized(one) : String(format: Chrome.localized(many), n)
    }
}

/// Aligns a tool row's icon with the branch tip without changing its content.
private struct ActivityTreeStyleKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var activityTreeStyle: Bool {
        get { self[ActivityTreeStyleKey.self] }
        set { self[ActivityTreeStyleKey.self] = newValue }
    }
}

/// The header line of a group, and of a finished turn: the chevron in the trunk's slot,
/// pointing down while open, and the title, quiet until the pointer is on it. A group the
/// turn is still working in sweeps a soft light across its title.
struct ActivityHeaderLabel: View {
    let title: String
    let isOpen: Bool
    var isActive = false
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: ActivityMetrics.headerSpacing) {
            Image(systemName: "chevron.down")
                .font(.chat(size: 9, weight: .semibold))
                .frame(width: ActivityMetrics.chevronSize, height: ActivityMetrics.chevronSize)
                .rotationEffect(.degrees(isOpen ? 0 : -90))
                .padding(.leading, ActivityMetrics.trunkX - ActivityMetrics.chevronSize / 2)
                .frame(width: ActivityMetrics.chevronSlot, alignment: .leading)
            Text(verbatim: title)
                .lineLimit(1)
                .truncationMode(.tail)
                .modifier(ActivityShimmer(isActive: isActive))
        }
        .font(.chat(.callout))
        .foregroundStyle(isHovering ? AnyShapeStyle(Chrome.primaryText) : AnyShapeStyle(Chrome.secondaryText))
        .frame(height: ActivityMetrics.headerHeight)
        .padding(.trailing, 4)
        .contentShape(.rect)
        .onHover { isHovering = $0 }
    }
}

/// A slow light sweeping across a working group's title. The highlight is the title again
/// in the primary colour, shown through a soft band that crosses it about every 1.7
/// seconds; a still frame while the reader scrolls, and none at all with reduced motion.
private struct ActivityShimmer: ViewModifier {
    let isActive: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("performanceMode", store: CaptureRun.defaults ?? .standard) private var performanceMode = false
    @State private var width: CGFloat = 0

    private static let period: TimeInterval = 3.4
    /// Half the band, as a share of the title's width.
    private static let halfBand: CGFloat = 0.36

    /// Where the band crossing the title is centred at `date`, in title widths: copies of
    /// the band sit three widths apart and travel six widths a period, so one crosses about
    /// every 1.7 seconds. Off the title (-1) between crossings.
    private static func bandCentre(at date: Date) -> CGFloat {
        let phase = CGFloat(date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period)
        let lead: CGFloat = -2.5 + phase * 6
        for copy in -2...2 {
            let centre = lead + CGFloat(copy) * 3
            if centre > -halfBand, centre < 1 + halfBand { return centre }
        }
        return -1
    }

    func body(content: Content) -> some View {
        if !isActive || reduceMotion || performanceMode {
            content
        } else {
            content
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
                .overlay {
                    TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: ScrollActivity.shared.isScrolling)) { context in
                        let centre = Self.bandCentre(at: context.date)
                        content
                            .foregroundStyle(Chrome.primaryText)
                            .mask(alignment: .leading) {
                                LinearGradient(
                                    stops: [
                                        .init(color: .clear, location: 0),
                                        .init(color: .white, location: 0.5),
                                        .init(color: .clear, location: 1),
                                    ],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                                .frame(width: max(1, width * Self.halfBand * 2))
                                .offset(x: (centre - Self.halfBand) * width)
                            }
                            .allowsHitTesting(false)
                    }
                }
        }
    }
}

/// The trunk coming down from above and rounding off into this step's branch.
private struct ActivityBranch: Shape {
    func path(in rect: CGRect) -> Path {
        let x = ActivityMetrics.trunkX
        let y = ActivityMetrics.branchY
        let r = ActivityMetrics.bendRadius
        var path = Path()
        path.move(to: CGPoint(x: x, y: 0))
        path.addLine(to: CGPoint(x: x, y: y - r))
        path.addQuadCurve(to: CGPoint(x: x + r, y: y), control: CGPoint(x: x, y: y))
        path.addLine(to: CGPoint(x: ActivityMetrics.branchEndX, y: y))
        return path
    }
}

/// The trunk carrying on past this step to the next one, alongside whatever the step
/// has opened beneath its line.
private struct ActivityContinuation: Shape {
    func path(in rect: CGRect) -> Path {
        let x = ActivityMetrics.trunkX
        var path = Path()
        path.move(to: CGPoint(x: x, y: ActivityMetrics.branchY - ActivityMetrics.bendRadius))
        path.addLine(to: CGPoint(x: x, y: rect.maxY))
        return path
    }
}

/// One step of a group: the gutter with its piece of the tree, then the step itself.
/// A step that arrives while the turn runs draws its branch in and then lifts its words
/// into place; one already there when the block was built draws whole and still.
private struct ActivityStep<Content: View>: View {
    let continues: Bool
    @ViewBuilder let content: Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("performanceMode", store: CaptureRun.defaults ?? .standard) private var performanceMode = false
    @State private var connector: CGFloat
    @State private var revealed: Bool
    private let delay: TimeInterval
    private let hasPredecessor: Bool

    init(id: String, hasPredecessor: Bool, continues: Bool, animatesArrival: Bool, isFirstOfNewGroup: Bool, @ViewBuilder content: () -> Content) {
        self.continues = continues
        self.content = content()
        self.hasPredecessor = hasPredecessor
        let arrives = ActivityReveal.claim(id) && animatesArrival
        _connector = State(initialValue: arrives ? 0 : 1)
        _revealed = State(initialValue: !arrives)
        delay = isFirstOfNewGroup ? ActivityMetrics.firstStepDelay : 0
    }

    private var motionEnabled: Bool { !reduceMotion && !performanceMode }

    var body: some View {
        // Opacity, offset and line trim leave the measured row height at its final value.
        content
            .padding(.vertical, ActivityMetrics.stepPadding)
            .opacity(!motionEnabled || revealed ? 1 : 0)
            .offset(y: !motionEnabled || revealed ? 0 : ActivityMetrics.revealLift)
            .padding(.leading, ActivityMetrics.gutterWidth)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(alignment: .topLeading) {
                ZStack(alignment: .topLeading) {
                    ActivityBranch()
                        .trim(from: 0, to: motionEnabled ? connector : 1)
                        .stroke(Chrome.primaryText.opacity(ActivityMetrics.lineOpacity), lineWidth: 1)
                    ActivityContinuation()
                        .trim(from: 0, to: continues ? 1 : 0)
                        .stroke(Chrome.primaryText.opacity(ActivityMetrics.lineOpacity), lineWidth: 1)
                        .animation(motionEnabled ? .easeIn(duration: ActivityMetrics.connectorDuration * ActivityMetrics.continuationShare) : nil, value: continues)
                }
                .frame(width: ActivityMetrics.gutterWidth)
                .frame(maxHeight: .infinity, alignment: .top)
                .accessibilityHidden(true)
            }
            .onAppear {
                guard motionEnabled else {
                    connector = 1
                    revealed = true
                    return
                }
                guard connector < 1 else { return }
                // Below a step, the trunk first grows down to this one; the first step of
                // a group draws its whole leg itself.
                let lead = hasPredecessor ? ActivityMetrics.connectorDuration * ActivityMetrics.continuationShare : 0
                let draw = ActivityMetrics.connectorDuration - lead
                withAnimation(ActivityMetrics.connector(duration: draw).delay(delay + lead)) { connector = 1 }
                // The words follow the branch into its tip.
                withAnimation(ActivityMetrics.rowReveal.delay(delay + lead + draw * 0.6)) { revealed = true }
            }
    }
}

/// A work group with the same initial fold and summary rules as the local list.
struct ActivityTreeGroup: View {
    let entries: [TimelineEntry]
    let runtime: ThreadRuntime
    var workingDirectory: String?
    var startsCollapsed = false
    @Environment(\.revealTimelineEnd) private var revealBox
    @Environment(\.timelineLiveAppearance) private var liveAppearance
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("performanceMode", store: CaptureRun.defaults ?? .standard) private var performanceMode = false
    @State private var isCollapsed: Bool
    @State private var stepLimit = ActivityMetrics.stepPage

    init(entries: [TimelineEntry], runtime: ThreadRuntime, workingDirectory: String? = nil, startsCollapsed: Bool = false) {
        self.entries = entries
        self.runtime = runtime
        self.workingDirectory = workingDirectory
        self.startsCollapsed = startsCollapsed
        _isCollapsed = State(initialValue: startsCollapsed)
    }

    private var isRunning: Bool {
        entries.contains { entry in
            switch entry.item.content {
            case .tool(let call): return call.status == .running
            case .reasoning(let block): return block.isStreaming
            case .assistant(let message): return message.isStreaming
            default: return false
            }
        }
    }

    private var summary: String {
        // Delegations keep the local wording even once the head has been sent out.
        let hasDelegation = entries.contains { entry in
            if case .tool(let call) = entry.item.content { return call.kind == .agent }
            return false
        }
        return isRunning || hasDelegation
            ? WorkGroupSummary.text(for: entries)
            : ActivitySummary.text(for: entries)
    }

    private var motionEnabled: Bool { !reduceMotion && !performanceMode }

    var body: some View {
        let isOpen = !isCollapsed
        let hidden = max(0, entries.count - stepLimit)
        let visible = hidden > 0 ? Array(entries.suffix(stepLimit)) : entries
        let animates = liveAppearance && isRunning && motionEnabled
        VStack(alignment: .leading, spacing: 0) {
            Button {
                // Animating this height (up to a page of steps) while the reader is
                // pinned to the end leaves the scroll offset past the content for a
                // few frames, and the timeline draws empty. The height changes at once.
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { isCollapsed.toggle() }
                if !isOpen { revealBox?.action() }
            } label: {
                ActivityHeaderLabel(title: summary, isOpen: isOpen, isActive: isRunning)
            }
            .buttonStyle(.plain)
            .help(Text(verbatim: Chrome.localized(isOpen ? "Hide these steps" : "Show these steps")))
            .accessibilityLabel(Text(verbatim: summary))
            .accessibilityHint(Text(verbatim: Chrome.localized(isOpen ? "Hides these steps" : "Shows these steps")))

            if isOpen {
                VStack(alignment: .leading, spacing: 0) {
                    if hidden > 0 {
                        Button {
                            stepLimit += ActivityMetrics.stepPage
                            revealBox?.action()
                        } label: {
                            Text(verbatim: TurnFinishedBlock.earlierStepsLabel(hidden: hidden))
                        }
                        .buttonStyle(.plain)
                        .font(.chat(.callout))
                        .foregroundStyle(Chrome.secondaryText)
                        .padding(.leading, ActivityMetrics.gutterWidth + TimelineMetrics.iconWidth + TimelineMetrics.iconSpacing)
                        .padding(.vertical, ActivityMetrics.stepPadding)
                    }
                    ForEach(Array(visible.enumerated()), id: \.element.id) { index, entry in
                        ActivityStep(
                            id: entry.id,
                            hasPredecessor: index > 0,
                            continues: index < visible.count - 1,
                            animatesArrival: animates,
                            isFirstOfNewGroup: index == 0
                        ) {
                            step(entry)
                        }
                    }
                }
                .padding(.top, ActivityMetrics.bodyTopPadding)
                .environment(\.activityTreeStyle, true)
                .transition(.identity)
            }
        }
        .onChange(of: startsCollapsed) { _, collapsed in
            if collapsed { isCollapsed = true }
        }
    }

    @ViewBuilder
    private func step(_ entry: TimelineEntry) -> some View {
        switch entry.kind {
        case .tool:
            ToolRow(entry: entry, runtime: runtime, workingDirectory: workingDirectory)
        case .reasoning:
            ActivityThoughtStep(entry: entry)
        case .assistant:
            ActivityNarrationStep(entry: entry, runtime: runtime)
        default:
            EmptyView()
        }
    }
}

/// The agent's thinking as a step: "Thought process" with its bubble, open while the
/// thinking still arrives and closing once it is done, unless the reader chose otherwise.
private struct ActivityThoughtStep: View {
    let entry: TimelineEntry
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("performanceMode", store: CaptureRun.defaults ?? .standard) private var performanceMode = false
    @State private var pin: Bool?
    @State private var isHovering = false

    var body: some View {
        if case .reasoning(let block) = entry.item.content {
            let isOpen = pin ?? block.isStreaming
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    withAnimation(reduceMotion || performanceMode ? nil : ActivityMetrics.fold) { pin = !isOpen }
                } label: {
                    HStack(spacing: TimelineMetrics.iconSpacing) {
                        Image(systemName: "bubble.left")
                            .font(.chat(.caption))
                            .foregroundStyle(Chrome.secondaryText)
                            .frame(width: TimelineMetrics.iconWidth)
                        Text(verbatim: Chrome.localized("Thought process"))
                            .foregroundStyle(isHovering ? Chrome.primaryText : Chrome.secondaryText)
                        Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                            .font(.chat(.caption2, weight: .semibold))
                            .foregroundStyle(Chrome.secondaryText)
                            .opacity(isHovering ? 1 : 0)
                    }
                    .font(.chat(.callout))
                    .padding(.trailing, 12)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .onHover { isHovering = $0 }
                .help(Text(verbatim: Chrome.localized(isOpen ? "Hide the thinking" : "Show the thinking")))
                if isOpen {
                    MarkdownView(text: block.text, isStreaming: block.isStreaming).equatable()
                        .foregroundStyle(Chrome.secondaryText)
                        .environment(\.markdownPointSize, TypeScale.shared.content(12))
                        .environment(\.markdownDimmed, true)
                        .padding(.leading, TimelineMetrics.iconWidth + TimelineMetrics.iconSpacing)
                        .padding(.trailing, 12)
                        .transition(reduceMotion || performanceMode ? .identity : .opacity)
                }
            }
        }
    }
}

/// A line the agent said on its way to the next step, read as a step: small and quiet,
/// in the column of the steps around it.
private struct ActivityNarrationStep: View {
    let entry: TimelineEntry
    let runtime: ThreadRuntime

    var body: some View {
        if case .assistant(let message) = entry.item.content {
            HStack(alignment: .firstTextBaseline, spacing: TimelineMetrics.iconSpacing) {
                Image(systemName: "text.bubble")
                    .font(.chat(.caption))
                    .foregroundStyle(Chrome.secondaryText)
                    .frame(width: TimelineMetrics.iconWidth)
                MarkdownView(text: message.text, isStreaming: message.isStreaming).equatable()
                    .foregroundStyle(Chrome.secondaryText)
                    .environment(\.markdownPointSize, TypeScale.shared.content(12))
                    .environment(\.markdownDimmed, true)
                    .padding(.trailing, 12)
            }
            .messageMenu(text: message.text, runtime: runtime)
        }
    }
}

