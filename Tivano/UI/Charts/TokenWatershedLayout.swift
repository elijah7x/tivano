import CoreGraphics
import Foundation

enum TokenWatershedMetric: Hashable { case tokens, cost }

enum TokenKind: Int, Hashable, CaseIterable {
    case input, cacheRead, cacheWrite, output

    var title: String {
        switch self {
        case .input: "Fresh input"
        case .cacheRead: "Cache reads"
        case .cacheWrite: "Cache writes"
        case .output: "Output"
        }
    }
}

enum TokenWatershedSelection: Hashable {
    case tool(String), model(String), kind(TokenKind)
}

struct TokenWatershedAmounts: Equatable {
    var tokens: Int64 = 0
    var pricedTokens: Int64 = 0
    var reasoning: Int64 = 0
    var cost: Decimal = 0
    var reasoningCost: Decimal = 0

    var unpricedTokens: Int64 { tokens - pricedTokens }

    func value(_ metric: TokenWatershedMetric) -> Double {
        metric == .tokens ? Double(tokens) : NSDecimalNumber(decimal: cost).doubleValue
    }

    mutating func add(_ other: Self) {
        tokens += other.tokens
        pricedTokens += other.pricedTokens
        reasoning += other.reasoning
        cost += other.cost
        reasoningCost += other.reasoningCost
    }
}

struct TokenWatershedFlowID: Hashable {
    var tool: String
    var model: String
    var kind: TokenKind

    func matches(_ selection: TokenWatershedSelection) -> Bool {
        switch selection {
        case .tool(let tool): self.tool == tool
        case .model(let model): self.model == model
        case .kind(let kind): self.kind == kind
        }
    }
}

struct TokenWatershedAggregate: Equatable {
    struct Flow: Equatable {
        var id: TokenWatershedFlowID
        var amounts: TokenWatershedAmounts
    }

    var flows: [Flow] = []
    var total = TokenWatershedAmounts()
    var tools: [String: TokenWatershedAmounts] = [:]
    var models: [String: TokenWatershedAmounts] = [:]

    init(rows: [TokenUsageRow]) {
        var accumulated: [TokenWatershedFlowID: TokenWatershedAmounts] = [:]
        for row in rows {
            let values = [row.inputTokens, row.cachedInputTokens, row.cacheWriteTokens, row.outputTokens]
                .map { max(0, $0) }
            let tokenCount = values.reduce(Int64(0), +)
            guard tokenCount > 0 else { continue }
            let rowCost = row.costUSD.map { max(Decimal.zero, $0) }
            var remainingCost = rowCost ?? 0
            let lastKind = values.lastIndex(where: { $0 > 0 })
            for kind in TokenKind.allCases where values[kind.rawValue] > 0 {
                let count = values[kind.rawValue]
                // Allocate within this row, never by a tool/model's aggregate share.
                // Assign the Decimal remainder to the last nonempty kind to conserve cost.
                let cost: Decimal
                if let rowCost {
                    cost = kind.rawValue == lastKind ? remainingCost
                        : rowCost * Decimal(count) / Decimal(tokenCount)
                    remainingCost -= cost
                } else {
                    cost = 0
                }
                let reasoning = kind == .output ? min(count, max(0, row.reasoningTokens)) : 0
                let amounts = TokenWatershedAmounts(
                    tokens: count, pricedTokens: rowCost == nil ? 0 : count,
                    reasoning: reasoning, cost: cost,
                    reasoningCost: reasoning > 0 ? cost * Decimal(reasoning) / Decimal(count) : 0
                )
                let id = TokenWatershedFlowID(tool: row.tool, model: row.model, kind: kind)
                accumulated[id, default: .init()].add(amounts)
                total.add(amounts)
                tools[row.tool, default: .init()].add(amounts)
                models[row.model, default: .init()].add(amounts)
            }
        }
        flows = accumulated.map { Flow(id: $0.key, amounts: $0.value) }.sorted {
            if $0.id.tool != $1.id.tool { return $0.id.tool < $1.id.tool }
            if $0.id.model != $1.id.model { return $0.id.model < $1.id.model }
            return $0.id.kind.rawValue < $1.id.kind.rawValue
        }
    }

