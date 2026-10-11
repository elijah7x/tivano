import Foundation

struct ProviderStatus: Equatable, Sendable {
    enum Auth: Equatable, Sendable {
        case unknown
        case signedIn(String?)
        case signedOut
    }

    var executable: URL?
    var version: String?
    var auth: Auth = .unknown
    var isChecking = false
    /// Native API providers (DeepSeek, Meta, Z.ai) have no CLI; they are installed once an API key exists.
    var apiKeyConfigured = false

    var isInstalled: Bool { executable != nil || apiKeyConfigured }

    var summary: String {
        guard isInstalled else { return AppText.localized("Not installed") }
        switch auth {
        case .signedIn(let account): return account.map { String(format: AppText.localized("Signed in as %@"), $0) } ?? AppText.localized("Signed in")
        case .signedOut: return AppText.localized("Not signed in")
        case .unknown: return version.map { String(format: AppText.localized("Installed · %@"), $0) } ?? AppText.localized("Installed")
        }
    }
}

/// Finds provider CLIs, checks their sign-in state and caches their model catalogs.
@MainActor
@Observable
final class ProviderRegistry {
    private(set) var statuses: [ProviderKind: ProviderStatus] = [:]
    private(set) var catalogs: [ProviderKind: [ModelOption]] = [:]
    private(set) var commands: [String: [SlashCommand]] = [:]
    private(set) var commandErrors: [String: String] = [:]
    private(set) var recentCommands: [String: [String]] = [:]
    @ObservationIgnored private var commandLoads: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var commandsFetchedAt: [String: Date] = [:]
    /// How long a provider's command list is served without asking again. Listing means
    /// launching the CLI once per (provider, directory), and the list only changes when
    /// the user edits their commands or skills, so a thread switch every minute should
    /// not cost a process launch every minute.
    private static let commandFreshness: TimeInterval = 600
    private(set) var loadingCatalogs: Set<ProviderKind> = []

    @ObservationIgnored private let settings: any ProviderSettings
    @ObservationIgnored private let cacheKey = "providerModelCatalogs"
    // When the provider last delivered a list, persisted under `catalogDatesKey`.
    @ObservationIgnored private let catalogDatesKey = "providerModelCatalogDates"
    @ObservationIgnored private var catalogFetchedAt: [ProviderKind: Date] = [:]

    /// Providers whose CLI is being updated right now (see `updateCLIIfDue`).
    private(set) var updatingCLIs: Set<ProviderKind> = []
    @ObservationIgnored private let cliUpdatesKey = "providerCLIUpdateDates"

    /// A list read within this window is served as it is; an older one, or one cached by an
    /// earlier build that stored no date, is read again on the next ask, so a model the
    /// account gained on a new plan appears without hunting for the Refresh button.
    private static let catalogFreshness: TimeInterval = 6 * 3600
    private(set) var planLimits: [ProviderKind: PlanLimits] = [:]
    private(set) var loadingLimits: Set<ProviderKind> = []
    /// The banked reset being spent right now: its credit id, or "codex" for one the app-server listed only by count.
    private(set) var redeemingReset: String?
    @ObservationIgnored private var limitsFetchedAt: [ProviderKind: Date] = [:]
    // A forced read that arrives while a read is out is remembered, not dropped.
    @ObservationIgnored private var forcedLimitReads: Set<ProviderKind> = []

    /// Pay-as-you-go balances (DeepSeek's credit), shown where subscriptions show their windows.
    private(set) var credits: [ProviderKind: ProviderCredits] = [:]
    private(set) var loadingCredits: Set<ProviderKind> = []
    @ObservationIgnored private var creditsFetchedAt: [ProviderKind: Date] = [:]

    private static let claudeEfforts = ["low", "medium", "high", "xhigh", "max"]
    private static let claudeSeed = [
        ModelOption(id: "default", name: "Default", detail: "Claude Code's recommended model", efforts: claudeEfforts, isDefault: true, fastTier: "fast"),
        ModelOption(id: "opus", name: "Opus", efforts: claudeEfforts, fastTier: "fast"),
        ModelOption(id: "claude-fable-5-1[1m]", name: "Fable", detail: "Fable 5.1 · Most capable for your hardest and longest-running tasks", efforts: claudeEfforts),
        ModelOption(id: "sonnet", name: "Sonnet", efforts: claudeEfforts),
        ModelOption(id: "haiku", name: "Haiku"),
    ]

    /// A cached Claude list made only of the earlier seed's ids is that seed, persisted when another
    /// provider's live catalog arrived, not a list the CLI reported: a live list always names `opus[1m]`
    /// and the Fable row. Re-seeding it gives launches that cached the old seed the Fable row, while a
    /// live list without Fable stays as it is, since that account cannot use it.
    /// The seed with a live Claude list laid over it: a live row for a seed id lends its
    /// effort levels, description and fast tier; a row the seed lacks is appended; no seed
    /// row is ever dropped, since threads keep naming those ids.
    private static func mergedClaudeCatalog(_ live: [ModelOption]) -> [ModelOption] {
        var merged = claudeSeed
        for option in live {
            if let index = merged.firstIndex(where: { $0.id == option.id }) {
                var kept = merged[index]
                // The CLI's own name carries the version ("Opus 5.5"), and recipes pick the
                // newest family member by it: a seed row named just "Opus" lost to the
                // older "Opus 5" row. The Default row keeps its short name.
                if option.id != "default", !option.name.isEmpty, option.name != option.id { kept.name = option.name }
                if !option.efforts.isEmpty { kept.efforts = option.efforts }
                if let detail = option.detail, !detail.isEmpty { kept.detail = detail }
                if option.fastTier != nil { kept.fastTier = option.fastTier }
                if option.defaultEffort != nil { kept.defaultEffort = option.defaultEffort }
                merged[index] = kept
            } else {
                merged.append(option)
            }
        }
        return merged
    }

