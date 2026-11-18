import AppKit
import Charts
import SwiftUI

struct TokenUsageSettingsPage: View {
    @Environment(AppModel.self) private var model
    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var sourceStatus: TokenTakenStatus = TokenTakenSource.detect()
    @State private var shareDimension: ShareDimension = .tool
    @State private var isBreakdownExpanded = false
    @State private var areWarningsExpanded = false
    @State private var hoveredDayIndex: Int?
    @State private var hoveredSliceID: String?

    private static let periodOptions: [(Int, String)] = [
        (7, "Last 7 days"),
        (30, "Last 30 days"),
        (90, "Last 90 days"),
        (365, "Last year"),
    ]

    private static let dimensionOptions: [(ShareDimension, String)] = [
        (.tool, "By tool"),
        (.model, "By model"),
    ]

    private var isInstalled: Bool {
        if case .installed = sourceStatus { return true }
        return false
    }

    private var installedVersion: String? {
        guard case .installed(let version) = sourceStatus,
              let trimmed = version?.trimmed,
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    var body: some View {
        Group {
            if isInstalled {
                VStack(alignment: .leading, spacing: Chrome.pageSectionSpacing) {
                    storyBlock
                    dataSourceSection
                }
            } else {
                notInstalledSection
            }
        }
        .onAppear(perform: handleAppear)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            handleDidBecomeActive()
        }
        .onChange(of: model.tokenUsage.rangePreset) { _, _ in
            hoveredDayIndex = nil
        }
        .onChange(of: shareDimension) { _, _ in
            hoveredSliceID = nil
        }
    }

    // MARK: - Story