    func foldedModels(metric: TokenWatershedMetric) -> Set<String> {
        guard total.tokens > 0 else { return [] }
        return Set(models.compactMap { name, amounts in
            let small = Double(amounts.tokens) / Double(total.tokens) < 0.03
            return small && (metric == .tokens || amounts.pricedTokens > 0) ? name : nil
        })
    }

    func height(metric: TokenWatershedMetric, expanded: Bool, slot: CGFloat) -> CGFloat {
        let folded = expanded ? [] : foldedModels(metric: metric)
        let modelCount = models.count - folded.count + (folded.isEmpty ? 0 : 1)
        return max(340, CGFloat(max(modelCount, max(tools.count, TokenKind.allCases.count))) * slot + 58)
    }
}

/// Geometry is independent of SwiftUI. CGPaths are rebuilt only for a new layout
/// or a morph frame; the flow clock reuses the settled paths.
struct TokenWatershedLayout {
    static let otherModels = "Other models"
    static let barWidth: CGFloat = 3

    struct Node: Identifiable {
        var id: TokenWatershedSelection
        var column: Int
        var title: String
        var amounts: TokenWatershedAmounts
        var x: CGFloat
        var y: CGFloat = 0
        var height: CGFloat = 0
        var labelY: CGFloat = 0
        var opacity: Double = 1
        var unpriced: Bool = false
        var isFolded: Bool = false
    }

    struct RibbonID: Hashable {
        var stage: Int
        var tool: String?
        var model: String
        var kind: TokenKind?
    }

    struct Geometry {
        var x0: CGFloat
        var x1: CGFloat
        var y0: CGFloat
        var y1: CGFloat
        var height: CGFloat
        var core: CGFloat
        var path: CGPath
        var center: CGPath
        var corePath: CGPath

        init(x0: CGFloat, x1: CGFloat, y0: CGFloat, y1: CGFloat, height: CGFloat, core: CGFloat = 0) {
            self.x0 = x0; self.x1 = x1; self.y0 = y0; self.y1 = y1
            self.height = height; self.core = min(height, max(0, core))
            let dx = (x1 - x0) * 0.48
            func shape(_ h: CGFloat) -> CGPath {
                let a = y0 + (height - h) / 2, b = y1 + (height - h) / 2
                let p = CGMutablePath()
                p.move(to: CGPoint(x: x0, y: a))
                p.addCurve(to: CGPoint(x: x1, y: b), control1: CGPoint(x: x0 + dx, y: a),
                           control2: CGPoint(x: x1 - dx, y: b))
                p.addLine(to: CGPoint(x: x1, y: b + h))
                p.addCurve(to: CGPoint(x: x0, y: a + h), control1: CGPoint(x: x1 - dx, y: b + h),
                           control2: CGPoint(x: x0 + dx, y: a + h))
                p.closeSubpath()
                return p
            }
            path = shape(height)
            corePath = shape(min(height, max(0, core)))
            let line = CGMutablePath()
            line.move(to: CGPoint(x: x0, y: y0 + height / 2))
            line.addCurve(to: CGPoint(x: x1, y: y1 + height / 2),
                          control1: CGPoint(x: x0 + dx, y: y0 + height / 2),
                          control2: CGPoint(x: x1 - dx, y: y1 + height / 2))
            center = line
        }

        var collapsed: Self {
            Self(x0: x0, x1: x1, y0: y0 + height / 2, y1: y1 + height / 2, height: 0)
        }

        func interpolated(to b: Self, fraction t: CGFloat) -> Self {
            Self(x0: x0 + (b.x0 - x0) * t, x1: x1 + (b.x1 - x1) * t,
                 y0: y0 + (b.y0 - y0) * t, y1: y1 + (b.y1 - y1) * t,
                 height: height + (b.height - height) * t, core: core + (b.core - core) * t)
        }
    }

    struct Band: Identifiable {
        var id: TokenWatershedFlowID
        var amounts: TokenWatershedAmounts
        var geometry: Geometry
        var opacity: Double = 1
    }

