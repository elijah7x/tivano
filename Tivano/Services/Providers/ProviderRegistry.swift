import Foundation
import Observation

struct ProviderStatus: Equatable, Sendable {
    enum Auth: Equatable, Sendable {
        case unknown
        case signedIn(String?)
        case signedOut
    }

    var executable: URL?
    var version: String?
    var auth: Auth = .unknown
    var authMessage: String?
    var isChecking = false
    var catalogError: String?
    /// Native API providers (DeepSeek, Meta, Z.ai) have no CLI; they are installed once an API key exists.
    var apiKeyConfigured = false

    var isInstalled: Bool { executable != nil || apiKeyConfigured }

    var summary: String {
        guard isInstalled else { return AppText.localized("Not installed") }
        if let authMessage { return authMessage }
        switch auth {
        case .signedIn(let account): return account.map { String(format: AppText.localized("Signed in as %@"), $0) } ?? AppText.localized("Signed in")
        case .signedOut: return authMessage ?? AppText.localized("Not signed in")
        case .unknown: return version.map { String(format: AppText.localized("Installed · %@"), $0) } ?? AppText.localized("Installed")
        }
    }
}

enum DshIntegrationConfiguration {
    static var isEnabled: Bool {
        #if DEBUG
        CaptureRun.isEnabled && (CommandLine.arguments.contains("--dsh-integration-probe")
            || CommandLine.arguments.contains("--dsh-offline-native-probe"))
        #else
        false
        #endif
    }

    static var isOfflineHydra: Bool {
        isEnabled && CommandLine.arguments.contains("--dsh-offline-hydra-probe")
    }

    static var isOfflineNative: Bool {
        isEnabled && CommandLine.arguments.contains("--dsh-offline-native-probe")
    }

    struct Paths {
        let executable: URL
        let home: URL
    }

    static var paths: Paths? {
        guard isEnabled else { return nil }
        let arguments = CommandLine.arguments
        func path(_ flag: String) -> URL? {
            guard arguments.filter({ $0 == flag }).count == 1,
                  let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1),
                  arguments[index + 1].hasPrefix("/") else { return nil }
            return URL(fileURLWithPath: arguments[index + 1]).standardizedFileURL.resolvingSymlinksInPath()
        }
        guard let executable = path("--dsh-test-executable"), let home = path("--dsh-test-home"),
              let binary = try? executable.resourceValues(forKeys: [.isRegularFileKey]), binary.isRegularFile == true,
              FileManager.default.isExecutableFile(atPath: executable.path),
              let directory = try? home.resourceValues(forKeys: [.isDirectoryKey]), directory.isDirectory == true else { return nil }
        guard let output = CaptureRun.outputDirectory?.standardizedFileURL.resolvingSymlinksInPath() else { return nil }
        if isOfflineNative {
            let temporary = URL(fileURLWithPath: "/private/tmp", isDirectory: true).resolvingSymlinksInPath()
            let environment = ProcessInfo.processInfo.environment
            guard !isOfflineHydra, output.deletingLastPathComponent() == temporary,
                  output.lastPathComponent.hasPrefix("tivano-dsh-app-native-"),
                  home == output.appendingPathComponent("dsh-home"),
                  !executable.path.hasPrefix(output.path + "/"),
                  let processHome = environment["HOME"], let dshHome = environment["DSH_HOME"],
                  URL(fileURLWithPath: processHome).resolvingSymlinksInPath() == output.appendingPathComponent("home"),
                  URL(fileURLWithPath: dshHome).resolvingSymlinksInPath() == home else { return nil }
        } else if isOfflineHydra {
            // Canonical descendants only: symlinks cannot point this offline fixture at the account or installed CLI.
            let ownerHome = FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().path
            guard output.path != "/", output.path != ownerHome,
                  !ownerHome.hasPrefix(output.path + "/"),
                  home.path.hasPrefix(output.path + "/"),
                  executable.path.hasPrefix(output.path + "/"),
                  !executable.path.hasPrefix(home.path + "/") else { return nil }
        } else {
            guard home.path != output.path,
                  !home.path.hasPrefix(output.path + "/"),
                  !output.path.hasPrefix(home.path + "/") else { return nil }
        }
        return Paths(executable: executable, home: home)
    }

    static var environment: [String: String] {
        guard let paths, let root = CaptureRun.storageRoot else { return [:] }
        if isOfflineNative {
            guard let output = CaptureRun.outputDirectory?.resolvingSymlinksInPath(),
                  let data = try? Data(contentsOf: output.appendingPathComponent("manifest.json")),
                  let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: String],
                  manifest["fixture"] == "tivano-dsh-app-native-v1",
                  let port = manifest["port"].flatMap(Int.init), (1024...65535).contains(port),
                  FileManager.default.fileExists(atPath: output.appendingPathComponent("started").path) else { return [:] }
            return ["HOME": output.appendingPathComponent("home").path,
                    "DSH_HOME": paths.home.path, "TMPDIR": output.appendingPathComponent("tmp").path,
                    "PATH": paths.executable.deletingLastPathComponent().path + ":/opt/homebrew/bin:/usr/bin:/bin",
                    "LANG": "en_US.UTF-8", "SHELL": "/bin/sh", "TERM": "dumb",
                    "DEEPSEEK_API_KEY": "offline-fixture-only", "DSH_TELEMETRY_DISABLED": "1",
                    "DEEPSEEK_BASE_URL": "http://127.0.0.1:\(port)/anthropic",
                    "NO_PROXY": "127.0.0.1,localhost",
                    "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null"]
        }
        let home = root.appendingPathComponent("probe-home", isDirectory: true)
        let temporary = root.appendingPathComponent("probe-tmp", isDirectory: true)
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        // An allowlist, not a filtered login environment: no shell hooks or injected auth.
        return [
            "HOME": home.path, "TMPDIR": temporary.path,
            "PATH": paths.executable.deletingLastPathComponent().path + ":/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "LANG": "en_US.UTF-8", "TERM": "dumb", "SHELL": "/bin/sh",
            "DSH_HOME": paths.home.path,
            "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
        ]
    }
}

