import SwiftUI

enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case english
    case simplifiedChinese

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "System default"
        case .english: "English"
        case .simplifiedChinese: "简体中文"
        }
    }
}

enum TextGenerationChoice: String, CaseIterable, Identifiable {
    case automatic
    case claude
    case codex
    case off

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: "Automatic"
        case .claude: "Claude"
        case .codex: "Codex"
        case .off: "Off"
        }
    }
}

enum TimelineHapticStyle: String, CaseIterable, Identifiable {
    case soft
    case strong
    case none

    var id: String { rawValue }

    var title: String {
        switch self {
        case .soft: "Soft"
        case .strong: "Strong"
        case .none: "None"
        }
    }
}

enum ActivityThreadStyle: String, CaseIterable, Identifiable {
    /// The project's emoji or SF Symbol before the thread's name: one line per thread.
    case icon
    /// The project's name, with a folder mark, on a line under the thread's title.
    case projectName

    var id: String { rawValue }

    var title: String {
        switch self {
        case .icon: "Icon"
        case .projectName: "Project name"
        }
    }

    var detail: String {
        switch self {
        case .icon: "Each project's emoji or symbol before the thread's name, one line per thread"
        case .projectName: "The project's name, with a folder mark, on a line under the thread's title"
        }
    }
}

struct NewThreadModelSelection: Codable, Hashable {
    let provider: ProviderKind
    let modelID: String
    /// The reasoning effort new chats start on; nil leaves the model's default.
    let effort: String?

    init(provider: ProviderKind, modelID: String, effort: String? = nil) {
        self.provider = provider
        self.modelID = modelID
        self.effort = effort
    }
}

enum NewThreadLocation: String, Codable, CaseIterable {
    case recent
    case standalone
}

/// A model the composer's picker offers.
struct ModelPin: Codable, Hashable, Identifiable, Sendable {
    var provider: ProviderKind
    var modelID: String

    var id: String { "\(provider.rawValue)/\(modelID)" }
    var displayName: String { provider == .dsh ? DshCLI.displayName(forModelID: modelID) : modelID }
}

/// A user-named heading in the picker's list. It sits before the pin at `position` in
/// `modelList` (or after the last pin when `position` is the list's count) and holds the
/// pins down to the next heading.
struct ModelSection: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    var position: Int
}

/// What a new chat was started on in the picker: a model, or a pair. A pair is kept whole,
/// so a temporary one, never saved in Settings › Hydra, can be picked again as it was.
enum NewChatChoice: Codable, Hashable, Sendable {
    case model(ModelPin)
    case pair(HydraPair)
}

/// One row of the picker's list as Settings arranges it: a model or a heading.
enum ModelListItem: Hashable, Identifiable, Sendable {
    case pin(ModelPin)
    case section(ModelSection)

    var id: String {
        switch self {
        case .pin(let pin): pin.id
        case .section(let section): "section/\(section.id.uuidString)"
        }
    }

    // Equal by identity: a heading stays the same row while it is renamed or moved,
    // which the reorder drag and the measured row heights rely on.
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// How a model starts in new chats.
struct ModelPreference: Codable, Hashable, Sendable {
    var effort: String?
    var fastMode = false
}

/// Preferences that belong to this Mac, stored in user defaults.
@MainActor
@Observable
final class AppSettings {
    /// The per-chat Hydra default's key, owned by `ChatThread`, which seeds new
    /// threads from it before any settings object is in reach.
    nonisolated static let hydraDefaultEnabledKey = ChatThread.hydraDefaultKey

    private enum Key {
        static let defaultProvider = "defaultProvider"
        static let runtimeMode = "defaultRuntimeMode"
        static let workspaceMode = "defaultWorkspaceMode"
        static let newThreadModelSelection = "newThreadModelSelection"
        static let newThreadLocation = "newThreadLocation"
        static let notify = "notifyWhenFinished"
        static let chime = "chimeWhenFinished"
        static let confirmDelete = "confirmBeforeDeleting"
        static let showReasoning = "showReasoning"
        static let antiSlopEnabled = "antiSlopEnabled"
        static let showsWorkingCard = "showsWorkingCard"
        static let timelineHapticStyle = "timelineHapticStyle"
        static let uiFontSize = "uiFontSize"
        static let contentFontSize = "contentFontSize"
        static let codeFontSize = "codeFontSize"
        static let sidebarActivityView = "sidebarActivityView"
        static let sidebarProjectsCollapsed = "sidebarProjectsCollapsed"
        static let sidebarTasksCollapsed = "sidebarTasksCollapsed"
        static let showsSkylight = "showsSkylight"
        static let codexVoice = "codexVoice"
        static let alphaEnabled = "alphaEnabled"
        static let alphaVoiceEnabled = "alphaVoiceEnabled"
        static let alphaHydra2Enabled = "alphaHydra2Enabled"
        static let externalControlEnabled = "externalControlEnabled"
        static let remoteMCPEnabled = "remoteMCPEnabled"
        static let remoteMCPPublicURL = "remoteMCPPublicURL"
        static let remoteMCPPort = "remoteMCPPort"
        static let remoteMCPFullAccess = "remoteMCPFullAccess"
        static let cliInstallationTarget = "cliInstallationTarget"
        static let appTheme = "appTheme"
        static let backdropOpacity = "backdropOpacity"
        static let appearance = "appearance"
        static let clearerBackdrop = "clearerBackdrop"
        static let performanceMode = "performanceMode"
        static let autoHideTopControls = "autoHideTopControls"
        static let binaryPaths = "providerBinaryPaths"
        static let disabledProviders = "disabledProviders"
        static let unmonitoredProviders = "unmonitoredProviderUpdates"
        static let showsProviderUsage = "showsProviderUsage"
        static let models = "lastModels"
        static let efforts = "lastEfforts"
        static let openCodeProviderMigrated = "openCodeProviderMigrated"
        static let lastHydraPair = "lastHydraPairID"
        static let textGeneration = "textGeneration"
        static let preventSleepDuringTasks = "preventSleepDuringTasks"
        static let taskSleepMode = "taskSleepMode"
        static let appLanguage = "appLanguage"
        static let commitInstructions = "commitInstructions"
        static let terminalHeight = "terminalHeight"
        static let modelList = "modelList"
        static let modelPreferences = "modelPreferences"
        static let modelSections = "modelSections"
        static let collapsedModelSections = "collapsedModelSections"
        static let lastNewChatModel = "lastNewChatModel"
        static let lastNewChatPair = "lastNewChatPair"
        static let dismissedModelGroupsTip = "dismissedModelGroupsTip"
        static let hidesOutdatedModels = "hidesOutdatedModels"
        static let recentDownloadsPicker = "recentDownloadsPicker"
        static let lastProjectID = "lastProjectID"
        static let lastThreadAffiliation = "lastThreadAffiliation"
        static let projectsEnabled = "projectsEnabled"
        static let projectActivationOverrides = "projectActivationOverrides"
        static let deepseekAPIKey = "deepseekAPIKey"
        static let metaAPIKey = "metaAPIKey"
        static let zaiAPIKey = "zaiAPIKey"
        static let zaiRegion = ZaiRegion.defaultsKey
        static let commandcodeAPIKey = "commandcodeAPIKey"
        static let hydraEnabled = "hydraEnabled"
        static let panelSize = "floatingPanelSize"
        static let hydraDefaultEnabled = AppSettings.hydraDefaultEnabledKey
        static let hydraQueueHeads = "hydraQueueHeads"
        static let hydraAlwaysHeads = "hydraAlwaysHeads"
        static let hydraTilt = "hydraTilt"
        static let hydraIsolateHeads = "hydraIsolateHeads"
        static let hydraAutoMerge = "hydraAutoMerge"
        static let hydraReviewHeads = "hydraReviewHeads"
        static let hydraArchivesCodexHeads = "hydraArchivesCodexHeads"
        static let hydraShowsHeadDetails = "hydraShowsHeadDetails"
        static let hydraAutoPopsHeads = "hydraAutoPopsHeads"
        static let hydraTempersHeadEffort = "hydraTempersHeadEffort"
        static let hydraMaxHeads = "hydraMaxHeads"
        static let sidebarPanelOrigin = "sidebarPanelOrigin"
        static let sidebarPanelSize = "sidebarPanelSize"
        static let hydraPairs = "hydraPairs"
        static let hasSeenHydraIntro = "hasSeenHydraIntro"
    }

