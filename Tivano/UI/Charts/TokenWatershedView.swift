import AppKit
import SwiftUI

enum TokenWatershedPalette {
    static func color(forTool id: String) -> Color {
        let index: Int
        switch id.lowercased() {
        case "claude", "claude-code", "claude_code", "claudecode": index = 0
        case "codex", "openai-codex": index = 1
        case "gemini", "gemini-cli", "gemini_cli": index = 2
        case "opencode", "open-code": index = 3
        case "cursor": index = 4
        case "kimi", "kimi-cli", "kimi_cli": index = 5
        default:
            let hash = id.lowercased().utf8.reduce(UInt64(14_695_981_039_346_656_037)) {
                ($0 ^ UInt64($1)) &* 1_099_511_628_211
            }
            index = Int(hash % 6)
        }
        let accent = NSColor(Chrome.accent), blue = NSColor(Chrome.blue)
        let orange = NSColor(Chrome.orange), gray = NSColor(Chrome.gray)
        let colors = [accent, blue.blended(withFraction: 0.45, of: accent) ?? blue,
                      blue, gray.blended(withFraction: 0.3, of: accent) ?? gray,
                      orange, orange.blended(withFraction: 0.55, of: accent) ?? orange]
        return Color(nsColor: colors[index].blended(withFraction: 0.35, of: gray) ?? colors[index])
    }
}

struct TokenWatershedData: Equatable {
    let aggregate: TokenWatershedAggregate
    let palette: [String: Color]
    let summaryText: String

    init(rows: [TokenUsageRow]) {
        let aggregate = TokenWatershedAggregate(rows: rows)
        self.aggregate = aggregate
        self.palette = Dictionary(uniqueKeysWithValues: aggregate.tools.keys.map {
            ($0, TokenWatershedPalette.color(forTool: $0))
        })
        let tool = aggregate.tools.max {
            $0.value.tokens == $1.value.tokens ? $0.key > $1.key : $0.value.tokens < $1.value.tokens
        }?.key
        let model = aggregate.models.max {
            $0.value.tokens == $1.value.tokens ? $0.key > $1.key : $0.value.tokens < $1.value.tokens
        }?.key
        self.summaryText = String(
            format: Chrome.localized("Token watershed: %@ tokens. Top tool: %@. Top model: %@."),
            TokenWatershedFormat.exact(aggregate.total.tokens),
            tool.map { TokenUsageTool.displayName(for: $0) } ?? "—",
            model ?? "—"
        )
    }
}

struct TokenWatershedView: View {
    private let data: TokenWatershedData
    private var aggregate: TokenWatershedAggregate { data.aggregate }
    private let metric: TokenWatershedMetric
    private let isAnimating: Bool
    private let refreshToken: Int
    @Binding private var selection: TokenWatershedSelection?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var previous = TokenWatershedLayout()
    @State private var target = TokenWatershedLayout()
    @State private var palette: [String: Color] = [:]
    @State private var revision: Double = 0
    @State private var morphStarted: Date?
    @State private var hovered: TokenWatershedSelection?
    @FocusState private var focused: TokenWatershedSelection?
    @State private var expanded = false
    @State private var visible = false
    @State private var hasAppeared = false
    @State private var arrivalStarted: Date?
    @State private var flowStarted: Date?
    @State private var flowElapsed: TimeInterval = 0

    init(data: TokenWatershedData, metric: TokenWatershedMetric, isAnimating: Bool,
         selection: Binding<TokenWatershedSelection?>, refreshToken: Int) {
        self.data = data
        self.metric = metric
        self.isAnimating = isAnimating
        self._selection = selection
        self.refreshToken = refreshToken
    }

    private struct Request: Equatable {
        var aggregate: TokenWatershedAggregate
        var metric: TokenWatershedMetric
        var width: CGFloat
        var expanded: Bool
        var slot: CGFloat
    }

    private var running: Bool { isAnimating && visible && !reduceMotion && scenePhase == .active }
    private var active: TokenWatershedSelection? { selection ?? hovered ?? focused }

