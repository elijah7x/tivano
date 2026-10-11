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

/// What the check on a thread row does once you are done with the thread.
enum ThreadFinishAction: String, CaseIterable, Identifiable {
    /// The thread stays in the sidebar, small and grey at the bottom of its list.
    case settle
    /// The thread leaves the sidebar for the Archive page.
    case archive

    var id: String { rawValue }

    var title: String {
        switch self {
        case .settle: "Settle"
        case .archive: "Archive"
        }
    }

    var detail: String {
        switch self {
        case .settle: "A settled thread drops to the bottom of the sidebar, small and grey, until you reopen it"
        case .archive: "An archived thread leaves the sidebar for the Archive page"
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

/// A model the composer's picker offers.
struct ModelPin: Codable, Hashable, Identifiable, Sendable {
    var provider: ProviderKind
    var modelID: String

    var id: String { "\(provider.rawValue)/\(modelID)" }
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
        static let notify = "notifyWhenFinished"
        static let chime = "chimeWhenFinished"
        static let confirmDelete = "confirmBeforeDeleting"
        static let autoContinueAfterLimit = "autoContinueAfterLimit"
        static let threadFinishAction = "threadFinishAction"
        static let settleSound = "settleSound"
        static let showReasoning = "showReasoning"
        static let antiSlopEnabled = "antiSlopEnabled"
        static let showsWorkingCard = "showsWorkingCard"
        static let timelineHapticStyle = "timelineHapticStyle"
        static let uiFontSize = "uiFontSize"
        static let contentFontSize = "contentFontSize"
        static let codeFontSize = "codeFontSize"
        static let sidebarActivityView = "sidebarActivityView"
        static let settledCollapsed = "settledSectionCollapsed"
        static let appTheme = "appTheme"
        static let backdropOpacity = "backdropOpacity"
        static let appearance = "appearance"
        static let performanceMode = "performanceMode"
        static let autoHideTopControls = "autoHideTopControls"
        static let binaryPaths = "providerBinaryPaths"
        static let disabledProviders = "disabledProviders"
        static let unmonitoredProviders = "unmonitoredProviderUpdates"
        static let models = "lastModels"
        static let efforts = "lastEfforts"
        static let lastHydraPair = "lastHydraPairID"
        static let textGeneration = "textGeneration"
        static let preventSleepDuringTasks = "preventSleepDuringTasks"
        static let appLanguage = "appLanguage"
        static let commitInstructions = "commitInstructions"
        static let terminalHeight = "terminalHeight"
        static let modelList = "modelList"
        static let modelPreferences = "modelPreferences"
        static let recentDownloadsPicker = "recentDownloadsPicker"
        static let lastProjectID = "lastProjectID"
        static let projectsEnabled = "projectsEnabled"
        static let projectActivationOverrides = "projectActivationOverrides"
        static let deepseekAPIKey = "deepseekAPIKey"
        static let metaAPIKey = "metaAPIKey"
        static let zaiAPIKey = "zaiAPIKey"
        static let commandcodeAPIKey = "commandcodeAPIKey"
        static let hydraEnabled = "hydraEnabled"
        static let panelSize = "floatingPanelSize"
        static let hydraDefaultEnabled = AppSettings.hydraDefaultEnabledKey
        static let hydraQueueHeads = "hydraQueueHeads"
        static let hydraAlwaysHeads = "hydraAlwaysHeads"
        static let hydraIsolateHeads = "hydraIsolateHeads"
        static let hydraAutoMerge = "hydraAutoMerge"
        static let hydraReviewHeads = "hydraReviewHeads"
        static let hydraAutoClearFinished = "hydraAutoClearFinished"
        static let hydraAutoHidesIdleHeads = "hydraAutoHidesIdleHeads"
        static let hydraArchivesCodexHeads = "hydraArchivesCodexHeads"
        static let hydraShowsHeadDetails = "hydraShowsHeadDetails"
        static let hydraAutoPopsHeads = "hydraAutoPopsHeads"
        static let hydraTempersHeadEffort = "hydraTempersHeadEffort"
        static let hydraMaxHeads = "hydraMaxHeads"
        static let showsUsagePanel = "showsUsagePanel"
        static let sidebarPanelOrigin = "sidebarPanelOrigin"
        static let sidebarPanelSize = "sidebarPanelSize"
        static let usagePanelDock = "usagePanelDock"
        static let usagePanelHeight = "usagePanelHeight"
        static let hydraPairs = "hydraPairs"
        static let hasSeenHydraIntro = "hasSeenHydraIntro"
    }

    static let modelListLimit = 15

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

    var notifyWhenFinished: Bool {
        didSet { defaults.set(notifyWhenFinished, forKey: Key.notify) }
    }

    /// A soft chime plays when a turn finishes, whether or not the thread is in view.
    var chimeWhenFinished: Bool {
        didSet { defaults.set(chimeWhenFinished, forKey: Key.chime) }
    }

    @ObservationIgnored var onSleepPreventionChanged: (() -> Void)?

    var preventSleepDuringTasks: Bool {
        didSet {
            defaults.set(preventSleepDuringTasks, forKey: Key.preventSleepDuringTasks)
            onSleepPreventionChanged?()
        }
    }

    var confirmBeforeDeleting: Bool {
        didSet { defaults.set(confirmBeforeDeleting, forKey: Key.confirmDelete) }
    }

    /// A turn that stops on the provider's usage limit is picked back up by itself: the chat
    /// waits for the limit to reset, then tells the agent to continue where it left off.
    var autoContinueAfterLimit: Bool {
        didSet { defaults.set(autoContinueAfterLimit, forKey: Key.autoContinueAfterLimit) }
    }

    /// What the check on a thread row, ⇧⌘⌫ and the palette's finish action do.
    var threadFinishAction: ThreadFinishAction {
        didSet { defaults.set(threadFinishAction.rawValue, forKey: Key.threadFinishAction) }
    }

    /// A soft note plays as a thread settles.
    var settleSound: Bool {
        didSet { defaults.set(settleSound, forKey: Key.settleSound) }
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
        uiFontSize == TypeScale.stockUI
            && contentFontSize == TypeScale.defaultContent
            && codeFontSize == TypeScale.stockCode
    }

    func resetFontSizes() {
        uiFontSize = TypeScale.stockUI
        contentFontSize = TypeScale.defaultContent
        codeFontSize = TypeScale.stockCode
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

    /// The sidebar lists every thread by when it was last active, instead of by project.
    var sidebarActivityView: Bool {
        didSet { defaults.set(sidebarActivityView, forKey: Key.sidebarActivityView) }
    }

    /// The activity list always shows the project's name under the thread title.
    let activityThreadStyle: ActivityThreadStyle = .projectName

    /// The sidebar's Settled section is folded away. Expanded by default.
    var settledCollapsed: Bool {
        didSet { defaults.set(settledCollapsed, forKey: Key.settledCollapsed) }
    }

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

    /// Disables window transparency, blurs, glows and background effects for lowest GPU usage.
    var performanceMode: Bool {
        didSet { defaults.set(performanceMode, forKey: Key.performanceMode) }
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
        projectActivationOverrides[id.uuidString] ?? projectsEnabled
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
    /// Stored in the Keychain when available, with a UserDefaults fallback for migration.
    /// Read once, on the first ask, and cached: a Keychain query on every render made
    /// Settings lag, and two of them before the window exists made launch wait on securityd.
    var deepseekAPIKeyInput: String {
        didSet {
            storeAPIKeyChange(deepseekAPIKeyInput, from: oldValue, provider: .deepseek, fallbackKey: Key.deepseekAPIKey)
        }
    }

    /// Meta Model API (Muse Spark) talks to https://api.meta.ai/v1 directly,
    /// so it needs a MODEL_API_KEY instead of a CLI login.
    /// Stored in the Keychain when available, with a UserDefaults fallback for migration.
    var metaAPIKeyInput: String {
        didSet {
            storeAPIKeyChange(metaAPIKeyInput, from: oldValue, provider: .meta, fallbackKey: Key.metaAPIKey)
        }
    }

    /// Z.ai's GLM Coding Plan talks to https://api.z.ai/api/coding/paas/v4 directly,
    /// so it needs a ZAI_API_KEY instead of a CLI login.
    /// Stored in the Keychain when available, with a UserDefaults fallback for migration.
    /// Read once, on the first ask, and cached: a Keychain query on every render made
    /// Settings lag, and two of them before the window exists made launch wait on securityd.
    var zaiAPIKeyInput: String {
        didSet {
            storeAPIKeyChange(zaiAPIKeyInput, from: oldValue, provider: .zai, fallbackKey: Key.zaiAPIKey)
        }
    }

    /// Command Code signs in with `cmd login`; a Studio API key here is the alternative,
    /// handed to the CLI as `COMMAND_CODE_API_KEY`. Stored in the Keychain when available,
    /// with a UserDefaults fallback for a Mac whose Keychain refused it.
    var commandcodeAPIKeyInput: String {
        didSet {
            storeAPIKeyChange(commandcodeAPIKeyInput, from: oldValue, provider: .commandcode, fallbackKey: Key.commandcodeAPIKey)
        }
    }

    @ObservationIgnored private var didReadKeychain = false
    @ObservationIgnored private var isReadingKeychain = false

    /// One provider's key as read: the Keychain's, or the plaintext copy in the defaults
    /// for a Mac whose Keychain refused it.
    private struct StoredKey: Sendable {
        var value: String
        var inKeychain: Bool

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

    /// One Keychain round trip per key.
    private nonisolated static func readKeys(fallbacks: (deepseek: String, meta: String, zai: String, commandcode: String)) -> StoredKeys {
        StoredKeys(
            deepseek: storedKey(for: .deepseek, fallback: fallbacks.deepseek),
            meta: storedKey(for: .meta, fallback: fallbacks.meta),
            zai: storedKey(for: .zai, fallback: fallbacks.zai),
            commandcode: storedKey(for: .commandcode, fallback: fallbacks.commandcode)
        )
    }

    private nonisolated static func storedKey(for provider: ProviderKind, fallback: String) -> StoredKey {
        StoredKey(keychain: APIKeychain.key(for: provider, fallback: ""), fallback: fallback)
    }

    /// The stored keys, from the Keychain the first time anything asks for one. The fill
    /// bypasses the observers above, which write keys back to the Keychain and the
    /// fallback: the fallback must never receive a key it did not already hold.
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
        // Earlier builds kept a plaintext copy of every key in the defaults; one the
        // Keychain holds needs none.
        if keys.deepseek.inKeychain { defaults.removeObject(forKey: Key.deepseekAPIKey) }
        if keys.meta.inKeychain { defaults.removeObject(forKey: Key.metaAPIKey) }
        if keys.zai.inKeychain { defaults.removeObject(forKey: Key.zaiAPIKey) }
        if keys.commandcode.inKeychain { defaults.removeObject(forKey: Key.commandcodeAPIKey) }
    }

    /// One provider key changed: hand it to the Keychain and keep a plaintext copy in
    /// the defaults only for a Mac whose Keychain refused it.
    private func storeAPIKeyChange(_ value: String, from oldValue: String, provider: ProviderKind, fallbackKey: String) {
        guard !isReadingKeychain, value != oldValue else { return }
        let kept = APIKeychain.setKey(value, for: provider)
        storeAPIKeyFallback(kept ? "" : value, forKey: fallbackKey)
    }

    /// The plaintext copy in defaults, for a Mac whose Keychain refused the key; an empty
    /// value removes it, so a key the Keychain holds never sits in the defaults too.
    private func storeAPIKeyFallback(_ value: String, forKey key: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            defaults.removeObject(forKey: key)
        } else {
            defaults.set(trimmed, forKey: key)
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

    /// A head that finishes leaves the Hydra panel on its own, for the sidebar under its
    /// lead, instead of waiting for "Clear finished heads".
    var hydraAutoClearFinished: Bool {
        didSet { defaults.set(hydraAutoClearFinished, forKey: Key.hydraAutoClearFinished) }
    }

    /// Finished heads leave the sidebar with their card: a chat's heads show there while one
    /// of them runs, and the card goes once every head of that chat has finished. Off by
    /// default, so the heads stay in the sidebar until it is asked for.
    var hydraAutoHidesIdleHeads: Bool {
        didSet { defaults.set(hydraAutoHidesIdleHeads, forKey: Key.hydraAutoHidesIdleHeads) }
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

    /// A floating panel with the chat's usage, the plan's limits and credits, beside
    /// every chat for as long as it is on: the General setting, the popover's pop-out
    /// button and the panel's own close button all set it, so it stays across threads
    /// and relaunches.
    var showsUsagePanel: Bool {
        didSet { defaults.set(showsUsagePanel, forKey: Key.showsUsagePanel) }
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

    /// The corner the usage panel is docked in, for every chat; it goes where it was
    /// last dragged.
    var usagePanelDock: PanelDockCorner {
        didSet { defaults.set(usagePanelDock.rawValue, forKey: Key.usagePanelDock) }
    }

    /// The height the usage panel was dragged to, for every chat; nil fits the panel to its rows.
    var usagePanelHeight: CGFloat? {
        didSet {
            if let usagePanelHeight {
                defaults.set(Double(usagePanelHeight), forKey: Key.usagePanelHeight)
            } else {
                defaults.removeObject(forKey: Key.usagePanelHeight)
            }
        }
    }

    /// The lead-and-heads pairings, in the order they were added.
    private(set) var hydraPairs: [HydraPair] {
        didSet { store(hydraPairs, forKey: Key.hydraPairs) }
    }

    init() {
        let defaults = CaptureRun.defaults ?? .standard
        defaultProvider = ProviderKind(rawValue: defaults.string(forKey: Key.defaultProvider) ?? "") ?? .codex
        defaultRuntimeMode = RuntimeMode(rawValue: defaults.string(forKey: Key.runtimeMode) ?? "") ?? .fullAccess
        defaultWorkspaceMode = WorkspaceMode(rawValue: defaults.string(forKey: Key.workspaceMode) ?? "") ?? .local
        notifyWhenFinished = defaults.object(forKey: Key.notify) as? Bool ?? true
        chimeWhenFinished = defaults.object(forKey: Key.chime) as? Bool ?? true
        preventSleepDuringTasks = defaults.object(forKey: Key.preventSleepDuringTasks) as? Bool ?? true
        confirmBeforeDeleting = defaults.object(forKey: Key.confirmDelete) as? Bool ?? true
        autoContinueAfterLimit = defaults.object(forKey: Key.autoContinueAfterLimit) as? Bool ?? false
        threadFinishAction = ThreadFinishAction(rawValue: defaults.string(forKey: Key.threadFinishAction) ?? "") ?? .settle
        settleSound = defaults.object(forKey: Key.settleSound) as? Bool ?? true
        showReasoning = defaults.object(forKey: Key.showReasoning) as? Bool ?? false
        antiSlopEnabled = defaults.object(forKey: Key.antiSlopEnabled) as? Bool ?? true
        showsWorkingCard = defaults.object(forKey: Key.showsWorkingCard) as? Bool ?? true
        timelineHapticStyle = TimelineHapticStyle(rawValue: defaults.string(forKey: Key.timelineHapticStyle) ?? "") ?? .soft
        uiFontSize = Self.clampedFontSize(defaults, key: Key.uiFontSize, stock: TypeScale.stockUI, range: TypeScale.uiRange)
        contentFontSize = Self.clampedFontSize(defaults, key: Key.contentFontSize, stock: TypeScale.defaultContent, range: TypeScale.contentRange)
        codeFontSize = Self.clampedFontSize(defaults, key: Key.codeFontSize, stock: TypeScale.stockCode, range: TypeScale.codeRange)
        sidebarActivityView = defaults.bool(forKey: Key.sidebarActivityView)
        settledCollapsed = defaults.object(forKey: Key.settledCollapsed) as? Bool ?? true
        backdropOpacity = defaults.object(forKey: Key.backdropOpacity) as? Double ?? Self.defaultBackdropOpacity
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
        lastModels = defaults.dictionary(forKey: Key.models) as? [String: String] ?? [:]
        lastEfforts = defaults.dictionary(forKey: Key.efforts) as? [String: String] ?? [:]
        lastHydraPairID = defaults.string(forKey: Key.lastHydraPair).flatMap(UUID.init(uuidString:))
        modelList = Self.load([ModelPin].self, forKey: Key.modelList) ?? []
        modelPreferences = Self.load([String: ModelPreference].self, forKey: Key.modelPreferences) ?? [:]
        hydraEnabled = defaults.object(forKey: Key.hydraEnabled) as? Bool ?? true
        hydraDefaultEnabled = defaults.object(forKey: Key.hydraDefaultEnabled) as? Bool ?? true
        hasSeenHydraIntro = defaults.object(forKey: Key.hasSeenHydraIntro) as? Bool ?? false
        if let stored = defaults.array(forKey: Key.panelSize) as? [Double], stored.count == 2 {
            panelSize = CGSize(width: stored[0], height: stored[1])
        }
        hydraQueueHeads = defaults.object(forKey: Key.hydraQueueHeads) as? Bool ?? true
        hydraAlwaysHeads = defaults.object(forKey: Key.hydraAlwaysHeads) as? Bool ?? false
        hydraIsolateHeads = defaults.object(forKey: Key.hydraIsolateHeads) as? Bool ?? true
        hydraMaxHeads = HydraPair.clampedCap(defaults.object(forKey: Key.hydraMaxHeads) as? Int)
        hydraAutoMerge = defaults.object(forKey: Key.hydraAutoMerge) as? Bool ?? false
        hydraReviewHeads = defaults.object(forKey: Key.hydraReviewHeads) as? Bool ?? false
        hydraAutoClearFinished = defaults.object(forKey: Key.hydraAutoClearFinished) as? Bool ?? false
        hydraAutoHidesIdleHeads = defaults.object(forKey: Key.hydraAutoHidesIdleHeads) as? Bool ?? false
        hydraArchivesCodexHeads = defaults.object(forKey: Key.hydraArchivesCodexHeads) as? Bool ?? false
        hydraShowsHeadDetails = defaults.object(forKey: Key.hydraShowsHeadDetails) as? Bool ?? false
        hydraAutoPopsHeads = defaults.object(forKey: Key.hydraAutoPopsHeads) as? Bool ?? false
        hydraTempersHeadEffort = defaults.object(forKey: Key.hydraTempersHeadEffort) as? Bool ?? true
        showsUsagePanel = defaults.object(forKey: Key.showsUsagePanel) as? Bool ?? false
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
        usagePanelDock = defaults.string(forKey: Key.usagePanelDock).flatMap(PanelDockCorner.init(rawValue:)) ?? .bottomLeading
        usagePanelHeight = defaults.object(forKey: Key.usagePanelHeight).flatMap { $0 as? Double }.map { CGFloat($0) }
        hydraPairs = Self.load([Lenient<HydraPair>].self, forKey: Key.hydraPairs)?.compactMap(\.value) ?? []
        // The window zoom is gone. Drop a stored percent instead of turning it into a font size.
        defaults.removeObject(forKey: "appZoom")
        TypeScale.shared.ui = uiFontSize
        TypeScale.shared.content = contentFontSize
        TypeScale.shared.code = codeFontSize
    }

    /// A stored size outside its range is written back clamped. A missing key stays missing
    /// and comes back as the stock size.
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
        modelList.removeAll { $0 == pin }
    }

    /// Moves `pin` to sit right before or after `target`; returns whether the list changed.
    @discardableResult
    func moveModel(_ pin: ModelPin, to target: ModelPin, placeAfter: Bool) -> Bool {
        guard pin != target,
              let from = modelList.firstIndex(of: pin),
              let to = modelList.firstIndex(of: target) else { return false }
        var dest = to + (placeAfter ? 1 : 0)
        if from < dest { dest -= 1 }
        guard from != dest else { return false }
        let moved = modelList.remove(at: from)
        modelList.insert(moved, at: dest)
        return true
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
        var owners: [String: (family: ModelOption, variant: ModelVariant)] = [:]
        for family in families {
            for variant in family.variants where variant.id != family.id { owners[variant.id] = (family, variant) }
        }
        guard !owners.isEmpty else { return }
        var list: [ModelPin] = []
        var preferences = modelPreferences
        for pin in modelList {
            guard pin.provider == provider, let owner = owners[pin.modelID] else {
                if !list.contains(pin) { list.append(pin) }
                continue
            }
            let adopted = ModelPin(provider: provider, modelID: owner.family.id)
            if !list.contains(adopted) { list.append(adopted) }
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
        if list != modelList { modelList = list }
        if preferences != modelPreferences { modelPreferences = preferences }
        if let last = lastModels[provider.rawValue], let owner = owners[last] {
            lastModels[provider.rawValue] = owner.family.id
            if lastEfforts[provider.rawValue] == nil { lastEfforts[provider.rawValue] = owner.variant.effort }
        }
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