    static let modelListLimit = 30

    @ObservationIgnored private let defaults = CaptureRun.defaults ?? .standard

    /// The provider last chosen in a composer's model picker (or by a Hydra pair): what a
    /// new thread starts on when there is no thread to follow. Not a setting of its own
    /// any more; Settings says as much under New threads.
    var defaultProvider: ProviderKind {
        didSet { defaults.set(defaultProvider.rawValue, forKey: Key.defaultProvider) }
    }

    var defaultRuntimeMode: RuntimeMode {
        didSet { defaults.set(defaultRuntimeMode.rawValue, forKey: Key.runtimeMode) }
    }

    var defaultWorkspaceMode: WorkspaceMode {
        didSet { defaults.set(defaultWorkspaceMode.rawValue, forKey: Key.workspaceMode) }
    }

    var newThreadModelSelection: NewThreadModelSelection? {
        didSet { store(newThreadModelSelection, forKey: Key.newThreadModelSelection) }
    }

    var newThreadLocation: NewThreadLocation {
        didSet { defaults.set(newThreadLocation.rawValue, forKey: Key.newThreadLocation) }
    }

    var notifyWhenFinished: Bool {
        didSet { defaults.set(notifyWhenFinished, forKey: Key.notify) }
    }

    /// A soft chime plays when a turn finishes, whether or not the thread is in view.
    var chimeWhenFinished: Bool {
        didSet { defaults.set(chimeWhenFinished, forKey: Key.chime) }
    }

    @ObservationIgnored var onSleepPreventionChanged: (() -> Void)?
    @ObservationIgnored var onExternalControlChanged: (() -> Void)?

    var taskSleepMode: TaskSleepMode {
        didSet {
            defaults.set(taskSleepMode.rawValue, forKey: Key.taskSleepMode)
            onSleepPreventionChanged?()
        }
    }

    var confirmBeforeDeleting: Bool {
        didSet { defaults.set(confirmBeforeDeleting, forKey: Key.confirmDelete) }
    }

    var showReasoning: Bool {
        didSet { defaults.set(showReasoning, forKey: Key.showReasoning) }
    }

    var antiSlopEnabled: Bool {
        didSet { defaults.set(antiSlopEnabled, forKey: Key.antiSlopEnabled) }
    }

    /// The running turn's line as the head panel's progress card (the task, the stave bar
    /// of the turn's steps, the time); off, it is the one-line badge with the words and the time.
    var showsWorkingCard: Bool {
        didSet { defaults.set(showsWorkingCard, forKey: Key.showsWorkingCard) }
    }

    /// The style of haptic feedback played when hovering over timeline ticks and progress bars.
    var timelineHapticStyle: TimelineHapticStyle {
        didSet { defaults.set(timelineHapticStyle.rawValue, forKey: Key.timelineHapticStyle) }
    }

    /// Base sizes in points. Each shifts its category off the original rendering baseline.
    var uiFontSize: Int {
        didSet {
            let clamped = TypeScale.clamp(uiFontSize, to: TypeScale.uiRange)
            if clamped != uiFontSize { uiFontSize = clamped }
            defaults.set(uiFontSize, forKey: Key.uiFontSize)
            TypeScale.shared.ui = uiFontSize
        }
    }

    var contentFontSize: Int {
        didSet {
            let clamped = TypeScale.clamp(contentFontSize, to: TypeScale.contentRange)
            if clamped != contentFontSize { contentFontSize = clamped }
            defaults.set(contentFontSize, forKey: Key.contentFontSize)
            TypeScale.shared.content = contentFontSize
        }
    }

    var codeFontSize: Int {
        didSet {
            let clamped = TypeScale.clamp(codeFontSize, to: TypeScale.codeRange)
            if clamped != codeFontSize { codeFontSize = clamped }
            defaults.set(codeFontSize, forKey: Key.codeFontSize)
            TypeScale.shared.code = codeFontSize
        }
    }

    /// True when Interface, Content and Code are all on their default sizes.
    var isDefault: Bool {
        uiFontSize == TypeScale.defaultUI
            && contentFontSize == TypeScale.defaultContent
            && codeFontSize == TypeScale.defaultCode
    }

    func resetFontSizes() {
        uiFontSize = TypeScale.defaultUI
        contentFontSize = TypeScale.defaultContent
        codeFontSize = TypeScale.defaultCode
    }

    /// Moves each size by `delta` points and clamps it to that size's own range.
    func stepFontSizes(by delta: Int) {
        uiFontSize += delta
        contentFontSize += delta
        codeFontSize += delta
    }

    /// The floating panels' size once one has been resized by hand; nil leaves them to
    /// size themselves to the pane. Every chat's panels share it, and the layout fits it
    /// to the room there is, so a panel never outgrows the pane it is in.
    var panelSize: CGSize? {
        didSet {
            if let panelSize {
                defaults.set([panelSize.width, panelSize.height], forKey: Key.panelSize)
            } else {
                defaults.removeObject(forKey: Key.panelSize)
            }
        }
    }

    /// Voice style for the next call; nil uses Codex's default.
    var codexVoice: String? {
        didSet { defaults.set(codexVoice, forKey: Key.codexVoice) }
    }

    /// Alpha's master switch: off hides every experimental feature, whatever its own switch.
    var alphaEnabled: Bool {
        didSet {
            defaults.set(alphaEnabled, forKey: Key.alphaEnabled)
            onExternalControlChanged?()
        }
    }

    /// Codex realtime voice, an Alpha feature.
    var alphaVoiceEnabled: Bool {
        didSet { defaults.set(alphaVoiceEnabled, forKey: Key.alphaVoiceEnabled) }
    }

    var isVoiceEnabled: Bool { alphaEnabled && alphaVoiceEnabled }

    /// Hydra 2.0: every new request of a Hydra lead runs the v2 decision layer
    /// (docs/hydra2.md). Read once per request, see `ThreadRuntime.startTurn`.
    var alphaHydra2Enabled: Bool {
        didSet { defaults.set(alphaHydra2Enabled, forKey: Key.alphaHydra2Enabled) }
    }

    var isHydra2Enabled: Bool { alphaEnabled && alphaHydra2Enabled }

    /// Dedicated, default-false permission. Installing the command never changes it.
    var externalControlEnabled: Bool {
        didSet {
            defaults.set(externalControlEnabled, forKey: Key.externalControlEnabled)
            onExternalControlChanged?()
        }
    }
    var isExternalControlEnabled: Bool { alphaEnabled && externalControlEnabled }

    var remoteMCPEnabled: Bool {
        didSet {
            defaults.set(remoteMCPEnabled, forKey: Key.remoteMCPEnabled)
            onExternalControlChanged?()
        }
    }
    /// Saved as typed; the server picks it up when editing ends (`RemoteMCPService.refresh`).
    var remoteMCPPublicURL: String {
        didSet { defaults.set(remoteMCPPublicURL, forKey: Key.remoteMCPPublicURL) }
    }
    var remoteMCPPort: Int {
        didSet { defaults.set(remoteMCPPort, forKey: Key.remoteMCPPort) }
    }
    var isRemoteMCPEnabled: Bool { alphaEnabled && remoteMCPEnabled }
    /// Default false. Only threads Remote MCP creates while it is on start in Full access;
    /// existing threads keep their permissions.
    var remoteMCPFullAccess: Bool {
        didSet { defaults.set(remoteMCPFullAccess, forKey: Key.remoteMCPFullAccess) }
    }
    var isRemoteMCPFullAccess: Bool { isRemoteMCPEnabled && remoteMCPFullAccess }

    /// Receipt for user-action-only PATH repair/removal; not an authorization gate.
    var cliInstallationTarget: String? {
        didSet { defaults.set(cliInstallationTarget, forKey: Key.cliInstallationTarget) }
    }

    /// The sidebar lists every thread by when it was last active, instead of by project.
    var sidebarActivityView: Bool {
        didSet { defaults.set(sidebarActivityView, forKey: Key.sidebarActivityView) }
    }