    /// An ACP session reports the effort scale of the model it runs on, not of every
    /// model it lists (Cursor and OpenCode send the current model's `thought_level`
    /// alone; the catalog probe walked the rest), so a live row without a scale keeps
    /// the scale, default and fast tier the catalog already holds for that id. Rows the
    /// live list dropped go; rows it added come in as they are.
    private static func mergedACPCatalog(_ live: [ModelOption], over cached: [ModelOption]) -> [ModelOption] {
        guard !cached.isEmpty else { return live }
        let known = Dictionary(cached.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return live.map { option in
            guard option.efforts.isEmpty, let kept = known[option.id] else { return option }
            var option = option
            option.efforts = kept.efforts
            if option.defaultEffort == nil { option.defaultEffort = kept.defaultEffort }
            if option.fastTier == nil { option.fastTier = kept.fastTier }
            return option
        }
    }

    private static func isStaleClaudeSeed(_ list: [ModelOption]) -> Bool {
        let earlierSeedIDs: Set<String> = ["default", "opus", "sonnet", "haiku"]
        return list.isEmpty || list.allSatisfy { earlierSeedIDs.contains($0.id) }
    }

    // Seeds come from the same tables the live fetch uses, so the two can never disagree.
    static let deepseekSeed = ["deepseek-v4-pro", "deepseek-flash"].compactMap(DeepSeekAPI.option(for:))
    static let metaSeed = ["muse-spark-1.3", "muse-spark-1.3-contributor", "muse-spark-1.2", "muse-spark-1.2-contributor", "muse-spark-1.1"]
        .compactMap(MetaAPI.option(for:))
    static let zaiSeed = ["glm-5.3", "glm-5.3-flash"].compactMap(ZaiAPI.option(for:))

    /// From `agy models`: base models with their supported effort levels.
    /// Effort is adjusted via the effort slider, not separate duplicate rows.
    static let antigravitySeed: [ModelOption] = [
        ModelOption(id: "gemini-3.8-flash", name: "Gemini 3.8 Flash", efforts: ["low", "medium", "high"], defaultEffort: "high", isDefault: true),
        ModelOption(id: "gemini-3.7-flash", name: "Gemini 3.7 Flash", efforts: ["low", "medium", "high"], defaultEffort: "high"),
        ModelOption(id: "gemini-3.6-flash", name: "Gemini 3.6 Flash", efforts: ["low", "medium", "high"], defaultEffort: "high"),
        ModelOption(id: "gemini-3.1-pro", name: "Gemini 3.1 Pro", efforts: ["low", "high"], defaultEffort: "high"),
        ModelOption(id: "claude-sonnet-4-6", name: "Claude Sonnet 4.6 (Thinking)", efforts: []),
        ModelOption(id: "claude-opus-4-6-thinking", name: "Claude Opus 4.6 (Thinking)", efforts: []),
        ModelOption(id: "gpt-oss-120b", name: "GPT-OSS 120B", efforts: ["medium"], defaultEffort: "medium"),
    ]

    /// Copilot's own choice of model, which the CLI accepts as `auto`. The live catalog lists
    /// the account's models behind it; a fresh install starts with just this row.
    static let copilotAuto = ModelOption(id: "auto", name: "Auto", detail: "Copilot picks the model for each request", isDefault: true)

    /// Command Code's starting catalog; `cmd --list-models` replaces it with the account's
    /// seventy-odd models, led by the one the CLI itself is set to.
    static let commandcodeSeed = CommandCodeAPI.seed

    /// Pi's starting catalog; the live catalog from pi's RPC `get_available_models` replaces it.
    static let piSeed = [ModelOption(id: "default", name: "Default", detail: "The model pi itself is set to", efforts: ["off", "minimal", "low", "medium", "high", "xhigh", "max"], defaultEffort: "medium", isDefault: true)]

    /// Every provider tries its live catalog at most once per launch unless forced, success or not,
    /// so views that ask on appear never re-spawn a CLI or re-hit an API while scrolling.
    @ObservationIgnored private var attemptedCatalogs: Set<ProviderKind> = []

    /// The opencode ACP catalogue, probed once per launch and shared by Zen and Go.
    @ObservationIgnored private var openCodeCatalogTask: Task<[ModelOption]?, Never>?

    init(settings: any ProviderSettings) {
        self.settings = settings
        recentCommands = (CaptureRun.defaults ?? .standard).dictionary(forKey: "recentSlashCommands") as? [String: [String]] ?? [:]
        if !CaptureRun.isEnabled,
           let data = UserDefaults.standard.data(forKey: cacheKey),
           let cached = try? JSONDecoder().decode([String: [ModelOption]].self, from: data) {
            for (key, list) in cached {
                guard let provider = ProviderKind(rawValue: key) else { continue }
                // A list cached before the scales were ordered may still run high to low
                // (Grok's did); the slider reads them low to high, so they are put right here.
                let ordered = Self.openCodeModels(list, for: provider).map { option in
                    var option = option
                    option.efforts = ModelOption.orderedEfforts(option.efforts)
                    return option
                }
                // A list cached before variants were merged is merged on the way in.
                catalogs[provider] = provider.namesModelVariants ? ModelFamilies.collapsed(ordered) : ordered
            }
        }
        if !CaptureRun.isEnabled,
           let data = UserDefaults.standard.data(forKey: catalogDatesKey),
           let raw = try? JSONDecoder().decode([String: Double].self, from: data) {
            for (key, seconds) in raw {
                if let provider = ProviderKind(rawValue: key) { catalogFetchedAt[provider] = Date(timeIntervalSince1970: seconds) }
            }
        }
        if Self.isStaleClaudeSeed(catalogs[.claude] ?? []) { catalogs[.claude] = Self.claudeSeed }
        if catalogs[.deepseek]?.isEmpty ?? true { catalogs[.deepseek] = Self.deepseekSeed }
        if catalogs[.meta]?.isEmpty ?? true { catalogs[.meta] = Self.metaSeed }
        if catalogs[.zai]?.isEmpty ?? true { catalogs[.zai] = Self.zaiSeed }
        if catalogs[.antigravity]?.isEmpty ?? true || catalogs[.antigravity]?.contains(where: { $0.id.hasSuffix("-high") || $0.id.hasSuffix("-medium") || $0.id.hasSuffix("-low") }) == true {
            catalogs[.antigravity] = Self.antigravitySeed
        }
        if catalogs[.copilot]?.isEmpty ?? true { catalogs[.copilot] = [Self.copilotAuto] }
        if catalogs[.commandcode]?.isEmpty ?? true { catalogs[.commandcode] = Self.commandcodeSeed }
        if catalogs[.pi]?.isEmpty ?? true { catalogs[.pi] = Self.piSeed }
        for provider in ProviderKind.allCases where provider.namesModelVariants {
            if let list = catalogs[provider] { settings.adoptModelFamilies(list, for: provider) }
        }
    }

    var availableProviders: [ProviderKind] {
        ProviderKind.allCases.filter { settings.isEnabled($0) && countsAsInstalled($0) }
    }

    /// Whether a provider counts as installed with its first check still out: a check that
    /// has not happened yet is not a "no". The launch screen builds its first chat before
    /// `bootstrap()` probes the providers (see `AppDelegate`), so a strict read there found
    /// no pair and no provider: every one of them read as missing.
    func countsAsInstalled(_ provider: ProviderKind) -> Bool {
        statuses[provider]?.isInstalled ?? true
    }

    func status(_ provider: ProviderKind) -> ProviderStatus {
        // A capture run never probes the CLIs (see `refresh`), and reads as a Mac with every
        // provider installed and signed in, so the pairs and pickers show what they offer.
        if CaptureRun.isEnabled {
            return ProviderStatus(executable: URL(fileURLWithPath: "/usr/bin/true"), auth: .signedIn(nil), apiKeyConfigured: true)
        }
        return statuses[provider] ?? ProviderStatus()
    }

    func executable(for provider: ProviderKind) -> URL? {
        guard !provider.isAPIKeyBased else { return nil }
        let custom = settings.binaryPath(for: provider)
        guard !custom.isEmpty || !provider.executableName.isEmpty else { return nil }
        if let found = LoginEnvironment.which(custom.isEmpty ? provider.executableName : custom) { return found }
        guard custom.isEmpty else { return nil }
        return Self.fallbackExecutables(for: provider).first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// Where a provider lands when its installer keeps it off the PATH: `gh copilot`
    /// downloads the Copilot CLI into gh's data directory.
    private static func fallbackExecutables(for provider: ProviderKind) -> [URL] {
        switch provider {
        case .copilot:
            let environment = LoginEnvironment.current
            let dataDirectory = environment["GH_DATA_DIR"].flatMap { $0.isEmpty ? nil : $0 }
                ?? environment["XDG_DATA_HOME"].flatMap { $0.isEmpty ? nil : ($0 as NSString).appendingPathComponent("gh") }
                ?? (LoginEnvironment.homeDirectory as NSString).appendingPathComponent(".local/share/gh")
            return [URL(fileURLWithPath: dataDirectory).appendingPathComponent("copilot/copilot")]
        case .commandcode:
            // npm's global bin under a user prefix, plus the CLI's other names: `cmd` is
            // the documented alias, `command-code` and `commandcode` the package's own.
            let home = LoginEnvironment.homeDirectory
            var candidates: [URL] = []
            for name in ["command-code", "commandcode", "cmd"] {
                if let found = LoginEnvironment.which(name) { candidates.append(found) }
            }
            for directory in ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.npm-global/bin", "\(home)/.volta/bin"] {
                for name in ["command-code", "cmd"] {
                    candidates.append(URL(fileURLWithPath: directory).appendingPathComponent(name))
                }
            }
            return candidates
        case .pi, .kimi:
            let home = LoginEnvironment.homeDirectory
            let name = provider.executableName
            return ["\(home)/.npm-global/bin/\(name)", "/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)", "\(home)/.local/bin/\(name)", "\(home)/.volta/bin/\(name)", "\(home)/.bun/bin/\(name)"].map { URL(fileURLWithPath: $0) }
        default:
            return []
        }
    }

    func environment(for provider: ProviderKind) -> [String: String] {
        var environment = LoginEnvironment.current
        if let directory = executable(for: provider)?.deletingLastPathComponent().path,
           let path = environment["PATH"],
           !path.split(separator: ":").contains(Substring(directory)) {
            environment["PATH"] = directory + ":" + path
        }
        // A Studio key pasted into Settings reaches the CLI the way its docs say, and takes
        // precedence over the `cmd login` in `~/.commandcode/auth.json`.
        if provider == .commandcode {
            let key = settings.apiKey(for: .commandcode)
            if !key.isEmpty { environment["COMMAND_CODE_API_KEY"] = key }
        }
        // OpenCode takes its MCP servers as config content in the environment,
        // so the connected servers reach it without a line written into its config files.
        if provider == .opencode || provider == .opencodeGo { environment.merge(MCPSessionOverrides.opencodeEnvironment()) { _, new in new } }
        // The CLI reads system settings from that path, so the connected servers reach it without a line in `~/.gemini/settings.json`.
        if provider == .antigravity, let path = MCPProviderConfig.geminiSettingsPath() { environment["GEMINI_CLI_SYSTEM_SETTINGS_PATH"] = path }
        return environment
    }

    private(set) var isRefreshing = false

    /// The provider currently being signed in from the Providers page, if any.
    private(set) var signingIn: ProviderKind?

    /// Signs a CLI provider in from the app: the provider's own login command, which opens the
    /// browser, then a fresh status check and usage read, so the numbers follow the new login
    /// without a trip to Terminal. Returns the CLI's message when it failed, nil on success.
    func signIn(_ provider: ProviderKind) async -> String? {
        guard signingIn == nil else { return nil }
        guard !provider.isAPIKeyBased else { return nil }
        signingIn = provider
        defer { signingIn = nil }
        await LoginEnvironment.load()
        guard let executable = executable(for: provider) else {
            let missing = "\(provider.displayName) was not found."
            return LoginEnvironment.diagnostic.map { missing + " " + $0 } ?? missing
        }
        // The login command starts with the executable's own name; the rest are its arguments.
        let arguments = provider.loginCommand.split(whereSeparator: \.isWhitespace).dropFirst().map(String.init)
        let result = try? await Shell.run(executable, arguments, environment: environment(for: provider), timeout: 300)
        if let result, result.succeeded {
            await refresh(provider)
            refreshPlanLimits(provider, force: true)
            await loadCatalog(provider, force: true)
            return nil
        }
        let output = result.map { TextCleanup.stripANSI($0.output + $0.errorOutput) } ?? ""
        guard let lastLine = output.split(separator: "\n", omittingEmptySubsequences: true).last, !lastLine.isEmpty else {
            return "\(provider.displayName) did not finish signing in."
        }
        return String(lastLine)
    }

    /// The Providers page's refresh button: checks every provider again, re-reads the usage limits
    /// the page shows for each signed-in account and reloads the live catalogs. Beyond the limits,
    /// nothing on that page checks on its own, so this is the only way it hits the CLIs and APIs.
    func refreshEverything() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        await LoginEnvironment.load(force: true)
        await refreshAll()
        // Credits were already re-read when the key proved itself in `refreshAPIProvider`.
        for provider in ProviderKind.allCases where status(provider).auth != .signedOut {
            refreshPlanLimits(provider, force: true)
        }
        // Every installed provider, the ACP ones included: OpenCode, Cursor, Grok and Devin
        // report their models from a session of their own, and a list of the others left
        // them out, so a model OpenCode gained after launch (its catalog follows models.dev)
        // could not be found in Settings until the app was relaunched.
        await withTaskGroup(of: Void.self) { group in
            for provider in ProviderKind.allCases where status(provider).isInstalled {
                group.addTask { await self.loadCatalog(provider, force: true) }
            }
        }
    }