    struct Ribbon: Identifiable {
        var id: RibbonID
        var geometry: Geometry
        var bands: [Band]
        var opacity: Double = 1
    }

    var nodes: [Node] = []
    var ribbons: [Ribbon] = []
    var total = TokenWatershedAmounts()
    var size = CGSize.zero
    var metric: TokenWatershedMetric = .tokens
    var folded: Set<String> = []
    var slot: CGFloat = 24

    init() {}

    init(aggregate: TokenWatershedAggregate, metric: TokenWatershedMetric,
         width: CGFloat, expanded: Bool, slot: CGFloat = 24) {
        self.metric = metric
        self.total = aggregate.total
        self.slot = max(24, slot)
        folded = expanded ? [] : aggregate.foldedModels(metric: metric)
        size = CGSize(width: max(720, width), height: aggregate.height(metric: metric, expanded: expanded, slot: self.slot))
        let x: [CGFloat] = [size.width * 155 / 900, size.width * 420 / 900, size.width * 741 / 900]
        var displayed: [TokenWatershedFlowID: TokenWatershedAmounts] = [:]
        var nodeAmounts: [TokenWatershedSelection: TokenWatershedAmounts] = [:]
        for flow in aggregate.flows {
            var id = flow.id
            if folded.contains(id.model) { id.model = Self.otherModels }
            displayed[id, default: .init()].add(flow.amounts)
            for selection in [TokenWatershedSelection.tool(id.tool), .model(id.model), .kind(id.kind)] {
                nodeAmounts[selection, default: .init()].add(flow.amounts)
            }
        }
        func node(_ id: TokenWatershedSelection, column: Int, title: String) -> Node {
            let amounts = nodeAmounts[id] ?? .init()
            return Node(id: id, column: column, title: title, amounts: amounts, x: x[column],
                        unpriced: metric == .cost && amounts.tokens > 0 && amounts.pricedTokens == 0,
                        isFolded: id == .model(Self.otherModels) && !folded.isEmpty)
        }
        func descending(_ a: Node, _ b: Node) -> Bool {
            let av = a.amounts.value(metric), bv = b.amounts.value(metric)
            return av == bv ? a.title < b.title : av > bv
        }
        var tools = aggregate.tools.keys.map { node(.tool($0), column: 0, title: $0) }.sorted(by: descending)
        let modelNames = Set(displayed.keys.map(\.model))
        let allModels = modelNames.map { node(.model($0), column: 1, title: $0) }
        var models = allModels.filter { !$0.unpriced }.sorted(by: descending)
        var unpriced = allModels.filter(\.unpriced).sorted { $0.title < $1.title }
        var kinds = TokenKind.allCases.map { node(.kind($0), column: 2, title: $0.title) }
        let top: CGFloat = 36, gap: CGFloat = 6
        let bottom = size.height - 22 - CGFloat(unpriced.count) * self.slot
        let available = max(0, bottom - top)
        let totalValue = total.value(metric)
        var low: CGFloat = 0
        var high = max(0, available - CGFloat(max(tools.count, max(models.count, kinds.count)) - 1) * gap)
            / CGFloat(totalValue > 0 ? totalValue : 1)
        for _ in 0..<28 {
            let candidate = (low + high) / 2
            let occupied = models.reduce(CGFloat.zero) { $0 + max(self.slot, CGFloat($1.amounts.value(metric)) * candidate + gap) } - gap
            if occupied <= available { low = candidate } else { high = candidate }
        }
        let scale = low
        func positioned(_ input: [Node]) -> [Node] {
            let isModel = input.first?.column == 1
            let slots = input.map { max(isModel ? self.slot : gap, CGFloat($0.amounts.value(metric)) * scale + gap) }
            var y = (top + bottom - slots.reduce(0, +) + gap) / 2
            return input.enumerated().map { index, node in
                var n = node
                n.height = CGFloat(n.amounts.value(metric)) * scale
                n.y = y + (slots[index] - gap - n.height) / 2
                n.labelY = n.y + n.height / 2
                y += slots[index]
                return n
            }
        }
        tools = positioned(tools); kinds = positioned(kinds); models = positioned(models)
        let toolRank = Dictionary(uniqueKeysWithValues: tools.enumerated().map { ($0.element.title, $0.offset) })
        let toolCenters = Dictionary(uniqueKeysWithValues: tools.map { ($0.title, $0.y + $0.height / 2) })
        let kindCenters = Dictionary(uniqueKeysWithValues: kinds.compactMap { n -> (TokenKind, CGFloat)? in
            guard case .kind(let kind) = n.id else { return nil }; return (kind, n.y + n.height / 2)
        })
        let byModel = Dictionary(grouping: displayed.keys, by: \.model)
        func barycenter(_ model: Node, side: Int) -> Double {
            let keys = byModel[model.title] ?? []
            let denominator = model.amounts.value(metric)
            guard denominator > 0 else { return .greatestFiniteMagnitude }
            return keys.reduce(0) { result, id in
                let center = side == 0 ? toolCenters[id.tool, default: 0] : kindCenters[id.kind, default: 0]
                return result + Double(center) * (displayed[id]?.value(metric) ?? 0)
            } / denominator
        }
        func crossingScore(_ list: [Node]) -> Double {
            let rank = Dictionary(uniqueKeysWithValues: list.enumerated().map { ($0.element.title, $0.offset) })
            struct Connection: Hashable { var from: Int; var to: Int }
            var left: [Connection: Double] = [:], right: [Connection: Double] = [:]
            for (id, amounts) in displayed {
                guard let m = rank[id.model], amounts.value(metric) > 0 else { continue }
                let weight = amounts.value(metric) / max(1, totalValue)
                left[Connection(from: toolRank[id.tool, default: 0], to: m), default: 0] += weight
                right[Connection(from: m, to: id.kind.rawValue), default: 0] += weight
            }
            return [left, right].reduce(0) { result, connections in
                let entries = Array(connections)
                var score = result
                for i in entries.indices {
                    for j in entries.indices where j > i {
                        let a = entries[i], b = entries[j]
                        if (a.key.from - b.key.from) * (a.key.to - b.key.to) < 0 { score += a.value * b.value }
                    }
                }
                return score
            }
        }
        var best = models, bestScore = crossingScore(models)
        for pass in 0..<3 {
            func score(_ node: Node) -> Double {
                if pass == 0 { return barycenter(node, side: 0) }
                if pass == 1 { return barycenter(node, side: 1) }
                return (barycenter(node, side: 0) + barycenter(node, side: 1)) / 2
            }
            models.sort { score($0) == score($1) ? $0.title < $1.title : score($0) < score($1) }
            let candidateScore = crossingScore(models)
            if candidateScore <= bestScore { best = models; bestScore = candidateScore }
        }
        models = positioned(best)
        func spacedLabels(_ input: [Node]) -> [Node] {
            guard !input.isEmpty else { return [] }
            var output = input
            let spacing = min(self.slot, max(0, bottom - top - 10) / CGFloat(max(1, input.count - 1)))
            var previous = top + 5 - spacing
            for index in output.indices {
                output[index].labelY = max(output[index].labelY, previous + spacing)
                previous = output[index].labelY
            }
            let excess = max(0, previous - (bottom - 5))
            for index in output.indices { output[index].labelY -= excess }
            return output
        }
        tools = spacedLabels(tools); kinds = spacedLabels(kinds)
        for i in unpriced.indices {
            unpriced[i].y = bottom + 6 + CGFloat(i) * self.slot
            unpriced[i].labelY = unpriced[i].y + 6
        }
        nodes = tools + models + unpriced + kinds
        let modelRank = Dictionary(uniqueKeysWithValues: models.enumerated().map { ($0.element.title, $0.offset) })
        func toolOrder(_ a: TokenWatershedFlowID, _ b: TokenWatershedFlowID) -> Bool {
            let ar = toolRank[a.tool, default: 0], br = toolRank[b.tool, default: 0]
            return ar == br ? a.kind.rawValue < b.kind.rawValue : ar < br
        }
        func modelOrder(_ a: TokenWatershedFlowID, _ b: TokenWatershedFlowID) -> Bool {
            let ar = modelRank[a.model, default: Int.max], br = modelRank[b.model, default: Int.max]
            return ar == br ? toolOrder(a, b) : ar < br
        }
        func slots(_ list: [Node], sort: (TokenWatershedFlowID, TokenWatershedFlowID) -> Bool) -> [TokenWatershedFlowID: CGFloat] {
            var result: [TokenWatershedFlowID: CGFloat] = [:]
            for node in list {
                var y = node.y
                for id in displayed.keys.filter({ $0.matches(node.id) }).sorted(by: sort) {
                    result[id] = y
                    y += CGFloat(displayed[id]?.value(metric) ?? 0) * scale
                }
            }
            return result
        }
        let source = slots(tools, sort: modelOrder)
        let incoming = slots(models, sort: toolOrder)
        let outgoing = slots(models) { a, b in a.kind == b.kind ? toolOrder(a, b) : a.kind.rawValue < b.kind.rawValue }
        let sink = slots(kinds, sort: modelOrder)
        var groups: [RibbonID: [Band]] = [:]
        for (id, amounts) in displayed {
            let height = CGFloat(amounts.value(metric)) * scale
            guard height > 0, let a = source[id], let b = incoming[id], let c = outgoing[id], let d = sink[id] else { continue }
            let core = CGFloat(metric == .tokens ? Double(amounts.reasoning)
                               : NSDecimalNumber(decimal: amounts.reasoningCost).doubleValue) * scale
            let left = RibbonID(stage: 0, tool: id.tool, model: id.model, kind: nil)
            let right = RibbonID(stage: 1, tool: nil, model: id.model, kind: id.kind)
            groups[left, default: []].append(Band(id: id, amounts: amounts,
                geometry: Geometry(x0: x[0] + Self.barWidth, x1: x[1], y0: a, y1: b, height: height)))
            groups[right, default: []].append(Band(id: id, amounts: amounts,
                geometry: Geometry(x0: x[1] + Self.barWidth, x1: x[2], y0: c, y1: d, height: height, core: core)))
        }
        ribbons = groups.map { id, values in
            let bands = values.sorted { $0.geometry.y0 < $1.geometry.y0 }
            let first = bands[0].geometry
            let geometry = Geometry(x0: first.x0, x1: first.x1,
                y0: bands.map(\.geometry.y0).min() ?? 0, y1: bands.map(\.geometry.y1).min() ?? 0,
                height: bands.reduce(0) { $0 + $1.geometry.height }, core: bands.reduce(0) { $0 + $1.geometry.core })
            return Ribbon(id: id, geometry: geometry, bands: bands)
        }.sorted {
            if $0.id.stage != $1.id.stage { return $0.id.stage < $1.id.stage }
            if $0.geometry.y0 != $1.geometry.y0 { return $0.geometry.y0 < $1.geometry.y0 }
            return $0.geometry.y1 < $1.geometry.y1
        }
    }