    var sidebarProjectsCollapsed: Bool {
        didSet { defaults.set(sidebarProjectsCollapsed, forKey: Key.sidebarProjectsCollapsed) }
    }

    var sidebarTasksCollapsed: Bool {
        didSet { defaults.set(sidebarTasksCollapsed, forKey: Key.sidebarTasksCollapsed) }
    }

    var showsSkylight: Bool {
        didSet { defaults.set(showsSkylight, forKey: Key.showsSkylight) }
    }

    var showsSkylightNow: Bool { showsSkylight && !performanceMode }

    /// The activity list always shows the project's name under the thread title.
    let activityThreadStyle: ActivityThreadStyle = .projectName

    var theme: AppTheme {
        didSet {
            defaults.set(theme.rawValue, forKey: Key.appTheme)
            ThemeManager.current = theme
        }
    }

    /// How solid the window's backdrop is, 0 (clear glass, the desktop shows through) to
    /// 1 (a solid base). With a wallpaper the backdrop is the picture, drawn at this same
    /// value, so the desktop shows through the picture below the solid end.
    var backdropOpacity: Double {
        didSet { defaults.set(backdropOpacity, forKey: Key.backdropOpacity) }
    }
    static let defaultBackdropOpacity = 0.5

    var appLanguage: AppLanguage {
        didSet {
            defaults.set(appLanguage.rawValue, forKey: Key.appLanguage)
            switch appLanguage {
            case .system:
                UserDefaults.standard.removeObject(forKey: "AppleLanguages")
            case .english:
                UserDefaults.standard.set(["en"], forKey: "AppleLanguages")
            case .simplifiedChinese:
                UserDefaults.standard.set(["zh-Hans"], forKey: "AppleLanguages")
            }
        }
    }

    /// Uses Liquid Glass to show more of the desktop instead of a lighter system blur.
    var clearerBackdrop: Bool {
        didSet { defaults.set(clearerBackdrop, forKey: Key.clearerBackdrop) }
    }

    /// Disables window transparency, blurs, glows and background effects for lowest GPU usage.
    var performanceMode: Bool {
        didSet {
            // Clearer glass keeps its own value: the backdrop ignores it while this is on.
            defaults.set(performanceMode, forKey: Key.performanceMode)
        }
    }

    var autoHideTopControls: Bool {
        didSet { defaults.set(autoHideTopControls, forKey: Key.autoHideTopControls) }
    }

    var textGeneration: TextGenerationChoice {
        didSet { defaults.set(textGeneration.rawValue, forKey: Key.textGeneration) }
    }

    var commitInstructions: String {
        didSet { defaults.set(commitInstructions, forKey: Key.commitInstructions) }
    }

    var terminalHeight: Double {
        didSet { defaults.set(terminalHeight, forKey: Key.terminalHeight) }
    }

    /// The attach button offers recent downloads first instead of opening Finder straight away.
    var recentDownloadsPicker: Bool {
        didSet { defaults.set(recentDownloadsPicker, forKey: Key.recentDownloadsPicker) }
    }

    /// The folder a new thread opens in when no thread is selected. Updated whenever a thread
    /// is selected or created, so ⌘N stays in the last folder you used.
    var lastProjectID: UUID? {
        didSet {
            if let lastProjectID {
                defaults.set(lastProjectID.uuidString, forKey: Key.lastProjectID)
            } else {
                defaults.removeObject(forKey: Key.lastProjectID)
            }
        }
    }

    var lastThreadAffiliation: ThreadAffiliation? {
        didSet {
            if let lastThreadAffiliation { store(lastThreadAffiliation, forKey: Key.lastThreadAffiliation) }
            else { defaults.removeObject(forKey: Key.lastThreadAffiliation) }
        }
    }

    /// Whether projects are active app-wide. This is the default every project follows:
    /// with it on, all projects are active without any per-project step; a project the
    /// user explicitly switched off (or on) keeps its own choice.
    var projectsEnabled: Bool {
        didSet { defaults.set(projectsEnabled, forKey: Key.projectsEnabled) }
    }

    /// Per-project activation choices, by project id. Absent means the project follows
    /// `projectsEnabled`; present means the user explicitly overrode it.
    private(set) var projectActivationOverrides: [String: Bool] {
        didSet { store(projectActivationOverrides, forKey: Key.projectActivationOverrides) }
    }

    /// Whether a project is active: its own explicit choice, else the global switch.
    func isProjectActive(_ id: UUID) -> Bool {
        true
    }

    /// Explicitly switch a project on or off, overriding the global switch.
    func setProjectActive(_ active: Bool, for id: UUID) {
        projectActivationOverrides[id.uuidString] = active
    }

    /// Forget a project's own choice, so it follows the global switch again.
    func clearProjectActivationOverride(for id: UUID) {
        projectActivationOverrides[id.uuidString] = nil
    }

    /// Whether a project has its own explicit choice instead of following the switch.
    func hasProjectActivationOverride(for id: UUID) -> Bool {
        projectActivationOverrides[id.uuidString] != nil
    }

    /// DeepSeek talks to its cloud API directly, so it needs an API key instead of a CLI login.
    /// Stored in the Keychain; older plaintext defaults are migrated when read.
    /// Read once, on the first ask, and cached: a Keychain query on every render made
    /// Settings lag, and two of them before the window exists made launch wait on securityd.
    var deepseekAPIKeyInput: String {
        didSet {
            storeAPIKeyChange(deepseekAPIKeyInput, from: oldValue, provider: .deepseek, fallbackKey: Key.deepseekAPIKey)
        }
    }

    /// Meta Model API (Muse Spark) talks to https://api.meta.ai/v1 directly,
    /// so it needs a MODEL_API_KEY instead of a CLI login.
    /// Stored in the Keychain; older plaintext defaults are migrated when read.
    var metaAPIKeyInput: String {
        didSet {
            storeAPIKeyChange(metaAPIKeyInput, from: oldValue, provider: .meta, fallbackKey: Key.metaAPIKey)
        }
    }

    var zaiRegion: ZaiRegion {
        didSet { defaults.set(zaiRegion.rawValue, forKey: Key.zaiRegion) }
    }

    /// Z.ai's GLM Coding Plan talks to api.z.ai or open.bigmodel.cn by region,
    /// so it needs a ZAI_API_KEY instead of a CLI login.
    /// Stored in the Keychain; older plaintext defaults are migrated when read.
    /// Read once, on the first ask, and cached: a Keychain query on every render made
    /// Settings lag, and two of them before the window exists made launch wait on securityd.
    var zaiAPIKeyInput: String {
        didSet {
            storeAPIKeyChange(zaiAPIKeyInput, from: oldValue, provider: .zai, fallbackKey: Key.zaiAPIKey)
        }
    }

    /// Command Code signs in with `cmd login`; a Studio API key here is the alternative,
    /// handed to the CLI as `COMMAND_CODE_API_KEY`. Stored in the Keychain.
    var commandcodeAPIKeyInput: String {
        didSet {
            storeAPIKeyChange(commandcodeAPIKeyInput, from: oldValue, provider: .commandcode, fallbackKey: Key.commandcodeAPIKey)
        }
    }

    private(set) var apiKeyStoreErrors: [ProviderKind: String] = [:]
    private(set) var apiKeyMigrationFailures: Set<ProviderKind> = []

    enum APIKeySource {
        case settings
        case environment(String)
        case none
    }

    @ObservationIgnored private var didReadKeychain = false
    @ObservationIgnored private var isReadingKeychain = false

    /// One provider's key as read: the Keychain's, or the plaintext copy in the defaults
    /// for a Mac whose Keychain refused it.
    private struct StoredKey: Sendable {
        var value: String
        var inKeychain: Bool
        var migrationError: String?

        init(keychain: String, fallback: String) {
            inKeychain = !keychain.isEmpty
            value = inKeychain ? keychain : fallback
        }
    }

    private struct StoredKeys: Sendable {
        var deepseek: StoredKey
        var meta: StoredKey
        var zai: StoredKey
        var commandcode: StoredKey
    }