    /// How many providers are checked at the same time. Every check spawns the provider's
    /// CLI, and launch checks them all: starting a dozen node processes at once is a
    /// visible stall in everything else the app is doing just then.
    private static let probeWidth = 4

    func refreshAll() async {
        let providers = ProviderKind.allCases
        var next = 0
        await withTaskGroup(of: Void.self) { group in
            while next < providers.count, next < Self.probeWidth {
                let provider = providers[next]
                group.addTask { await self.refresh(provider) }
                next += 1
            }
            for await _ in group {
                guard next < providers.count else { continue }
                let provider = providers[next]
                next += 1
                group.addTask { await self.refresh(provider) }
            }
        }
    }

    func refresh(_ provider: ProviderKind) async {
        guard !CaptureRun.isEnabled else { return }
        var status = statuses[provider] ?? ProviderStatus()
        status.isChecking = true
        statuses[provider] = status
        if provider.isAPIKeyBased {
            await refreshAPIProvider(provider)
            return
        }
        await LoginEnvironment.load()
        guard let executable = executable(for: provider) else {
            statuses[provider] = ProviderStatus()
            return
        }
        let environment = environment(for: provider)
        // Both probes spawn the CLI. One after the other rather than together: the pair
        // was two processes per provider at the same moment, on top of every other
        // provider being checked alongside.
        let version = await Self.version(executable, environment)
        let auth = await Self.auth(provider, executable, environment)
        statuses[provider] = ProviderStatus(executable: executable, version: version, auth: auth)
    }