    var body: some View {
        let slot = max(24, TypeScale.shared.ui(24))
        let height = aggregate.height(metric: metric, expanded: expanded, slot: slot)
        VStack(alignment: .leading, spacing: Chrome.trayGap) {
            GeometryReader { proxy in
                let width = max(720, proxy.size.width)
                let request = Request(aggregate: aggregate, metric: metric, width: width, expanded: expanded, slot: slot)
                ScrollView(.horizontal) {
                    TokenWatershedMorph(
                        from: previous, to: target, phase: revision, endPhase: revision,
                        palette: palette.isEmpty ? data.palette : palette,
                        active: active, focused: $focused, selection: selection,
                        running: running, arrivalStarted: arrivalStarted,
                        flowStarted: flowStarted, flowElapsed: flowElapsed,
                        onHover: { hovered = $0 }, onPin: pin
                    )
                    .frame(width: width, height: height)
                    .onChange(of: request, initial: true) { _, value in update(value) }
                }
                .scrollIndicators(.hidden)
            }
            .frame(height: height)
            .background(Chrome.overlay(0.03), in: RoundedRectangle(cornerRadius: Chrome.cardCornerRadius))
            .onKeyPress(.leftArrow) { moveFocus(column: -1, row: 0); return .handled }
            .onKeyPress(.rightArrow) { moveFocus(column: 1, row: 0); return .handled }
            .onKeyPress(.upArrow) { moveFocus(column: 0, row: -1); return .handled }
            .onKeyPress(.downArrow) { moveFocus(column: 0, row: 1); return .handled }
            .onKeyPress(.escape) { selection = nil; hovered = nil; return .handled }

            HStack(alignment: .firstTextBaseline, spacing: Chrome.groupGap) {
                if metric == .tokens { Text("Width = tokens") } else { Text("Width = priced USD") }
                Spacer(minLength: Chrome.trayGap)
                if expanded && !aggregate.foldedModels(metric: metric).isEmpty {
                    Button("Fold small models") { expanded = false; selection = nil; hovered = nil }
                        .buttonStyle(.plain)
                        .foregroundStyle(Chrome.accent)
                }
                Text("Reasoning is part of Output")
            }
            .font(.ui(.caption2))
            .foregroundStyle(Chrome.secondaryText)

            if aggregate.total.unpricedTokens > 0 {
                Text(verbatim: String(format: Chrome.localized("%@ unpriced tokens; excluded from cost widths"),
                                      TokenWatershedFormat.exact(aggregate.total.unpricedTokens)))
                    .font(.ui(.caption))
                    .foregroundStyle(Chrome.secondaryText)
            }
            if metric == .cost && aggregate.total.tokens > 0 && aggregate.total.value(.cost) == 0 {
                Text("No priced cost in this range")
                    .font(.ui(.caption)).foregroundStyle(Chrome.secondaryText)
            }
            inspector
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: data.summaryText))
        .onAppear {
            visible = true
            if !hasAppeared {
                hasAppeared = true
                arrivalStarted = isAnimating && !reduceMotion ? Date() : nil
            }
        }
        .onDisappear { visible = false }
        .onChange(of: running) { _, nowRunning in
            if nowRunning {
                flowStarted = Date()
            } else {
                if let flowStarted { flowElapsed += Date().timeIntervalSince(flowStarted) }
                flowStarted = nil
                arrivalStarted = nil
            }
        }
        .onChange(of: refreshToken) { _, _ in arrivalStarted = running ? Date() : nil }
        .onChange(of: reduceMotion) { _, reduced in
            if reduced { previous = target; morphStarted = nil }
        }
    }

    @ViewBuilder private var inspector: some View {
        // A dedicated region below the plot keeps every highlighted curve unobscured.
        let resolved = target.resolved(active)
        let node = target.nodes.first { $0.id == resolved }
        ChromeCard {
            VStack(alignment: .leading, spacing: Chrome.trayGap) {
                HStack(spacing: Chrome.groupGap) {
                    if let node {
                        Text(verbatim: TokenWatershedFormat.title(node)).font(.ui(.subheadline, weight: .medium))
                    } else {
                        Text("Explore token paths").font(.ui(.subheadline, weight: .medium))
                    }
                    Spacer(minLength: Chrome.trayGap)
                    if selection != nil {
                        Text("Selection pinned · Escape clears")
                    } else {
                        Text("Hover to inspect · Click to pin")
                    }
                }
                .foregroundStyle(Chrome.secondaryText)
                if let node {
                    let amounts = node.amounts
                    HStack(alignment: .top, spacing: Chrome.sectionSpacing) {
                        detail("Tokens", value: TokenWatershedFormat.exact(amounts.tokens))
                        detail("Share of range tokens", value: TokenWatershedFormat.share(Double(amounts.tokens), of: Double(target.total.tokens)))
                        detail("Priced cost", value: amounts.pricedTokens > 0 ? TokenWatershedFormat.money(amounts.cost, exact: true) : Chrome.localized("Unpriced"))
                        detail("Reasoning (in Output)", value: TokenWatershedFormat.exact(amounts.reasoning))
                    }
                    HStack(spacing: Chrome.groupGap) {
                        Text(verbatim: String(format: Chrome.localized("Share of priced cost: %@"),
                            amounts.pricedTokens > 0 ? TokenWatershedFormat.share(amounts.value(.cost), of: target.total.value(.cost)) : "—"))
                        Text(verbatim: String(format: Chrome.localized("%@ unpriced tokens"), TokenWatershedFormat.exact(amounts.unpricedTokens)))
                    }
                    .foregroundStyle(Chrome.secondaryText)
                } else {
                    Text("Follow each tool through shared models to token types.")
                        .foregroundStyle(Chrome.secondaryText)
                    Text("Use arrow keys to explore · Return to pin")
                        .foregroundStyle(Chrome.secondaryText)
                }
            }
            .font(.ui(.caption))
            .padding(Chrome.contentHorizontalPadding)
            .frame(maxWidth: .infinity, minHeight: TypeScale.shared.ui(112), alignment: .topLeading)
        }
    }

    private func detail(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: Chrome.capsuleVerticalPadding) {
            Text(verbatim: Chrome.localized(title)).foregroundStyle(Chrome.secondaryText)
            Text(verbatim: value).monospacedDigit().foregroundStyle(Chrome.primaryText).textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func update(_ request: Request) {
        palette.merge(data.palette) { _, new in new }
        let next = TokenWatershedLayout(aggregate: request.aggregate, metric: request.metric,
                                       width: request.width, expanded: request.expanded, slot: request.slot)
        hovered = nil
        if let focused, !next.nodes.contains(where: { $0.id == focused }) { self.focused = nil }
        if let selection, !next.nodes.contains(where: { $0.id == next.resolved(selection) }) { self.selection = nil }
        if target.size == .zero || reduceMotion || scenePhase != .active {
            previous = next
            target = next
            morphStarted = nil
            return
        }
        let progress = morphStarted.map { min(1, Date().timeIntervalSince($0) / 0.6) } ?? 1
        previous = previous.interpolated(to: target, fraction: progress)
        target = next
        morphStarted = Date()
        // Animatable interpolation is independent of the arrival/flow clock.
        // Continue from the presentation phase when a range drag interrupts a morph.
        withAnimation(.linear(duration: 0.6)) { revision += progress }
    }

    private func pin(_ item: TokenWatershedSelection?) {
        guard let item else { selection = nil; hovered = nil; focused = nil; return }
        if item == .model(TokenWatershedLayout.otherModels), !target.folded.isEmpty {
            expanded = true
            selection = nil
            hovered = nil
            return
        }
        selection = selection == item ? nil : item
        focused = item
    }

    private func moveFocus(column: Int, row: Int) {
        guard let current = target.nodes.first(where: { $0.id == focused }) ?? target.nodes.first else { return }
        if column != 0 {
            let destination = min(2, max(0, current.column + column))
            focused = target.nodes.filter { $0.column == destination }
                .min { abs($0.labelY - current.labelY) < abs($1.labelY - current.labelY) }?.id
        } else {
            let list = target.nodes.filter { $0.column == current.column }
            guard !list.isEmpty else { return }
            let index = list.firstIndex { $0.id == current.id } ?? 0
            focused = list[(index + row + list.count) % list.count].id
        }
        hovered = nil
    }
}