    private var keyFallbacks: (deepseek: String, meta: String, zai: String, commandcode: String) {
        (
            defaults.string(forKey: Key.deepseekAPIKey) ?? "",
            defaults.string(forKey: Key.metaAPIKey) ?? "",
            defaults.string(forKey: Key.zaiAPIKey) ?? "",
            defaults.string(forKey: Key.commandcodeAPIKey) ?? ""
        )
    }

    /// Reads stored keys and migrates any legacy plaintext defaults.
    private nonisolated static func readKeys(fallbacks: (deepseek: String, meta: String, zai: String, commandcode: String)) -> StoredKeys {
        StoredKeys(
            deepseek: storedKey(for: .deepseek, fallback: fallbacks.deepseek),
            meta: storedKey(for: .meta, fallback: fallbacks.meta),
            zai: storedKey(for: .zai, fallback: fallbacks.zai),
            commandcode: storedKey(for: .commandcode, fallback: fallbacks.commandcode)
        )
    }

    private nonisolated static func storedKey(for provider: ProviderKind, fallback: String) -> StoredKey {
        guard !CaptureRun.isEnabled else { return StoredKey(keychain: "", fallback: "") }
        var key = StoredKey(keychain: APIKeychain.key(for: provider, fallback: ""), fallback: fallback)
        if !key.inKeychain, !fallback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            key.migrationError = APIKeychain.store(fallback, for: provider)
            key.inKeychain = key.migrationError == nil
        }
        return key
    }

    /// The stored keys, from the Keychain the first time anything asks for one. The fill
    /// bypasses the observers above, which write edited keys back to the Keychain.
    private func readKeychainIfNeeded() {
        guard !didReadKeychain else { return }
        fillKeys(Self.readKeys(fallbacks: keyFallbacks))
    }

    /// Reads the keys off the main thread once the window is up, so neither the first
    /// frame nor the first ask waits on securityd. An ask that comes first reads for itself.
    func loadKeychainInBackground() async {
        guard !didReadKeychain else { return }
        let fallbacks = keyFallbacks
        let keys = await Task.detached(priority: .userInitiated) { Self.readKeys(fallbacks: fallbacks) }.value
        fillKeys(keys)
    }

    private func fillKeys(_ keys: StoredKeys) {
        guard !didReadKeychain else { return }
        didReadKeychain = true
        isReadingKeychain = true
        deepseekAPIKeyInput = keys.deepseek.value
        metaAPIKeyInput = keys.meta.value
        zaiAPIKeyInput = keys.zai.value
        commandcodeAPIKeyInput = keys.commandcode.value
        isReadingKeychain = false
        for (provider, key, fallbackKey) in [
            (ProviderKind.deepseek, keys.deepseek, Key.deepseekAPIKey),
            (.meta, keys.meta, Key.metaAPIKey),
            (.zai, keys.zai, Key.zaiAPIKey),
            (.commandcode, keys.commandcode, Key.commandcodeAPIKey),
        ] {
            if key.inKeychain { defaults.removeObject(forKey: fallbackKey) }
            if let error = key.migrationError {
                apiKeyStoreErrors[provider] = error
                apiKeyMigrationFailures.insert(provider)
            }
        }
    }

    /// Failed writes keep the edited key in memory without creating a plaintext copy.
    private func storeAPIKeyChange(_ value: String, from oldValue: String, provider: ProviderKind, fallbackKey: String) {
        guard !isReadingKeychain, value != oldValue, !CaptureRun.isEnabled else { return }
        apiKeyMigrationFailures.remove(provider)
        if let error = APIKeychain.store(value, for: provider) {
            apiKeyStoreErrors[provider] = error
        } else {
            apiKeyStoreErrors.removeValue(forKey: provider)
            defaults.removeObject(forKey: fallbackKey)
        }
    }

    private(set) var binaryPaths: [String: String] {
        didSet { defaults.set(binaryPaths, forKey: Key.binaryPaths) }
    }

    private(set) var disabledProviders: [String] {
        didSet { defaults.set(disabledProviders, forKey: Key.disabledProviders) }
    }

    /// CLI update checks the user turned off, stored by provider id. Older preferences
    /// have no entry, so a provider stays monitored until it is listed here.
    private(set) var unmonitoredProviders: [String] {
        didSet { defaults.set(unmonitoredProviders, forKey: Key.unmonitoredProviders) }
    }

    var showsProviderUsage: Bool {
        didSet { defaults.set(showsProviderUsage, forKey: Key.showsProviderUsage) }
    }

    private(set) var lastModels: [String: String] {
        didSet { defaults.set(lastModels, forKey: Key.models) }
    }

    private(set) var lastEfforts: [String: String] {
        didSet { defaults.set(lastEfforts, forKey: Key.efforts) }
    }

    /// The pair a chat was last put in from the model picker, so a new chat with no chat to
    /// carry from (after a relaunch, say) starts in it rather than on the bare last model.
    /// Cleared when a chat leaves its pair or the pair is removed.
    var lastHydraPairID: UUID? {
        didSet { defaults.set(lastHydraPairID?.uuidString, forKey: Key.lastHydraPair) }
    }

    private(set) var modelList: [ModelPin] {
        didSet { store(modelList, forKey: Key.modelList) }
    }

    private(set) var modelPreferences: [String: ModelPreference] {
        didSet { store(modelPreferences, forKey: Key.modelPreferences) }
    }

    /// The headings between the pins, kept apart from `modelList` so that list stays what
    /// it always was. Read them through `modelListItems`.
    private(set) var modelSections: [ModelSection] {
        didSet { store(modelSections, forKey: Key.modelSections) }
    }

    /// The headings folded shut in the composer's picker.
    private(set) var collapsedModelSections: Set<UUID> {
        didSet { defaults.set(collapsedModelSections.map(\.uuidString), forKey: Key.collapsedModelSections) }
    }

    /// The tip in Settings › Models that suggests groups, once closed.
    var dismissedModelGroupsTip: Bool {
        didSet { defaults.set(dismissedModelGroupsTip, forKey: Key.dismissedModelGroupsTip) }
    }

    /// Model pickers show the newest three versions of each line; chosen, default and
    /// in-use models always show.
    var hidesOutdatedModels: Bool {
        didSet { defaults.set(hidesOutdatedModels, forKey: Key.hidesOutdatedModels) }
    }

    /// The model and the pair new chats were last started on from the picker, offered
    /// again as Recent. Kept apart, so going back and forth between a model and a
    /// temporary pair never loses the pair.
    private(set) var lastNewChatModel: ModelPin? {
        didSet { store(lastNewChatModel, forKey: Key.lastNewChatModel) }
    }

    private(set) var lastNewChatPair: HydraPair? {
        didSet { store(lastNewChatPair, forKey: Key.lastNewChatPair) }
    }

    /// Hydra is on for the app from the first launch: what the app is for. Switched
    /// off in Settings › Hydra, or per chat from the mark.
    var hydraEnabled: Bool {
        didSet { defaults.set(hydraEnabled, forKey: Key.hydraEnabled) }
    }

    /// The per-chat Hydra choice new threads start with. Every per-chat switch flip saves
    /// here too, so the choice sticks as the default for next threads across relaunch.
    /// True until the user first switches a chat off.
    var hydraDefaultEnabled: Bool {
        didSet { defaults.set(hydraDefaultEnabled, forKey: Key.hydraDefaultEnabled) }
    }

    /// The first chat's Hydra intro was read (see `HydraIntroPopover`).
    var hasSeenHydraIntro: Bool {
        didSet { defaults.set(hasSeenHydraIntro, forKey: Key.hasSeenHydraIntro) }
    }

    /// With Hydra on, a follow-up queued while a turn runs goes to a head at once
    /// instead of waiting for the turn.
    var hydraQueueHeads: Bool {
        didSet { defaults.set(hydraQueueHeads, forKey: Key.hydraQueueHeads) }
    }

    /// With Hydra on, every message the user sends goes to a head, sent or queued, idle
    /// lead or not: the lead only ever hears the heads' reports. When every head is busy,
    /// a message goes the ordinary way.
    var hydraAlwaysHeads: Bool {
        didSet { defaults.set(hydraAlwaysHeads, forKey: Key.hydraAlwaysHeads) }
    }

