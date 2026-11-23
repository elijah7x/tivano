import Foundation

private struct AntigravityModelsProbeKey: Hashable {
    let executable: String
    let environment: String

    init(executable: URL, environment: [String: String]) {
        self.executable = executable.resolvingSymlinksInPath().standardizedFileURL.path
        self.environment = environment.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "\0")
    }
}

private actor AntigravityModelsProbeCache {
    struct Entry {
        let key: AntigravityModelsProbeKey
        let task: Task<ShellResult, Error>
        var completedAt: Date?
    }

    var entry: Entry?

    func reset(key: AntigravityModelsProbeKey) {
        if entry?.key == key { entry = nil }
    }

    func models(
        key: AntigravityModelsProbeKey,
        force: Bool,
        operation: @escaping @Sendable () async throws -> ShellResult
    ) async throws -> ShellResult {
        if force { entry = nil }
        if let entry, entry.key == key,
           entry.completedAt.map({ (0..<5).contains(Date.now.timeIntervalSince($0)) }) ?? true {
            return try await entry.task.value
        }
        let task = Task { try await operation() }
        entry = Entry(key: key, task: task, completedAt: nil)
        do {
            let result = try await task.value
            if entry?.task == task {
                if result.succeeded {
                    entry?.completedAt = .now
                } else {
                    entry = nil
                }
            }
            return result
        } catch {
            if entry?.task == task { entry = nil }
            throw error
        }
    }
}

/// CLI helpers for Google's Antigravity CLI (`agy`): model catalog, model/effort
/// normalization, auth status, plan limits, one-shot stream-json review parsing,
/// transient-failure classification, and retry-log parsing.
///
/// Interactive Antigravity chats run through `agy acp` in `ACPSession`.
///
/// Protocol reference: https://antigravity.google/docs/cli/headless/
/// Verified live against `agy 1.2.2` (models TSV, `/usage` and `/credits`
/// headless envelopes).
@MainActor
enum AntigravitySession {
    /// Reasoning efforts `agy --effort` accepts.
    static let efforts = ["low", "medium", "high", "xhigh", "max"]
    private static let modelsProbeCache = AntigravityModelsProbeCache()

    static func beginCatalogProbeCycle(executable: URL, environment: [String: String]) async {
        await modelsProbeCache.reset(key: AntigravityModelsProbeKey(executable: executable, environment: environment))
    }

    // MARK: - Retry log tailing

    static func makeLogFileURL() -> URL {
        let logDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini/antigravity-cli/log", isDirectory: true)
        try? FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let timestamp = formatter.string(from: Date())
        let suffix = String(UUID().uuidString.prefix(8)).lowercased()
        return logDirectory.appendingPathComponent("cli-\(timestamp)-tivano-\(suffix).log", isDirectory: false)
    }

    nonisolated static func parseRetry(_ line: String) -> (attempt: Int, labelKey: String)? {
        guard let retry = parseRetryDetails(line) else { return nil }
        return (retry.attempt, retry.labelKey)
    }