private struct TokenWatershedMorph: View, Animatable {
    let from: TokenWatershedLayout
    let to: TokenWatershedLayout
    var phase: Double
    let endPhase: Double
    let palette: [String: Color]
    let active: TokenWatershedSelection?
    var focused: FocusState<TokenWatershedSelection?>.Binding
    let selection: TokenWatershedSelection?
    let running: Bool
    let arrivalStarted: Date?
    let flowStarted: Date?
    let flowElapsed: TimeInterval
    let onHover: (TokenWatershedSelection?) -> Void
    let onPin: (TokenWatershedSelection?) -> Void

    // SwiftUI supplies presentation values here, including during interrupted animations.
    // https://developer.apple.com/documentation/swiftui/animatable
    var animatableData: Double {
        get { phase }
        set { phase = newValue }
    }

    var body: some View {
        let layout = from.interpolated(to: to, fraction: phase - endPhase + 1)
        TokenWatershedScene(layout: layout, palette: palette, active: active, focused: focused, selection: selection,
                            running: running, arrivalStarted: arrivalStarted, flowStarted: flowStarted,
                            flowElapsed: flowElapsed, onHover: onHover, onPin: onPin)
    }
}

private struct TokenWatershedScene: View {
    let layout: TokenWatershedLayout
    let palette: [String: Color]
    let active: TokenWatershedSelection?
    var focused: FocusState<TokenWatershedSelection?>.Binding
    let selection: TokenWatershedSelection?
    let running: Bool
    let arrivalStarted: Date?
    let flowStarted: Date?
    let flowElapsed: TimeInterval
    let onHover: (TokenWatershedSelection?) -> Void
    let onPin: (TokenWatershedSelection?) -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack(alignment: .topLeading) {
            Group {
                if running {
                    // Like ThinkingOrb, cap the cadence at 30 fps; the static branch has no schedule.
                    // https://developer.apple.com/documentation/swiftui/timelineschedule/animation(minimuminterval:paused:)
                    TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
                        canvas(date: timeline.date)
                    }
                } else {
                    canvas(date: nil)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(coordinateSpace: .local) { point in onPin(layout.hit(at: point)) }
            .accessibilityHidden(true)

            columnTitle("Tools", x: layout.size.width * 155 / 900 - 10, alignment: .trailing)
            columnTitle("Shared models", x: layout.size.width * 420 / 900 + 9, alignment: .leading)
            columnTitle("Token types", x: layout.size.width * 741 / 900 + 9, alignment: .leading)
            ForEach(layout.nodes) { node in
                label(node)
            }
            if layout.total.tokens == 0 {
                Text("No token usage in this range")
                    .font(.ui(.callout)).foregroundStyle(Chrome.secondaryText)
                    .frame(width: layout.size.width, height: layout.size.height)
                    .allowsHitTesting(false)
            }
        }
        .onContinuousHover { phase in
            switch phase {
            case .active(let point): onHover(layout.hit(at: point))
            case .ended: onHover(nil)
            }
        }
    }