/// Finds provider CLIs, checks their sign-in state and caches their model catalogs.
@MainActor
@Observable
final class ProviderRegistry {
    private(set) var statuses: [ProviderKind: ProviderStatus] = [:]
    private(set) var catalogs: [ProviderKind: [ModelOption]] = [:] {
        didSet {
            for provider in sortedModelCache.keys where oldValue[provider] != catalogs[provider] {
                sortedModelCache[provider] = nil
            }
        }
    }
    @ObservationIgnored private var sortedModelCache: [ProviderKind: [ModelOption]] = [:]
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
    @ObservationIgnored private var deepSeekKeyFingerprint: Int?
    @ObservationIgnored private var deepSeekKeyRefresh: Task<Void, Never>?
    @ObservationIgnored private var dshCatalogTask: Task<[ModelOption]?, Never>?
    @ObservationIgnored private var dshCatalogGeneration = UUID()
    @ObservationIgnored private(set) var dshAuthenticationRevision = UUID()

    /// Visible to `ProviderRegistry+CLIUpdates`. The registry still does not see the rest of the app.
    @ObservationIgnored let settings: any ProviderSettings
    @ObservationIgnored private let cacheKey = "providerModelCatalogs"
    // When the provider last delivered a list, persisted under `catalogDatesKey`.
    @ObservationIgnored private let catalogDatesKey = "providerModelCatalogDates"
    @ObservationIgnored var catalogFetchedAt: [ProviderKind: Date] = [:]

    /// Installed and latest CLI versions, and whether an update is waiting or running.
    /// A nil `latest` is an unknown feed, not confirmation that the install is current.
    var cliUpdates: [ProviderKind: CLIUpdateStatus] = [:]

    /// Whether that provider has a running turn. AppModel installs this from its runtimes.
    /// Shared installs consult it for every provider on the same binary.
    @ObservationIgnored var isProviderBusy: @MainActor (ProviderKind) -> Bool = { _ in false }

    /// Ownership probes and release feeds. Replacing this does not install anything.
    @ObservationIgnored var cliProbe: CLIProbe = .live

    /// `--version` and the install command. A fake run replaces these and leaves `cliProbe` for feeds.
    @ObservationIgnored var cliCommandRunner: CLICommandRunner = .live

    /// When set, used instead of `refresh(_:)`. False means the version was not confirmed.
    @ObservationIgnored var cliProviderReloader: (@MainActor (ProviderKind) async -> Bool)?

    /// When set, used instead of `loadCatalog(_:force:)`. False means the catalog was not reloaded.
    @ObservationIgnored var cliCatalogReloader: (@MainActor (ProviderKind) async -> Bool)?

    @ObservationIgnored var cliCheckTasks: [ProviderKind: CLITrackedTask<Void>] = [:]
    @ObservationIgnored var cliCheckGeneration: [ProviderKind: UUID] = [:]
    @ObservationIgnored var cliUpdateTasks: [String: CLITrackedTask<Bool>] = [:]
    @ObservationIgnored var cliUpdateRequesters: [String: ProviderKind] = [:]
    @ObservationIgnored var cliRecoveryLocks: Set<String> = []
    @ObservationIgnored var cliRefreshPending: [String: String] = [:]
    @ObservationIgnored var cliCheckCache: [ProviderKind: CLICheckCache] = [:]
    @ObservationIgnored var cliCheckLoop: Task<Void, Never>?
    /// Shared by every single check and every batch. `cliCheckConcurrency` is this cap.
    @ObservationIgnored var cliCheckPermits = ProviderRegistry.cliCheckConcurrency
    @ObservationIgnored var cliCheckWaiters: [CheckedContinuation<Void, Never>] = []
    /// Bumped when an update starts waiting or running, so a check already in flight cannot publish over it.
    @ObservationIgnored var cliStatusEpoch: [ProviderKind: UInt] = [:]