    nonisolated static func parseRetryDetails(_ line: String) -> (attempt: Int, reason: String, labelKey: String)? {
        // agy logs retries both with a "request failed: " prefix and with bare causes like "stream reading error: unexpected EOF".
        guard let match = line.firstMatch(of: #/run\.go:\d+\] Run: attempt (\d+) failed \((?:request failed: )?(.+)\), retrying in ([0-9.]+)(ms|s|m)/#),
              let attempt = Int(match.output.1) else {
            return nil
        }
        let reason = String(match.output.2)
        return (attempt, reason, retryLabelKey(for: reason))
    }

    nonisolated static func retryLabelKey(for reason: String) -> String {
        let lowered = reason.lowercased()
        if lowered.contains("stream idle timeout") {
            return "no response for 5 minutes"
        }
        if lowered.hasSuffix(": eof") || lowered.contains("unexpected eof") {
            return "connection dropped"
        }
        if lowered.contains("no such host") || lowered.contains("i/o timeout") {
            return "network/DNS error"
        }
        if lowered.contains("429") || lowered.contains("resource_exhausted") {
            return "rate limited"
        }
        if lowered.contains("503") || lowered.contains("capacity") {
            return "server busy"
        }
        return "request failed"
    }

    static func retryNotice(attempt: Int, reason: String, labelKey: String) -> Notice {
        let localizedLabel = AppText.localized(labelKey)
        let message = String(
            format: AppText.localized("Antigravity: the model request failed (%@); agy is retrying, attempt %lld."),
            localizedLabel,
            Int64(attempt + 1)
        )
        return Notice(level: .info, message: message)
    }

    static func loginHint(in text: String) -> String? {
        let lowered = text.lowercased()
        guard lowered.contains("authentication required")
            || lowered.contains("authentication failed")
            || lowered.contains("failed to authenticate")
            || lowered.contains("not signed in")
            || lowered.contains("not logged in")
            || lowered.contains("unauthenticated")
            || (lowered.contains("login") && (lowered.contains("agy") || lowered.contains("required") || lowered.contains("failed"))) else { return nil }
        return AppText.localized("Antigravity is not signed in. Run `agy` once in Terminal to sign in.")
    }

    // MARK: - Turn outcome

    /// The message of an error step. The stream does not document the error shape, so the
    /// fields it plausibly rides on are tried in turn; the free-text fields only count on
    /// a step that is an error itself, because ordinary steps put their reply there.
    nonisolated private static func errorMessage(in step: JSONValue) -> String? {
        var candidates: [String?] = [step["error"]?["message"]?.string, step["error"]?.string, step["error_message"]?.string]
        if step["step_type"]?.string?.localizedCaseInsensitiveContains("error") == true || step["state"]?.string == "ERROR" {
            candidates += [step["text"]?.string, step["message"]?.string, step["text_delta"]?.string]
        }
        guard let message = candidates.lazy.compactMap({ $0?.trimmed }).first(where: { !$0.isEmpty }) else { return nil }
        return message.count > 500 ? String(message.prefix(499)) + "…" : message
    }

    struct TurnOutcome: Equatable {
        enum Status: Equatable {
            case completed
            case interrupted
            case failed
        }

        let status: Status
        let recovered: Bool
    }

    /// agy's result status and error are conversation-sticky: an earlier error step is repeated
    /// on later results with finished_reason "error". The turn's own stream decides instead:
    /// when this turn had a cascade error, recovery requires a completed agent_response after
    /// it, with reply text and no denied actions; without a cascade error in this turn, a reply
    /// (streamed or in `result["response"]`) with no denied actions succeeds when the result
    /// error matches one seen in an earlier turn or when the turn also completed tool work.
    nonisolated static func turnOutcome(
        interruptRequested: Bool,
        status: String?,
        finishedReason: String?,
        hasDeniedActions: Bool,
        hasReply: Bool,
        completedResponseIndex: Int?,
        latestCascadeErrorIndex: Int?,
        cascadeErrorMessages: Set<String>,
        knownConversationErrors: Set<String>,
        hasCompletedToolWork: Bool = false,
        replyOnlyInResult: Bool = false,
        resultError: String?
    ) -> TurnOutcome {
        if interruptRequested {
            return TurnOutcome(status: .interrupted, recovered: false)
        }
        // An empty or blank reason is the same as an absent one: agy omits it on normal completion.
        let trimmedReason = finishedReason?.trimmingCharacters(in: .whitespacesAndNewlines)
        let finishedReason = trimmedReason?.isEmpty == true ? nil : trimmedReason
        if finishedReason == "interrupted" {
            return TurnOutcome(status: .interrupted, recovered: false)
        }
        if let finishedReason, !(finishedReason == "error" && status == "ERROR") {
            return TurnOutcome(status: .failed, recovered: false)
        }
        switch status {
        case "SUCCESS":
            return TurnOutcome(status: .completed, recovered: false)
        case "CANCELED", "INTERRUPTED":
            return TurnOutcome(status: .interrupted, recovered: false)
        case "WAITING":
            return TurnOutcome(status: hasDeniedActions ? .failed : .completed, recovered: false)
        default:
            guard hasReply, !hasDeniedActions else {
                return TurnOutcome(status: .failed, recovered: false)
            }
            let resultError = resultError?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if let latestCascadeErrorIndex {
                guard let completedResponseIndex,
                      completedResponseIndex > latestCascadeErrorIndex,
                      resultError.isEmpty || matchesError(resultError, in: cascadeErrorMessages) else {
                    return TurnOutcome(status: .failed, recovered: false)
                }
            } else if resultError.isEmpty {
                guard completedResponseIndex != nil else {
                    return TurnOutcome(status: .failed, recovered: false)
                }
            } else {
                // No error step this turn: the result error is agy's sticky one only when an
                // earlier turn of this conversation (or this session's retry log) already
                // reported it. An unknown error stays a failure, whatever work came before it.
                // A streamed reply still needs its closing agent_response (a tool after an
                // interim reply clears it); only a reply agy handed over solely in the result
                // stands without one.
                guard matchesError(resultError, in: knownConversationErrors),
                      completedResponseIndex != nil || replyOnlyInResult else {
                    return TurnOutcome(status: .failed, recovered: false)
                }
            }
            return TurnOutcome(status: .completed, recovered: true)
        }
    }

    nonisolated private static func matchesError(_ resultError: String, in knownErrors: Set<String>) -> Bool {
        if knownErrors.contains(resultError) { return true }
        return knownErrors.contains { known in
            guard !known.isEmpty else { return false }
            if resultError.contains(known) { return true }
            if known.hasSuffix("…"), known.count > 1, resultError.hasPrefix(String(known.dropLast())) {
                return true
            }
            return false
        }
    }

    /// Whether agy gave up on a failure that automatic continuation can safely retry.
    /// Keep this conservative: quota, configuration, authentication and permission failures
    /// need user action, and print timeouts describe Tivano's own output limit, not transport.
    nonisolated static func isTransientFailure(_ message: String) -> Bool {
        let lowered = message.lowercased()
        if lowered.contains("print_timeout") || lowered.contains("print timeout") {
            return false
        }
        let permanent = [
            "quota", "resource_exhausted", "credits", "billing",
            "sign in", "sign-in", "log in", "log-in", "not logged into",
            "auth", "permission", "denied",
            "invalid model selection", "unknown flag", "not supported for model",
            // agy already retries 503/capacity internally with backoff; Tivano retrying causes a storm.
            "503", "unavailable", "no capacity",
        ]
        if permanent.contains(where: { lowered.contains($0) })
            || (lowered.contains("has no \"") && lowered.contains("effort")) {
            return false
        }
        let transient = [
            "unexpected eof", "tls handshake timeout", "no such host", "i/o timeout",
            "connection reset", "broken pipe", "network issue", "network is down",
            "stream idle timeout", "http2:", "timeout awaiting response headers",
            "502", "500 ", "internal", "deadline_exceeded",
            "the stream was interrupted",
            "antigravity did not finish starting in time",
            "antigravity 未能及时完成启动",
            "antigravity 未能及時完成啟動",
            "antigravity n’a pas terminé son démarrage à temps",
            "antigravity n'a pas terminé son démarrage à temps",
            "antigravity が時間内に起動を完了できませんでした",
            "antigravity가 제시간에 시작을 완료하지 못했습니다",
            "antigravity did not start within 90 seconds",
            "antigravity 在 90 秒内没有启动",
            "antigravity 在 90 秒內未啟動",
            "antigravity n’a pas démarré sous 90 secondes",
            "antigravity n'a pas démarré sous 90 secondes",
            "antigravity は 90 秒以内に開始しませんでした",
            "antigravity 응답이 90초 이내에 시작되지 않았습니다",
        ]
        return transient.contains(where: { lowered.contains($0) })
    }

    // MARK: - Model and Effort Normalization

    struct ParsedModelRow {
        let baseSlug: String
        let baseName: String
        let effort: String?
    }

    static func parseModelRow(slug: String, name: String) -> ParsedModelRow {
        // Longest suffix first so `-xhigh` is not parsed as `-x` + `high`.
        for effort in ["medium", "xhigh", "high", "low", "max"] {
            if slug.hasSuffix("-\(effort)") {
                let baseSlug = String(slug.dropLast(effort.count + 1))
                var baseName = name
                if let range = baseName.range(of: " (\(effort))", options: [.anchored, .backwards, .caseInsensitive]) {
                    baseName = String(baseName[..<range.lowerBound])
                }
                return ParsedModelRow(baseSlug: baseSlug, baseName: baseName, effort: effort)
            }
        }
        return ParsedModelRow(baseSlug: slug, baseName: name, effort: nil)
    }

    /// A catalog restored from before a seed row existed lacks that model, which would
    /// send it as unknown with whatever effort the thread carries; the seed fills the gap.
    static func addingSeedRows(_ catalog: [ModelOption], seed: [ModelOption]) -> [ModelOption] {
        catalog + seed.filter { row in !catalog.contains { $0.id == row.id } }
    }

    /// Exact effort-suffixed model IDs listed by `agy models` (verified on `agy 1.5.10`).
    /// Passing `--model <base>-<effort>` without `--effort` resolves locally when `agy`'s
    /// startup model fetch fails, whereas `--model <base> --effort <effort>` requires the
    /// fetched catalog and fails when that fetch hits a DNS blip.
    private static let suffixedModelEfforts: [String: Set<String>] = [
        "gemini-4-carbon": ["low", "medium", "high"],
        "gemini-4-argon": ["low", "medium", "high"],
        "gemini-4-hydrogen": ["low", "medium", "high", "xhigh"],
        "gemini-3.8-flash": ["low", "medium", "high"],
        "gpt-oss-120b": ["medium"],
    ]

    private static func resolvedArguments(baseSlug: String, effort: String?) -> (model: String, effort: String?) {
        if let effort, suffixedModelEfforts[baseSlug]?.contains(effort) == true {
            return ("\(baseSlug)-\(effort)", nil)
        }
        return (baseSlug, effort)
    }

    /// Normalizes model and effort flags for `agy`.
    /// Strips any legacy effort suffixes from model slugs and resolves the effort
    /// level against the model's catalog row: `--effort` only carries an effort the
    /// model declares (the CLI exits on one it does not), and an unknown model gets
    /// only an explicitly requested effort, never an invented default. When the
    /// resolved `(baseSlug, effort)` pair matches an exact effort-suffixed ID in
    /// `agy models`, sends `--model <base>-<effort>` with no `--effort`.
    static func normalize(model: String?, effort: String?, catalog: [ModelOption]) -> (model: String?, effort: String?) {
        guard let model, !model.isEmpty else { return (nil, nil) }
        let parsed = parseModelRow(slug: model, name: "")
        let baseSlug = parsed.baseSlug

        // Models that do not take --effort (such as Claude models hosted on Antigravity)
        if baseSlug.contains("claude") {
            return (baseSlug, nil)
        }

        var requested = effort
        if requested == nil || requested?.isEmpty == true {
            requested = parsed.effort
        }

        // The catalog keys rows by base slug: `listModels` groups every effort
        // variant of a model under the one row its `id` names.
        guard let row = catalog.first(where: { $0.id == baseSlug }) else {
            // Unknown model: pass only what was asked for. The two slugs known to
            // accept effort keep their adjustments, and their old default when
            // nothing was requested.
            var resolvedEffort = requested
            if resolvedEffort == nil || resolvedEffort?.isEmpty == true {
                if baseSlug == "gpt-oss-120b" {
                    resolvedEffort = "medium"
                } else if baseSlug == "gemini-3.1-pro" {
                    resolvedEffort = "high"
                }
            }
            if baseSlug == "gemini-3.1-pro" && resolvedEffort == "medium" {
                resolvedEffort = "high"
            } else if baseSlug == "gpt-oss-120b" {
                resolvedEffort = "medium"
            }
            return resolvedArguments(baseSlug: baseSlug, effort: resolvedEffort)
        }

        guard !row.efforts.isEmpty else { return (baseSlug, nil) }
        var resolvedEffort: String?
        if let requested, row.efforts.contains(requested) {
            resolvedEffort = requested
        } else if let fallback = row.defaultEffort, row.efforts.contains(fallback) {
            resolvedEffort = fallback
        } else {
            // `listModels` orders efforts low to high, so the last one is the highest it takes.
            resolvedEffort = row.efforts.last
        }

        // Validate effort against model constraints, without leaving the row's efforts.
        if baseSlug == "gemini-3.1-pro" && resolvedEffort == "medium" && row.efforts.contains("high") {
            resolvedEffort = "high"
        } else if baseSlug == "gpt-oss-120b" && row.efforts.contains("medium") {
            resolvedEffort = "medium"
        }

        return resolvedArguments(baseSlug: baseSlug, effort: resolvedEffort)
    }

    // MARK: - Catalog

    /// `agy models` prints `slug<TAB>Name` rows on stdout (progress goes to
    /// stderr). Rows with effort variants (-low, -medium, -high, -xhigh, -max)
    /// are collapsed into a single base model entry whose supported efforts are
    /// toggled via the reasoning effort slider.
    static func listModels(executable: URL, environment: [String: String]) async throws -> [ModelOption] {
        try await listModels(executable: executable, environment: environment, force: false)
    }

    static func listModels(executable: URL, environment: [String: String], force: Bool) async throws -> [ModelOption] {
        async let modelsFetch: ShellResult = try modelsResult(executable: executable, environment: environment, force: force)
        // The default model is a print-mode read too, so it is skipped offline like the limits.
        async let defaultFetch: ShellResult? = NetworkPath.isUsable() ? try? Shell.run(executable, ["-p", "/model", "--output-format", "json"], environment: environment, timeout: 30) : nil
        let models = try? await modelsFetch
        let current = await defaultFetch
        var currentID: String?
        if let stdout = current?.stdout, let json = JSONValue.parse(stdout) {
            currentID = json["command"]?["data"]?["id"]?.string
        }
        guard let output = models?.stdout, let text = String(data: output, encoding: .utf8) else {
            throw ShellError(AppText.localized("`agy models` produced no output."))
        }

        var grouped: [String: (name: String, efforts: [String], isDefault: Bool)] = [:]
        var order: [String] = []

        for line in TextCleanup.stripANSI(text).components(separatedBy: .newlines) {
            let trimmed = line.trimmed
            guard !trimmed.isEmpty else { continue }
            let parts = trimmed.split(separator: "\t", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard let slug = parts.first, Self.isSlug(slug) else { continue }
            let name = parts.count > 1 && !parts[1].isEmpty ? parts[1] : slug
            let parsed = parseModelRow(slug: slug, name: name)

            let isCurrent = slug == currentID || parsed.baseSlug == currentID || (currentID?.hasPrefix(parsed.baseSlug) == true)

            if grouped[parsed.baseSlug] == nil {
                order.append(parsed.baseSlug)
                grouped[parsed.baseSlug] = (
                    name: parsed.baseName,
                    efforts: parsed.effort.map { [$0] } ?? [],
                    isDefault: isCurrent
                )
            } else {
                if let eff = parsed.effort, !grouped[parsed.baseSlug]!.efforts.contains(eff) {
                    grouped[parsed.baseSlug]!.efforts.append(eff)
                }
                if isCurrent {
                    grouped[parsed.baseSlug]!.isDefault = true
                }
            }
        }

        var list: [ModelOption] = []
        for baseSlug in order {
            guard let data = grouped[baseSlug] else { continue }
            let sortedEfforts = efforts.filter { data.efforts.contains($0) }
            let defaultEffort = sortedEfforts.contains("high") ? "high" : sortedEfforts.last
            list.append(ModelOption(
                id: baseSlug,
                name: data.name,
                efforts: sortedEfforts,
                defaultEffort: defaultEffort,
                isDefault: data.isDefault
            ))
        }

        guard !list.isEmpty else { throw ShellError(AppText.localized("`agy models` listed no models.")) }
        if !list.contains(where: \.isDefault), let first = list.first {
            list[list.startIndex] = ModelOption(
                id: first.id, name: first.name, detail: first.detail,
                efforts: first.efforts, defaultEffort: first.defaultEffort, isDefault: true
            )
        }
        return list
    }

    private static func isSlug(_ text: String) -> Bool {
        guard let first = text.first, first.isLetter || first.isNumber else { return false }
        return text.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." }
            && !text.contains(" ")
    }

    private static func modelsResult(executable: URL, environment: [String: String], force: Bool = false) async throws -> ShellResult {
        let key = AntigravityModelsProbeKey(executable: executable, environment: environment)
        return try await modelsProbeCache.models(key: key, force: force) {
            try await Shell.run(executable, ["models"], environment: environment, timeout: 30)
        }
    }

    /// Sign-in state without spending tokens: `agy models` needs the cached
    /// Google session (or `GEMINI_API_KEY`) and fails loudly without one.
    static func authStatus(executable: URL, environment: [String: String]) async -> ProviderStatus.Auth {
        guard let result = try? await modelsResult(executable: executable, environment: environment) else {
            return .unknown
        }
        let text = TextCleanup.stripANSI(result.output + result.errorOutput)
        let rows = text.components(separatedBy: .newlines).filter { isSlug($0.split(separator: "\t").first.map(String.init) ?? "") }
        if result.succeeded, !rows.isEmpty { return .signedIn(nil) }
        let lowered = text.lowercased()
        if lowered.contains("authentication required") || lowered.contains("not signed in")
            || lowered.contains("unauthenticated") || lowered.contains("sign in") || lowered.contains("login") {
            return .signedOut
        }
        return result.succeeded ? .signedIn(nil) : .unknown
    }

    // MARK: - Plan limits

    /// Model quotas (`/usage`: weekly + 5-hour buckets per model group) and
    /// the AI credit balance (`/credits`). Both are zero-token headless
    /// calls, so reading limits never spends quota itself.
    ///
    /// Neither runs without a network path. Print mode refreshes the Google token first,
    /// and when that fails it starts the interactive sign-in, which opens the browser:
    /// offline, each of the two processes opened a sign-in page of its own.
    static func readPlanLimits(executable: URL, environment: [String: String]) async throws -> PlanLimits? {
        guard await NetworkPath.isUsable() else { return nil }
        async let usageFetch: ShellResult = try Shell.run(executable, ["-p", "/usage", "--output-format", "json"], environment: environment, timeout: 30)
        async let creditsFetch: ShellResult = try Shell.run(executable, ["-p", "/credits", "--output-format", "json"], environment: environment, timeout: 30)
        let usage = try? await usageFetch
        let credits = try? await creditsFetch
        var windows: [PlanLimits.Window] = []
        if let usage, let data = String(data: usage.stdout, encoding: .utf8), let json = JSONValue.parse(data) {
            windows += parseUsage(json["command"]?["data"], fallback: json["response"]?.string)
        }
        if let credits, let data = String(data: credits.stdout, encoding: .utf8), let json = JSONValue.parse(data),
           let window = parseCredits(json["command"]?["data"], fallback: json["response"]?.string) {
            windows.append(window)
        }
        guard !windows.isEmpty else { return nil }
        return PlanLimits(planName: nil, windows: windows)
    }

    /// The structured envelope: groups of models sharing a weekly and a
    /// 5-hour bucket. `remaining_fraction` is what is left, so the usage
    /// panel's percent is the complement.
    private static func parseUsage(_ data: JSONValue?, fallback response: String?) -> [PlanLimits.Window] {
        var windows: [PlanLimits.Window] = []
        for group in data?["groups"]?.array ?? [] {
            let groupName = group["name"]?.string ?? "Models"
            for bucket in group["buckets"]?.array ?? [] {
                guard let remaining = bucket["remaining_fraction"]?.double else { continue }
                windows.append(PlanLimits.Window(
                    id: bucket["id"]?.string ?? "\(groupName)-\(windows.count)",
                    title: "\(groupName) · \(bucket["name"]?.string ?? "Limit")",
                    percent: max(0, min(100, (1 - remaining) * 100)),
                    resetsAt: bucket["reset_time"]?.string.flatMap(ISO8601.date(from:))
                ))
            }
        }
        if windows.isEmpty, let response { windows += parseUsageText(response) }
        return windows
    }

    /// Older CLIs without the structured envelope: `Group<TAB>Bucket<TAB>95%<TAB><ISO date>`
    /// rows, where the percent is what remains.
    private static func parseUsageText(_ response: String) -> [PlanLimits.Window] {
        var windows: [PlanLimits.Window] = []
        for line in response.components(separatedBy: .newlines) {
            let parts = line.split(separator: "\t").map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count >= 3 else { continue }
            let percentText = parts[2].replacingOccurrences(of: "%", with: "")
            guard let remaining = Double(percentText) else { continue }
            let reset = parts.count >= 4 ? ISO8601.date(from: parts[3]) : nil
            windows.append(PlanLimits.Window(
                id: "usage-\(windows.count)",
                title: "\(parts[0]) · \(parts[1])",
                percent: max(0, min(100, 100 - remaining)),
                resetsAt: reset
            ))
        }
        return windows
    }

    private static func parseCredits(_ data: JSONValue?, fallback response: String?) -> PlanLimits.Window? {
        if let remaining = data?["remaining_credits"]?.int {
            return PlanLimits.Window(
                id: "ai-credits",
                title: String(format: AppText.localized("AI credits · %d remaining"), remaining),
                percent: remaining > 0 ? 0 : 100,
                resetsAt: nil
            )
        }
        guard let response else { return nil }
        for line in response.components(separatedBy: .newlines) {
            let parts = line.split(separator: "\t").map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count >= 2, parts[0].localizedCaseInsensitiveContains("credit"),
                  let remaining = Int(parts[1]) else { continue }
            return PlanLimits.Window(
                id: "ai-credits",
                title: String(format: AppText.localized("AI credits · %d remaining"), remaining),
                percent: remaining > 0 ? 0 : 100,
                resetsAt: nil
            )
        }
        return nil
    }
}

/// Tails `agy`'s `--log-file` on a utility queue while a turn is active so
/// silent model-request retries surface in the thread without polling when idle.
final class AntigravityLogTailer: @unchecked Sendable {
    private static let maxRemainderBytes = 1_048_576

    private let url: URL
    private let queue = DispatchQueue(label: "tivano.antigravity.logtailer", qos: .utility)
    private let onLine: @Sendable (String) -> Void
    private var timer: DispatchSourceTimer?
    private var handle: FileHandle?
    private var offset: UInt64 = 0
    private var remainder = Data()
    private var turnActive = false
    private var closed = false

    init(url: URL, onLine: @escaping @Sendable (String) -> Void) {
        self.url = url
        self.onLine = onLine
    }

    func setTurnActive(_ active: Bool) {
        queue.async { [self] in
            guard !closed, turnActive != active else { return }
            turnActive = active
            if active {
                // Whatever was logged since the last turn's final tick belongs to that turn,
                // which is over: skip it, so a late retry line never shows on this turn or
                // suppresses this turn's own attempt with the same number.
                skipBacklog()
                let timer = DispatchSource.makeTimerSource(queue: queue)
                timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(200))
                timer.setEventHandler { [weak self] in
                    self?.poll()
                }
                self.timer = timer
                timer.resume()
            } else {
                timer?.cancel()
                timer = nil
            }
        }
    }

    func shutDown() {
        queue.async { [self] in
            guard !closed else { return }
            closed = true
            turnActive = false
            timer?.cancel()
            timer = nil
            try? handle?.close()
            handle = nil
            remainder.removeAll(keepingCapacity: false)
        }
    }

    deinit {
        timer?.cancel()
        try? handle?.close()
    }

    private func skipBacklog() {
        if handle == nil { handle = try? FileHandle(forReadingFrom: url) }
        guard let handle, let end = try? handle.seekToEnd() else { return }
        offset = end
        remainder.removeAll(keepingCapacity: false)
    }

    private func poll() {
        guard !closed, turnActive else { return }
        if handle == nil {
            guard let opened = try? FileHandle(forReadingFrom: url) else { return }
            handle = opened
        }
        guard let handle else { return }
        do {
            let endOffset = try handle.seekToEnd()
            if endOffset < offset {
                offset = 0
                remainder.removeAll(keepingCapacity: false)
            }
            guard endOffset > offset else { return }
            try handle.seek(toOffset: offset)
            while !closed, turnActive {
                guard let chunk = try handle.read(upToCount: 65_536), !chunk.isEmpty else { break }
                offset += UInt64(chunk.count)
                consume(chunk)
            }
        } catch {
            try? handle.close()
            self.handle = nil
        }
    }

    private func consume(_ chunk: Data) {
        remainder.append(chunk)
        var cursor = remainder.startIndex
        while let newline = remainder[cursor...].firstIndex(of: 0x0A) {
            let slice = remainder[cursor..<newline]
            cursor = remainder.index(after: newline)
            guard !slice.isEmpty else { continue }
            var line = String(decoding: slice, as: UTF8.self)
            if line.hasSuffix("\r") { line.removeLast() }
            if !line.isEmpty { onLine(line) }
        }
        if cursor > remainder.startIndex {
            remainder = Data(remainder[cursor...])
        }
        if remainder.count > Self.maxRemainderBytes {
            remainder.removeAll(keepingCapacity: false)
        }
    }
}

// One-shot review turns (TextGeneration.review) still use headless stream-json.
extension AntigravitySession {
    /// The reply of one headless stream-json turn (`agy -p --output-format stream-json`),
    /// judged by stream recovery rules: agy retries a failed model call inside the turn and may
    /// still report the earlier `ERROR`, so a completed agent_response after the last error
    /// step recovers the turn. Nil reply when the turn failed; `result` is the first result
    /// event (a later one is agy's shutdown echo).
    nonisolated static func oneShotReply(streamJSON output: String) -> (reply: String?, result: JSONValue?) {
        var reply = ""
        var replyIndex: Int?
        var replyAfterError = false
        var completedIndex: Int?
        var latestError: (index: Int, message: String)?
        var errorMessages: Set<String> = []
        var completedToolWork = false
        var result: JSONValue?
        for line in output.split(whereSeparator: \.isNewline) {
            guard let message = JSONValue.parse(String(line)) else { continue }
            if message["event"]?.string == "result" {
                result = message["result"]
                break
            }
            guard message["event"]?.string == "step_update", let step = message["step_update"] else { continue }
            let index = step["step_index"]?.int ?? 0
            let stepType = step["step_type"]?.string
            if stepType == "agent_response" {
                if step["state"]?.string == "ERROR", let error = errorMessage(in: step) {
                    latestError = (index, error)
                    errorMessages.insert(error)
                    completedIndex = nil
                    replyAfterError = false
                    reply = ""
                    continue
                }
                if step["state"]?.string == "DONE" { completedIndex = index }
                guard let text = step["text_delta"]?.string, !text.isEmpty else { continue }
                // Deltas of one reply step append; a later reply step replaces an interim one.
                if replyIndex == index { reply += text } else { reply = text; replyIndex = index }
                if !text.trimmed.isEmpty { replyAfterError = true }
            } else if stepType == "tool" {
                completedIndex = nil
                if step["state"]?.string == "DONE", step["error"] == nil { completedToolWork = true }
            } else {
                if let error = errorMessage(in: step) {
                    latestError = (index, error)
                    errorMessages.insert(error)
                    completedIndex = nil
                    replyAfterError = false
                    reply = ""
                }
            }
        }
        guard let result else { return (nil, nil) }
        let response = result["response"]?.string?.trimmed.nilIfEmpty
        let streamed = reply.trimmed.nilIfEmpty
        let denied = !(result["denied_actions"]?.array ?? []).isEmpty
        let outcome = turnOutcome(
            interruptRequested: false,
            status: result["status"]?.string,
            finishedReason: result["finished_reason"]?.string,
            hasDeniedActions: denied,
            hasReply: latestError == nil ? (streamed != nil || response != nil) : replyAfterError,
            completedResponseIndex: completedIndex,
            latestCascadeErrorIndex: latestError?.index,
            cascadeErrorMessages: errorMessages,
            knownConversationErrors: [],
            hasCompletedToolWork: completedToolWork,
            replyOnlyInResult: streamed == nil && response != nil,
            resultError: result["error"]?.string
        )
        guard outcome.status == .completed else { return (nil, result) }
        let text = result["status"]?.string == "SUCCESS" ? (response ?? streamed) : (streamed ?? response)
        return (text, result)
    }
}
