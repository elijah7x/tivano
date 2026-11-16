import AppKit
import SwiftUI

struct TokenUsagePage: View {
    let model: TokenUsageModel
    let isActive: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appIsActive = NSApp.isActive
    @State private var windowAllowsMotion = false
    @State private var isPresented = false
    @State private var relativeUpdate = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Chrome.sectionSpacing) {
                header
                controls
                if model.snapshot != nil {
                    summary
                }
                chartRegion
                if let range = model.resolvedBrush, let snapshot = model.snapshot {
                    timeline(range: range, snapshot: snapshot)
                    ChromeCard {
                        ChromeRow(title: "Cost estimate", detail: "API-equivalent estimate from Token Taken, not a bill.") {}
                    }
                }
            }
            .padding(Chrome.pageTitleSpacing)
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
        .trayPanel()
        .background {
            TokenUsageWindowObserver { windowAllowsMotion = $0 }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .onAppear {
            isPresented = true
            appIsActive = NSApp.isActive
            if isActive { model.onAppear() }
            updateRelativeTime()
        }
        .onDisappear { isPresented = false }
        .onChange(of: isActive) { _, active in
            if active {
                model.onAppear()
                updateRelativeTime()
            }
        }
        .onChange(of: model.refreshToken) { _, _ in updateRelativeTime() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            appIsActive = true
            updateRelativeTime()
        }
        // Keeps "Updated …" current while the page is in front; stops when it is hidden or the app is inactive.
        .task(id: isActive && appIsActive) {
            guard isActive && appIsActive else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                updateRelativeTime()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            appIsActive = false
        }
    }

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: Chrome.sectionSpacing) {
                heading
                Spacer(minLength: Chrome.unitHeaderSpacing)
                refreshButton
            }
            VStack(alignment: .leading, spacing: Chrome.unitHeaderSpacing) {
                heading
                refreshButton
            }
        }
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: Chrome.unitHeaderSpacing) {
            Text("Tokens")
                .font(.ui(.title2, weight: .semibold))
                .foregroundStyle(Chrome.primaryText)
            if let snapshot = model.snapshot {
                let updateDescription = absoluteUpdate(snapshot)
                Text(verbatim: String(format: Chrome.localized("Updated %@ · Token Taken"), relativeUpdate))
                    .font(.ui(.subheadline))
                    .foregroundStyle(Chrome.secondaryText)
                    .help(Text(verbatim: updateDescription))
                    .accessibilityLabel(Text(verbatim: updateDescription))
            } else {
                Text("Token Taken")
                    .font(.ui(.subheadline))
                    .foregroundStyle(Chrome.secondaryText)
            }
        }
    }

    private var refreshButton: some View {
        ChromeTextButton(symbol: "arrow.clockwise", title: refreshTitle, help: refreshTitle,
                         isEnabled: !model.isFetching) { model.refresh() }
    }

    private var refreshTitle: String {
        model.isFetching ? "Refreshing…" : "Refresh"
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: Chrome.unitHeaderSpacing) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Chrome.sectionSpacing) {
                    scopePicker
                    Spacer(minLength: Chrome.unitHeaderSpacing)
                    metricPicker
                }
                VStack(alignment: .leading, spacing: Chrome.unitHeaderSpacing) {
                    scopePicker
                    metricPicker
                }
            }
            Text("Personal excludes account-level sources such as Cursor.")
                .font(.ui(.caption))
                .foregroundStyle(Chrome.secondaryText)
        }
    }

    private var scopePicker: some View {
        GlassPickerButton(options: [(TokenUsageScope.all, "All tools"), (.personal, "Personal")],
                          selection: Binding(get: { model.scope }, set: { model.scope = $0 }))
            .accessibilityLabel(Text("Scope"))
    }

    private var metricPicker: some View {
        ChromeSegmentedPicker(options: [(TokenWatershedMetric.tokens, "Tokens"), (.cost, "Cost")],
                              selection: Binding(get: { model.metric }, set: { model.metric = $0 }))
            .accessibilityLabel(Text("Metric"))
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: Chrome.unitHeaderSpacing) {
            if let selection = model.selection {
                HStack(spacing: Chrome.unitHeaderSpacing) {
                    Text(verbatim: String(format: Chrome.localized("Selected: %@"), selectionTitle(selection)))
                        .font(.ui(.caption))
                        .foregroundStyle(Chrome.secondaryText)
                    Text(verbatim: "·").foregroundStyle(Chrome.secondaryText)
                    Button("Clear") { model.selection = nil }
                        .buttonStyle(.plain)
                        .font(.ui(.caption))
                        .foregroundStyle(Chrome.accent)
                }
            }
            ChromeCard {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: Chrome.contentHorizontalPadding)],
                          alignment: .leading, spacing: Chrome.sectionSpacing) {
                    summaryValue("Total tokens", value: TokenUsageFormatting.compact(model.summary.total),
                                 exact: TokenUsageFormatting.exact(model.summary.total), isNumber: true)
                    summaryValue("Cost estimate", value: summaryCost, exact: exactCost, isNumber: true)
                    summaryValue("Top tool", value: model.summary.topTool.map { TokenUsageTool.displayName(for: $0) } ?? "—")
                    summaryValue("Top model", value: model.summary.topModel ?? "—")
                }
                .padding(Chrome.contentHorizontalPadding)
            }
            if model.summary.hasCategorySelection {
                note("Costs are not available by token type.")
            } else if !model.summary.unpricedModels.isEmpty {
                Text(verbatim: String(format: Chrome.localized("Unpriced: %@"), model.summary.unpricedModels.joined(separator: ", ")))
                    .font(.ui(.caption))
                    .foregroundStyle(Chrome.secondaryText)
                    .textSelection(.enabled)
            }
        }
    }

    private func summaryValue(_ title: String, value: String, exact: String? = nil, isNumber: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: Chrome.unitHeaderSpacing) {
            Text(verbatim: Chrome.localized(title))
                .font(.ui(.caption))
                .foregroundStyle(Chrome.secondaryText)
            Text(verbatim: value)
                .font(.ui(isNumber ? .title2 : .body, weight: .medium))
                .foregroundStyle(Chrome.primaryText)
                .monospacedDigit()
                .lineLimit(1)
                .help(Text(verbatim: exact ?? value))
                .accessibilityLabel(Text(verbatim: exact ?? value))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var summaryCost: String {
        guard !model.summary.hasCategorySelection, let costUSD = model.summary.costUSD else { return "—" }
        let value = TokenUsageFormatting.cost(costUSD)
        return model.summary.unpricedModels.isEmpty ? value : String(format: Chrome.localized("≥ %@"), value)
    }

    private var exactCost: String {
        guard !model.summary.hasCategorySelection else { return Chrome.localized("Costs are not available by token type.") }
        guard let costUSD = model.summary.costUSD else { return "—" }
        let value = TokenUsageFormatting.cost(costUSD, exact: true)
        return model.summary.unpricedModels.isEmpty ? value : String(format: Chrome.localized("≥ %@"), value)
    }

    private var chartRegion: some View {
        ChromeSection(title: "Token distribution") {
            ChromeCard {
                VStack(alignment: .leading, spacing: Chrome.sectionSpacing) {
                    if let snapshot = model.snapshot {
                        snapshotNotices(snapshot)
                        if model.summary.hasRangeTokens {
                            TokenWatershedView(data: model.watershedData, metric: model.metric,
                                               isAnimating: isAnimating,
                                               selection: Binding(get: { model.selection }, set: { model.selection = $0 }),
                                               refreshToken: model.refreshToken)
                                .frame(minHeight: 340)
                                .accessibilityLabel(Text(verbatim: chartAccessibility(snapshot)))
                        } else {
                            emptyState
                        }
                    } else {
                        initialState
                            .frame(maxWidth: .infinity, minHeight: 340)
                    }
                }
                .padding(Chrome.contentHorizontalPadding)
            }
        }
    }

    @ViewBuilder
    private func snapshotNotices(_ snapshot: TokenUsageSnapshot) -> some View {
        if case .notInstalled = model.status {
            installationState
        } else if case .failed(let error) = model.phase {
            failureState(error)
        }
        if case .failed = model.phase {
            note(model.isSaved ? "Saved data" : "Unsaved data")
        } else if model.isFetching {
            note(model.isSaved ? "Saved data" : "Unsaved data")
        }
        if !model.isSaved {
            note("Couldn't save this data. It is available until Tivano closes.")
        }
        if snapshot.scope != model.scope {
            Text(verbatim: String(format: Chrome.localized("Press Refresh to load %@ data"), scopeTitle(model.scope)))
                .font(.ui(.body))
                .foregroundStyle(Chrome.secondaryText)
            Text(verbatim: String(format: Chrome.localized("Showing %@ data"), scopeTitle(snapshot.scope)))
                .font(.ui(.caption))
                .foregroundStyle(Chrome.secondaryText)
        }
        if !snapshot.warnings.isEmpty {
            VStack(alignment: .leading, spacing: Chrome.unitHeaderSpacing) {
                Text("Source warnings")
                    .font(.ui(.caption, weight: .semibold))
                ForEach(Array(snapshot.warnings.enumerated()), id: \.offset) { _, warning in
                    Text(verbatim: Chrome.localized(warning))
                        .font(.ui(.caption))
                        .textSelection(.enabled)
                }
            }
            .foregroundStyle(Chrome.secondaryText)
        }
    }

    @ViewBuilder
    private var initialState: some View {
        if model.isFetching {
            VStack(spacing: Chrome.unitHeaderSpacing) {
                ProgressView()
                Text("Loading token usage…")
                    .font(.ui(.body))
                    .foregroundStyle(Chrome.secondaryText)
            }
        } else if case .notInstalled = model.status {
            installationState
        } else if case .failed(let error) = model.phase {
            failureState(error)
        } else {
            state(title: "No token usage loaded", detail: "Press Refresh to load token usage.")
        }
    }

    private var emptyState: some View {
        state(title: "No token usage in this range", detail: "Choose another range or press Refresh.")
            .frame(maxWidth: .infinity, minHeight: 340)
    }

    private var installationState: some View {
        VStack(alignment: .leading, spacing: Chrome.unitHeaderSpacing) {
            state(title: "Token Taken is not installed", detail: "Tivano shows token usage collected by Token Taken. Install it, then press Refresh.")
            ChromeTextButton(symbol: "gearshape", title: "Open Settings", help: "Open Settings") {
                SettingsNavigation.shared.present(page: .connections)
            }
        }
    }

    private func failureState(_ error: TokenUsageFetchError) -> some View {
        VStack(alignment: .leading, spacing: Chrome.unitHeaderSpacing) {
            switch error {
            case .cliMissing:
                state(title: "Token Taken needs an update", detail: "This version of Token Taken has no command-line helper. Update it, then press Refresh.")
            case .noData:
                state(title: "Token Taken has no data yet", detail: "Open Token Taken once so it can collect usage, then press Refresh.")
            case .unsupportedSchema:
                state(title: "Token Taken's data format changed", detail: "Update Tivano or Token Taken, then press Refresh.")
            case .schemaChanged(let missing):
                state(title: "Token Taken's data format changed", detail: "Update Tivano or Token Taken, then press Refresh.")
                Text(verbatim: String(format: Chrome.localized("Missing fields: %@"), missing.joined(separator: ", ")))
                    .font(.ui(.caption))
                    .foregroundStyle(Chrome.secondaryText)
                    .textSelection(.enabled)
            case .timedOut:
                state(title: "Token Taken took too long to respond", detail: "Press Refresh to try again.")
            case .failed(let status, let message):
                state(title: "Couldn't refresh token usage", detail: "Press Refresh to try again.")
                Text(verbatim: String(format: Chrome.localized("Token Taken exited with status %lld."), Int64(status)))
                    .font(.ui(.caption))
                    .foregroundStyle(Chrome.secondaryText)
                if !message.trimmed.isEmpty {
                    Text(verbatim: message)
                        .font(.ui(.caption))
                        .foregroundStyle(Chrome.secondaryText)
                        .textSelection(.enabled)
                }
            case .cancelled:
                state(title: "Refresh cancelled", detail: "Press Refresh to try again.")
            case .other(let detail):
                state(title: "Couldn't refresh token usage", detail: "Press Refresh to try again.")
                Text(verbatim: detail)
                    .font(.ui(.caption))
                    .foregroundStyle(Chrome.secondaryText)
                    .textSelection(.enabled)
            }
            ChromeTextButton(symbol: "arrow.clockwise", title: "Retry", help: "Retry",
                             isEnabled: !model.isFetching) { model.refresh() }
        }
    }

    private func state(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: Chrome.unitHeaderSpacing) {
            Text(verbatim: Chrome.localized(title))
                .font(.ui(.headline))
                .foregroundStyle(Chrome.primaryText)
            Text(verbatim: Chrome.localized(detail))
                .font(.ui(.body))
                .foregroundStyle(Chrome.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func note(_ text: String) -> some View {
        Text(verbatim: Chrome.localized(text))
            .font(.ui(.caption))
            .foregroundStyle(Chrome.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func timeline(range: ClosedRange<Int>, snapshot: TokenUsageSnapshot) -> some View {
        VStack(alignment: .leading, spacing: Chrome.unitHeaderSpacing) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Chrome.sectionSpacing) {
                    dateLabel(range)
                    Spacer(minLength: Chrome.unitHeaderSpacing)
                    presetPicker
                }
                VStack(alignment: .leading, spacing: Chrome.unitHeaderSpacing) {
                    dateLabel(range)
                    presetPicker
                }
            }
            TokenTimeStrip(data: model.timeStripData,
                           brush: Binding(get: { model.resolvedBrush ?? range }, set: { model.brush = $0 }))
            Text(verbatim: String(format: Chrome.localized("%@ · %@"), scopeTitle(snapshot.scope), snapshot.timeZone))
                .font(.ui(.caption))
                .foregroundStyle(Chrome.secondaryText)
        }
    }

    private func dateLabel(_ range: ClosedRange<Int>) -> some View {
        Text(verbatim: String(format: Chrome.localized(range.count == 1 ? "%@ · 1 day" : "%@ · %lld days"),
                              TokenUsageFormatting.span(from: model.days[range.lowerBound].day, to: model.days[range.upperBound].day),
                              Int64(range.count)))
            .font(.ui(.caption))
            .monospacedDigit()
            .foregroundStyle(Chrome.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var presetPicker: some View {
        ChromeSegmentedPicker(options: [(7, "7 days"), (30, "30 days"), (90, "90 days"), (365, "365 days")],
                              selection: Binding(get: { model.brush == nil ? model.rangePreset : 0 }, set: { model.setPreset($0) }))
            .accessibilityLabel(Text("Date range presets"))
    }

    private var isAnimating: Bool {
        isPresented && isActive && !reduceMotion && appIsActive && windowAllowsMotion
    }

    private func scopeTitle(_ scope: TokenUsageScope) -> String {
        Chrome.localized(scope == .all ? "All tools" : "Personal")
    }

    private func selectionTitle(_ selection: TokenWatershedSelection) -> String {
        switch selection {
        case .tool(let tool): TokenUsageTool.displayName(for: tool)
        case .model(let model): model
        case .kind(let kind):
            switch kind {
            case .input: Chrome.localized("Fresh input")
            case .cacheRead: Chrome.localized("Cache reads")
            case .cacheWrite: Chrome.localized("Cache writes")
            case .output: Chrome.localized("Output")
            }
        }
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()

    private static let absoluteFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = .long
        return formatter
    }()

    private func updateRelativeTime() {
        guard let fetchedAt = model.snapshot?.fetchedAt else { relativeUpdate = ""; return }
        relativeUpdate = Self.relativeFormatter.localizedString(for: fetchedAt, relativeTo: Date())
    }

    private func absoluteUpdate(_ snapshot: TokenUsageSnapshot) -> String {
        String(format: Chrome.localized("Updated %@ · Token Taken"), Self.absoluteFormatter.string(from: snapshot.fetchedAt))
    }

    private func chartAccessibility(_ snapshot: TokenUsageSnapshot) -> String {
        guard let range = model.resolvedBrush else { return Chrome.localized("No token usage in this range") }
        return String(format: Chrome.localized("%@ · Token Taken · %@ · %@ tokens"),
                      TokenUsageFormatting.span(from: model.days[range.lowerBound].day, to: model.days[range.upperBound].day),
                      scopeTitle(snapshot.scope), TokenUsageFormatting.exact(model.summary.rangeTotal))
    }
}

private struct TokenUsageWindowObserver: NSViewRepresentable {
    var changed: (Bool) -> Void

    func makeNSView(context: Context) -> TokenUsageVisibilityView {
        let view = TokenUsageVisibilityView(frame: .zero)
        view.changed = changed
        return view
    }

    func updateNSView(_ nsView: TokenUsageVisibilityView, context: Context) {
        nsView.changed = changed
    }

    static func dismantleNSView(_ nsView: TokenUsageVisibilityView, coordinator: ()) {
        nsView.stopObserving()
    }
}

@MainActor
private final class TokenUsageVisibilityView: NSView {
    var changed: ((Bool) -> Void)?
    private weak var observedWindow: NSWindow?
    private var lastValue: Bool?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let center = NotificationCenter.default
        for name in [ProcessInfo.thermalStateDidChangeNotification, NSNotification.Name.NSProcessInfoPowerStateDidChange] {
            center.addObserver(self, selector: #selector(environmentChanged), name: name, object: nil)
        }
    }

    required init?(coder: NSCoder) { return nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let center = NotificationCenter.default
        let names = [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                     NSWindow.didDeminiaturizeNotification]
        if let observedWindow {
            for name in names { center.removeObserver(self, name: name, object: observedWindow) }
        }
        observedWindow = window
        if let window {
            for name in names { center.addObserver(self, selector: #selector(environmentChanged), name: name, object: window) }
        }
        reportVisibility()
    }

    override func viewDidHide() {
        super.viewDidHide()
        reportVisibility()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        reportVisibility()
    }

    @objc nonisolated private func environmentChanged() {
        Task { @MainActor [weak self] in self?.reportVisibility() }
    }

    private func reportVisibility() {
        let process = ProcessInfo.processInfo
        let allowed = window?.occlusionState.contains(.visible) == true && window?.isMiniaturized == false
            && !isHiddenOrHasHiddenAncestor && !process.isLowPowerModeEnabled
            && process.thermalState != .serious && process.thermalState != .critical
        guard allowed != lastValue else { return }
        lastValue = allowed
        // AppKit can attach this view during a SwiftUI update; publish on the next turn.
        Task { @MainActor [weak self] in
            guard let self, self.lastValue == allowed else { return }
            self.changed?(allowed)
        }
    }

    func stopObserving() {
        NotificationCenter.default.removeObserver(self)
        changed = nil
    }
}