    /// A list read within this window is served as it is; an older one, or one cached by an
    /// earlier build that stored no date, is read again on the next ask, so a model the
    /// account gained on a new plan appears without hunting for the Refresh button.
    private static let catalogFreshness: TimeInterval = 6 * 3600
    private(set) var planLimits: [ProviderKind: PlanLimits] = [:]
    private(set) var loadingLimits: Set<ProviderKind> = []
    /// The banked reset being spent right now: its credit id, or "codex" for one the app-server listed only by count.
    private(set) var redeemingReset: String?
    @ObservationIgnored private var limitsFetchedAt: [ProviderKind: Date] = [:]
    @ObservationIgnored private var limitReadGenerations: [ProviderKind: UUID] = [:]
    @ObservationIgnored private var limitReadTasks: [ProviderKind: Task<Void, Never>] = [:]

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
    private static func mergedACPCatalog(_ live: [ModelOption], over cached: [ModelOption], provider: ProviderKind) -> [ModelOption] {
        guard !cached.isEmpty else { return live }
        let known = Dictionary(cached.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return live.map { option in
            let id = provider == .dsh ? DshCLI.resolvedModelID(option.id, in: cached) : option.id
            guard option.efforts.isEmpty, let kept = known[id] else { return option }
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
    static let dshSeed = ["deepseek-flash", "deepseek-v4-pro"].map { model in
        let id = "[\"deepseek-account\",\"\(model)\"]"
        return ModelOption(id: id, name: DshCLI.displayName(forModelID: id), efforts: ["off", "low", "high", "max"], defaultEffort: "high", isDefault: model == "deepseek-flash")
    }
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

    /// omp's starting catalog; its live model list replaces it.
    static let ompSeed = [ModelOption(id: "default", name: "Default", detail: "The model omp itself is set to", efforts: ["off", "minimal", "low", "medium", "high", "xhigh", "max"], defaultEffort: "medium", isDefault: true)]

    /// Pi's starting catalog; the live catalog from pi's RPC `get_available_models` replaces it.
    static let piSeed = [ModelOption(id: "default", name: "Default", detail: "The model pi itself is set to", efforts: ["off", "minimal", "low", "medium", "high", "xhigh", "max"], defaultEffort: "medium", isDefault: true)]

    /// Every provider tries its live catalog at most once per launch unless forced, success or not,
    /// so views that ask on appear never re-spawn a CLI or re-hit an API while scrolling.
    @ObservationIgnored private var attemptedCatalogs: Set<ProviderKind> = []

    /// The full opencode ACP catalogue, probed once per launch.
    @ObservationIgnored private var openCodeCatalogTask: Task<[ModelOption]?, Never>?

    init(settings: any ProviderSettings) {
        self.settings = settings
        var initialCatalogs: [ProviderKind: [ModelOption]] = [:]
        recentCommands = (CaptureRun.defaults ?? .standard).dictionary(forKey: "recentSlashCommands") as? [String: [String]] ?? [:]
        if !CaptureRun.isEnabled,
           let data = UserDefaults.standard.data(forKey: cacheKey),
           let cached = try? JSONDecoder().decode([String: [ModelOption]].self, from: data) {
            for (key, list) in cached {
                guard key != "opencodeGo", !(key == "opencode" && cached["opencodeGo"] != nil),
                      let provider = ProviderKind(rawValue: key) else { continue }
                if provider == .dsh, list.contains(where: { $0.name == $0.id || $0.name.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("[") }) { continue }
                // A list cached before the scales were ordered may still run high to low
                // (Grok's did); the slider reads them low to high, so they are put right here.
                let ordered = list.map { option in
                    var option = option
                    option.efforts = ModelOption.orderedEfforts(option.efforts)
                    return option
                }
                // A list cached before variants were merged is merged on the way in.
                initialCatalogs[provider] = provider.namesModelVariants ? ModelFamilies.collapsed(ordered) : ordered
            }
        }
        if !CaptureRun.isEnabled,
           let data = UserDefaults.standard.data(forKey: catalogDatesKey),
           let raw = try? JSONDecoder().decode([String: Double].self, from: data) {
            for (key, seconds) in raw {
                guard key != "opencodeGo", !(key == "opencode" && raw["opencodeGo"] != nil) else { continue }
                if let provider = ProviderKind(rawValue: key) { catalogFetchedAt[provider] = Date(timeIntervalSince1970: seconds) }
            }
        }
        if Self.isStaleClaudeSeed(initialCatalogs[.claude] ?? []) { initialCatalogs[.claude] = Self.claudeSeed }
        if initialCatalogs[.deepseek]?.isEmpty ?? true { initialCatalogs[.deepseek] = Self.deepseekSeed }
        if initialCatalogs[.dsh]?.isEmpty ?? true {
            initialCatalogs[.dsh] = Self.dshSeed
            catalogFetchedAt[.dsh] = nil
        }
        if initialCatalogs[.meta]?.isEmpty ?? true { initialCatalogs[.meta] = Self.metaSeed }
        if initialCatalogs[.zai]?.isEmpty ?? true { initialCatalogs[.zai] = Self.zaiSeed }
        if initialCatalogs[.antigravity]?.isEmpty ?? true || initialCatalogs[.antigravity]?.contains(where: { $0.id.hasSuffix("-high") || $0.id.hasSuffix("-medium") || $0.id.hasSuffix("-low") }) == true {
            initialCatalogs[.antigravity] = Self.antigravitySeed
        }
        if initialCatalogs[.copilot]?.isEmpty ?? true { initialCatalogs[.copilot] = [Self.copilotAuto] }
        if initialCatalogs[.commandcode]?.isEmpty ?? true { initialCatalogs[.commandcode] = Self.commandcodeSeed }
        if initialCatalogs[.pi]?.isEmpty ?? true { initialCatalogs[.pi] = Self.piSeed }
        if initialCatalogs[.omp]?.isEmpty ?? true { initialCatalogs[.omp] = Self.ompSeed }
        if catalogs != initialCatalogs { catalogs = initialCatalogs }
        for provider in ProviderKind.allCases where provider.namesModelVariants || provider == .dsh {
            if let list = catalogs[provider] { settings.adoptModelFamilies(list, for: provider) }
        }
        observeDeepSeekKey()
    }

    private func observeDeepSeekKey() {
        let fingerprint = withObservationTracking {
            settings.apiKey(for: .deepseek).hashValue
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.observeDeepSeekKey() }
        }
        defer { deepSeekKeyFingerprint = fingerprint }
        guard let previous = deepSeekKeyFingerprint, previous != fingerprint else { return }
        invalidateDshAuthentication()
        deepSeekKeyRefresh?.cancel()
        deepSeekKeyRefresh = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(600)) } catch { return }
            guard let self, !Task.isCancelled else { return }
            await self.refresh(.dsh)
            guard !Task.isCancelled else { return }
            await self.loadCatalog(.dsh, force: true)
            guard !Task.isCancelled else { return }
            await self.refresh(.deepseek)
            guard !Task.isCancelled else { return }
            await self.loadCatalog(.deepseek, force: true)
        }
    }

    private func invalidateDshAuthentication() {
        dshAuthenticationRevision = UUID()
        dshCatalogGeneration = UUID()
        dshCatalogTask?.cancel()
        dshCatalogTask = nil
        if loadingCatalogs.contains(.dsh) { loadingCatalogs.remove(.dsh) }
        attemptedCatalogs.remove(.dsh)
        catalogFetchedAt[.dsh] = nil
        storeCatalogDates()
        var status = statuses[.dsh] ?? ProviderStatus()
        status.auth = .unknown
        status.authMessage = nil
        status.catalogError = nil
        status.isChecking = false
        setStatus(status, for: .dsh)
    }

    private func setDshCatalogError(_ message: String?) {
        var status = statuses[.dsh] ?? ProviderStatus()
        status.catalogError = message
        setStatus(status, for: .dsh)
    }

    var availableProviders: [ProviderKind] {
        ProviderKind.allCases.filter { settings.isEnabled($0) && countsAsInstalled($0) }
    }

    /// Whether a provider counts as installed with its first check still out: a check that
    /// has not happened yet is not a "no". The launch screen builds its first chat before
    /// `bootstrap()` probes the providers (see `AppDelegate`), so a strict read there found
    /// no pair and no provider: every one of them read as missing.
    func countsAsInstalled(_ provider: ProviderKind) -> Bool {
        if DshIntegrationConfiguration.isEnabled { return status(provider).isInstalled }
        return statuses[provider]?.isInstalled ?? true
    }

    func status(_ provider: ProviderKind) -> ProviderStatus {
        if DshIntegrationConfiguration.isEnabled {
            return provider == .dsh ? (statuses[provider] ?? ProviderStatus()) : ProviderStatus()
        }
        // A capture run never probes the CLIs (see `refresh`), and reads as a Mac with every
        // provider installed and signed in, so the pairs and pickers show what they offer.
        if CaptureRun.isEnabled {
            return ProviderStatus(executable: URL(fileURLWithPath: "/usr/bin/true"), auth: .signedIn(nil), apiKeyConfigured: true)
        }
        return statuses[provider] ?? ProviderStatus()
    }

    func executable(for provider: ProviderKind) -> URL? {
        if DshIntegrationConfiguration.isEnabled {
            return provider == .dsh ? DshIntegrationConfiguration.paths?.executable : nil
        }
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
        case .omp:
            let home = LoginEnvironment.homeDirectory
            return ["\(home)/.bun/bin/omp", "\(home)/.npm-global/bin/omp", "/opt/homebrew/bin/omp", "/usr/local/bin/omp", "\(home)/.local/bin/omp", "\(home)/.volta/bin/omp"].map { URL(fileURLWithPath: $0) }
        case .minimaxCode:
            let home = LoginEnvironment.homeDirectory
            // Official standalone installer first, then documented npm/user-prefix locations.
            return ["\(home)/.minimax-code/bin/mcode", "\(home)/.npm-global/bin/mcode", "/opt/homebrew/bin/mcode", "/usr/local/bin/mcode", "\(home)/.local/bin/mcode", "\(home)/.volta/bin/mcode"].map { URL(fileURLWithPath: $0) }
        case .pi, .kimi, .dsh:
            let home = LoginEnvironment.homeDirectory
            let name = provider.executableName
            var candidates = ["\(home)/.npm-global/bin/\(name)", "/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)", "\(home)/.local/bin/\(name)", "\(home)/.volta/bin/\(name)", "\(home)/.bun/bin/\(name)"]
            if provider == .dsh {
                candidates.append("/Applications/DeepSeek Harness.app/Contents/Resources/runtime/cli/bin/dsh")
            }
            return candidates.map { URL(fileURLWithPath: $0) }
        default:
            return []
        }
    }

    func environment(for provider: ProviderKind) -> [String: String] {
        if DshIntegrationConfiguration.isEnabled {
            return provider == .dsh ? DshIntegrationConfiguration.environment : [:]
        }
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
        if provider == .dsh {
            DshCLI.applyBaseEnvironment(&environment, apiKey: settings.apiKey(for: .deepseek))
        }
        // OpenCode takes its MCP servers as config content in the environment,
        // so the connected servers reach it without a line written into its config files.
        if provider == .opencode { environment.merge(MCPSessionOverrides.opencodeEnvironment()) { _, new in new } }
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
        guard !DshIntegrationConfiguration.isEnabled else {
            return AppText.localized("DeepSeek Harness sign-in did not finish. Try again.")
        }
        guard signingIn == nil else { return nil }
        guard !provider.isAPIKeyBased, provider == .dsh || !provider.loginCommand.isEmpty else { return nil }
        signingIn = provider
        defer { signingIn = nil }
        await LoginEnvironment.load()
        guard let executable = executable(for: provider) else {
            let missing = String(format: AppText.localized("%@ was not found on your PATH."), provider.displayName)
            return LoginEnvironment.diagnostic.map { missing + " " + $0 } ?? missing
        }
        let loginEnvironment = environment(for: provider)
        do {
            if provider == .dsh {
                try await DshLogin.signIn(executable: executable, environment: loginEnvironment)
            } else {
                // The login command starts with the executable's own name; the rest are its arguments.
                let arguments = provider.loginCommand.split(whereSeparator: \.isWhitespace).dropFirst().map(String.init)
                let result = try await Shell.run(executable, arguments, environment: loginEnvironment, timeout: 300)
                if !result.succeeded {
                    let output = TextCleanup.stripANSI(result.output + result.errorOutput)
                    guard let lastLine = output.split(separator: "\n", omittingEmptySubsequences: true).last, !lastLine.isEmpty else {
                        return "\(provider.displayName) did not finish signing in."
                    }
                    return String(lastLine)
                }
            }
        } catch {
            return provider == .dsh ? AppText.localized("DeepSeek Harness sign-in did not finish. Try again.") : error.localizedDescription
        }
        if provider == .dsh { invalidateDshAuthentication() }
        refreshPlanLimits(provider, force: true, executable: executable, environment: loginEnvironment)
        await refresh(provider)
        await loadCatalog(provider, force: true)
        return nil
    }

    /// The Providers page's refresh button: checks every provider again, re-reads usage limits
    /// for each signed-in account only while the page shows them and reloads the live catalogs.
    /// Beyond the limits, nothing on that page checks on its own, so this is the only way it hits the CLIs and APIs.
    func refreshEverything() async {
        guard !DshIntegrationConfiguration.isEnabled else { return }
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        await LoginEnvironment.load(force: true)
        await refreshAll()
        // Credits were already re-read when the key proved itself in `refreshAPIProvider`.
        if settings.showsProviderUsage {
            for provider in ProviderKind.allCases where status(provider).auth != .signedOut {
                refreshPlanLimits(provider, force: true)
            }
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
        // The button re-reads versions. `refreshAll` does not: launch already probes every CLI,
        // and a check there would run twice.
        await checkCLIUpdates(freshness: 0)
    }

    /// How many providers are checked at the same time. Every check spawns the provider's
    /// CLI, and launch checks them all: starting a dozen node processes at once is a
    /// visible stall in everything else the app is doing just then.
    private static let probeWidth = 4

    func refreshAll() async {
        // The integration runner owns its deadlines and serializes its probes.
        guard !DshIntegrationConfiguration.isEnabled else { return }
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

    private func setStatus(_ status: ProviderStatus, for provider: ProviderKind) {
        guard statuses[provider] != status else { return }
        statuses[provider] = status
    }

    func refresh(_ provider: ProviderKind) async {
        if DshIntegrationConfiguration.isEnabled {
            guard provider == .dsh, let executable = executable(for: provider) else { return }
            let version = await Self.version(executable, environment(for: provider))
            // Credential contents belong to dsh. A version check is not evidence of login.
            setStatus(ProviderStatus(executable: executable, version: version, auth: .unknown), for: provider)
            return
        }
        guard !CaptureRun.isEnabled else { return }
        let dshRevision = dshAuthenticationRevision
        var status = statuses[provider] ?? ProviderStatus()
        status.isChecking = true
        setStatus(status, for: provider)
        if provider.isAPIKeyBased {
            await refreshAPIProvider(provider)
            return
        }
        await LoginEnvironment.load()
        guard let executable = executable(for: provider) else {
            setStatus(ProviderStatus(), for: provider)
            return
        }
        let environment = environment(for: provider)
        // Both probes spawn the CLI. One after the other rather than together: the pair
        // was two processes per provider at the same moment, on top of every other
        // provider being checked alongside.
        let version = await Self.version(executable, environment)
        if provider == .minimaxCode {
            let authentication = await ACPSession.minimaxCodeAuthentication(executable: executable, environment: environment)
            setStatus(ProviderStatus(executable: executable, version: version, auth: authentication.auth,
                                     authMessage: authentication.message, catalogError: statuses[provider]?.catalogError), for: provider)
            return
        }
        let auth = await Self.auth(provider, executable, environment)
        guard provider != .dsh || (dshRevision == dshAuthenticationRevision && !Task.isCancelled) else { return }
        let authMessage = provider == .dsh && auth == .signedOut
            ? AppText.localized("DeepSeek Harness needs a signed-in DeepSeek account or a DeepSeek API key. Sign in with the DeepSeek Harness app, or add a key in Settings → Providers → DeepSeek.")
            : nil
        setStatus(ProviderStatus(executable: executable, version: version, auth: auth, authMessage: authMessage, catalogError: statuses[provider]?.catalogError), for: provider)
    }

    /// API-key providers have no binary: presence (and validity) of the key is the install state.
    private func refreshAPIProvider(_ provider: ProviderKind) async {
        let apiKey = settings.apiKey(for: provider)
        guard !apiKey.isEmpty else {
            setStatus(ProviderStatus(auth: .signedOut), for: provider)
            return
        }
        if provider == .deepseek {
            let valid = await DeepSeekAPI.validate(apiKey: apiKey)
            setStatus(ProviderStatus(
                version: "API",
                auth: valid ? .signedIn(nil) : .signedOut,
                apiKeyConfigured: true
            ), for: provider)
            // The key just proved itself, so read the balance behind it right away: the
            // usage panel has it from launch, and a rejected key must not leave a stale one.
            if valid {
                refreshCredits(.deepseek, force: true)
            } else {
                if credits[.deepseek] != nil { credits[.deepseek] = nil }
                creditsFetchedAt[.deepseek] = nil
            }
        } else if provider == .meta {
            let valid = await MetaAPI.validate(apiKey: apiKey)
            setStatus(ProviderStatus(
                version: "API",
                auth: valid ? .signedIn(nil) : .signedOut,
                apiKeyConfigured: true
            ), for: provider)
        } else if provider == .zai {
            let valid = await ZaiAPI.validate(apiKey: apiKey)
            setStatus(ProviderStatus(
                version: "API",
                auth: valid ? .signedIn(nil) : .signedOut,
                apiKeyConfigured: true
            ), for: provider)
            if valid {
                refreshPlanLimits(.zai, force: true)
            } else {
                limitReadGenerations[.zai] = nil
                limitReadTasks[.zai]?.cancel()
                limitReadTasks[.zai] = nil
                if loadingLimits.contains(.zai) { loadingLimits.remove(.zai) }
                if planLimits[.zai] != nil { planLimits[.zai] = nil }
                limitsFetchedAt[.zai] = nil
            }
        } else {
            setStatus(ProviderStatus(auth: .signedIn(nil), apiKeyConfigured: true), for: provider)
        }
    }

    // MARK: - Models

    func models(for provider: ProviderKind) -> [ModelOption] {
        catalogs[provider] ?? []
    }

    func sortedModels(for provider: ProviderKind) -> [ModelOption] {
        // Read even on cache hits so views keep observing catalogue changes.
        let catalogue = models(for: provider)
        if let cached = sortedModelCache[provider] { return cached }
        let sorted = catalogue.sortedByName()
        sortedModelCache[provider] = sorted
        return sorted
    }

    func model(_ id: String?, for provider: ProviderKind) -> ModelOption? {
        guard let id else { return nil }
        let list = models(for: provider)
        if provider == .dsh { return list.first { $0.id == DshCLI.resolvedModelID(id, in: list) } }
        return Self.match(id, in: list)
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
    /// version 2.1.280 or newer is required". That error prompts a manual update;
    /// recovery never installs a CLI.
    /// The providers whose reply can ask for a newer CLI (`claude`, `codex`).
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

    /// Retained for error-recovery callers. Recovery never authorizes an installation.
    @discardableResult
    func updateCLIIfDue(_ provider: ProviderKind, force: Bool = false) async -> Bool {
        return false
    }

    /// The version the installed CLI reports, or nil when it cannot be read.
    func installedCLIVersion(_ provider: ProviderKind) async -> String? {
        if DshIntegrationConfiguration.isEnabled {
            guard provider == .dsh, let executable = executable(for: provider) else { return nil }
            return await Self.version(executable, environment(for: provider))
        }
        await LoginEnvironment.load()
        guard let executable = executable(for: provider) else { return nil }
        let raw = await cliCommandRunner.readVersion(executable, CLIInstallEnvironment.current)
        return Self.readableCLIVersion(raw)
    }

    func loadCatalog(_ provider: ProviderKind, force: Bool = false) async {
        guard !CaptureRun.isEnabled || (DshIntegrationConfiguration.isEnabled && provider == .dsh && DshIntegrationConfiguration.paths != nil) else { return }
        if provider == .dsh {
            await loadDshCatalog(force: force)
            return
        }
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
            || (provider == .omp && models(for: provider) == Self.ompSeed)
            || (provider == .opencode && Self.lacksEffortWalk(models(for: provider)))
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
        case .omp: try? await OmpCLI.listModels(executable: executable, environment: environment)
        case .minimaxCode:
            await loadMiniMaxCodeCatalog(executable: executable, environment: environment)
        case .cursor, .grok, .devin, .kimi, .dsh: try? await ACPSession.probeModels(provider: provider, executable: executable, environment: environment)
        case .opencode: await openCodeCatalog(force: force, executable: executable, environment: environment)
        case .deepseek, .meta, .zai: nil
        }
        if let list = raw, !list.isEmpty {
            updateCatalog(list, for: provider)
            catalogFetchedAt[provider] = .now
            storeCatalogDates()
            // Only a delivered catalog closes the attempt: a probe that came back with
            // nothing (a cold CLI losing to its handshake timeout, say) is tried again
            // on the next ask rather than leaving the provider empty for the whole run.
            attemptedCatalogs.insert(provider)
        }
    }

    private func loadMiniMaxCodeCatalog(executable: URL, environment: [String: String]) async -> [ModelOption]? {
        do {
            let list = try await ACPSession.probeModels(provider: .minimaxCode, executable: executable, environment: environment)
            var status = statuses[.minimaxCode] ?? ProviderStatus(executable: executable)
            status.catalogError = list.isEmpty ? AppText.localized("MiniMax Code did not advertise any models. Configure a provider in mcode, then refresh.") : nil
            setStatus(status, for: .minimaxCode)
            return list
        } catch is CancellationError {
            return nil
        } catch {
            // Keep the last advertised catalogue, but never present a failed read as a fresh one.
            var status = statuses[.minimaxCode] ?? ProviderStatus(executable: executable)
            status.catalogError = error.localizedDescription
            setStatus(status, for: .minimaxCode)
            return nil
        }
    }

    private func loadDshCatalog(force: Bool) async {
        guard !loadingCatalogs.contains(.dsh) else { return }
        let stale = catalogFetchedAt[.dsh].map { Date.now.timeIntervalSince($0) > Self.catalogFreshness } ?? true
        let seeded = models(for: .dsh) == Self.dshSeed
        guard force || (!attemptedCatalogs.contains(.dsh) && (seeded || stale || models(for: .dsh).isEmpty)) else { return }
        let generation = UUID()
        dshCatalogGeneration = generation
        loadingCatalogs.insert(.dsh)
        setDshCatalogError(nil)
        defer {
            if dshCatalogGeneration == generation {
                loadingCatalogs.remove(.dsh)
                dshCatalogTask = nil
            }
        }
        if !DshIntegrationConfiguration.isEnabled { await LoginEnvironment.load() }
        guard dshCatalogGeneration == generation, !Task.isCancelled else { return }
        guard let executable = executable(for: .dsh) else {
            setDshCatalogError(AppText.localized("DeepSeek Harness is not installed or its binary path is unavailable."))
            return
        }
        let environment = environment(for: .dsh)
        let task = Task { () -> [ModelOption]? in
            do {
                return try await ACPSession.probeModels(provider: .dsh, executable: executable, environment: environment)
            } catch {
                guard !Task.isCancelled, self.dshCatalogGeneration == generation else { return nil }
                NSLog("DeepSeek Harness catalog probe failed: %@", error.localizedDescription)
                self.setDshCatalogError(String(format: AppText.localized("Could not load DeepSeek Harness models. %@"), error.localizedDescription))
                return nil
            }
        }
        dshCatalogTask = task
        let list = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        guard dshCatalogGeneration == generation, !Task.isCancelled else { return }
        guard let list, !list.isEmpty else {
            if statuses[.dsh]?.catalogError == nil {
                setDshCatalogError(AppText.localized("DeepSeek Harness returned no models. Check your sign-in and retry."))
            }
            return
        }
        updateCatalog(list, for: .dsh)
        catalogFetchedAt[.dsh] = .now
        storeCatalogDates()
        attemptedCatalogs.insert(.dsh)
    }

    /// An OpenCode list cached before the catalog probe walked the models for their
    /// reasoning levels holds a scale for the model the probe's session started on alone.
    private static func lacksEffortWalk(_ list: [ModelOption]) -> Bool {
        list.count(where: { !$0.efforts.isEmpty }) <= 1
    }

    /// The full opencode ACP catalogue once per launch, with the CLI's model ids and names.
    /// The probe spawns the CLI and walks every model.
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
    func refreshPlanLimits(_ provider: ProviderKind, force: Bool = false,
                           executable suppliedExecutable: URL? = nil,
                           environment suppliedEnvironment: [String: String]? = nil) {
        guard !CaptureRun.isEnabled, PlanLimitsReader.exposesLimits(provider) else { return }
        guard force || !loadingLimits.contains(provider) else { return }
        if !force, let fetched = limitsFetchedAt[provider], Date.now.timeIntervalSince(fetched) < 60 { return }
        let generation = UUID()
        limitReadGenerations[provider] = generation
        limitReadTasks[provider]?.cancel()
        limitsFetchedAt[provider] = nil
        if !loadingLimits.contains(provider) { loadingLimits.insert(provider) }
        // Cancellation is advisory for the underlying readers. Generation ownership
        // protects both publication and cleanup when a timed-out request returns late.
        let watchdog = Task {
            do { try await Task.sleep(for: .seconds(90)) } catch { return }
            guard limitReadGenerations[provider] == generation else { return }
            limitReadTasks[provider]?.cancel()
            finishPlanLimits(provider, generation: generation,
                             limits: PlanLimitsReader.failure("The usage request timed out. Try again."))
        }
        limitReadTasks[provider] = Task {
            defer { watchdog.cancel() }
            let limits: PlanLimits
            if provider.isAPIKeyBased {
                let apiKey = settings.apiKey(for: provider)
                if apiKey.isEmpty {
                    limits = PlanLimitsReader.failure("No API key is configured.", kind: .authentication)
                } else {
                    limits = await PlanLimitsReader.read(provider, apiKey: apiKey)
                        ?? PlanLimitsReader.failure("The provider did not return usage data. The usage request may have failed or may be unsupported.")
                }
            } else {
                await LoginEnvironment.load()
                guard limitReadGenerations[provider] == generation, !Task.isCancelled else { return }
                guard let executable = suppliedExecutable ?? executable(for: provider) else {
                    finishPlanLimits(provider, generation: generation,
                                     limits: PlanLimitsReader.failure(String(format: AppText.localized("%@ was not found on your PATH."), provider.displayName)))
                    return
                }
                limits = await PlanLimitsReader.read(provider, executable: executable,
                                                     environment: suppliedEnvironment ?? environment(for: provider))
                    ?? PlanLimitsReader.failure("The provider did not return usage data. The usage request may have failed or may be unsupported.")
            }
            finishPlanLimits(provider, generation: generation, limits: limits)
        }
    }

    private func finishPlanLimits(_ provider: ProviderKind, generation: UUID, limits: PlanLimits) {
        guard limitReadGenerations[provider] == generation else { return }
        limitReadGenerations[provider] = nil
        limitReadTasks[provider] = nil
        if loadingLimits.contains(provider) { loadingLimits.remove(provider) }
        var limits = limits
        // A read that only counted the banked resets keeps the expiries the last read listed, while the count is unchanged.
        if let fresh = limits.resetCredits, fresh.credits.count < fresh.availableCount,
           let previous = planLimits[provider]?.resetCredits,
           previous.availableCount == fresh.availableCount, previous.credits.count > fresh.credits.count {
            limits.resetCredits = previous
        }
        if planLimits[provider] != limits { planLimits[provider] = limits }
        limitsFetchedAt[provider] = limits.problem == nil ? .now : nil
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
            refreshPlanLimits(.codex, force: true)
            return outcome
        case .zai:
            let apiKey = settings.apiKey(for: .zai)
            guard !apiKey.isEmpty, let creditID else { throw ResetCreditError.unknownOutcome }
            let outcome = try await ZaiAPI.consumeResetCredit(apiKey: apiKey, creditID: creditID)
            refreshPlanLimits(.zai, force: true)
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
            if credits[provider] != nil { credits[provider] = nil }
            return
        }
        if !force, let fetched = creditsFetchedAt[provider], Date.now.timeIntervalSince(fetched) < 60 { return }
        loadingCredits.insert(provider)
        Task {
            let balance = await CreditsReader.read(provider, apiKey: apiKey)
            loadingCredits.remove(provider)
            guard let balance else { return }
            if credits[provider] != balance { credits[provider] = balance }
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
        // MiniMax supplies complete snapshots; an empty current scale revokes old values.
        case .minimaxCode: list
        case _ where provider.namesModelVariants: Self.mergedACPCatalog(ModelFamilies.collapsed(list), over: catalogs[provider] ?? [], provider: provider)
        case _ where provider.usesACP: Self.mergedACPCatalog(list, over: catalogs[provider] ?? [], provider: provider)
        default: list
        }
        // A delivered list retires an earlier load failure: the error and its Retry
        // belong to a refresh that produced nothing, which this list just disproved.
        if !list.isEmpty, var status = statuses[provider], status.catalogError != nil {
            status.catalogError = nil
            setStatus(status, for: provider)
        }
        guard (!list.isEmpty || provider == .minimaxCode), list != catalogs[provider] else { return }
        catalogs[provider] = list
        if provider.namesModelVariants || provider == .dsh { settings.adoptModelFamilies(list, for: provider) }
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
        var updatedCommands = commands
        var updatedErrors = commandErrors
        if updatedCommands[key] == nil, updatedCommands.count >= 32,
           let oldest = commandsFetchedAt.min(by: { $0.value < $1.value })?.key {
            updatedCommands[oldest] = nil
            commandsFetchedAt[oldest] = nil
            updatedErrors[oldest] = nil
        }
        updatedCommands[key] = list
        updatedErrors[key] = nil
        if commands != updatedCommands { commands = updatedCommands }
        commandsFetchedAt[key] = .now
        if commandErrors != updatedErrors { commandErrors = updatedErrors }
    }

    func recordCommand(_ name: String, for provider: ProviderKind) {
        var recent = recentCommands[provider.rawValue] ?? []
        recent.removeAll { $0 == name }
        recent.insert(name, at: 0)
        let updated = Array(recent.prefix(100))
        if recentCommands[provider.rawValue] != updated { recentCommands[provider.rawValue] = updated }
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
                var updatedErrors = commandErrors
                if updatedErrors.count >= 32 { updatedErrors.removeAll(keepingCapacity: true) }
                updatedErrors[key] = error.localizedDescription
                if commandErrors != updatedErrors { commandErrors = updatedErrors }
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
        case .omp:
            return await OmpCLI.authStatus(executable: executable, environment: environment)
        case .kimi:
            return await ACPSession.authStatus(provider: provider, executable: executable, environment: environment)
        case .dsh:
            if DshCLI.hasAccountLogin(environment: environment) {
                return .signedIn(AppText.localized("DeepSeek account"))
            }
            return (environment["DEEPSEEK_API_KEY"] ?? "").isEmpty ? .signedOut : .signedIn(AppText.localized("API key"))
        case .opencode:
            guard let result = try? await Shell.run(executable, ["auth", "list"], environment: environment, timeout: 20) else { return .unknown }
            guard result.succeeded else { return .unknown }
            let credentials = Self.opencodeCredentialNames(from: result.output + result.errorOutput)
            if let name = credentials.first { return .signedIn(name) }
            return .signedOut
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
        case .deepseek, .meta, .zai, .minimaxCode:
            return .unknown
        }
    }

    // Accept legacy ● credential lines and V2 provider / credential / source table rows.
    static func opencodeCredentialNames(from output: String) -> [String] {
        let text = TextCleanup.stripANSI(output)
        var inLegacyEnvironment = false
        return text.components(separatedBy: "\n").compactMap { line -> String? in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.hasPrefix("\u{25CF}") {
                let columns = trimmed.replacingOccurrences(of: #"\s{2,}|\t+"#, with: "\t", options: .regularExpression)
                    .components(separatedBy: "\t")
                if columns.count == 3, columns.allSatisfy({ !$0.isEmpty }) {
                    return columns[2].lowercased() == "stored" ? columns[0] : nil
                }
            }
            if line.contains("Environment") { inLegacyEnvironment = true }
            guard !inLegacyEnvironment, trimmed.hasPrefix("\u{25CF}") else { return nil }
            var name = trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
            for suffix in [" api", " oauth"] where name.lowercased().hasSuffix(suffix) {
                name = String(name.dropLast(suffix.count))
            }
            return name.isEmpty ? nil : name
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