    /// API-key providers have no binary: presence (and validity) of the key is the install state.
    private func refreshAPIProvider(_ provider: ProviderKind) async {
        let apiKey = settings.apiKey(for: provider)
        guard !apiKey.isEmpty else {
            statuses[provider] = ProviderStatus(auth: .signedOut)
            return
        }
        if provider == .deepseek {
            let valid = await DeepSeekAPI.validate(apiKey: apiKey)
            statuses[provider] = ProviderStatus(
                version: "API",
                auth: valid ? .signedIn(nil) : .signedOut,
                apiKeyConfigured: true
            )
            // The key just proved itself, so read the balance behind it right away: the
            // usage panel has it from launch, and a rejected key must not leave a stale one.
            if valid {
                refreshCredits(.deepseek, force: true)
            } else {
                credits[.deepseek] = nil
                creditsFetchedAt[.deepseek] = nil
            }
        } else if provider == .meta {
            let valid = await MetaAPI.validate(apiKey: apiKey)
            statuses[provider] = ProviderStatus(
                version: "API",
                auth: valid ? .signedIn(nil) : .signedOut,
                apiKeyConfigured: true
            )
        } else if provider == .zai {
            let valid = await ZaiAPI.validate(apiKey: apiKey)
            statuses[provider] = ProviderStatus(
                version: "API",
                auth: valid ? .signedIn(nil) : .signedOut,
                apiKeyConfigured: true
            )
            if valid {
                refreshPlanLimits(.zai, force: true)
            } else {
                planLimits[.zai] = nil
                limitsFetchedAt[.zai] = nil
            }
        } else {
            statuses[provider] = ProviderStatus(auth: .signedIn(nil), apiKeyConfigured: true)
        }
    }

    // MARK: - Models

    func models(for provider: ProviderKind) -> [ModelOption] {
        catalogs[provider] ?? []
    }

    func model(_ id: String?, for provider: ProviderKind) -> ModelOption? {
        guard let id else { return nil }
        if let match = Self.match(id, in: models(for: provider)) { return match }
        // A thread or pin made before Zen and Go split kept `.opencode` for a Go model;
        // the CLI is one and the same, so the Go catalogue answers.
        guard provider == .opencode, id.hasPrefix("opencode-go/") else { return nil }
        return Self.match(id, in: models(for: .opencodeGo))
    }

    private static func match(_ id: String, in list: [ModelOption]) -> ModelOption? {
        if let exact = list.first(where: { $0.id == id }) { return exact }
        // A pin or thread from before a provider's variants were merged names one of
        // them; the row they were merged into answers for it.
        if let family = list.first(where: { $0.variant(id) != nil }) { return family }
        // Cursor used to advertise parameterized ids (`model[effort=…]`); the catalog now
        // stores the base name once the parameterized picker is declared.
        guard id.contains("["), let bracket = id.firstIndex(of: "[") else { return nil }
        let base = String(id[..<bracket])
        return list.first { $0.id == base }
    }

    func defaultModel(for provider: ProviderKind) -> ModelOption? {
        let list = models(for: provider)
        if let last = settings.lastModel(for: provider), let match = model(last, for: provider) {
            return match
        }
        return list.first(where: \.isDefault) ?? list.first
    }

    // MARK: - Keeping the CLIs current

