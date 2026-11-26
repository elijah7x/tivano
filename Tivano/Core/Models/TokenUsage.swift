import Foundation

struct TokenUsageRow: Codable, Hashable, Sendable {
    var day: String
    var tool: String
    var model: String
    var inputTokens: Int64
    var cachedInputTokens: Int64
    var cacheWriteTokens: Int64
    var outputTokens: Int64
    var reasoningTokens: Int64
    var totalTokens: Int64
    var costUSD: Decimal?
}

enum TokenUsageScope: String, Codable, CaseIterable, Sendable {
    case all, personal
}

struct TokenUsageSourceInfo: Codable, Hashable, Sendable {
    var id: String
    var displayName: String
    var version: String?
    var fetchedFrom: String
}

struct TokenUsageSnapshot: Codable, Sendable {
    static let currentSchemaVersion = 1
    var schemaVersion: Int
    var source: TokenUsageSourceInfo
    var fetchedAt: Date
    var from: String
    var to: String
    var timeZone: String
    var scope: TokenUsageScope
    var rows: [TokenUsageRow]
    var warnings: [String]
}

struct TokenUsageDay: Hashable, Sendable {
    let day: String
    let total: Int64
    let byTool: [String: Int64]
}

extension TokenUsageSnapshot {
    /// Zero-filled only because the snapshot covers a confirmed complete range.
    func days() -> [TokenUsageDay] {
        guard let zone = TimeZone(identifier: timeZone) else { return [] }
        return DayFormatterCache.shared.withFormatter(for: zone) { calendar, formatter in
            guard let first = formatter.date(from: from),
                  let last = formatter.date(from: to),
                  formatter.string(from: first) == from,
                  formatter.string(from: last) == to,
                  first <= last else { return [] }

            var totals: [String: [String: Int64]] = [:]
            for row in rows(from: from, through: to) {
                totals[row.day, default: [:]][row.tool, default: 0] += row.totalTokens
            }
            var result: [TokenUsageDay] = []
            var date = first
            while date <= last {
                let day = formatter.string(from: date)
                let byTool = totals[day] ?? [:]
                result.append(TokenUsageDay(day: day, total: byTool.values.reduce(0, +), byTool: byTool))
                guard let next = calendar.date(byAdding: .day, value: 1, to: date), next > date else { break }
                date = calendar.startOfDay(for: next)
            }
            return result
        }
    }

    func rows(from: String, through: String) -> [TokenUsageRow] {
        rows.filter { $0.day >= from && $0.day <= through }
    }
}

enum TokenUsageTool {
    static func displayName(for id: String) -> String {
        switch id {
        case "claude": return "Claude Code"
        case "codex": return "Codex"
        case "gemini": return "Gemini CLI"
        case "opencode": return "OpenCode"
        case "cursor": return "Cursor"
        case "kimi": return "Kimi Code"
        case "copilot": return "Copilot"
        case "grok": return "Grok"
        case "devin": return "Devin"
        case "antigravity": return "Antigravity"
        case "qwen": return "Qwen"
        case "amp": return "Amp"
        case "zcode": return "Zcode"
        case "omp": return "oh-my-pi"
        case "pi": return "pi"
        case "hermes": return "Hermes"
        case "kiro": return "Kiro"
        case "droid": return "Droid"
        case "goose": return "Goose"
        case "zed": return "Zed"
        case "factory": return "Factory Droid"
        case "dsh": return "DeepSeek Harness"
        case "fx": return "fx"
        case "mcode": return "MiniMax Code"
        case "deepseek-cli": return "DeepSeek CLI"
        default: return id.prefix(1).uppercased() + id.dropFirst()
        }
    }
}
