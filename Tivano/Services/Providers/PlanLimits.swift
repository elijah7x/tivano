import Foundation

/// A provider's subscription limits: each rolling window, how much of it is used and when it resets.
struct PlanLimits: Sendable, Equatable {
    struct Window: Sendable, Equatable, Identifiable {
        var id: String
        var title: String
        var percent: Double
        var resetsAt: Date?
        var detail: String? = nil
    }

    var planName: String?
    var windows: [Window]
    var resetCredits: ResetCredits? = nil
    /// Why the read filled no windows, in the provider's own words; shown in place of the bars so an expired login never reads as an unchanged number.
    var problem: String? = nil
    enum ProblemKind: Sendable, Equatable { case authentication, unavailable, noWindows }
    var problemKind: ProblemKind? = nil

    /// One reset Codex has banked for the account. `title` and `detail` are the app-server's own words when it gives any.
    struct ResetCredit: Sendable, Equatable, Identifiable {
        var id: String
        var title: String?
        var detail: String?
        var expiresAt: Date?
    }

    /// Codex only: resets the account has banked, each spendable to clear the active windows. `credits` can be shorter than `availableCount` when the app-server reported only a total.
    struct ResetCredits: Sendable, Equatable {
        var availableCount: Int
        var credits: [ResetCredit]
    }

    /// What the app-server answered when a reset was spent.
    enum ResetOutcome: String, Sendable, Equatable {
        case reset, nothingToReset, noCredit, alreadyRedeemed

        var message: String {
            switch self {
            case .reset: "Usage was reset."
            case .nothingToReset: "There was no active usage to reset."
            case .noCredit: "No banked resets are left."
            case .alreadyRedeemed: "That reset was already used."
            }
        }
    }
}

/// Why a banked reset could not be spent.
enum ResetCreditError: LocalizedError {
    case codexUnavailable
    case unknownOutcome
    case rejected(String)

    var errorDescription: String? {
        switch self {
        case .codexUnavailable: AppText.localized("Codex CLI not found.")
        case .unknownOutcome: AppText.localized("Codex returned an unknown reset result.")
        case .rejected(let message): message
        }
    }
}

@MainActor
enum PlanLimitsReader {
    /// Codex, Claude, Antigravity, Copilot, Command Code and Z.ai report plan limits.
    /// Pi, omp, Cursor, OpenCode, Grok, DeepSeek, Meta, Devin and Kimi expose none.
    static func exposesLimits(_ provider: ProviderKind) -> Bool {
        provider == .codex || provider == .claude || provider == .antigravity || provider == .copilot || provider == .commandcode || provider == .zai
    }

    static func read(_ provider: ProviderKind, executable: URL, environment: [String: String]) async -> PlanLimits? {
        do {
            let limits: PlanLimits? = switch provider {
            case .codex: try await CodexSession.readPlanLimits(executable: executable, environment: environment)
            case .claude: await readClaude(environment: environment)
            case .antigravity: try await AntigravitySession.readPlanLimits(executable: executable, environment: environment)
            case .copilot: try await CopilotSession.readPlanLimits(executable: executable, environment: environment)
            case .commandcode: await CommandCodeAPI.planLimits(environment: environment)
            case .pi, .omp, .cursor, .opencode, .grok, .deepseek, .meta, .zai, .devin, .kimi, .dsh, .minimaxCode, .zcode: nil
            }
            return classified(limits)
        } catch {
            return failure(error.localizedDescription)
        }
    }

    /// API-key subscriptions read their windows from the API instead of a CLI.
    static func read(_ provider: ProviderKind, apiKey: String) async -> PlanLimits? {
        switch provider {
        case .zai: classified(await ZaiAPI.planLimits(apiKey: apiKey))
        default: nil
        }
    }

    static func failure(_ message: String, kind: PlanLimits.ProblemKind? = nil) -> PlanLimits {
        let text = message.lowercased()
        // Legacy readers return prose, not a typed error. Only explicit authentication
        // failures warrant login; forbidden, unavailable and empty results do not.
        let authentication = ["not logged in", "not signed in", "authentication required", "unauthorized", "token expired", "token has expired", "login has expired", "token_expired", "invalid access token"].contains { text.contains($0) }
        return PlanLimits(planName: nil, windows: [], problem: message,
                          problemKind: kind ?? (authentication ? .authentication : .unavailable))
    }