    /// Hydra 2.0's one delegation control. The two routing switches above are v1's:
    /// with Hydra 2.0 on every message goes to the lead, which decides what heads take.
    var hydraTilt: HydraTilt {
        didSet { defaults.set(hydraTilt.rawValue, forKey: Key.hydraTilt) }
    }

    /// Whether queued follow-ups go straight to heads: v1's switches, off under Hydra 2.0.
    var hydraQueuesToHeads: Bool { !isHydra2Enabled && (hydraQueueHeads || hydraAlwaysHeads) }
    /// Whether every message goes straight to a head: v1's switch, off under Hydra 2.0.
    var hydraSendsToHeads: Bool { !isHydra2Enabled && hydraAlwaysHeads }

    /// A head Tivano runs gets a copy of the checkout of its own, so no head ever
    /// sees another's half-done work; its changes land in the chat's checkout when it
    /// reports. Off, the heads work in the checkout itself.
    var hydraIsolateHeads: Bool {
        didSet { defaults.set(hydraIsolateHeads, forKey: Key.hydraIsolateHeads) }
    }

    /// The cap on heads at work at once for every chat, set on the Hydra page; nil is
    /// off. A pair's own cap still counts where it is lower.
    var hydraMaxHeads: Int? {
        didSet {
            if let hydraMaxHeads {
                defaults.set(hydraMaxHeads, forKey: Key.hydraMaxHeads)
            } else {
                defaults.removeObject(forKey: Key.hydraMaxHeads)
            }
        }
    }

    /// Once the lead has finished and every head is back, the team's work goes out as a
    /// merge request and lands, and the checkout is brought up to date. Off unless asked.
    var hydraAutoMerge: Bool {
        didSet { defaults.set(hydraAutoMerge, forKey: Key.hydraAutoMerge) }
    }

    /// The lead gives every head's landed work a quick audit before it finishes, reading
    /// the files the reports name and correcting what is wrong itself. Off unless asked.
    var hydraReviewHeads: Bool {
        didSet { defaults.set(hydraReviewHeads, forKey: Key.hydraReviewHeads) }
    }

    /// Provider-side history, independent of Tivano's sidebar. Never sweeps old heads.
    var hydraArchivesCodexHeads: Bool {
        didSet { defaults.set(hydraArchivesCodexHeads, forKey: Key.hydraArchivesCodexHeads) }
    }

    /// A head's panel shows its whole conversation instead of the progress bar. Off unless
    /// asked: the bar says how far it is and how long it took, the steps are the sidebar's
    /// to show.
    var hydraShowsHeadDetails: Bool {
        didSet { defaults.set(hydraShowsHeadDetails, forKey: Key.hydraShowsHeadDetails) }
    }

    /// While there is room beside the chat, each head after the first gets a panel of
    /// its own, on the left and the right, until each side is full (see `PanelScene.autoPopped`).
    var hydraAutoPopsHeads: Bool {
        didSet { defaults.set(hydraAutoPopsHeads, forKey: Key.hydraAutoPopsHeads) }
    }

    /// Heads think at a working effort rather than the lead's own: a lead above medium
    /// sends out medium heads on the same model (a scale without a medium works out at
    /// its middle rung), unless the pair names an effort for
    /// them (see `AppModel.hydraHeadsEffort`).
    var hydraTempersHeadEffort: Bool {
        didSet { defaults.set(hydraTempersHeadEffort, forKey: Key.hydraTempersHeadEffort) }
    }

    /// Where the floating sidebar was last left, from the chat area's top-left.
    var sidebarPanelOrigin: CGPoint? {
        didSet {
            if let sidebarPanelOrigin {
                defaults.set([sidebarPanelOrigin.x, sidebarPanelOrigin.y], forKey: Key.sidebarPanelOrigin)
            } else {
                defaults.removeObject(forKey: Key.sidebarPanelOrigin)
            }
        }
    }

    /// The size it was last dragged to.
    var sidebarPanelSize: CGSize? {
        didSet {
            if let sidebarPanelSize {
                defaults.set([sidebarPanelSize.width, sidebarPanelSize.height], forKey: Key.sidebarPanelSize)
            } else {
                defaults.removeObject(forKey: Key.sidebarPanelSize)
            }
        }
    }

    /// The lead-and-heads pairings, in the order Settings and the model picker show them.
    /// Reordering writes this array; nothing else stores the order.
    private(set) var hydraPairs: [HydraPair] {
        didSet { store(hydraPairs, forKey: Key.hydraPairs) }
    }