    /// Claude Code and Codex update themselves only inside their own interactive
    /// sessions. Tivano runs both headless, so a Mac that uses them only through the
    /// app stays on the version it was installed with, and a new model then fails
    /// outright: Opus 5.5 answers Claude Code 2.1.270 with "does not support this model;
    /// version 2.1.280 or newer is required". The app runs each CLI's own updater instead.
    private static let cliUpdateInterval: TimeInterval = 12 * 3600

    /// The providers whose CLI carries its own updater (`claude update`, `codex update`).
    static func updatesOwnCLI(_ provider: ProviderKind) -> Bool {
        provider == .claude || provider == .codex
    }

    /// Whether a provider's error says its CLI is too old for what was asked of it.
    nonisolated static func needsNewerCLI(_ message: String) -> Bool {
        let text = message.lowercased()
        return text.contains("or newer is required")
            || text.contains("requires a newer version")
            || text.contains("claude update")
            || text.contains("codex update")
            || text.contains("upgrade codex")
            || text.contains("update codex")
    }

    /// Runs the CLI's own updater when one is due (every 12 hours) or `force`d, and when
    /// a newer version went in, reads the provider and its catalog again so the models
    /// that version brings show at once. Returns whether a newer version was installed.
    /// A binary path the user set by hand is their own build, and is left alone.
    @discardableResult
    func updateCLIIfDue(_ provider: ProviderKind, force: Bool = false) async -> Bool {
        guard Self.updatesOwnCLI(provider), !CaptureRun.isEnabled, settings.binaryPath(for: provider).isEmpty else { return false }
        // An update already under way is not run twice; a forced one waits for it and
        // then runs, which is quick when that one already brought the newest version.
        if updatingCLIs.contains(provider) {
            guard force else { return false }
            while updatingCLIs.contains(provider) { try? await Task.sleep(for: .milliseconds(500)) }
        }
        var dates = (UserDefaults.standard.dictionary(forKey: cliUpdatesKey) as? [String: Double]) ?? [:]
        if !force, let last = dates[provider.rawValue],
           Date.now.timeIntervalSince1970 - last < Self.cliUpdateInterval { return false }
        await LoginEnvironment.load()
        guard let executable = executable(for: provider) else { return false }
        updatingCLIs.insert(provider)
        defer { updatingCLIs.remove(provider) }
        let environment = environment(for: provider)
        let before = await Self.cliVersion(executable, environment: environment)
        _ = try? await Shell.run(executable, ["update"], in: FileManager.default.temporaryDirectory, environment: environment, timeout: 300)
        dates[provider.rawValue] = Date.now.timeIntervalSince1970
        UserDefaults.standard.set(dates, forKey: cliUpdatesKey)
        let after = await Self.cliVersion(executable, environment: environment)
        guard let after, after != before else { return false }
        await refresh(provider)
        await loadCatalog(provider, force: true)
        return true
    }

    /// The version the installed CLI reports, or nil when it cannot be run.
    func installedCLIVersion(_ provider: ProviderKind) async -> String? {
        await LoginEnvironment.load()
        guard let executable = executable(for: provider) else { return nil }
        return await Self.cliVersion(executable, environment: environment(for: provider))
    }

    private nonisolated static func cliVersion(_ executable: URL, environment: [String: String]) async -> String? {
        guard let result = try? await Shell.run(executable, ["--version"], environment: environment, timeout: 30),
              result.succeeded else { return nil }
        let version = result.trimmedOutput
        return version.isEmpty ? nil : version
    }

    func loadCatalog(_ provider: ProviderKind, force: Bool = false) async {
        guard !CaptureRun.isEnabled else { return }
        guard !loadingCatalogs.contains(provider) else { return }
        guard force || !attemptedCatalogs.contains(provider) else { return }
        if provider.isAPIKeyBased {
            await loadAPICatalog(provider, force: force)
            return
        }
        // Copilot's seed is only its Auto row, and Command Code's a handful of its seventy
        // models, so the account's list is fetched on first use. Claude's seed is the four
        // names its CLI has always taken, so its handshake runs every launch: the CLI's own
        // list follows its version. An OpenCode list cached before the probe walked the
        // models for their reasoning levels holds a scale for one model at most, so it is
        // probed again.
        let seeded = provider == .claude || provider == .codex
            || (provider == .copilot && models(for: provider) == [Self.copilotAuto])
            || (provider == .commandcode && models(for: provider) == Self.commandcodeSeed)
            || (provider == .pi && models(for: provider) == Self.piSeed)
            || ((provider == .opencode || provider == .opencodeGo) && Self.lacksEffortWalk(models(for: provider)))
        let stale = catalogFetchedAt[provider].map { Date.now.timeIntervalSince($0) > Self.catalogFreshness } ?? !(models(for: provider).isEmpty)
        guard force || seeded || stale || models(for: provider).isEmpty else { return }
        loadingCatalogs.insert(provider)
        defer { loadingCatalogs.remove(provider) }
        await LoginEnvironment.load()
        guard let executable = executable(for: provider) else { return }
        let environment = environment(for: provider)
        let raw: [ModelOption]? = switch provider {
        case .claude: await loadClaudeCatalog(executable: executable, environment: environment)
        case .codex: try? await CodexSession.listModels(executable: executable, environment: environment)
        case .antigravity: try? await AntigravitySession.listModels(executable: executable, environment: environment)
        case .copilot: try? await CopilotSession.listModels(executable: executable, environment: environment)
        case .commandcode: try? await CommandCodeAPI.listModels(executable: executable, environment: environment)
        case .pi: try? await PiCLI.listModels(executable: executable, environment: environment)
        case .cursor, .grok, .devin, .kimi: try? await ACPSession.probeModels(provider: provider, executable: executable, environment: environment)
        case .opencode, .opencodeGo: await openCodeCatalog(force: force, executable: executable, environment: environment)
        case .deepseek, .meta, .zai: nil
        }
        let list = raw.map { Self.openCodeModels($0, for: provider) }
        if let list, !list.isEmpty {
            updateCatalog(list, for: provider)
            catalogFetchedAt[provider] = .now
            storeCatalogDates()
            // Only a delivered catalog closes the attempt: a probe that came back with
            // nothing (a cold CLI losing to its handshake timeout, say) is tried again
            // on the next ask rather than leaving the provider empty for the whole run.
            attemptedCatalogs.insert(provider)
            // One session answers both halves: Zen and Go come from the same probe, so a
            // load of either leaves the other's catalogue ready for the picker.
            if let raw, provider == .opencode || provider == .opencodeGo {
                for kind in [ProviderKind.opencode, .opencodeGo] where kind != provider {
                    let sibling = Self.openCodeModels(raw, for: kind)
                    guard !sibling.isEmpty else { continue }
                    updateCatalog(sibling, for: kind)
                    catalogFetchedAt[kind] = .now
                    attemptedCatalogs.insert(kind)
                }
                storeCatalogDates()
            }
        }
    }