    private static func classified(_ limits: PlanLimits?) -> PlanLimits {
        guard var limits else {
            return failure("The provider did not return usage data. The usage request may have failed or may be unsupported.")
        }
        if let problem = limits.problem, limits.problemKind == nil {
            limits.problemKind = problem == "Codex reported no usage windows for this account." ? .noWindows : failure(problem).problemKind
        } else if limits.problem == nil, limits.windows.isEmpty {
            limits.problem = "The provider reported no usage windows for this account."
            limits.problemKind = .noWindows
        }
        return limits
    }

    nonisolated static func windowTitle(minutes: Int?) -> String {
        guard let minutes, minutes > 0 else { return "Usage limit" }
        switch minutes {
        case 300: return "5-hour limit"
        case 1_440: return "Daily"
        case 10_080: return "Weekly"
        case 40_320...44_640: return "Monthly"
        default:
            return minutes % 1_440 == 0
                ? String(format: AppText.localized("%lld-day limit"), minutes / 1_440)
                : String(format: AppText.localized("%lld-hour limit"), max(1, minutes / 60))
        }
    }

    nonisolated static func planName(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        return raw.prefix(1).uppercased() + raw.dropFirst()
    }

    /// Codex's plan names the way OpenAI sells them. The `pro` account type is the $200 Pro
    /// tier, whose limits are 20x Plus's, and `prolite` is its $100 sibling at 5x (the ChatGPT
    /// help article names them "Pro $200 (Pro 20x)" and "Pro $100"); plan types only Codex
    /// spells get the wording its own CLI uses. Anything else falls back to `planName(_:)`.
    nonisolated static func codexPlanName(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        switch raw.trimmed.lowercased() {
        case "pro": return "Pro 20x"
        case "prolite", "pro lite": return "Pro 5x"
        case "ent26", "hc": return "Enterprise"
        case "self_serve_business_prolite": return "Business Premium"
        case "self_serve_business_usage_based": return "Business"
        case "enterprise_cbp_automation": return "Enterprise (Automation)"
        case "enterprise_cbp_usage_based": return "Enterprise"
        case "education": return "Edu"
        case "edu_plus": return "Edu Plus"
        case "edu_pro": return "Edu Pro"
        default: return planName(raw)
        }
    }

    // MARK: - Claude

    /// Reads existing credentials and usage only. Normal Claude sessions own token refresh.
    static func readClaude(environment: [String: String]) async -> PlanLimits? {
        guard !CaptureRun.isEnabled else { return nil }
        let managed = environment["CLAUDE_CODE_PROVIDER_MANAGED_BY_HOST"] == "1"
        let account = ProviderAccountStore.load().accounts.first {
            $0.provider == .claude && (managed ? $0.home == environment["CLAUDE_CONFIG_DIR"] : $0.isDefault)
        }
        guard !managed || account != nil,
              account?.requiresClaudeActivation != true,
              account?.requiresClaudeCleanup != true else { return nil }
        let accountID: UUID?
        do { accountID = try ProviderAccounts.beginClaudeCredentialRead(environment: environment) }
        catch { return failure(ProviderAccounts.safeClaudeError(error), kind: .unavailable) }
        defer { if let accountID { ProviderAccounts.endRead(accountID) } }
        return await readClaudeUsageEndpoint(environment: environment)
    }

    private struct ClaudeLogin {
        let accessToken: String
        let expiresAt: Date?
        let subscriptionType: String?
        let rateLimitTier: String?

        /// "Max (20x)" from `max` and `default_claude_max_20x`.
        var planName: String? {
            guard var name = PlanLimitsReader.planName(subscriptionType) else { return nil }
            if let tier = rateLimitTier?.range(of: #"\d+x"#, options: .regularExpression) {
                name += " (\(rateLimitTier![tier]))"
            }
            return name
        }
    }

    private static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private static let claudeUsageUnavailable = "Claude usage is temporarily unavailable. Use Claude normally to let the official CLI refresh its login, then check usage again."