    init() {
        let defaults = CaptureRun.defaults ?? .standard
        defaultProvider = ProviderKind(storedValue: defaults.string(forKey: Key.defaultProvider) ?? "") ?? .codex
        defaultRuntimeMode = RuntimeMode(rawValue: defaults.string(forKey: Key.runtimeMode) ?? "") ?? .fullAccess
        defaultWorkspaceMode = WorkspaceMode(rawValue: defaults.string(forKey: Key.workspaceMode) ?? "") ?? .local
        newThreadModelSelection = Self.load(NewThreadModelSelection.self, forKey: Key.newThreadModelSelection)
        newThreadLocation = NewThreadLocation(rawValue: defaults.string(forKey: Key.newThreadLocation) ?? "") ?? .recent
        notifyWhenFinished = defaults.object(forKey: Key.notify) as? Bool ?? true
        chimeWhenFinished = defaults.object(forKey: Key.chime) as? Bool ?? true
        // The mode replaced an on/off switch: an earlier "off" stays off, an earlier "on" keeps the Mac awake.
        taskSleepMode = TaskSleepMode(rawValue: defaults.string(forKey: Key.taskSleepMode) ?? "")
            ?? (defaults.object(forKey: Key.preventSleepDuringTasks) as? Bool == false ? .off : .system)
        confirmBeforeDeleting = defaults.object(forKey: Key.confirmDelete) as? Bool ?? true
        // Auto-continue is now chosen per chat. Drop the old global setting.
        defaults.removeObject(forKey: "autoContinueAfterLimit")
        showReasoning = defaults.object(forKey: Key.showReasoning) as? Bool ?? false
        antiSlopEnabled = defaults.object(forKey: Key.antiSlopEnabled) as? Bool ?? true
        showsWorkingCard = defaults.object(forKey: Key.showsWorkingCard) as? Bool ?? true
        timelineHapticStyle = TimelineHapticStyle(rawValue: defaults.string(forKey: Key.timelineHapticStyle) ?? "") ?? .soft
        zaiRegion = ZaiRegion(rawValue: defaults.string(forKey: Key.zaiRegion) ?? "") ?? .global
        uiFontSize = Self.clampedFontSize(defaults, key: Key.uiFontSize, stock: TypeScale.defaultUI, range: TypeScale.uiRange)
        contentFontSize = Self.clampedFontSize(defaults, key: Key.contentFontSize, stock: TypeScale.defaultContent, range: TypeScale.contentRange)
        codeFontSize = Self.clampedFontSize(defaults, key: Key.codeFontSize, stock: TypeScale.defaultCode, range: TypeScale.codeRange)
        sidebarActivityView = defaults.bool(forKey: Key.sidebarActivityView)
        sidebarProjectsCollapsed = defaults.bool(forKey: Key.sidebarProjectsCollapsed)
        sidebarTasksCollapsed = defaults.bool(forKey: Key.sidebarTasksCollapsed)
        showsSkylight = defaults.object(forKey: Key.showsSkylight) as? Bool ?? true
        codexVoice = defaults.string(forKey: Key.codexVoice)
        alphaEnabled = defaults.bool(forKey: Key.alphaEnabled)
        alphaVoiceEnabled = defaults.bool(forKey: Key.alphaVoiceEnabled)
        alphaHydra2Enabled = defaults.bool(forKey: Key.alphaHydra2Enabled)
        externalControlEnabled = defaults.bool(forKey: Key.externalControlEnabled)
        remoteMCPEnabled = defaults.bool(forKey: Key.remoteMCPEnabled)
        remoteMCPPublicURL = defaults.string(forKey: Key.remoteMCPPublicURL) ?? ""
        remoteMCPPort = defaults.integer(forKey: Key.remoteMCPPort)
        remoteMCPFullAccess = defaults.bool(forKey: Key.remoteMCPFullAccess)
        cliInstallationTarget = defaults.string(forKey: Key.cliInstallationTarget)
        backdropOpacity = defaults.object(forKey: Key.backdropOpacity) as? Double ?? Self.defaultBackdropOpacity
        clearerBackdrop = defaults.object(forKey: Key.clearerBackdrop) as? Bool ?? true
        performanceMode = defaults.bool(forKey: Key.performanceMode)
        autoHideTopControls = defaults.bool(forKey: Key.autoHideTopControls)
        // The old System/Light/Dark choice maps straight onto the same themes.
        let initialTheme = AppTheme(rawValue: defaults.string(forKey: Key.appTheme) ?? "")
            ?? AppTheme(rawValue: defaults.string(forKey: Key.appearance) ?? "")
            ?? .breeze
        theme = initialTheme
        ThemeManager.current = initialTheme
        appLanguage = AppLanguage(rawValue: defaults.string(forKey: Key.appLanguage) ?? "") ?? .system
        textGeneration = TextGenerationChoice(rawValue: defaults.string(forKey: Key.textGeneration) ?? "") ?? .automatic
        commitInstructions = defaults.string(forKey: Key.commitInstructions) ?? ""
        terminalHeight = defaults.object(forKey: Key.terminalHeight) as? Double ?? 260
        recentDownloadsPicker = defaults.object(forKey: Key.recentDownloadsPicker) as? Bool ?? true
        if let stored = defaults.string(forKey: Key.lastProjectID) {
            lastProjectID = UUID(uuidString: stored)
        } else {
            lastProjectID = nil
        }
        if let data = defaults.data(forKey: Key.lastThreadAffiliation) {
            lastThreadAffiliation = try? JSONDecoder().decode(ThreadAffiliation.self, from: data)
        } else {
            lastThreadAffiliation = defaults.string(forKey: Key.lastProjectID)
                .flatMap(UUID.init(uuidString:)).map(ThreadAffiliation.project)
        }
        projectsEnabled = defaults.object(forKey: Key.projectsEnabled) as? Bool ?? true
        projectActivationOverrides = Self.load([String: Bool].self, forKey: Key.projectActivationOverrides) ?? [:]
        // Read from the Keychain later (see `loadKeychainInBackground`), not before the first frame.
        deepseekAPIKeyInput = ""
        metaAPIKeyInput = ""
        zaiAPIKeyInput = ""
        commandcodeAPIKeyInput = ""
        binaryPaths = defaults.dictionary(forKey: Key.binaryPaths) as? [String: String] ?? [:]
        disabledProviders = defaults.stringArray(forKey: Key.disabledProviders) ?? []
        unmonitoredProviders = defaults.stringArray(forKey: Key.unmonitoredProviders) ?? []
        showsProviderUsage = defaults.object(forKey: Key.showsProviderUsage) as? Bool ?? true
        lastModels = defaults.dictionary(forKey: Key.models) as? [String: String] ?? [:]
        lastEfforts = defaults.dictionary(forKey: Key.efforts) as? [String: String] ?? [:]
        lastHydraPairID = defaults.string(forKey: Key.lastHydraPair).flatMap(UUID.init(uuidString:))
        modelList = Self.load([ModelPin].self, forKey: Key.modelList) ?? []
        modelPreferences = Self.load([String: ModelPreference].self, forKey: Key.modelPreferences) ?? [:]
        modelSections = Self.load([ModelSection].self, forKey: Key.modelSections) ?? []
        collapsedModelSections = Set((defaults.stringArray(forKey: Key.collapsedModelSections) ?? []).compactMap(UUID.init(uuidString:)))
        lastNewChatModel = Self.load(ModelPin.self, forKey: Key.lastNewChatModel)
        lastNewChatPair = Self.load(HydraPair.self, forKey: Key.lastNewChatPair)
        dismissedModelGroupsTip = defaults.bool(forKey: Key.dismissedModelGroupsTip)
        hidesOutdatedModels = defaults.object(forKey: Key.hidesOutdatedModels) as? Bool ?? true
        hydraEnabled = defaults.object(forKey: Key.hydraEnabled) as? Bool ?? true
        hydraDefaultEnabled = defaults.object(forKey: Key.hydraDefaultEnabled) as? Bool ?? true
        hasSeenHydraIntro = defaults.object(forKey: Key.hasSeenHydraIntro) as? Bool ?? false
        if let stored = defaults.array(forKey: Key.panelSize) as? [Double], stored.count == 2 {
            panelSize = CGSize(width: stored[0], height: stored[1])
        }
        hydraQueueHeads = defaults.object(forKey: Key.hydraQueueHeads) as? Bool ?? true
        hydraAlwaysHeads = defaults.object(forKey: Key.hydraAlwaysHeads) as? Bool ?? false
        hydraTilt = defaults.string(forKey: Key.hydraTilt).flatMap(HydraTilt.init(rawValue:)) ?? .active
        hydraIsolateHeads = defaults.object(forKey: Key.hydraIsolateHeads) as? Bool ?? true
        hydraMaxHeads = HydraPair.clampedCap(defaults.object(forKey: Key.hydraMaxHeads) as? Int)
        hydraAutoMerge = defaults.object(forKey: Key.hydraAutoMerge) as? Bool ?? false
        hydraReviewHeads = defaults.object(forKey: Key.hydraReviewHeads) as? Bool ?? false
        hydraArchivesCodexHeads = defaults.object(forKey: Key.hydraArchivesCodexHeads) as? Bool ?? false
        hydraShowsHeadDetails = defaults.object(forKey: Key.hydraShowsHeadDetails) as? Bool ?? false
        hydraAutoPopsHeads = defaults.object(forKey: Key.hydraAutoPopsHeads) as? Bool ?? false
        hydraTempersHeadEffort = defaults.object(forKey: Key.hydraTempersHeadEffort) as? Bool ?? true
        if let stored = defaults.array(forKey: Key.sidebarPanelOrigin) as? [Double], stored.count == 2 {
            sidebarPanelOrigin = CGPoint(x: stored[0], y: stored[1])
        } else {
            sidebarPanelOrigin = nil
        }
        if let stored = defaults.array(forKey: Key.sidebarPanelSize) as? [Double], stored.count == 2 {
            sidebarPanelSize = CGSize(width: stored[0], height: stored[1])
        } else {
            sidebarPanelSize = nil
        }
        hydraPairs = Self.load([Lenient<HydraPair>].self, forKey: Key.hydraPairs)?.compactMap(\.value) ?? []
        // The window zoom is gone. Drop a stored percent instead of turning it into a font size.
        defaults.removeObject(forKey: "appZoom")
        TypeScale.shared.ui = uiFontSize
        TypeScale.shared.content = contentFontSize
        TypeScale.shared.code = codeFontSize
        migrateOpenCodeGo()
    }

    private func migrateOpenCodeGo() {
        // A second pass would re-enable OpenCode when both old entries were disabled.
        guard !defaults.bool(forKey: Key.openCodeProviderMigrated) else { return }
        let legacy = "opencodeGo"
        let current = ProviderKind.opencode.rawValue
        let goDisabled = disabledProviders.contains(legacy)
        disabledProviders.removeAll { $0 == legacy || (!goDisabled && $0 == current) }
        let goUnmonitored = unmonitoredProviders.contains(legacy)
        unmonitoredProviders.removeAll { $0 == legacy || (!goUnmonitored && $0 == current) }
        if let value = binaryPaths[legacy] {
            if binaryPaths[current]?.isEmpty ?? true { binaryPaths[current] = value }
            binaryPaths[legacy] = nil
        }
        if let value = lastModels[legacy] {
            if lastModels[current]?.isEmpty ?? true { lastModels[current] = value }
            lastModels[legacy] = nil
        }
        if let value = lastEfforts[legacy] {
            if lastEfforts[current]?.isEmpty ?? true { lastEfforts[current] = value }
            lastEfforts[legacy] = nil
        }
        // Effort and speed choices are keyed `provider/modelID`; Go's keep working under OpenCode.
        let legacyPrefix = legacy + "/"
        if modelPreferences.keys.contains(where: { $0.hasPrefix(legacyPrefix) }) {
            var preferences = modelPreferences
            for (key, value) in modelPreferences where key.hasPrefix(legacyPrefix) {
                preferences[key] = nil
                let moved = current + "/" + key.dropFirst(legacyPrefix.count)
                if preferences[moved] == nil { preferences[moved] = value }
            }
            modelPreferences = preferences
        }
        defaults.set(true, forKey: Key.openCodeProviderMigrated)
    }

