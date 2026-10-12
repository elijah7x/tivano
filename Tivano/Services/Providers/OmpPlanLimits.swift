import Foundation

/// The subscription windows omp itself reports (`omp usage --json`) for every account it is
/// signed into, so the usage panel shows the same windows omp's own `/usage` does.
enum OmpPlanLimits {
    /// omp serves a last-good report for up to 24 h when the network fails; a window that old
    /// would read as live, so anything fetched longer ago than this is dropped.
    private static let maxReportAge: TimeInterval = 6 * 3_600

    private static let providerNames = [
        "anthropic": "Claude", "openai-codex": "Codex", "github-copilot": "Copilot",
        "google-gemini-cli": "Gemini", "google-antigravity": "Gemini", "zai": "Z.ai", "commandcode": "Command Code",
    ]

    /// Nil when omp is missing, fails, or has no usage to report (an API-key-only login), so the
    /// panel shows nothing instead of a login prompt.
    static func read(executable: URL, environment: [String: String]) async -> PlanLimits? {
        let home = environment["HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? LoginEnvironment.homeDirectory
        // Cold, omp needs the network to refresh its 5-minute cache.
        guard let result = try? await Shell.run(
            executable,
            ["usage", "--json", "--no-extensions"],
            in: URL(fileURLWithPath: home),
            environment: environment,
            timeout: 45
        ), result.succeeded else { return nil }
        let text = String(decoding: result.stdout, as: UTF8.self)
        guard let start = text.firstIndex(of: "{"), let payload = JSONValue.parse(String(text[start...])) else { return nil }
        return windows(from: payload)
    }

    /// The pure mapping from omp's usage payload; `now` is a parameter so a harness can pin it.
    nonisolated static func windows(from payload: JSONValue, now: Date = .now) -> PlanLimits? {
        var windows: [PlanLimits.Window] = []
        var names: [String] = []
        var seenProviders: Set<String> = []
        for report in payload["reports"]?.array ?? [] {
            guard let provider = report["provider"]?.string,
                  let limits = report["limits"]?.array, !limits.isEmpty,
                  !seenProviders.contains(provider) else { continue }
            if let fetched = report["fetchedAt"]?.double,
               now.timeIntervalSince(Date(timeIntervalSince1970: fetched / 1_000)) > maxReportAge { continue }
            let metadata = report["metadata"]
            let prefix = providerNames[provider] ?? (provider.prefix(1).uppercased() + provider.dropFirst())
            var kept = 0
            for limit in limits {
                guard let id = limit["id"]?.string,
                      let window = window(from: limit, id: "\(provider)|\(id)", prefix: prefix, now: now) else { continue }
                windows.append(window)
                kept += 1
            }
            if kept > 0 { seenProviders.insert(provider) }
            if kept > 0, let name = planName(provider: provider, metadata: metadata), !names.contains(name) {
                names.append(name)
            }
        }
        guard !windows.isEmpty else { return nil }
        return PlanLimits(planName: names.isEmpty ? nil : names.joined(separator: " · "), windows: windows)
    }

    private nonisolated static func window(from limit: JSONValue, id: String, prefix: String, now: Date) -> PlanLimits.Window? {
        let amount = limit["amount"]
        let unit = amount?["unit"]?.string ?? "unknown"
        let used = amount?["used"]?.double
        let max = amount?["limit"]?.double
        // omp's own resolveUsedFraction order.
        let fraction: Double
        if let value = amount?["usedFraction"]?.double {
            fraction = value
        } else if let used, let max, max > 0 {
            fraction = used / max
        } else if unit == "percent", let used {
            fraction = used / 100
        } else if let remaining = amount?["remainingFraction"]?.double {
            fraction = 1 - remaining
        } else if limit["status"]?.string == "exhausted" {
            fraction = 1
        } else {
            return nil
        }

        let window = limit["window"]
        var title = window?["durationMs"]?.double
            .map { PlanLimitsReader.windowTitle(minutes: Int($0 / 60_000)) }
            ?? limit["label"]?.string.map { $0.hasPrefix(prefix + " ") ? String($0.dropFirst(prefix.count + 1)) : $0 } ?? String(localized: "Usage limit")
        let scope = limit["scope"]
        if let extra = (scope?["tier"]?.string ?? scope?["modelId"]?.string)?.nilIfEmpty,
           !title.localizedCaseInsensitiveContains(extra) {
            title += " · \(extra)"
        }

        var detail: [String] = []
        if unit != "percent", unit != "unknown", let used, let max {
            detail.append(unit == "usd"
                ? String(format: "$%.2f / $%.2f", used, max)
                : "\(number(used)) / \(number(max)) \(unit)")
        }
        if let notes = limit["notes"]?.array?.compactMap(\.string).filter({ !$0.isEmpty }), !notes.isEmpty { detail.append(contentsOf: notes) }

        let resetsAt = window?["resetsAt"]?.double.map { Date(timeIntervalSince1970: $0 / 1_000) }
        return PlanLimits.Window(
            id: id,
            title: "\(prefix) · \(title)",
            percent: Swift.min(Swift.max(fraction, 0), 1) * 100,
            resetsAt: resetsAt.flatMap { $0 > now ? $0 : nil },
            detail: detail.isEmpty ? nil : detail.joined(separator: " · ")
        )
    }

    private nonisolated static func planName(provider: String, metadata: JSONValue?) -> String? {
        let raw = (metadata?["planType"]?.string ?? metadata?["plan"]?.string ?? metadata?["currentTierName"]?.string)?.nilIfEmpty
        switch provider {
        case "openai-codex": return PlanLimitsReader.codexPlanName(raw).map { "Codex \($0)" }
        case "github-copilot": return PlanLimitsReader.planName(raw).map { "Copilot \($0)" }
        case "zai": return PlanLimitsReader.planName(raw).map { "Coding Plan \($0)" }
        case "commandcode": return CommandCodeAPI.planName(raw)
        case "google-gemini-cli", "google-antigravity": return raw
        default: return nil
        }
    }

    private nonisolated static func number(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }
}