    func resolved(_ selection: TokenWatershedSelection?) -> TokenWatershedSelection? {
        if let selection, case .model(let name) = selection, folded.contains(name) { return .model(Self.otherModels) }
        return selection
    }

    func amounts(for selection: TokenWatershedSelection) -> TokenWatershedAmounts {
        nodes.first { $0.id == resolved(selection) }?.amounts ?? .init()
    }

    func isRelevant(_ node: Node, to selection: TokenWatershedSelection?) -> Bool {
        guard let selection = resolved(selection) else { return true }
        if node.id == selection { return true }
        return ribbons.contains { $0.bands.contains { $0.id.matches(node.id) && $0.id.matches(selection) } }
    }

    func labelRect(for node: Node) -> CGRect {
        let height = max(18, slot - 6)
        switch node.column {
        case 0:
            return CGRect(x: 22, y: node.labelY - height / 2, width: max(0, node.x - 32), height: height)
        case 1:
            return CGRect(x: node.x + 6, y: node.labelY - height / 2,
                          width: max(0, size.width * 741 / 900 - node.x - 18), height: height)
        default:
            return CGRect(x: node.x + 9, y: node.labelY - height / 2,
                          width: max(0, size.width - node.x - 31), height: height)
        }
    }

    func hit(at point: CGPoint) -> TokenWatershedSelection? {
        for node in nodes where node.opacity > 0.65 {
            if labelRect(for: node).contains(point) { return node.id }
        }
        for node in nodes where node.opacity > 0.65 {
            if CGRect(x: node.x - 5, y: node.y - 3, width: 13, height: max(node.height, 12) + 6).contains(point) {
                return node.id
            }
        }
        for ribbon in ribbons.reversed() where ribbon.opacity > 0.65 {
            guard ribbon.geometry.path.contains(point) else { continue }
            if ribbon.id.stage == 0, let tool = ribbon.id.tool { return .tool(tool) }
            return .model(ribbon.id.model)
        }
        return nil
    }