    /// A stored size outside its range is written back clamped. A missing key stays missing
    /// and comes back as the default size.
    private static func clampedFontSize(_ defaults: UserDefaults, key: String, stock: Int, range: ClosedRange<Int>) -> Int {
        let raw = defaults.object(forKey: key) as? Int ?? stock
        let clamped = TypeScale.clamp(raw, to: range)
        if clamped != raw { defaults.set(clamped, forKey: key) }
        return clamped
    }

    // MARK: - Hydra pairs

    func addHydraPair(_ pair: HydraPair) {
        hydraPairs.append(pair)
    }

    func updateHydraPair(_ id: UUID, _ change: (inout HydraPair) -> Void) {
        guard let index = hydraPairs.firstIndex(where: { $0.id == id }) else { return }
        var pair = hydraPairs[index]
        change(&pair)
        pair.maxHeads = HydraPair.clampedCap(pair.maxHeads)
        guard pair != hydraPairs[index] else { return }
        hydraPairs[index] = pair
    }

    func removeHydraPair(_ id: UUID) {
        hydraPairs.removeAll { $0.id == id }
    }

    /// Moves a pair to sit right before or after another; returns whether the list changed.
    /// A missing id, or a pair moved onto itself, leaves the list and every pair as they are.
    @discardableResult
    func moveHydraPair(_ id: UUID, to neighbourID: UUID, placeAfter: Bool) -> Bool {
        guard id != neighbourID,
              let from = hydraPairs.firstIndex(where: { $0.id == id }),
              let to = hydraPairs.firstIndex(where: { $0.id == neighbourID }) else { return false }
        var dest = to + (placeAfter ? 1 : 0)
        if from < dest { dest -= 1 }
        guard from != dest else { return false }
        var reordered = hydraPairs
        let moved = reordered.remove(at: from)
        reordered.insert(moved, at: dest)
        hydraPairs = reordered
        return true
    }

    func hydraPair(_ id: UUID?) -> HydraPair? {
        guard let id else { return nil }
        return hydraPairs.first { $0.id == id }
    }

    /// The pair a chat leads with: the one for its provider whose lead model is the chat's,
    /// else one for any model on the provider, else the provider's first pair.
    func hydraPair(for provider: ProviderKind, model: String?) -> HydraPair? {
        let candidates = hydraPairs.filter { $0.provider == provider }
        if let model, let exact = candidates.first(where: { $0.orchestratorModel == model }) { return exact }
        if let any = candidates.first(where: { $0.orchestratorModel == nil }) { return any }
        return candidates.first
    }

    // MARK: - Model picker

    func addToModelList(_ pin: ModelPin) {
        guard !modelList.contains(pin), modelList.count < Self.modelListLimit else { return }
        modelList.append(pin)
    }

    func removeFromModelList(_ pin: ModelPin) {
        setModelListItems(modelListItems.filter { $0 != .pin(pin) })
        if lastNewChatModel == pin { lastNewChatModel = nil }
    }

    /// Moves `pin` to sit right before or after `target`; returns whether the list changed.
    @discardableResult
    func moveModel(_ pin: ModelPin, to target: ModelPin, placeAfter: Bool) -> Bool {
        moveModelListItem(.pin(pin), to: .pin(target), placeAfter: placeAfter)
    }

    /// The pins and headings in the order Settings shows them.
    var modelListItems: [ModelListItem] {
        var items: [ModelListItem] = []
        let sections = modelSections.enumerated().sorted { ($0.element.position, $0.offset) < ($1.element.position, $1.offset) }.map(\.element)
        var next = sections.makeIterator()
        var pending = next.next()
        for (index, pin) in modelList.enumerated() {
            while let section = pending, section.position <= index {
                items.append(.section(section))
                pending = next.next()
            }
            items.append(.pin(pin))
        }
        while let section = pending {
            items.append(.section(section))
            pending = next.next()
        }
        return items
    }

    /// Splits `items` back into `modelList` and the headings' positions.
    private func setModelListItems(_ items: [ModelListItem]) {
        var pins: [ModelPin] = []
        var sections: [ModelSection] = []
        for item in items {
            switch item {
            case .pin(let pin): pins.append(pin)
            case .section(var section):
                section.position = pins.count
                sections.append(section)
            }
        }
        if pins != modelList { modelList = pins }
        if sections != modelSections { modelSections = sections }
    }

    /// Moves a pin or a heading to sit right before or after another row; returns whether the list changed.
    @discardableResult
    func moveModelListItem(_ item: ModelListItem, to target: ModelListItem, placeAfter: Bool) -> Bool {
        var items = modelListItems
        guard item.id != target.id,
              let from = items.firstIndex(where: { $0.id == item.id }),
              let to = items.firstIndex(where: { $0.id == target.id }) else { return false }
        var dest = to + (placeAfter ? 1 : 0)
        if from < dest { dest -= 1 }
        guard from != dest else { return false }
        let moved = items.remove(at: from)
        items.insert(moved, at: dest)
        setModelListItems(items)
        return true
    }

    /// Moves `pin` into the group `sectionID` (nil: the ungrouped models at the top), right
    /// before `before` when that model is in the group, else at the group's end.
    func moveModel(_ pin: ModelPin, toSection sectionID: UUID?, before: ModelPin? = nil) {
        var items = modelListItems.filter { $0 != .pin(pin) }
        let start = sectionID.flatMap { id in items.firstIndex { if case .section(let s) = $0 { s.id == id } else { false } } }
        if sectionID != nil, start == nil { return }
        let afterStart = start.map { $0 + 1 } ?? 0
        let end = items[afterStart...].firstIndex { if case .section = $0 { true } else { false } } ?? items.count
        let slot = before.flatMap { target in items[afterStart..<end].firstIndex(of: .pin(target)) } ?? end
        items.insert(.pin(pin), at: slot)
        setModelListItems(items)
    }

    /// Moves the group `id`, with its models, one group up (`offset` -1) or down (+1).
    /// The ungrouped models always stay on top.
    func moveModelSection(_ id: UUID, by offset: Int) {
        let items = modelListItems
        var head: [ModelListItem] = []
        var blocks: [[ModelListItem]] = []
        for item in items {
            if case .section = item { blocks.append([item]) } else if blocks.isEmpty { head.append(item) } else { blocks[blocks.count - 1].append(item) }
        }
        guard let from = blocks.firstIndex(where: { $0.first?.id == "section/\(id.uuidString)" }),
              blocks.indices.contains(from + offset) else { return }
        blocks.swapAt(from, from + offset)
        setModelListItems(head + blocks.flatMap { $0 })
    }

    /// Adds a heading at the end of the list, where the next models added fall under it.
    @discardableResult
    func addModelSection(named name: String) -> UUID {
        let section = ModelSection(name: name, position: modelList.count)
        modelSections.append(section)
        return section.id
    }

    func renameModelSection(_ id: UUID, to name: String) {
        guard let index = modelSections.firstIndex(where: { $0.id == id }) else { return }
        modelSections[index].name = name
    }

    /// Takes the heading away; its models join the heading above, or the top of the list.
    func removeModelSection(_ id: UUID) {
        modelSections.removeAll { $0.id == id }
        collapsedModelSections.remove(id)
    }

    func isModelSectionCollapsed(_ id: UUID) -> Bool {
        collapsedModelSections.contains(id)
    }

    func toggleModelSectionCollapsed(_ id: UUID) {
        if collapsedModelSections.remove(id) == nil { collapsedModelSections.insert(id) }
    }