    /// An OpenCode list cached before the catalog probe walked the models for their
    /// reasoning levels holds a scale for the model the probe's session started on alone.
    private static func lacksEffortWalk(_ list: [ModelOption]) -> Bool {
        list.count(where: { !$0.efforts.isEmpty }) <= 1
    }

    /// The opencode ACP catalogue once per launch, shared by Zen and Go: the probe spawns
    /// the CLI and walks every model, so it runs once and each provider keeps its half.
    private func openCodeCatalog(force: Bool, executable: URL, environment: [String: String]) async -> [ModelOption]? {
        if force { openCodeCatalogTask = nil }
        let task: Task<[ModelOption]?, Never>
        if let openCodeCatalogTask {
            task = openCodeCatalogTask
        } else {
            task = Task { try? await ACPSession.probeModels(provider: .opencode, executable: executable, environment: environment) }
            openCodeCatalogTask = task
        }
        let list = await task.value
        if list == nil { openCodeCatalogTask = nil }
        return list
    }

    /// OpenCode serves two catalogues through one CLI and marks them in the model id:
    /// `opencode/…` is Zen, `opencode-go/…` is Go. Each provider keeps its own half.
    private static func openCodeModels(_ list: [ModelOption], for provider: ProviderKind) -> [ModelOption] {
        let goPrefix = "opencode-go/"
        let half: [ModelOption] = switch provider {
        case .opencode: list.filter { !$0.id.hasPrefix(goPrefix) }
        case .opencodeGo: list.filter { $0.id.hasPrefix(goPrefix) }
        default: list
        }
        // The CLI names a row "OpenCode Go/DeepSeek V4 Flash"; the provider already says
        // which of the two it is, so the redundant half of the name goes.
        let namePrefix = provider.displayName + "/"
        return half.map { option in
            guard option.name.hasPrefix(namePrefix) else { return option }
            var option = option
            option.name = String(option.name.dropFirst(namePrefix.count))
            return option
        }
    }

    private func loadClaudeCatalog(executable: URL, environment: [String: String]) async -> [ModelOption]? {
        // The handshake runs somewhere: the models are the same from any folder.
        let directory = FileManager.default.temporaryDirectory
        return try? await ClaudeSession.handshake(executable: executable, directory: directory, environment: environment).models
    }

    private func loadAPICatalog(_ provider: ProviderKind, force: Bool) async {
        // The seed keeps API providers usable offline; a live fetch only refines it.
        let seed: [ModelOption]? = switch provider {
        case .deepseek: Self.deepseekSeed
        case .meta: Self.metaSeed
        case .zai: Self.zaiSeed
        default: nil
        }
        guard let seed else { return }
        if models(for: provider).isEmpty { updateCatalog(seed, for: provider) }
        loadingCatalogs.insert(provider)
        defer { loadingCatalogs.remove(provider) }
        let apiKey = settings.apiKey(for: provider)
        guard !apiKey.isEmpty else { return }
        attemptedCatalogs.insert(provider)
        let list: [ModelOption]? = switch provider {
        case .deepseek: try? await DeepSeekAPI.listModels(apiKey: apiKey)
        case .meta: try? await MetaAPI.listModels(apiKey: apiKey)
        case .zai: try? await ZaiAPI.listModels(apiKey: apiKey)
        default: nil
        }
        if let list, !list.isEmpty {
            updateCatalog(list, for: provider)
            catalogFetchedAt[provider] = .now
            storeCatalogDates()
        }
    }

    /// Persists when each provider last delivered a list, so a build that launches later
    /// can tell a fresh catalog from one cached before the account gained a model.
    private func storeCatalogDates() {
        guard !CaptureRun.isEnabled else { return }
        let raw = Dictionary(catalogFetchedAt.map { ($0.key.rawValue, $0.value.timeIntervalSince1970) }, uniquingKeysWith: { first, _ in first })
        guard let data = try? JSONEncoder().encode(raw) else { return }
        UserDefaults.standard.set(data, forKey: catalogDatesKey)
    }

    /// Reads the provider's plan limits, at most once a minute after a successful read unless forced.
    /// The read runs on its own task, so closing the popover that asked for it cannot cancel it.
    func refreshPlanLimits(_ provider: ProviderKind, force: Bool = false) {
        guard !CaptureRun.isEnabled else { return }
        guard PlanLimitsReader.exposesLimits(provider) else { return }
        guard !loadingLimits.contains(provider) else { if force { forcedLimitReads.insert(provider) }; return }
        if !force, let fetched = limitsFetchedAt[provider], Date.now.timeIntervalSince(fetched) < 60 { return }
        if provider.isAPIKeyBased {
            let apiKey = settings.apiKey(for: provider)
            guard !apiKey.isEmpty else {
                planLimits[provider] = nil
                return
            }
            loadingLimits.insert(provider)
            let watchdog = Task { try? await Task.sleep(for: .seconds(25)); loadingLimits.remove(provider); drainedForcedRead(provider) }
            Task {
                defer { watchdog.cancel(); loadingLimits.remove(provider); drainedForcedRead(provider) }
                let limits = await PlanLimitsReader.read(provider, apiKey: apiKey)
                guard let limits else { return }
                planLimits[provider] = limits
                limitsFetchedAt[provider] = .now
            }
            return
        }
        guard PlanLimitsReader.exposesLimits(provider), !loadingLimits.contains(provider) else { return }
        loadingLimits.insert(provider)
        let watchdog = Task { try? await Task.sleep(for: .seconds(25)); loadingLimits.remove(provider); drainedForcedRead(provider) }
        Task {
            defer { watchdog.cancel(); loadingLimits.remove(provider); drainedForcedRead(provider) }
            // A popover opened right after launch waits for the login shell like everything
            // else; before that read the CLI can only be found on the fallback PATH.
            await LoginEnvironment.load()
            guard let executable = executable(for: provider) else { return }
            let limits = await PlanLimitsReader.read(provider, executable: executable, environment: environment(for: provider))
            guard let limits else { return }
            planLimits[provider] = limits
            limitsFetchedAt[provider] = .now
        }
    }