    private func columnTitle(_ title: String, x: CGFloat, alignment: Alignment) -> some View {
        Text(verbatim: Chrome.localized(title))
            .font(.ui(.caption2)).foregroundStyle(Chrome.secondaryText)
            .frame(width: 140, alignment: alignment)
            .position(x: x + (alignment == .trailing ? -70 : 70), y: 18)
            .accessibilityHidden(true)
            .allowsHitTesting(false)
    }

    private func label(_ node: TokenWatershedLayout.Node) -> some View {
        let rect = layout.labelRect(for: node)
        let value = layout.metric == .cost
            ? TokenWatershedFormat.money(node.amounts.cost) : TokenWatershedFormat.compact(node.amounts.tokens)
        let share = TokenWatershedFormat.share(node.amounts.value(layout.metric), of: layout.total.value(layout.metric), exact: false)
        let title = TokenWatershedFormat.title(node) + (node.isFolded ? " +" : "")
        let detail = node.unpriced
            ? "  " + String(format: Chrome.localized("%@ · Unpriced"), TokenWatershedFormat.compact(node.amounts.tokens))
            : "  " + value + " · " + share
        let relevant = layout.isRelevant(node, to: active)
        return Button { onPin(node.id) } label: {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 0) {
                    Text(verbatim: title).foregroundStyle(Chrome.primaryText)
                    Text(verbatim: detail).foregroundStyle(Chrome.secondaryText).monospacedDigit()
                }
                .fixedSize(horizontal: true, vertical: false)
                Text(verbatim: title).foregroundStyle(Chrome.primaryText).lineLimit(1)
            }
            .font(.ui(.caption))
            .padding(.horizontal, Chrome.capsuleHorizontalPadding / 2)
            .padding(.vertical, Chrome.capsuleVerticalPadding)
            .background(Chrome.glassTint, in: Capsule())
            .overlay {
                if focused.wrappedValue == node.id {
                    Capsule().strokeBorder(Chrome.accent, lineWidth: 1)
                }
            }
            .opacity(node.opacity * (relevant ? 1 : 0.22))
            .frame(width: rect.width, height: rect.height, alignment: node.column == 0 ? .trailing : .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable()
        .focused(focused, equals: node.id)
        .focusEffectDisabled()
        .onKeyPress(.return) { onPin(node.id); return .handled }
        .position(x: rect.midX, y: rect.midY)
        .allowsHitTesting(node.opacity > 0.65)
        .accessibilityLabel(Text(verbatim: TokenWatershedFormat.title(node)))
        .accessibilityValue(Text(verbatim: String(format: Chrome.localized("%@ tokens, %@ of range, %@ priced cost, %@ reasoning tokens"),
            TokenWatershedFormat.exact(node.amounts.tokens),
            TokenWatershedFormat.share(Double(node.amounts.tokens), of: Double(layout.total.tokens)),
            node.amounts.pricedTokens > 0 ? TokenWatershedFormat.money(node.amounts.cost, exact: true) : Chrome.localized("Unpriced"),
            TokenWatershedFormat.exact(node.amounts.reasoning))))
        .accessibilityAddTraits(selection == node.id ? [.isSelected] : [])
        .accessibilityHint(node.isFolded ? Text("Expand small models") : Text("Pin this path"))
    }