    @ViewBuilder
    private var storyBlock: some View {
        if model.tokenUsage.snapshot != nil {
            let range = model.tokenUsage.resolvedBrush
            let rangeDays = range.map { Array(model.tokenUsage.days[$0]) } ?? []
            let stats = RangeStats(rows: model.tokenUsage.rangeRows)

            VStack(alignment: .leading, spacing: 24) {
                periodPicker

                if stats.totalTokens > 0, !rangeDays.isEmpty {
                    heroBlock(stats: stats, range: range)

                    TokenUsageSparkline(
                        days: rangeDays,
                        locale: locale,
                        formatTokens: formatTokens,
                        hoveredIndex: $hoveredDayIndex
                    )

                    shareSection(stats: stats)

                    breakdownDisclosure(stats: stats)
                } else {
                    Text(verbatim: Chrome.localized("No token usage in this range"))
                        .font(.ui(.title3))
                        .foregroundStyle(Chrome.secondaryText)
                        .padding(.vertical, 8)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if case .failed(let error) = model.tokenUsage.phase {
            let key = error == .noData ? "No token usage in this range" : "Couldn't refresh token usage"
            Text(verbatim: Chrome.localized(key))
                .font(.ui(.body))
                .foregroundStyle(Chrome.secondaryText)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text(verbatim: Chrome.localized("Loading token usage…"))
                    .font(.ui(.body))
                    .foregroundStyle(Chrome.secondaryText)
            }
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var periodPicker: some View {
        ChromeSegmentedPicker(
            options: Self.periodOptions,
            selection: Binding(
                get: { model.tokenUsage.rangePreset },
                set: { model.tokenUsage.setPreset($0) }
            )
        )
    }

    private func heroBlock(stats: RangeStats, range: ClosedRange<Int>?) -> some View {
        let tooltip = costTooltip(unpricedCount: stats.unpricedModelCount)
        return VStack(alignment: .leading, spacing: 8) {
            heroSentenceText(stats: stats)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
                .help(Text(verbatim: tooltip))

            if let caption = comparisonCaption(currentTotal: stats.totalTokens, range: range) {
                Text(verbatim: caption)
                    .font(.ui(.subheadline))
                    .foregroundStyle(Chrome.secondaryText)
                    .monospacedDigit()
            }
        }
    }

    private func heroSentenceText(stats: RangeStats) -> Text {
        let periodPhrase = Chrome.localized(heroPeriodKey)
        let tokensText = formatTokens(stats.totalTokens)

        let firstFormatKey: String
        let firstSentence: Text
        if let costUSD = stats.costUSD {
            firstFormatKey = "%1$@, you used %2$@ tokens, about %3$@."
            firstSentence = formattedHeroSegment(
                firstFormatKey,
                args: [periodPhrase, tokensText, TokenUsageFormatting.cost(costUSD)]
            )
        } else {
            firstFormatKey = "%1$@, you used %2$@ tokens."
            firstSentence = formattedHeroSegment(
                firstFormatKey,
                args: [periodPhrase, tokensText]
            )
        }

        var combined = firstSentence
        if let topToolName = stats.topToolName, stats.totalTokens > 0 {
            let shareRatio = Double(stats.topToolTokens) / Double(stats.totalTokens)
            let secondSentence = formattedHeroSegment(
                "%1$@ accounts for %2$@.",
                args: [topToolName, formatPercent(shareRatio)]
            )
            let localizedFirst = Chrome.localized(firstFormatKey)
            let usesFullwidthStop = localizedFirst.last.map { "。！？".contains($0) } ?? false
            if usesFullwidthStop {
                combined = Text("\(combined)\(secondSentence)")
            } else {
                let space: Text = Text(verbatim: " ")
                    .font(.ui(.title2, weight: .light))
                    .foregroundStyle(Chrome.secondaryText)
                combined = Text("\(combined)\(space)\(secondSentence)")
            }
        }

        let iconSpacer: Text = Text(verbatim: " ")
            .font(.ui(.title2, weight: .light))
        let infoIcon: Text = Text(Image(systemName: "info.circle"))
            .font(.ui(.callout))
            .foregroundStyle(Chrome.secondaryText.opacity(0.8))
            .baselineOffset(1)
        return Text("\(combined)\(iconSpacer)\(infoIcon)")
    }

    private var heroPeriodKey: String {
        switch model.tokenUsage.rangePreset {
        case 7: "In the last 7 days"
        case 30: "In the last 30 days"
        case 90: "In the last 90 days"
        default: "In the last year"
        }
    }

    private func formattedHeroSegment(_ formatKey: String, args: [String]) -> Text {
        let template = Chrome.localized(formatKey)
        var pieces: [Text] = []
        var cursor = template.startIndex
        var sequentialIndex = 0

        for match in template.matches(of: #/(?:%%|%([1-9][0-9]*)\$@|%@)/#) {
            if cursor < match.range.lowerBound {
                let literal = String(template[cursor..<match.range.lowerBound])
                pieces.append(
                    Text(verbatim: literal)
                        .font(.ui(.title2, weight: .light))
                        .foregroundStyle(Chrome.secondaryText)
                )
            }
            if match.output.0 == "%%" {
                pieces.append(
                    Text(verbatim: "%")
                        .font(.ui(.title2, weight: .light))
                        .foregroundStyle(Chrome.secondaryText)
                )
            } else if let posSubstring = match.output.1, let position = Int(posSubstring) {
                let index = position - 1
                if args.indices.contains(index) {
                    pieces.append(
                        Text(verbatim: args[index])
                            .font(.ui(.title2, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(Chrome.primaryText)
                    )
                }
            } else {
                let index = sequentialIndex
                sequentialIndex += 1
                if args.indices.contains(index) {
                    pieces.append(
                        Text(verbatim: args[index])
                            .font(.ui(.title2, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(Chrome.primaryText)
                    )
                }
            }
            cursor = match.range.upperBound
        }

        if cursor < template.endIndex {
            let tail = String(template[cursor...])
            pieces.append(
                Text(verbatim: tail)
                    .font(.ui(.title2, weight: .light))
                    .foregroundStyle(Chrome.secondaryText)
            )
        }

        guard var result = pieces.first else {
            return Text(verbatim: "")
        }
        for piece in pieces.dropFirst() {
            result = Text("\(result)\(piece)")
        }
        return result
    }

    private func costTooltip(unpricedCount: Int) -> String {
        let base = Chrome.localized("API-equivalent estimate, not a bill.")
        guard unpricedCount > 0 else { return base }
        let unpriced = String(
            format: Chrome.localized("%lld models have no price yet."),
            Int64(unpricedCount)
        )
        return "\(base)\n\(unpriced)"
    }

    private func comparisonCaption(currentTotal: Int64, range: ClosedRange<Int>?) -> String? {
        guard currentTotal > 0, let range else { return nil }
        let allDays = model.tokenUsage.days
        let spanCount = range.count
        guard spanCount > 0 else { return nil }

        let previousStart = range.lowerBound - spanCount
        let previousEnd = range.lowerBound - 1
        guard previousStart >= 0, previousEnd >= previousStart, previousEnd < allDays.count else {
            return nil
        }

        let previousTotal = allDays[previousStart...previousEnd].reduce(Int64(0)) { $0 + $1.total }
        guard previousTotal > 0 else { return nil }

        let delta = Double(currentTotal - previousTotal) / Double(previousTotal)
        if abs(delta) <= 0.02 {
            return Chrome.localized("About the same as the previous period")
        } else if delta > 0 {
            return String(
                format: Chrome.localized("%@ more than the previous period"),
                formatPercent(delta)
            )
        } else {
            return String(
                format: Chrome.localized("%@ less than the previous period"),
                formatPercent(abs(delta))
            )
        }
    }

    // MARK: - Share Bar & Legend

    private func shareSection(stats: RangeStats) -> some View {
        let slices = makeShareSlices(stats: stats)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                ChromeSegmentedPicker(options: Self.dimensionOptions, selection: $shareDimension)
                Spacer(minLength: 0)
                if let hovered = slices.first(where: { $0.id == hoveredSliceID }) {
                    Text(verbatim: "\(hovered.name) · \(formatTokens(hovered.tokens))")
                        .font(.ui(.caption))
                        .foregroundStyle(Chrome.secondaryText)
                        .monospacedDigit()
                        .lineLimit(1)
                }
            }

            GeometryReader { proxy in
                let widths = Self.segmentWidths(for: slices, totalWidth: proxy.size.width)
                HStack(spacing: 2) {
                    ForEach(Array(slices.enumerated()), id: \.element.id) { index, slice in
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(slice.color)
                            .opacity(hoveredSliceID == nil || hoveredSliceID == slice.id ? 1 : 0.4)
                            .frame(width: index < widths.count ? widths[index] : 0, height: 8)
                            .onHover { hovering in
                                updateHoveredSlice(id: slice.id, hovering: hovering)
                            }
                    }
                }
            }
            .frame(height: 8)
            .accessibilityHidden(true)

            FlowLayout(spacing: 16, lineSpacing: 8) {
                ForEach(slices) { slice in
                    HStack(spacing: 6) {
                        Circle()
                            .fill(slice.color)
                            .frame(width: 7.5, height: 7.5)
                            .accessibilityHidden(true)
                        Text(verbatim: slice.name)
                            .font(.ui(.subheadline))
                            .foregroundStyle(Chrome.primaryText)
                            .lineLimit(1)
                        Text(verbatim: formatPercent(slice.share))
                            .font(.ui(.subheadline))
                            .foregroundStyle(Chrome.secondaryText)
                            .monospacedDigit()
                    }
                    .opacity(hoveredSliceID == nil || hoveredSliceID == slice.id ? 1 : 0.45)
                    .onHover { hovering in
                        updateHoveredSlice(id: slice.id, hovering: hovering)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(.top, 2)
        }
    }

    private func updateHoveredSlice(id: String, hovering: Bool) {
        if hovering {
            if hoveredSliceID != id { hoveredSliceID = id }
        } else if hoveredSliceID == id {
            hoveredSliceID = nil
        }
    }

    private func makeShareSlices(stats: RangeStats) -> [ShareSlice] {
        guard stats.totalTokens > 0 else { return [] }
        let entries = shareDimension == .tool ? stats.byTool : stats.byModel
        let total = Double(stats.totalTokens)

        var result: [ShareSlice] = []
        let topEntries = entries.prefix(5)
        for (index, entry) in topEntries.enumerated() {
            result.append(
                ShareSlice(
                    id: "rank-\(index)-\(entry.name)",
                    name: entry.name,
                    tokens: entry.tokens,
                    share: Double(entry.tokens) / total,
                    color: Self.sliceColor(index: index, isOther: false)
                )
            )
        }

        if entries.count > 5 {
            let overflowTokens = entries.dropFirst(5).reduce(Int64(0)) { $0 + $1.tokens }
            if overflowTokens > 0 {
                result.append(
                    ShareSlice(
                        id: "overflow-other",
                        name: Chrome.localized("Other"),
                        tokens: overflowTokens,
                        share: Double(overflowTokens) / total,
                        color: Self.sliceColor(index: 5, isOther: true)
                    )
                )
            }
        }

        return result
    }

    private static func sliceColor(index: Int, isOther: Bool) -> Color {
        if isOther {
            return Chrome.secondaryText.opacity(0.18)
        }
        switch index {
        case 0: return Chrome.accent
        case 1: return Chrome.accent.opacity(0.7)
        case 2: return Chrome.accent.opacity(0.45)
        case 3: return Chrome.secondaryText.opacity(0.55)
        default: return Chrome.secondaryText.opacity(0.35)
        }
    }

    private static func segmentWidths(for slices: [ShareSlice], totalWidth: CGFloat) -> [CGFloat] {
        guard !slices.isEmpty, totalWidth > 0 else { return [] }
        let gaps = CGFloat(max(slices.count - 1, 0)) * 2
        let available = max(0, totalWidth - gaps)
        guard available > 0 else { return Array(repeating: 0, count: slices.count) }

        let totalTokens = Double(max(slices.reduce(Int64(0)) { $0 + $1.tokens }, 1))
        let minSegment = min(4, available / CGFloat(slices.count))
        let raw = slices.map { max(minSegment, available * CGFloat(Double($0.tokens) / totalTokens)) }
        let rawSum = raw.reduce(0, +)
        guard rawSum > 0 else { return raw }
        let scale = available / rawSum
        return raw.map { $0 * scale }
    }

    // MARK: - Breakdown Disclosure

    private func breakdownDisclosure(stats: RangeStats) -> some View {
        let items: [(key: String, tokens: Int64)] = [
            ("Fresh input", stats.inputTokens),
            ("Cache reads", stats.cachedInputTokens),
            ("Cache writes", stats.cacheWriteTokens),
            ("Output", stats.outputTokens),
        ]
        let columns = Array(
            repeating: GridItem(.flexible(minimum: 80), spacing: 16, alignment: .leading),
            count: 4
        )

        return VStack(alignment: .leading, spacing: 12) {
            Button {
                if reduceMotion {
                    isBreakdownExpanded.toggle()
                } else {
                    withAnimation(Chrome.hover) {
                        isBreakdownExpanded.toggle()
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(Chrome.chevronFont)
                        .rotationEffect(.degrees(isBreakdownExpanded ? 90 : 0))
                        .accessibilityHidden(true)
                    Text(verbatim: Chrome.localized("Breakdown"))
                        .font(.ui(.subheadline))
                }
                .foregroundStyle(Chrome.secondaryText)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

            if isBreakdownExpanded {
                Divider()
                LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                    ForEach(items, id: \.key) { item in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(verbatim: Chrome.localized(item.key))
                                .font(.ui(.caption))
                                .foregroundStyle(Chrome.secondaryText)
                            Text(verbatim: formatTokens(item.tokens))
                                .font(.ui(.body, weight: .medium))
                                .foregroundStyle(Chrome.primaryText)
                                .monospacedDigit()
                                .help(Text(verbatim: TokenUsageFormatting.exact(item.tokens)))
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
    }

    // MARK: - Data Source & Not Installed

    private var dataSourceSection: some View {
        let syncWarnings = (model.tokenUsage.snapshot?.warnings ?? []).filter {
            $0 != "Some models are unpriced"
        }
        return ChromeSection(title: "Data source") {
            ChromeCard {
                TimelineView(.periodic(from: .now, by: 60)) { timeline in
                    let _ = timeline.date
                    ChromeRow(
                        title: "Token Taken",
                        detail: installedDetail,
                        localizesDetail: false,
                        localizesTitle: false
                    ) {
                        HStack(spacing: 8) {
                            Button("Refresh") { model.tokenUsage.refresh() }
                                .chromeGlassButtonStyle()
                                .disabled(model.tokenUsage.isFetching)
                            if let appURL = TokenTakenSource.appURL() {
                                Button("Open Token Taken") {
                                    NSWorkspace.shared.openApplication(at: appURL, configuration: .init())
                                }
                                .chromeGlassButtonStyle()
                            }
                        }
                        .controlSize(.small)
                    }

                    if !syncWarnings.isEmpty {
                        ChromeRowDivider()
                        warningsRow(syncWarnings)
                    }
                }
            }
            footerLinks
        }
    }

    private var notInstalledSection: some View {
        ChromeSection(title: "Data source") {
            Text(verbatim: Chrome.localized("Tivano does not collect token usage itself. It shows the history that Token Taken, a companion app, collects from your AI coding tools on this Mac. Nothing leaves your computer."))
                .font(.ui(.subheadline))
                .foregroundStyle(Chrome.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            ChromeCard {
                ChromeRow(title: "Token Taken", detail: "Not installed", localizesTitle: false) {
                    Link("Get Token Taken", destination: TokenTakenSource.downloadURL)
                        .chromeGlassButtonStyle()
                        .controlSize(.small)
                }
            }
            footerLinks
        }
    }

    private var installedDetail: String? {
        switch model.tokenUsage.phase {
        case .fetching:
            let status = Chrome.localized("Refreshing…")
            return joinedWithVersion(status)
        case .failed:
            let status = Chrome.localized("Couldn't refresh token usage")
            return joinedWithVersion(status)
        case .idle:
            guard let fetchedAt = model.tokenUsage.snapshot?.fetchedAt else {
                return installedVersion
            }
            let relative = fetchedAt.formatted(.relative(presentation: .named).locale(locale))
            let updated = String(format: Chrome.localized("Updated %@"), relative)
            return joinedWithVersion(updated)
        }
    }

    private func joinedWithVersion(_ status: String) -> String {
        guard let version = installedVersion else { return status }
        return String(format: Chrome.localized("%@ · %@"), version, status)
    }

    private func warningsRow(_ warnings: [String]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                if reduceMotion {
                    areWarningsExpanded.toggle()
                } else {
                    withAnimation(Chrome.hover) {
                        areWarningsExpanded.toggle()
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Circle()
                        .fill(Chrome.orange)
                        .frame(width: 6, height: 6)
                        .accessibilityHidden(true)
                    Text(verbatim: String(
                        format: Chrome.localized("%lld devices synced only part of their data"),
                        Int64(warnings.count)
                    ))
                    .font(.ui(.subheadline))
                    .foregroundStyle(Chrome.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(Chrome.chevronFont)
                        .foregroundStyle(Chrome.secondaryText)
                        .rotationEffect(.degrees(areWarningsExpanded ? 90 : 0))
                        .accessibilityHidden(true)
                }
                .padding(.leading, 16)
                .padding(.trailing, 14)
                .padding(.vertical, 9)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

            if areWarningsExpanded {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(warnings.enumerated()), id: \.offset) { _, warning in
                        Text(verbatim: formattedWarning(warning))
                            .font(.ui(.caption))
                            .foregroundStyle(Chrome.secondaryText)
                            .monospacedDigit()
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.leading, 30)
                .padding(.trailing, 16)
                .padding(.bottom, 11)
            }
        }
    }

    private func formattedWarning(_ raw: String) -> String {
        let trimmed = raw.trimmed
        if let match = trimmed.wholeMatch(of: #/(?<name>.+?)\s*\([^()]+\):\s*partial,\s*last write\s+(?<stamp>\S+)/#) {
            let name = String(match.output.name).trimmed
            let stamp = String(match.output.stamp)
            if !name.isEmpty, let date = Self.parseWarningDate(stamp) {
                let relative = date.formatted(.relative(presentation: .named).locale(locale))
                return String(
                    format: Chrome.localized("%1$@ · last synced %2$@"),
                    name,
                    relative
                )
            }
        }
        return raw
    }

    private static func parseWarningDate(_ stamp: String) -> Date? {
        if let date = ISO8601.date(from: stamp) {
            return date
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: stamp) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: stamp)
    }

    private var footerLinks: some View {
        HStack(spacing: 6) {
            Link("Website", destination: TokenTakenSource.downloadURL)
            Text(verbatim: "·")
            Link("GitHub", destination: TokenTakenSource.projectURL)
        }
        .buttonStyle(.plain)
        .font(.ui(.caption))
        .foregroundStyle(Chrome.secondaryText)
    }

    // MARK: - Formatting & Lifecycle

    private func formatTokens(_ value: Int64) -> String {
        value.formatted(
            .number
                .notation(.compactName)
                .precision(.fractionLength(0...1))
                .locale(locale)
        )
    }

    private func formatPercent(_ ratio: Double) -> String {
        ratio.formatted(
            .percent
                .precision(.fractionLength(0))
                .locale(locale)
        )
    }

    private func handleAppear() {
        sourceStatus = TokenTakenSource.detect()
        if model.tokenUsage.brush != nil {
            model.tokenUsage.setPreset(model.tokenUsage.rangePreset)
        }
        model.tokenUsage.onAppear()
    }

    private func handleDidBecomeActive() {
        sourceStatus = TokenTakenSource.detect()
        model.tokenUsage.onAppear()
    }
}

// MARK: - Sparkline

private struct TokenUsageSparkline: View {
    let days: [TokenUsageDay]
    let locale: Locale
    let formatTokens: (Int64) -> String
    @Binding var hoveredIndex: Int?

    private var clampedHoveredDay: (index: Int, entry: TokenUsageDay)? {
        guard let hoveredIndex, days.indices.contains(hoveredIndex) else { return nil }
        return (hoveredIndex, days[hoveredIndex])
    }

    private var maxY: Double {
        let peak = days.map(\.total).max() ?? 0
        return max(Double(peak) * 1.08, 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geometry in
                if let hovered = clampedHoveredDay {
                    let fraction = days.count > 1
                        ? CGFloat(hovered.index) / CGFloat(days.count - 1)
                        : 0.5
                    let inset: CGFloat = min(60, geometry.size.width / 2)
                    let x = min(
                        max(inset, geometry.size.width * fraction),
                        max(inset, geometry.size.width - inset)
                    )
                    readoutText(for: hovered.entry)
                        .fixedSize()
                        .position(x: x, y: geometry.size.height / 2)
                }
            }
            .frame(height: 16)
            .allowsHitTesting(false)

            chartView
                .frame(height: 56)
                .clipped()

            if let first = days.first {
                HStack {
                    Text(verbatim: formatShortDate(first.day))
                    Spacer(minLength: 8)
                    if let last = days.last, days.count > 1 {
                        Text(verbatim: formatShortDate(last.day))
                    }
                }
                .font(.ui(.caption))
                .foregroundStyle(Chrome.secondaryText)
                .monospacedDigit()
            }
        }
    }

    private var chartView: some View {
        Chart {
            ForEach(Array(days.enumerated()), id: \.offset) { index, entry in
                AreaMark(
                    x: .value(Text(verbatim: "x"), index),
                    yStart: .value(Text(verbatim: "y0"), 0.0),
                    yEnd: .value(Text(verbatim: "y"), Double(entry.total))
                )
                .interpolationMethod(.catmullRom)
                .foregroundStyle(
                    LinearGradient(
                        colors: [Chrome.accent.opacity(0.18), Chrome.accent.opacity(0)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

                LineMark(
                    x: .value(Text(verbatim: "x"), index),
                    y: .value(Text(verbatim: "y"), Double(entry.total))
                )
                .interpolationMethod(.catmullRom)
                .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                .foregroundStyle(Chrome.accent)

                if days.count == 1 {
                    PointMark(
                        x: .value(Text(verbatim: "x"), index),
                        y: .value(Text(verbatim: "y"), Double(entry.total))
                    )
                    .symbolSize(24)
                    .foregroundStyle(Chrome.accent)
                }
            }

            if let hovered = clampedHoveredDay {
                RuleMark(x: .value(Text(verbatim: "x"), hovered.index))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .foregroundStyle(Chrome.secondaryText.opacity(0.45))

                PointMark(
                    x: .value(Text(verbatim: "x"), hovered.index),
                    y: .value(Text(verbatim: "y"), Double(hovered.entry.total))
                )
                .symbolSize(24)
                .foregroundStyle(Chrome.accent)
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .chartXScale(domain: 0...max(days.count - 1, 1))
        .chartYScale(domain: 0...maxY)
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle()
                    .fill(.clear)
                    .contentShape(.rect)
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            guard !days.isEmpty else {
                                if hoveredIndex != nil { hoveredIndex = nil }
                                return
                            }
                            let plotRect = proxy.plotFrame.map { geometry[$0] }
                                ?? CGRect(origin: .zero, size: geometry.size)
                            guard plotRect.width > 0 else { return }
                            let clampedX = min(max(location.x - plotRect.minX, 0), plotRect.width)
                            let index: Int
                            if days.count == 1 {
                                index = 0
                            } else {
                                let ratio = clampedX / plotRect.width
                                index = min(
                                    max(0, Int((ratio * CGFloat(days.count - 1)).rounded())),
                                    days.count - 1
                                )
                            }
                            if hoveredIndex != index {
                                hoveredIndex = index
                            }
                        case .ended:
                            if hoveredIndex != nil {
                                hoveredIndex = nil
                            }
                        }
                    }
            }
        }
    }

    private func readoutText(for entry: TokenUsageDay) -> Text {
        let datePart: Text = Text(verbatim: "\(formatShortDate(entry.day)) · ")
            .font(.ui(.caption))
            .foregroundStyle(Chrome.secondaryText)
        let valuePart: Text = Text(verbatim: formatTokens(entry.total))
            .font(.ui(.caption, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(Chrome.primaryText)
        return Text("\(datePart)\(valuePart)")
    }

    private func formatShortDate(_ dayString: String) -> String {
        guard let date = Self.parseDay(dayString) else { return dayString }
        var style = Date.FormatStyle.dateTime.month(.abbreviated).day()
        style.locale = locale
        style.timeZone = .gmt
        return date.formatted(style)
    }

    private static func parseDay(_ dayString: String) -> Date? {
        let parts = dayString.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2]) else {
            return nil
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))
    }
}

// MARK: - Supporting Types

private enum ShareDimension: Hashable {
    case tool
    case model
}

private struct ShareSlice: Identifiable {
    let id: String
    let name: String
    let tokens: Int64
    let share: Double
    let color: Color
}

private struct RangeStats {
    var totalTokens: Int64 = 0
    var inputTokens: Int64 = 0
    var cachedInputTokens: Int64 = 0
    var cacheWriteTokens: Int64 = 0
    var outputTokens: Int64 = 0
    var costUSD: Decimal?
    var unpricedModelCount = 0
    var topToolName: String?
    var topToolTokens: Int64 = 0
    var byTool: [(name: String, tokens: Int64)] = []
    var byModel: [(name: String, tokens: Int64)] = []

    init(rows: [TokenUsageRow]) {
        var toolTotals: [String: Int64] = [:]
        var modelTotals: [String: Int64] = [:]
        var unpricedModels = Set<String>()

        for row in rows {
            totalTokens += row.totalTokens
            inputTokens += row.inputTokens
            cachedInputTokens += row.cachedInputTokens
            cacheWriteTokens += row.cacheWriteTokens
            outputTokens += row.outputTokens

            if let cost = row.costUSD {
                costUSD = (costUSD ?? .zero) + cost
            } else if row.totalTokens > 0 {
                unpricedModels.insert(row.model)
            }

            if row.totalTokens > 0 {
                let toolDisplay = TokenUsageTool.displayName(for: row.tool)
                toolTotals[toolDisplay, default: 0] += row.totalTokens
                modelTotals[row.model, default: 0] += row.totalTokens
            }
        }

        unpricedModelCount = unpricedModels.count
        byTool = Self.sortedEntries(from: toolTotals)
        byModel = Self.sortedEntries(from: modelTotals)
        if let first = byTool.first {
            topToolName = first.name
            topToolTokens = first.tokens
        }
    }

    private static func sortedEntries(from totals: [String: Int64]) -> [(name: String, tokens: Int64)] {
        totals
            .map { (name: $0.key, tokens: $0.value) }
            .sorted { lhs, rhs in
                lhs.tokens == rhs.tokens ? lhs.name < rhs.name : lhs.tokens > rhs.tokens
            }
    }
}

/// Rows of subviews, each as wide as it needs, wrapping at the proposed width.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + lineSpacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            maxX = max(maxX, x - spacing)
        }
        return CGSize(width: proposal.width ?? maxX, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x: CGFloat = bounds.minX, y: CGFloat = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + lineSpacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