    /// Runs a forced read that had to wait because a read was already out for this provider.
    private func drainedForcedRead(_ provider: ProviderKind) {
        guard forcedLimitReads.remove(provider) != nil else { return }
        refreshPlanLimits(provider, force: true)
    }

    /// Spends one of a provider's banked resets and re-reads its limits so the bars show the cleared window. Codex through its app-server, Z.ai through its reset-card endpoint.
    func consumeResetCredit(_ provider: ProviderKind, _ creditID: String?) async throws -> PlanLimits.ResetOutcome {
        redeemingReset = creditID ?? provider.rawValue
        defer { redeemingReset = nil }
        switch provider {
        case .codex:
            await LoginEnvironment.load()
            guard let executable = executable(for: .codex) else { throw ResetCreditError.codexUnavailable }
            let environment = environment(for: .codex)
            let outcome = try await CodexSession.consumeResetCredit(executable: executable, environment: environment, creditID: creditID)
            if let limits = try? await CodexSession.readPlanLimits(executable: executable, environment: environment) {
                planLimits[.codex] = limits
                limitsFetchedAt[.codex] = .now
            }
            return outcome
        case .zai:
            let apiKey = settings.apiKey(for: .zai)
            guard !apiKey.isEmpty, let creditID else { throw ResetCreditError.unknownOutcome }
            let outcome = try await ZaiAPI.consumeResetCredit(apiKey: apiKey, creditID: creditID)
            if let limits = await ZaiAPI.planLimits(apiKey: apiKey) {
                planLimits[.zai] = limits
                limitsFetchedAt[.zai] = .now
            }
            return outcome
        default:
            throw ResetCreditError.unknownOutcome
        }
    }

    /// Reads a pay-as-you-go provider's balance, at most once a minute after a successful
    /// read unless forced. Like the plan limits, the read runs on its own task, so closing
    /// the popover that asked for it cannot cancel it.
    func refreshCredits(_ provider: ProviderKind, force: Bool = false) {
        guard CreditsReader.exposesCredits(provider), !loadingCredits.contains(provider) else { return }
        // Command Code's key is the CLI's own login unless Settings holds one.
        let apiKey = provider == .commandcode
            ? (CommandCodeAPI.apiKey(environment: environment(for: .commandcode)) ?? "")
            : settings.apiKey(for: provider)
        guard !apiKey.isEmpty else {
            credits[provider] = nil
            return
        }
        if !force, let fetched = creditsFetchedAt[provider], Date.now.timeIntervalSince(fetched) < 60 { return }
        loadingCredits.insert(provider)
        Task {
            let balance = await CreditsReader.read(provider, apiKey: apiKey)
            loadingCredits.remove(provider)
            guard let balance else { return }
            credits[provider] = balance
            creditsFetchedAt[provider] = .now
        }
    }

    /// A turn just spent tokens, so the cached balance is older than the spend. The next
    /// look reads the API again instead of handing back the number from before the turn.
    func invalidateCredits(_ provider: ProviderKind) {
        guard CreditsReader.exposesCredits(provider) else { return }
        creditsFetchedAt[provider] = nil
    }

    /// A turn just spent credits, so the cached plan windows are older than the spend.
    /// The next look reads the API again instead of handing back the numbers from
    /// before the turn.
    func invalidatePlanLimits(_ provider: ProviderKind) {
        guard provider.isAPIKeyBased, PlanLimitsReader.exposesLimits(provider) else { return }
        limitsFetchedAt[provider] = nil
    }

    func updateCatalog(_ list: [ModelOption], for provider: ProviderKind) {
        // Claude's live list refines the seed rather than replacing it: threads, pairs and
        // the chip name the seed's ids (`opus`, the Fable row), and a handshake that lists
        // the models another way left them as raw ids with one reasoning level; an ACP session's
        // list keeps the scales the probe walked, see `mergedACPCatalog`.
        let list = switch provider {
        case .claude: Self.mergedClaudeCatalog(list)
        case _ where provider.namesModelVariants: Self.mergedACPCatalog(ModelFamilies.collapsed(list), over: catalogs[provider] ?? [])
        case _ where provider.usesACP: Self.mergedACPCatalog(list, over: catalogs[provider] ?? [])
        default: list
        }
        guard !list.isEmpty, list != catalogs[provider] else { return }
        catalogs[provider] = list
        if provider.namesModelVariants { settings.adoptModelFamilies(list, for: provider) }
        guard !CaptureRun.isEnabled else { return }
        let encoded = Dictionary(uniqueKeysWithValues: catalogs.map { ($0.key.rawValue, $0.value) })
        if let data = try? JSONEncoder().encode(encoded) {
            UserDefaults.standard.set(data, forKey: cacheKey)
        }
    }

    static func commandKey(_ provider: ProviderKind, directory: String) -> String {
        provider.rawValue + "\n" + directory
    }

    func updateCommands(_ list: [SlashCommand], for provider: ProviderKind, directory: String) {
        let key = Self.commandKey(provider, directory: directory)
        if commands[key] == nil, commands.count >= 32,
           let oldest = commandsFetchedAt.min(by: { $0.value < $1.value })?.key {
            commands[oldest] = nil
            commandsFetchedAt[oldest] = nil
            commandErrors[oldest] = nil
        }
        commands[key] = list
        commandsFetchedAt[key] = .now
        commandErrors[key] = nil
    }