    private static func readClaudeUsageEndpoint(environment: [String: String]) async -> PlanLimits? {
        do {
            guard let login = try await claudeLogin(environment: environment) else {
                return failure("Claude credentials could not be read. Check this account's sign-in and macOS credential access.", kind: .unavailable)
            }
            if let expiresAt = login.expiresAt, expiresAt <= .now {
                return failure(claudeUsageUnavailable, kind: .unavailable)
            }
            let response = try await fetchClaudeUsage(token: login.accessToken)
            if response.status == 401 {
                return failure(claudeUsageUnavailable, kind: .unavailable)
            }
            guard response.status == 200 else {
                let detail = JSONValue.parse(response.data)?["error"]?["message"]?.string
                    ?? HTTPURLResponse.localizedString(forStatusCode: response.status)
                return failure(String(format: AppText.localized("Claude usage request failed (HTTP %lld): %@"), response.status, detail),
                               kind: .unavailable)
            }
            guard let json = JSONValue.parse(response.data), json.object != nil else {
                return failure("Claude returned an invalid usage response.")
            }
            return parseClaudeUsage(json, limits: json["limits"]?.array ?? [], planName: login.planName)
                ?? failure("The provider reported no usage windows for this account.", kind: .noWindows)
        } catch let error as ClaudeCredentialError {
            return failure(ProviderAccounts.safeClaudeError(error), kind: .unavailable)
        } catch {
            return failure(error.localizedDescription, kind: .unavailable)
        }
    }

    /// The stored Claude Code login: `.credentials.json`, or the macOS Keychain item the CLI writes.
    private static func claudeLogin(environment: [String: String]) async throws -> ClaudeLogin? {
        guard let data = try await ProviderAccountStore.claudeCredentials(environment: environment) else { return nil }
        return parseLogin(data)
    }

    private static func parseLogin(_ data: Data) -> ClaudeLogin? {
        guard let oauth = JSONValue.parse(data)?["claudeAiOauth"],
              let token = oauth["accessToken"]?.string, !token.isEmpty else { return nil }
        return ClaudeLogin(
            accessToken: token,
            expiresAt: oauth["expiresAt"]?.double.map { Date(timeIntervalSince1970: $0 / 1_000) },
            subscriptionType: oauth["subscriptionType"]?.string,
            rateLimitTier: oauth["rateLimitTier"]?.string
        )
    }

    private static func fetchClaudeUsage(token: String) async throws -> (status: Int, data: Data) {
        var request = URLRequest(url: usageURL, timeoutInterval: 15)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (http.statusCode, data)
    }

    /// The `limits` rows (session, weekly, weekly per model), falling back to the top-level
    /// `five_hour` and `seven_day` windows, plus extra usage when it is turned on.
    nonisolated static func parseClaudeUsage(_ root: JSONValue, limits: [JSONValue], planName: String?) -> PlanLimits? {
        var windows = limits.enumerated().compactMap { index, limit -> PlanLimits.Window? in
            guard let percent = limit["percent"]?.double else { return nil }
            let kind = limit["kind"]?.string ?? ""
            let group = self.planName(limit["group"]?.string) ?? "Usage"
            let scope = limit["scope"]?["model"]?["display_name"]?.string
            let title = switch kind {
            case "session": "5-hour limit"
            case "weekly_all": "Weekly · all models"
            default: scope.map { "\(group) · \($0)" } ?? group
            }
            return PlanLimits.Window(
                id: "\(kind)-\(index)",
                title: title,
                percent: percent,
                resetsAt: limit["resets_at"]?.string.flatMap(parseDate)
            )
        }
        if windows.isEmpty {
            for (key, title) in [("five_hour", "5-hour limit"), ("seven_day", "Weekly · all models")] {
                guard let window = root[key], let percent = window["utilization"]?.double else { continue }
                windows.append(PlanLimits.Window(id: key, title: title, percent: percent, resetsAt: window["resets_at"]?.string.flatMap(parseDate)))
            }
        }
        if let extra = root["extra_usage"], extra["is_enabled"]?.bool == true, let percent = extra["utilization"]?.double {
            windows.append(PlanLimits.Window(id: "extra-usage", title: "Extra usage", percent: percent, resetsAt: nil))
        }
        guard !windows.isEmpty else { return nil }
        return PlanLimits(planName: planName, windows: windows)
    }

    /// Claude writes microsecond timestamps, which the ISO 8601 parser does not take, so the fraction is dropped.
    nonisolated static func parseDate(_ text: String) -> Date? {
        let trimmed = text.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        return ISO8601.date(from: trimmed)
    }
}