    private func canvas(date: Date?) -> some View {
        let ink = Chrome.primaryText
        let dark = colorScheme == .dark
        let selected = layout.resolved(active)
        let elapsed = flowElapsed + (date.flatMap { date in flowStarted.map { date.timeIntervalSince($0) } } ?? 0)
        let arrival = date.flatMap { date in arrivalStarted.map { min(1, max(0, date.timeIntervalSince($0) / 1.2)) } } ?? 1
        return Canvas { context, size in
            var flow = context
            let left = layout.size.width * 155 / 900
            let right = layout.size.width * 741 / 900 + TokenWatershedLayout.barWidth
            flow.clip(to: Path(CGRect(x: left, y: 0, width: max(0, right - left) * arrival, height: size.height)))
            for ribbon in layout.ribbons {
                let matches = ribbon.bands.filter { selected == nil || $0.id.matches(selected!) }
                let relevant = !matches.isEmpty
                let split = selected != nil && matches.count < ribbon.bands.count
                var surface = flow
                surface.opacity = ribbon.opacity * (relevant ? 1 : 0.22)
                surface.fill(Path(ribbon.geometry.path), with: .color(Chrome.overlay(dark ? 0.025 : 0.035)))
                for band in ribbon.bands {
                    let highlighted = selected == nil || band.id.matches(selected!)
                    var tint = flow
                    tint.opacity = band.opacity * (highlighted ? 1 : 0.22)
                    tint.fill(Path(band.geometry.path), with: .color((palette[band.id.tool] ?? Chrome.gray).opacity(dark ? 0.32 : 0.23)))
                    if selected != nil && highlighted {
                        tint.fill(Path(band.geometry.path), with: .color((palette[band.id.tool] ?? Chrome.gray).opacity(0.14)))
                    }
                    if ribbon.id.stage == 1 && band.geometry.core > 0 {
                        tint.fill(Path(band.geometry.corePath), with: .color(ink.opacity(0.36)))
                    }
                    drawBars(band, stage: ribbon.id.stage, in: &tint, ink: ink, color: palette[band.id.tool] ?? Chrome.gray)
                }
                surface.stroke(Path(ribbon.geometry.path), with: .color(ink.opacity(relevant && selected != nil && !split ? 0.75 : 0.4)),
                               lineWidth: relevant && selected != nil && !split ? 1 : 0.6)
                if split {
                    for band in matches {
                        var highlight = flow
                        highlight.opacity = band.opacity
                        highlight.stroke(Path(band.geometry.path), with: .color(ink.opacity(0.7)), lineWidth: 0.8)
                    }
                }
                if date != nil && ribbon.geometry.height >= 1.5 {
                    var dashes = surface
                    dashes.clip(to: Path(ribbon.geometry.path))
                    dashes.stroke(Path(ribbon.geometry.center), with: .color(ink.opacity(0.19)),
                        style: StrokeStyle(lineWidth: 0.6, dash: [2, 29], dashPhase: -CGFloat(elapsed * 18).truncatingRemainder(dividingBy: 31)))
                }
            }
            for node in layout.nodes {
                var bar = context
                bar.opacity = node.opacity * (layout.isRelevant(node, to: selected) ? 1 : 0.22)
                if node.unpriced {
                    bar.stroke(Path(CGRect(x: node.x, y: node.y, width: 3, height: 12)), with: .color(ink.opacity(0.6)),
                               style: StrokeStyle(lineWidth: 0.65, dash: [2, 2]))
                } else if node.height > 0 {
                    bar.stroke(Path(CGRect(x: node.x, y: node.y, width: 3, height: node.height)),
                               with: .color(ink.opacity(0.4)), lineWidth: 0.55)
                }
            }
            var brackets = Path()
            let corners: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
                (17, 17, 12, 12), (size.width - 17, 17, -12, 12),
                (17, size.height - 17, 12, -12), (size.width - 17, size.height - 17, -12, -12)
            ]
            for (x, y, dx, dy) in corners {
                brackets.move(to: CGPoint(x: x + dx, y: y))
                brackets.addLine(to: CGPoint(x: x, y: y))
                brackets.addLine(to: CGPoint(x: x, y: y + dy))
            }
            context.stroke(brackets, with: .color(ink.opacity(0.25)), lineWidth: 0.6)
        }
    }

    private func drawBars(_ band: TokenWatershedLayout.Band, stage: Int, in context: inout GraphicsContext, ink: Color, color: Color) {
        let g = band.geometry
        let bars: [(CGFloat, CGFloat)] = stage == 0 ? [(g.x0 - 3, g.y0)] : [(g.x0 - 3, g.y0), (g.x1, g.y1)]
        for (x, y) in bars {
            context.fill(Path(CGRect(x: x, y: y, width: 3, height: g.height)), with: .color(color.opacity(0.65)))
            if stage == 1 && g.core > 0 {
                context.fill(Path(CGRect(x: x, y: y + (g.height - g.core) / 2, width: 3, height: g.core)),
                             with: .color(ink.opacity(0.7)))
            }
        }
    }
}

private enum TokenWatershedFormat {
    static func exact(_ value: Int64) -> String { value.formatted(.number) }
    static func compact(_ value: Int64) -> String { value.formatted(.number.notation(.compactName).precision(.fractionLength(0...1))) }
    static func money(_ value: Decimal, exact: Bool = false) -> String {
        value.formatted(.currency(code: "USD").precision(.fractionLength(exact ? 2...6 : 2...2)))
    }
    static func share(_ value: Double, of total: Double, exact: Bool = true) -> String {
        (total > 0 ? value / total : 0).formatted(.percent.precision(.fractionLength(exact ? 1 : 0)))
    }
    static func title(_ node: TokenWatershedLayout.Node) -> String {
        switch node.id {
        case .tool(let id): TokenUsageTool.displayName(for: id)
        case .model(let name): node.isFolded ? Chrome.localized("Other models") : name
        case .kind(let kind): Chrome.localized(kind.title)
        }
    }
}