    func interpolated(to next: Self, fraction: Double) -> Self {
        let t = CGFloat(min(1, max(0, fraction)))
        if t == 1 { return next }; if t == 0 { return self }
        var result = next
        result.size = CGSize(width: size.width + (next.size.width - size.width) * t,
                             height: size.height + (next.size.height - size.height) * t)
        let oldNodes = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        let newNodes = Dictionary(uniqueKeysWithValues: next.nodes.map { ($0.id, $0) })
        let nodeIDs = next.nodes.map(\.id) + nodes.filter { newNodes[$0.id] == nil }.map(\.id)
        result.nodes = nodeIDs.compactMap { id in
            guard var node = newNodes[id] ?? oldNodes[id] else { return nil }
            let a = oldNodes[id], b = newNodes[id]
            let ay = a?.y ?? node.y + node.height / 2, by = b?.y ?? node.y + node.height / 2
            node.x = (a?.x ?? node.x) + ((b?.x ?? node.x) - (a?.x ?? node.x)) * t
            node.y = ay + (by - ay) * t
            node.height = (a?.height ?? 0) + ((b?.height ?? 0) - (a?.height ?? 0)) * t
            node.labelY = (a?.labelY ?? node.labelY) + ((b?.labelY ?? node.labelY) - (a?.labelY ?? node.labelY)) * t
            node.opacity = (a?.opacity ?? 0) + ((b?.opacity ?? 0) - (a?.opacity ?? 0)) * Double(t)
            return node
        }
        let oldRibbons = Dictionary(uniqueKeysWithValues: ribbons.map { ($0.id, $0) })
        let newRibbons = Dictionary(uniqueKeysWithValues: next.ribbons.map { ($0.id, $0) })
        let ribbonIDs = next.ribbons.map(\.id) + ribbons.filter { newRibbons[$0.id] == nil }.map(\.id)
        result.ribbons = ribbonIDs.compactMap { id in
            guard var ribbon = newRibbons[id] ?? oldRibbons[id] else { return nil }
            let a = oldRibbons[id], b = newRibbons[id]
            ribbon.geometry = (a?.geometry ?? ribbon.geometry.collapsed)
                .interpolated(to: b?.geometry ?? ribbon.geometry.collapsed, fraction: t)
            ribbon.opacity = (a?.opacity ?? 0) + ((b?.opacity ?? 0) - (a?.opacity ?? 0)) * Double(t)
            let old = Dictionary(uniqueKeysWithValues: (a?.bands ?? []).map { ($0.id, $0) })
            let new = Dictionary(uniqueKeysWithValues: (b?.bands ?? []).map { ($0.id, $0) })
            let ids = (b?.bands ?? []).map(\.id) + (a?.bands ?? []).filter { new[$0.id] == nil }.map(\.id)
            ribbon.bands = ids.compactMap { key in
                guard var band = new[key] ?? old[key] else { return nil }
                band.geometry = (old[key]?.geometry ?? band.geometry.collapsed)
                    .interpolated(to: new[key]?.geometry ?? band.geometry.collapsed, fraction: t)
                band.opacity = (old[key]?.opacity ?? 0) + ((new[key]?.opacity ?? 0) - (old[key]?.opacity ?? 0)) * Double(t)
                return band
            }
            return ribbon
        }
        return result
    }
}