    func recordCommand(_ name: String, for provider: ProviderKind) {
        var recent = recentCommands[provider.rawValue] ?? []
        recent.removeAll { $0 == name }
        recent.insert(name, at: 0)
        recentCommands[provider.rawValue] = Array(recent.prefix(100))
        (CaptureRun.defaults ?? .standard).set(recentCommands, forKey: "recentSlashCommands")
    }

    /// `force` asks again whatever the list's age: the retry after a failed load.
    func loadCommands(_ provider: ProviderKind, directory: String, force: Bool = false) async {
        guard !CaptureRun.isEnabled, provider == .codex || provider == .claude else { return }
        let key = Self.commandKey(provider, directory: directory)
        if let task = commandLoads[key] { await task.value; return }
        if !force, let fetched = commandsFetchedAt[key], Date.now.timeIntervalSince(fetched) < Self.commandFreshness { return }
        guard let executable = executable(for: provider) else { return }
        let environment = environment(for: provider)
        let task = Task {
            do {
                let directoryURL = URL(fileURLWithPath: directory)
                let list = try await provider == .codex
                    ? CodexSession.listCommands(executable: executable, directory: directoryURL, environment: environment)
                    : ClaudeSession.handshake(executable: executable, directory: directoryURL, environment: environment).commands
                updateCommands(list, for: provider, directory: directory)
            } catch {
                if commandErrors.count >= 32 { commandErrors.removeAll(keepingCapacity: true) }
                commandErrors[key] = error.localizedDescription
            }
        }
        commandLoads[key] = task
        await task.value
        commandLoads[key] = nil
    }

    // MARK: - Probes

    private static func version(_ executable: URL, _ environment: [String: String]) async -> String? {
        guard let result = try? await Shell.run(executable, ["--version"], environment: environment, timeout: 20),
              result.succeeded else { return nil }
        let text = TextCleanup.stripANSI(result.output + result.errorOutput)
        if let match = text.firstMatch(of: #/\d+\.\d+(?:\.\d+)?(?:[-.][0-9A-Za-z]+)?/#) {
            return String(match.output)
        }
        return nil
    }

    private static func auth(_ provider: ProviderKind, _ executable: URL, _ environment: [String: String]) async -> ProviderStatus.Auth {
        switch provider {
        case .codex:
            guard let result = try? await Shell.run(executable, ["login", "status"], environment: environment, timeout: 20) else {
                return .unknown
            }
            let text = result.output + result.errorOutput
            return result.succeeded && text.localizedCaseInsensitiveContains("logged in") ? .signedIn(nil) : .signedOut
        case .claude:
            guard let result = try? await Shell.run(executable, ["auth", "status"], environment: environment, timeout: 20),
                  let json = JSONValue.parse(result.stdout) else { return .unknown }
            return json["loggedIn"]?.bool == true ? .signedIn(json["email"]?.string) : .signedOut
        case .cursor:
            guard let result = try? await Shell.run(executable, ["status"], environment: environment, timeout: 20) else {
                return .unknown
            }
            let text = TextCleanup.stripANSI(result.output + result.errorOutput)
            if let match = text.firstMatch(of: #/Logged in as (\S+)/#) { return .signedIn(String(match.output.1)) }
            return text.localizedCaseInsensitiveContains("not logged in") ? .signedOut : .unknown
        case .devin:
            guard let result = try? await Shell.run(executable, ["auth", "status"], environment: environment, timeout: 20) else {
                return .unknown
            }
            let text = TextCleanup.stripANSI(result.output + result.errorOutput)
            if text.localizedCaseInsensitiveContains("not logged in") { return .signedOut }
            guard text.localizedCaseInsensitiveContains("logged in") else { return .unknown }
            return .signedIn(Self.devinAccount(from: text))
        case .antigravity:
            return await AntigravitySession.authStatus(executable: executable, environment: environment)
        case .copilot:
            return await CopilotSession.authStatus(executable: executable, environment: environment)
        case .commandcode:
            return await CommandCodeAPI.authStatus(executable: executable, environment: environment)
        case .pi:
            return await PiCLI.authStatus(executable: executable, environment: environment)
        case .kimi:
            return await ACPSession.authStatus(provider: provider, executable: executable, environment: environment)
        case .opencode, .opencodeGo:
            guard let result = try? await Shell.run(executable, ["auth", "list"], environment: environment, timeout: 20) else { return .unknown }
            let text = TextCleanup.stripANSI(result.output + result.errorOutput)
            let credentialText = text.components(separatedBy: "\n").prefix { !$0.contains("Environment") }.joined(separator: "\n")
            let credentials = credentialText.components(separatedBy: "\n").compactMap { line -> String? in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("\u{25CF}") else { return nil }
                var name = trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
                for suffix in [" api", " oauth"] where name.lowercased().hasSuffix(suffix) {
                    name = String(name.dropLast(suffix.count))
                }
                return name.isEmpty ? nil : name
            }
            // Go carries its own credential in the one auth file; Zen is whatever else is there.
            let name = provider == .opencodeGo
                ? credentials.first { $0.localizedCaseInsensitiveContains("opencode go") }
                : credentials.first
            if let name { return .signedIn(name) }
            return result.succeeded ? .signedOut : .unknown
        case .grok:
            let url = URL(fileURLWithPath: (LoginEnvironment.homeDirectory as NSString).appendingPathComponent(".grok/auth.json"))
            guard let data = try? Data(contentsOf: url), let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .unknown }
            guard !root.isEmpty else { return .signedOut }
            let entries = root.values.compactMap { $0 as? [String: Any] }
            if let email = entries.lazy.compactMap({ $0["email"] as? String }).first(where: { !$0.isEmpty }) {
                return .signedIn(email)
            }
            if let name = entries.lazy.compactMap({ $0["first_name"] as? String }).first(where: { !$0.isEmpty }) {
                return .signedIn(name)
            }
            return .signedIn(nil)
        case .deepseek, .meta, .zai:
            return .unknown
        }
    }

    /// The `Name:` line of `devin auth status`, so Settings reads "Signed in as …".
    private static func devinAccount(from text: String) -> String? {
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmed
            guard trimmed.lowercased().hasPrefix("name:") else { continue }
            let name = trimmed.dropFirst("name:".count).trimmingCharacters(in: .whitespaces)
            return name.isEmpty ? nil : name
        }
        return nil
    }
}