    func noteNewChatChoice(_ choice: NewChatChoice) {
        switch choice {
        case .model(let pin): if lastNewChatModel != pin { lastNewChatModel = pin }
        case .pair(let pair): if lastNewChatPair != pair { lastNewChatPair = pair }
        }
    }

    func preference(for provider: ProviderKind, model: String?) -> ModelPreference {
        guard let model else { return ModelPreference() }
        return modelPreferences[ModelPin(provider: provider, modelID: model).id] ?? ModelPreference()
    }

    func setPreference(_ preference: ModelPreference, for provider: ProviderKind, model: String) {
        let key = ModelPin(provider: provider, modelID: model).id
        modelPreferences[key] = preference == ModelPreference() ? nil : preference
    }

    func adoptModelFamilies(_ families: [ModelOption], for provider: ProviderKind) {
        if provider == .dsh {
            adoptDshModels(families)
            return
        }
        var owners: [String: (family: ModelOption, variant: ModelVariant)] = [:]
        for family in families {
            for variant in family.variants where variant.id != family.id { owners[variant.id] = (family, variant) }
        }
        guard !owners.isEmpty else { return }
        var list: [ModelListItem] = []
        var preferences = modelPreferences
        for item in modelListItems {
            guard case .pin(let pin) = item else {
                list.append(item)
                continue
            }
            guard pin.provider == provider, let owner = owners[pin.modelID] else {
                if !list.contains(item) { list.append(item) }
                continue
            }
            let adopted = ModelPin(provider: provider, modelID: owner.family.id)
            if !list.contains(.pin(adopted)) { list.append(.pin(adopted)) }
            // The variant's own effort and speed become the row's preference, unless the
            // row already has one; a preference set on the variant wins over its name.
            let old = preferences.removeValue(forKey: pin.id)
            if preferences[adopted.id] == nil {
                var preference = old ?? ModelPreference()
                if preference.effort == nil { preference.effort = owner.variant.effort }
                preference.fastMode = preference.fastMode || owner.variant.isFast
                preferences[adopted.id] = preference == ModelPreference() ? nil : preference
            }
        }
        setModelListItems(list)
        if preferences != modelPreferences { modelPreferences = preferences }
        if let last = lastModels[provider.rawValue], let owner = owners[last] {
            lastModels[provider.rawValue] = owner.family.id
            if lastEfforts[provider.rawValue] == nil { lastEfforts[provider.rawValue] = owner.variant.effort }
        }
    }

    private func adoptDshModels(_ models: [ModelOption]) {
        func resolved(_ pin: ModelPin) -> ModelPin {
            guard pin.provider == .dsh else { return pin }
            return ModelPin(provider: .dsh, modelID: DshCLI.resolvedModelID(pin.modelID, in: models))
        }
        var items: [ModelListItem] = []
        for item in modelListItems {
            let adopted: ModelListItem = if case .pin(let pin) = item { .pin(resolved(pin)) } else { item }
            if !items.contains(adopted) { items.append(adopted) }
        }
        setModelListItems(items)
        var preferences = modelPreferences
        for (key, preference) in modelPreferences where key.hasPrefix("dsh/") {
            let pin = ModelPin(provider: .dsh, modelID: String(key.dropFirst("dsh/".count)))
            let adopted = resolved(pin)
            guard adopted != pin else { continue }
            preferences.removeValue(forKey: key)
            if preferences[adopted.id] == nil { preferences[adopted.id] = preference }
        }
        if preferences != modelPreferences { modelPreferences = preferences }
        if let last = lastModels[ProviderKind.dsh.rawValue] {
            let adopted = DshCLI.resolvedModelID(last, in: models)
            if adopted != last { lastModels[ProviderKind.dsh.rawValue] = adopted }
        }
        if let pin = lastNewChatModel, resolved(pin) != pin { lastNewChatModel = resolved(pin) }
        func resolvedPair(_ pair: HydraPair) -> HydraPair {
            var pair = pair
            if pair.provider == .dsh, let model = pair.orchestratorModel {
                pair.orchestratorModel = DshCLI.resolvedModelID(model, in: models)
            }
            if pair.headsProvider == .dsh, let model = pair.workerModel {
                pair.workerModel = DshCLI.resolvedModelID(model, in: models)
            }
            return pair
        }
        let pairs = hydraPairs.map(resolvedPair)
        if pairs != hydraPairs { hydraPairs = pairs }
        if let pair = lastNewChatPair, resolvedPair(pair) != pair { lastNewChatPair = resolvedPair(pair) }
    }

    private func store<Value: Encodable>(_ value: Value, forKey key: String) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }

    private static func load<Value: Decodable>(_ type: Value.Type, forKey key: String) -> Value? {
        guard let data = (CaptureRun.defaults ?? .standard).data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    func binaryPath(for provider: ProviderKind) -> String {
        binaryPaths[provider.rawValue] ?? ""
    }

    func setBinaryPath(_ path: String, for provider: ProviderKind) {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        binaryPaths[provider.rawValue] = trimmed.isEmpty ? nil : trimmed
    }

    func isEnabled(_ provider: ProviderKind) -> Bool {
        !disabledProviders.contains(provider.rawValue)
    }

    func setEnabled(_ enabled: Bool, for provider: ProviderKind) {
        disabledProviders.removeAll { $0 == provider.rawValue }
        if !enabled { disabledProviders.append(provider.rawValue) }
    }

    func monitorsUpdates(_ provider: ProviderKind) -> Bool {
        !unmonitoredProviders.contains(provider.rawValue)
    }

    func setMonitorsUpdates(_ monitors: Bool, for provider: ProviderKind) {
        unmonitoredProviders.removeAll { $0 == provider.rawValue }
        if !monitors { unmonitoredProviders.append(provider.rawValue) }
    }

    func lastModel(for provider: ProviderKind) -> String? {
        lastModels[provider.rawValue]
    }

    func lastEffort(for provider: ProviderKind) -> String? {
        lastEfforts[provider.rawValue]
    }

    func remember(model: String?, effort: String?, for provider: ProviderKind) {
        lastModels[provider.rawValue] = model
        lastEfforts[provider.rawValue] = effort
    }

    /// The API key Tivano sends to an API-key provider: the value from Settings,
    /// falling back to the provider's env var from the login environment
    /// (`DEEPSEEK_API_KEY` for DeepSeek, `MODEL_API_KEY` for Meta). Command Code's is
    /// optional: the CLI's own `cmd login` serves when it is empty.
    func apiKey(for provider: ProviderKind) -> String {
        readKeychainIfNeeded()
        let stored: String = switch provider {
        case .deepseek: deepseekAPIKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        case .meta: metaAPIKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        case .zai: zaiAPIKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        case .commandcode: commandcodeAPIKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        default: ""
        }
        if !stored.isEmpty { return stored }
        guard provider.acceptsAPIKey, let envVar = provider.apiKeyEnvVar else { return "" }
        return (LoginEnvironment.current[envVar] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func apiKeySource(for provider: ProviderKind) -> APIKeySource {
        if !apiKeyInput(for: provider).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .settings
        }
        if provider.acceptsAPIKey, let name = provider.apiKeyEnvVar,
           !(LoginEnvironment.current[name] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .environment(name)
        }
        return .none
    }

    func hasAPIKey(for provider: ProviderKind) -> Bool {
        !apiKey(for: provider).isEmpty
    }

    /// Settings-bound value for the Providers page, per API-key provider.
    func apiKeyInput(for provider: ProviderKind) -> String {
        readKeychainIfNeeded()
        return switch provider {
        case .deepseek: deepseekAPIKeyInput
        case .meta: metaAPIKeyInput
        case .zai: zaiAPIKeyInput
        case .commandcode: commandcodeAPIKeyInput
        default: ""
        }
    }

    func setAPIKeyInput(_ value: String, for provider: ProviderKind) {
        readKeychainIfNeeded()
        switch provider {
        case .commandcode: commandcodeAPIKeyInput = value
        case .deepseek: deepseekAPIKeyInput = value
        case .meta: metaAPIKeyInput = value
        case .zai: zaiAPIKeyInput = value
        default: break
        }
    }
}

/// The registry's view of the settings; the methods are the ones above.
extension AppSettings: ProviderSettings {}
