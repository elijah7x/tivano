import Foundation
import Observation

@MainActor @Observable
final class TokenUsageModel {
    enum Phase: Equatable {
        case idle
        case fetching
        case failed(TokenUsageFetchError)
    }

    private(set) var status: TokenTakenStatus = .notInstalled
    private(set) var snapshot: TokenUsageSnapshot?
    private(set) var phase: Phase = .idle
    var scope: TokenUsageScope = .all {
        didSet {
            guard scope != oldValue else { return }
            // A scope change invalidates an in-flight request without starting another.
            generation += 1
            fetchTask?.cancel()
            fetchTask = nil
            phase = .idle
        }
    }
    var metric: TokenWatershedMetric = .tokens
    var rangePreset = 30 {
        didSet { updateRange() }
    }
    var brush: ClosedRange<Int>? {
        didSet { updateRange() }
    }
    var selection: TokenWatershedSelection? {
        didSet { summary = TokenUsageSummary(rows: rangeRows, selection: selection) }
    }
    private(set) var refreshToken = 0
    private(set) var isSaved = false
    private(set) var days: [TokenUsageDay] = []
    private(set) var rangeRows: [TokenUsageRow] = []
    private(set) var toolOrder: [String] = []
    private(set) var timeStripData = TokenTimeStrip.Data(days: [], toolOrder: [])
    private(set) var watershedData = TokenWatershedData(rows: [])
    private(set) var summary = TokenUsageSummary(rows: [], selection: nil)

    @ObservationIgnored private var loadedCache = false
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var fetchTask: Task<Void, Never>?

    var isFetching: Bool {
        if case .fetching = phase { return true }
        return false
    }

    var resolvedBrush: ClosedRange<Int>? {
        guard !days.isEmpty else { return nil }
        let last = days.count - 1
        guard let brush else { return max(0, days.count - rangePreset)...last }
        let lower = min(max(0, brush.lowerBound), last)
        return lower...min(max(lower, brush.upperBound), last)
    }

    func onAppear() {
        loadCacheIfNeeded()
        if snapshot == nil, !isFetching, case .installed = status {
            refresh()
        }
    }

    /// Detects the source and loads the saved snapshot once, without fetching.
    func loadCacheIfNeeded() {
        status = TokenTakenSource.detect()
        // The feature requires Token Taken: hide saved usage while it is absent; the cache file stays for a reinstall.
        guard case .installed = status else {
            fetchTask?.cancel()
            snapshot = nil
            days = []
            loadedCache = false
            return
        }
        if !loadedCache {
            loadedCache = true
            if let saved = TokenUsageCache.load() {
                scope = saved.scope
                replaceSnapshot(saved)
                isSaved = true
            }
        }
    }

    func refresh() {
        generation += 1
        let request = generation
        fetchTask?.cancel()
        status = TokenTakenSource.detect()
        let requestedScope = scope
        let timeZone = TimeZone.current
        phase = .fetching
        fetchTask = Task { [weak self] in
            do {
                let result = try await TokenTakenSource.fetch(
                    lastDays: 365, timeZone: timeZone, scope: requestedScope
                )
                // A scope change during the fetch keeps the result; the snapshot records its own scope.
                guard let self, self.generation == request, !Task.isCancelled else { return }
                self.replaceSnapshot(result)
                do {
                    try TokenUsageCache.save(result)
                    self.isSaved = true
                } catch {
                    self.isSaved = false
                }
                self.refreshToken += 1
                self.phase = .idle
                self.fetchTask = nil
            } catch {
                guard let self, self.generation == request else { return }
                let failure = error as? TokenUsageFetchError
                    ?? (error is CancellationError ? .cancelled : .other(error.localizedDescription))
                self.phase = .failed(failure)
                self.fetchTask = nil
            }
        }
    }

    func setPreset(_ days: Int) {
        guard [7, 30, 90, 365].contains(days) else { return }
        rangePreset = days
        brush = nil
    }

    private func replaceSnapshot(_ value: TokenUsageSnapshot) {
        // Preserve a manually brushed calendar span when the fetched window advances.
        let previousDates = brush.flatMap { _ in
            resolvedBrush.map { (days[$0.lowerBound].day, days[$0.upperBound].day) }
        }
        snapshot = value
        days = value.days()
        var totals: [String: Int64] = [:]
        for day in days {
            for (tool, total) in day.byTool { totals[tool, default: 0] += total }
        }
        toolOrder = totals.keys.sorted {
            let lhs = totals[$0, default: 0], rhs = totals[$1, default: 0]
            return lhs == rhs ? $0 < $1 : lhs > rhs
        }
        timeStripData = TokenTimeStrip.Data(days: days, toolOrder: toolOrder)
        if let (from, to) = previousDates,
           let lower = days.firstIndex(where: { $0.day >= from }),
           let upper = days.lastIndex(where: { $0.day <= to }), lower <= upper {
            brush = lower...upper
        } else {
            brush = nil
        }
        updateRange()
    }

    private func updateRange() {
        if let snapshot, let range = resolvedBrush {
            rangeRows = snapshot.rows(from: days[range.lowerBound].day, through: days[range.upperBound].day)
        } else {
            rangeRows = []
        }
        watershedData = TokenWatershedData(rows: rangeRows)
        summary = TokenUsageSummary(rows: rangeRows, selection: selection)
    }
}

struct TokenUsageSummary {
    var total: Int64 = 0
    var rangeTotal: Int64 = 0
    var hasRangeTokens = false
    var costUSD: Decimal?
    var hasCategorySelection = false
    var unpricedModels: [String] = []
    var topTool: String?
    var topModel: String?

    init(rows: [TokenUsageRow], selection: TokenWatershedSelection?) {
        var tools: [String: Int64] = [:]
        var models: [String: Int64] = [:]
        var unpriced = Set<String>()
        if case .kind = selection { hasCategorySelection = true }
        for row in rows {
            if row.totalTokens > 0 { hasRangeTokens = true }
            rangeTotal += row.totalTokens
            let count: Int64
            switch selection {
            case .tool(let tool):
                guard row.tool == tool else { continue }
                count = row.totalTokens
            case .model(let model):
                guard row.model == model else { continue }
                count = row.totalTokens
            case .kind(let kind):
                switch kind {
                case .input: count = row.inputTokens
                case .cacheRead: count = row.cachedInputTokens
                case .cacheWrite: count = row.cacheWriteTokens
                case .output: count = row.outputTokens
                }
                guard count > 0 else { continue }
            case nil:
                count = row.totalTokens
            }
            total += count
            tools[row.tool, default: 0] += count
            models[row.model, default: 0] += count
            if let cost = row.costUSD { costUSD = (costUSD ?? .zero) + cost }
            else { unpriced.insert(row.model) }
        }
        unpricedModels = unpriced.sorted()
        topTool = Self.top(in: tools)
        topModel = Self.top(in: models)
    }

    private static func top(in values: [String: Int64]) -> String? {
        values.filter { $0.value > 0 }.sorted {
            $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value
        }.first?.key
    }
}
