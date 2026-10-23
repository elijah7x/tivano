import AppKit
import SwiftUI

enum SettingsPage: String, CaseIterable, Identifiable {
    case general
    case appearance
    case providers
    case models
    case hydra
    case mcp
    case sourceControl
    case shortcuts
    case archive
    case alpha
    case keepsakes
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .appearance: "Appearance"
        case .providers: "Providers"
        case .mcp: "MCP"
        case .models: "Models"
        case .alpha: "Alpha"
        case .hydra: "Hydra"
        case .sourceControl: "Source control"
        case .shortcuts: "Shortcuts"
        case .archive: "Archive"
        case .keepsakes: "Keepsakes"
        case .about: "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gear"
        case .appearance: "paintpalette"
        case .providers: "cpu"
        case .mcp: "puzzlepiece.extension"
        case .models: "slider.horizontal.3"
        // Never drawn: the sidebar gives the Alpha row its flask mark instead.
        case .alpha: "flask"
        // Never drawn: the sidebar gives the Hydra row the dragon mark instead. Kept so
        // the switch stays exhaustive and anything else that asks gets a sane symbol.
        case .hydra: "point.3.connected.trianglepath.dotted"
        case .sourceControl: "arrow.triangle.branch"
        case .shortcuts: "command"
        case .archive: "archivebox"
        case .keepsakes: "tag"
        case .about: "info.circle"
        }
    }

    var tint: Color {
        switch self {
        case .general: Chrome.gray
        case .alpha: Color(red: 0.95, green: 0.55, blue: 0.20)
        case .appearance: Color(red: 0.85, green: 0.44, blue: 0.36)
        case .providers: Chrome.blue
        case .mcp: Color(red: 0.95, green: 0.55, blue: 0.20)
        case .models: Color(red: 0.686, green: 0.322, blue: 0.871)
        case .hydra: Color(red: 0.188, green: 0.690, blue: 0.780)
        case .sourceControl: Color(red: 0.345, green: 0.337, blue: 0.839)
        case .shortcuts: Color(red: 0.32, green: 0.48, blue: 0.93)
        case .archive: Chrome.orange
        case .keepsakes: Color(red: 0.204, green: 0.780, blue: 0.349)
        case .about: Color(red: 0.204, green: 0.780, blue: 0.349)
        }
    }

    var keywords: [String] {
        switch self {
        case .general: ["permissions", "worktree", "reasoning", "thinking", "notifications", "token", "tokens", "activity", "usage", "panel", "limits", "credits", "heatmap", "daily", "weekly", "cumulative", "finish", "finished", "sound", "chime", "compact", "concise", "anti-slop", "slop", "verbose", "comments", "replies"]
        case .appearance: ["appearance", "theme", "transparency", "transparent", "opacity", "glass", "clear", "clearer", "liquid glass", "blur", "dark", "light", "accent", "tint", "catppuccin", "dracula", "tokyo", "nord", "gruvbox", "solarized", "github", "claude", "codex", "cursor", "matrix", "text", "size", "font", "zoom", "wallpaper", "sidebar", "performance", "gpu"]
        case .models: ["model", "effort", "reasoning", "fast", "slider", "picker"]
        case .hydra: ["hydra", "heads", "subagents", "sub-agents", "agents", "team", "orchestrator", "worker", "pair", "pairs", "parallel", "delegate", "queue"]
        case .providers: ["kimi", "pi", "codex", "claude", "cursor", "opencode", "opencode zen", "opencode go", "zen", "grok", "deepseek", "deepseek harness", "dsh", "meta", "muse", "spark", "zai", "z.ai", "glm", "coding plan", "devin", "cognition", "antigravity", "agy", "google", "gemini", "copilot", "github", "command code", "commandcode", "cmd", "binary", "path", "sign in", "login", "api key", "usage", "limits", "limit", "plan", "quota", "credits", "balance"]
        case .mcp: ["mcp", "model context protocol", "servers", "tools", "connect", "integrations", "github", "playwright", "notion", "linear", "slack", "figma", "supabase", "stripe", "resend", "email", "context7", "sentry", "postgres", "browser", "netlify", "deploy", "hosting"]
        case .sourceControl: ["git", "commit", "pull request", "titles", "text generation", "github", "repository", "repositories", "repo", "sign in", "token", "connect", "account"]
        case .alpha: ["alpha", "labs", "experimental", "beta", "preview", "voice", "speech", "talk", "call", "microphone", "mic", "realtime", "orb", "codex", "style", "实验室", "实验", "语音", "麦克风", "通话"]
        case .shortcuts: ["keyboard", "keys"]
        case .archive: ["archived", "restore"]
        case .keepsakes: ["keepsake", "early supporter", "信物"]
        case .about: ["version", "license"]
        }
    }
}

@MainActor
@Observable
final class SettingsNavigation {
    static let shared = SettingsNavigation()
    private(set) var isPresented = false
    var page: SettingsPage = .general
    var requestedPage: SettingsPage?

    func present(page: SettingsPage? = nil) {
        withAnimation(Chrome.panelSlide) {
            if let page { self.page = page }
            isPresented = true
        }
    }

    func dismiss() {
        guard isPresented else { return }
        withAnimation(Chrome.panelSlide) { isPresented = false }
    }
}

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme
    @State private var keepsakeOverlayShown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var keepsakeDismissRequest = 0
    @State private var page: SettingsPage = .general
    @State private var search = ""
    @State private var scrollTracker = SettingsScrollTracker()

    private var visiblePages: [SettingsPage] {
        let query = search.trimmed
        guard !query.isEmpty else { return SettingsPage.allCases }
        return SettingsPage.allCases.filter { page in
            ([page.title] + page.keywords).contains { key in
                [key, Chrome.localized(key)].contains {
                    $0.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                }
            }
        }
    }

    var body: some View {
        let visiblePages = self.visiblePages
        HStack(spacing: 0) {
            sidebar(visiblePages: visiblePages).frame(width: 212)
                .opacity(keepsakeOverlayShown ? 0.25 : 1)
                .allowsHitTesting(!keepsakeOverlayShown)
                .disabled(keepsakeOverlayShown)
                .overlay {
                    // Inserted only while shown, so the blur view costs nothing on other pages.
                    if keepsakeOverlayShown {
                        ZStack {
                            KeepsakeBackdrop()
                            KeepsakeOverlayStyle.veil(dark: colorScheme == .dark)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { keepsakeDismissRequest += 1 }
                        .transition(.opacity)
                    }
                }
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.5), value: keepsakeOverlayShown)
            SettingsDetail(page: page, fullWindow: false)
                .padding(.trailing, Chrome.sheetInset)
                .padding(.vertical, Chrome.sheetInset)
        }
        .environment(\.keepsakeDismissRequest, keepsakeDismissRequest)
        .onPreferenceChange(KeepsakeOverlayPreference.self) { keepsakeOverlayShown = $0 }
        .onDisappear { scrollTracker.end() }
        .background { WindowBackdrop(opacity: model.settings.backdropOpacity) }
        .background { WindowChromeConfigurator(performanceMode: model.settings.performanceMode) }
        .ignoresSafeArea()
        .frame(width: 780, height: 580)
        .onChange(of: SettingsNavigation.shared.requestedPage, initial: true) { _, requested in
            guard let requested else { return }
            page = requested
            SettingsNavigation.shared.requestedPage = nil
        }
        .onChange(of: visiblePages) { _, pages in
            guard !pages.isEmpty, !pages.contains(page), let first = pages.first else { return }
            page = first
        }
    }

    private func sidebar(visiblePages: [SettingsPage]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear
                .frame(height: Chrome.trafficLightDiameter)
                .padding(.top, Chrome.trafficLightTop)
            SidebarSearchField(text: $search, prompt: "Search settings pages or providers") {
                if let first = visiblePages.first { page = first }
            }
            .padding(.horizontal, Chrome.listInset)
            .padding(.top, 14)
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(visiblePages) { item in
                        SettingsSidebarRow(page: item, isSelected: page == item, hasUnseenKeepsakes: model.hasUnseenKeepsakes) { page = item }
                            .equatable()
                    }
                    if visiblePages.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("No results")
                                .font(.ui(.body, weight: .semibold))
                                .foregroundStyle(Chrome.primaryText.opacity(0.92))
                            Text("Try a setting or a provider name.")
                                .font(.ui(.subheadline))
                                .foregroundStyle(Chrome.secondaryText)
                        }
                        .padding(.horizontal, 8)
                        .padding(.top, 14)
                    }
                }
                .padding(.horizontal, Chrome.listInset)
                .padding(.top, 12)
                .padding(.bottom, 8)
                .allowsHitTesting(!scrollTracker.isFrozen)
            }
            .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentOffset.y }) { _, _ in
                scrollTracker.note()
            }
            .onScrollPhaseChange { _, phase in
                if phase == .interacting { scrollTracker.note() } else { scrollTracker.coast() }
            }
            .scrollIndicators(.never)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background { WindowDragArea() }
    }

}

private struct SettingsSidebarRow: View, Equatable {
    let page: SettingsPage
    let isSelected: Bool
    let hasUnseenKeepsakes: Bool
    let action: () -> Void

    // Each action only selects this row's fixed page in its owning sidebar.
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.page == rhs.page && lhs.isSelected == rhs.isSelected && lhs.hasUnseenKeepsakes == rhs.hasUnseenKeepsakes
    }

    var body: some View {
        SidebarRow(title: page.title, isSelected: isSelected, accessoryWidth: page == .keepsakes && hasUnseenKeepsakes ? 14 : 0, action: action) {
            SettingsSidebarIcon(page: page)
        } accessory: { _ in
            if page == .keepsakes && hasUnseenKeepsakes {
                Circle()
                    .fill(Chrome.accent)
                    .frame(width: 6, height: 6)
                    .accessibilityHidden(true)
            }
        }
    }
}

private struct SettingsSidebarIcon: View {
    let page: SettingsPage

    var body: some View {
        SidebarIconBadge {
            if page == .hydra {
                // The Hydra page wears the dragon mark, the same one as the composer button.
                HydraMarkImage()
                    .frame(width: Chrome.symbolSize * 1.15, height: Chrome.symbolSize * 1.15)
            } else if page == .alpha {
                AlphaMarkImage()
                    .frame(width: Chrome.symbolSize, height: Chrome.symbolSize)
            } else {
                SidebarSymbol(page.symbol, scale: page == .general ? 1.15 : 1)
            }
        }
        .overlay(alignment: .topTrailing) {
            if page == .about, UpdateChecker.shared.updateAvailable {
                UpdateAvailableDot()
            }
        }
    }
}

struct SettingsSidebar: View {
    @Environment(AppModel.self) private var model
    @Bindable private var navigation = SettingsNavigation.shared
    @State private var search = ""
    @State private var scrollTracker = SettingsScrollTracker()

    private var page: SettingsPage { navigation.page }

    private var visiblePages: [SettingsPage] {
        let query = search.trimmed
        guard !query.isEmpty else { return SettingsPage.allCases }
        return SettingsPage.allCases.filter { page in
            ([page.title] + page.keywords).contains { key in
                [key, Chrome.localized(key)].contains {
                    $0.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                }
            }
        }
    }

    var body: some View {
        let visiblePages = self.visiblePages
        VStack(alignment: .leading, spacing: 0) {
            Color.clear
                .frame(height: Chrome.trafficLightDiameter)
                .padding(.top, Chrome.trafficLightTop)
            SidebarRow(title: "Back", action: { WindowManager.shared.hideSettings() }) {
                SidebarIconBadge { SidebarSymbol("arrow.left") }
            }
            .help(Text(verbatim: Chrome.localized("Back to your threads")))
            .padding(.horizontal, Chrome.listInset)
            .padding(.top, 10)
            SidebarSearchField(text: $search, prompt: "Search settings pages or providers") {
                if let first = visiblePages.first { navigation.page = first }
            }
            .padding(.horizontal, Chrome.listInset)
            .padding(.top, 14)
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(visiblePages) { item in
                        SettingsSidebarRow(page: item, isSelected: page == item, hasUnseenKeepsakes: model.hasUnseenKeepsakes) { navigation.page = item }
                            .equatable()
                    }
                    if visiblePages.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("No results")
                                .font(.ui(.body, weight: .semibold))
                                .foregroundStyle(Chrome.primaryText.opacity(0.92))
                            Text("Try a setting or a provider name.")
                                .font(.ui(.subheadline))
                                .foregroundStyle(Chrome.secondaryText)
                        }
                        .padding(.horizontal, 8)
                        .padding(.top, 14)
                    }
                }
                .padding(.horizontal, Chrome.listInset)
                .padding(.top, 12)
                .padding(.bottom, 8)
                .allowsHitTesting(!scrollTracker.isFrozen)
            }
            .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentOffset.y }) { _, _ in
                scrollTracker.note()
            }
            .onScrollPhaseChange { _, phase in
                if phase == .interacting { scrollTracker.note() } else { scrollTracker.coast() }
            }
            .scrollIndicators(.never)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background { WindowDragArea() }
        .onDisappear { scrollTracker.end() }
        .onChange(of: visiblePages) { _, pages in
            guard !pages.isEmpty, !pages.contains(page), let first = pages.first else { return }
            navigation.page = first
        }
    }

}

struct SettingsDetail: View {
    let page: SettingsPage
    var fullWindow = true

    var body: some View {
        SettingsPageScroll(page: page, fullWindow: fullWindow)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .detailSheet()
    }
}

private struct SettingsArchiveDetail<Content: View>: View {
    @Environment(AppModel.self) private var model
    let content: Content

    var body: some View {
        if model.archivedThreads.isEmpty {
            // An empty archive is one symbol in the middle of the pane: no sentence, no chrome,
            // no button with nothing to delete.
            Image(systemName: "archivebox")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(Chrome.secondaryText.opacity(0.6))
                .accessibilityLabel(Text("No archived threads"))
        } else {
            content
        }
    }
}

private struct SettingsPageScroll: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var keepsakeOverlayShown = false
    let page: SettingsPage
    let fullWindow: Bool
    @State private var modelSearch = ""
    @State private var mcpSearch = ""
    @State private var archiveFilter = ArchiveFilter()
    @State private var scrollChrome = ChromeScrollModel()
    @State private var scrollTracker = SettingsScrollTracker()

    var body: some View {
        Group {
            if page == .archive {
                SettingsArchiveDetail(content: pageScroll)
            } else {
                pageScroll
            }
        }
        .onDisappear { scrollTracker.end() }
        .onChange(of: page, initial: true) {
            scrollChrome.update(travel: 0)
            modelSearch = ""
            mcpSearch = ""
            archiveFilter = ArchiveFilter()
        }
    }

    private var pageScroll: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Chrome.pageTitleSpacing) {
                if fullWindow {
                    Text(verbatim: Chrome.localized(page.title))
                        .font(.ui(.title2, weight: .medium))
                        .foregroundStyle(Chrome.primaryText)
                        .accessibilityAddTraits(.isHeader)
                        .opacity(keepsakeOverlayShown ? 0 : 1)
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.5), value: keepsakeOverlayShown)
                }
                VStack(alignment: .leading, spacing: Chrome.pageSectionSpacing) {
                    pageContent
                }
            }
            .environment(\.chromeSectionHeaderSpacing, Chrome.pageSectionHeaderSpacing)
            .frame(maxWidth: fullWindow ? 680 : .infinity, alignment: .leading)
            .padding(.horizontal, fullWindow ? Chrome.contentHorizontalPadding * 2 : Chrome.contentHorizontalPadding + 8)
            .frame(maxWidth: .infinity)
            // Full-window pages clear the titlebar; the old window keeps its existing inset.
            .padding(.top, fullWindow || pageHasChromeControls ? Chrome.chromeTopPadding + Chrome.capsuleHeight + 16 : 22)
            .padding(.bottom, fullWindow ? Chrome.contentHorizontalPadding * 2 : 24)
            .allowsHitTesting(!scrollTracker.isFrozen)
        }
        .onPreferenceChange(KeepsakeOverlayPreference.self) { keepsakeOverlayShown = $0 }
        // The expanded keepsake is placed at the card's frame; scrolling would separate them.
        .scrollDisabled(keepsakeOverlayShown)
        .scrollIndicators(.never)
        .id(page)
        .onScrollGeometryChange(for: CGFloat.self, of: Self.travel) { _, travel in
            scrollTracker.note()
            scrollChrome.update(travel: travel)
        }
        .onScrollPhaseChange { _, phase in
            // Fingers on the content freeze the rows (no click can land then anyway); the
            // moment the scroll coasts or settles they come back, so a click that stops a
            // flick always reaches its target. Wheel scrolling reports no phases and is
            // caught by the movement above instead.
            if phase == .interacting { scrollTracker.note() } else { scrollTracker.coast() }
        }
        .chromeEdgeFade(scrollChrome)
        .overlay(alignment: .top) {
            SettingsPageChrome(
                page: page,
                scrollChrome: scrollChrome,
                modelSearch: $modelSearch,
                mcpSearch: $mcpSearch,
                archiveFilter: $archiveFilter
            )
            .opacity(keepsakeOverlayShown ? 0 : 1)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.5), value: keepsakeOverlayShown)
        }
    }

    private var pageHasChromeControls: Bool {
        page == .providers || page == .models || page == .mcp || page == .archive || page == .about
    }

    @ViewBuilder
    private var pageContent: some View {
        switch page {
        case .general: GeneralSettingsPage()
        case .appearance: AppearanceSettingsPage()
        case .providers: ProvidersSettingsPage()
        case .mcp: MCPSettingsPage(query: mcpSearch)
        case .models:
            ModelsSettingsPage(query: modelSearch)
        case .hydra: HydraSettingsPage()
        case .alpha: AlphaSettingsPage()
        case .sourceControl: SourceControlSettingsPage()
        case .shortcuts: ShortcutsSettingsPage()
        case .archive: ArchiveSettingsPage(filter: $archiveFilter)
        case .keepsakes: KeepsakesSettingsPage()
        case .about: AboutSettingsPage()
        }
    }

    private nonisolated static func travel(_ geometry: ScrollGeometry) -> CGFloat {
        geometry.contentOffset.y + geometry.contentInsets.top
    }
}

private struct SettingsPageChrome: View {
    let page: SettingsPage
    let scrollChrome: ChromeScrollModel
    @Binding var modelSearch: String
    @Binding var mcpSearch: String
    @Binding var archiveFilter: ArchiveFilter

    var body: some View {
        HStack(spacing: 10) {
            ChromeCompactTitle(title: page.title, model: scrollChrome)
            if page == .models {
                ChromeSearchField(query: $modelSearch, prompt: "Search models")
            }
            if page == .mcp {
                ChromeSearchField(query: $mcpSearch, prompt: "Search servers")
            }
            if page == .archive {
                ArchiveChromeControls(filter: $archiveFilter)
            }
            if page == .providers {
                ProvidersRefreshButton()
            }
            if page == .about {
                AboutUpdateChromeAccessory()
            }
        }
        .frame(minHeight: Chrome.capsuleHeight)
        .padding(.horizontal, Chrome.chromeHorizontalPadding)
        .padding(.top, Chrome.chromeTopPadding)
    }
}

struct SettingsSwitch: View {
    @Binding var isOn: Bool

    var body: some View {
        Toggle("", isOn: $isOn)
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
    }
}

private struct GeneralSettingsPage: View {
    @Environment(AppModel.self) private var model

    private static let runtimeOptions = RuntimeMode.allCases.map { ($0, $0.title) }
    private static let workspaceOptions = WorkspaceMode.allCases.map { ($0, $0.title) }
    private static let hapticOptions = TimelineHapticStyle.allCases.map { ($0, $0.title) }
    private static let languageOptions = AppLanguage.allCases.map { ($0, $0.title) }
    private static let textGenerationOptions = TextGenerationChoice.allCases.map { ($0, $0.title) }
    private static let locationOptions: [(NewThreadLocation, String)] = [
        (.recent, "Follow the latest chat"),
        (.standalone, "Tasks (no project)"),
    ]

    var body: some View {
        @Bindable var settings = model.settings
        // The Token activity heatmap leads the page: it summarizes what the
        // settings below configure, rather than configuring anything itself.
        TokenActivitySection()
        ChromeSection(title: "New threads") {
            ChromeCard {
                newThreadModelRow
                ChromeRowDivider()
                ChromeRow(title: "Default location", detail: "By default, follow the latest chat's location, including Tasks. Applies only to ordinary new chats; creating a chat from a project still places it in that project.") {
                    GlassPickerButton(options: Self.locationOptions, selection: $settings.newThreadLocation, maxWidth: 190)
                        .accessibilityLabel(Text("Default location"))
                }
                ChromeRowDivider()
                ChromeRow(title: "Permissions", detail: settings.defaultRuntimeMode.summary) {
                    GlassPickerButton(options: Self.runtimeOptions, selection: $settings.defaultRuntimeMode, symbol: { $0.symbol })
                }
                ChromeRowDivider()
                ChromeRow(title: "Workspace", detail: "Where a new thread makes its changes") {
                    ChromeVisualPicker(options: Self.workspaceOptions, selection: $settings.defaultWorkspaceMode) { mode in
                        Image(systemName: mode == .local ? "folder" : "arrow.triangle.branch")
                    }
                }
            }
        }
            ChromeSection(title: "Conversation") {
                ChromeCard {
                    ChromeRow(title: "Show thinking", detail: "The working line opens to the agent's thinking") {
                        SettingsSwitch(isOn: $settings.showReasoning)
                    }
                    ChromeRowDivider()
                    ChromeRow(title: "Concise AI replies", detail: "Built-in guidance for shorter replies, useful code comments, and focused work, including Hydra heads. Changes apply on the next message.") {
                        SettingsSwitch(isOn: $settings.antiSlopEnabled)
                    }
                    ChromeRowDivider()
                    ChromeRow(title: "Working line", detail: "A card with the turn's progress bar, or a plain line") {
                        ChromeVisualPicker(options: [(true, "Card"), (false, "Line")], selection: $settings.showsWorkingCard) { isCard in
                            Image(systemName: isCard ? "rectangle.fill" : "minus")
                        }
                    }
                    ChromeRowDivider()
                    ChromeRow(title: "Timeline haptics", detail: "Play haptic feedback when hovering over timeline ticks and progress bars") {
                        GlassPickerButton(options: Self.hapticOptions, selection: $settings.timelineHapticStyle)
                    }
                    ChromeRowDivider()
                    ChromeRow(title: "Recent downloads", detail: "The attach button offers recent downloads first") {
                        SettingsSwitch(isOn: $settings.recentDownloadsPicker)
                    }
                    ChromeRowDivider()
                    ChromeRow(title: "Notify when a turn finishes") {
                    SettingsSwitch(isOn: $settings.notifyWhenFinished)
                }
                ChromeRowDivider()
                ChromeRow(title: "Chime when a turn finishes", detail: "A soft chime, whether or not the thread is in view") {
                    SettingsSwitch(isOn: $settings.chimeWhenFinished)
                }
                // Switching it on plays the chime once, so you hear what you are getting.
                .onChange(of: settings.chimeWhenFinished) { _, isOn in
                    if isOn { FinishChime.play() }
                }
                ChromeRowDivider()
                ChromeRow(title: "Confirm before deleting threads") {
                    SettingsSwitch(isOn: $settings.confirmBeforeDeleting)
                }
                ChromeRowDivider()
                ChromeRow(title: "Continue after a usage limit", detail: "When the provider's limit is spent, the chat waits for the reset and then tells the agent to carry on") {
                    SettingsSwitch(isOn: $settings.autoContinueAfterLimit)
                }
            }
        }
        ChromeSection(title: "Text generation") {
            ChromeCard {
                ChromeRow(
                    title: "Thread titles and commit messages",
                    detail: "Automatic uses the thread's own provider. Claude uses Haiku, Codex your default model."
                ) {
                    GlassPickerButton(options: Self.textGenerationOptions, selection: $settings.textGeneration, asset: { ProviderKind(rawValue: $0.rawValue)?.iconName })
                }
            }
        }
        ChromeSection(title: "Power") {
            ChromeCard {
                ChromeRow(
                    title: "Prevent sleep while tasks are running",
                    detail: "While tasks run, your Mac won't doze off. Keep Mac awake lets the screen turn off on its own; Keep Mac and screen awake leaves it lit too, which helps when an agent needs to see a front end. Manual sleep and closing the lid still work."
                ) {
                    GlassPickerButton(options: TaskSleepMode.allCases.map { ($0, $0.title) }, selection: $settings.taskSleepMode)
                }
            }
        }
        ChromeSection(title: "Languages") {
            ChromeCard {
                ChromeRow(title: "App language", detail: "Changes apply after the app restarts.") {
                    GlassPickerButton(options: Self.languageOptions, selection: $settings.appLanguage)
                }
            }
        }
    }

    private var newThreadModelRow: some View {
        NewThreadModelSettingsRow()
    }
}

private struct NewThreadModelSettingsRow: View {
    @Environment(AppModel.self) private var model
    @State private var isPresented = false

    var body: some View {
        let registry = model.providers
        let providers = registry.availableProviders
        let selection = model.settings.newThreadModelSelection
        let option = selection.flatMap { registry.model($0.modelID, for: $0.provider) }
        let isAvailable = selection.map { providers.contains($0.provider) && option != nil } ?? true
        let name = selection.map { ModelPin(provider: $0.provider, modelID: $0.modelID).displayName }
        let effortTitle = option.flatMap { option -> String? in
            guard !option.efforts.isEmpty else { return nil }
            let effort = selection?.effort.flatMap { option.efforts.contains($0) ? $0 : nil }
            return Chrome.localized(ModelOption.effortTitle(effort ?? option.defaultEffort ?? ""))
        }
        let title = selection.map { [$0.provider.displayName, option?.shortName ?? name ?? $0.modelID, effortTitle].compactMap { $0 }.joined(separator: " · ") }
            ?? Chrome.localized("Last selection")
        let fullTitle = selection.map { [$0.provider.displayName, option?.name ?? name ?? $0.modelID, effortTitle].compactMap { $0 }.joined(separator: " · ") }
            ?? Chrome.localized("Last selection")
        let displayedTitle = isAvailable ? title : String(format: Chrome.localized("%@ (unavailable)"), title)
        let helpTitle = isAvailable ? fullTitle : String(format: Chrome.localized("%@ (unavailable)"), fullTitle)
        var details = [Chrome.localized("Project Hydra presets take priority. Otherwise, Last selection uses the current or most recent model; a selected model stays fixed.")]
        if !isAvailable {
            details.append(Chrome.localized("The selected model is unavailable. New chats will use Last selection."))
        }
        if providers.isEmpty {
            details.append(Chrome.localized("No providers available. You can still use Last selection."))
        }
        return ChromeRow(title: "Default model", detail: details.joined(separator: "\n")) {
            Button {
                isPresented = true
            } label: {
                HStack(spacing: 6) {
                    if let selection {
                        Image(selection.provider.iconName)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 14, height: 14)
                    }
                    Text(verbatim: displayedTitle)
                        .font(.ui(size: 12.5, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Image(systemName: "chevron.down")
                        .font(Chrome.chevronFont)
                        .foregroundStyle(Chrome.secondaryText)
                }
                .padding(.horizontal, Chrome.capsuleHorizontalPadding)
                .frame(height: Chrome.capsuleContentHeight)
                .contentShape(Capsule(style: .continuous))
            }
            .buttonStyle(.plain)
            .chromeGlassCapsule()
            .frame(maxWidth: 190, alignment: .trailing)
            .foregroundStyle(Chrome.primaryText)
            .help(Text(verbatim: helpTitle))
            .accessibilityLabel(Text("Default model"))
            .accessibilityValue(Text(verbatim: helpTitle))
            .popover(isPresented: $isPresented, arrowEdge: .trailing) {
                NewThreadModelPicker(
                    selection: selection,
                    selectedModelID: option?.id ?? selection?.modelID,
                    initialProvider: selection?.provider
                        ?? (providers.contains(model.settings.defaultProvider) ? model.settings.defaultProvider : providers.first)
                ) { selection in
                    model.settings.newThreadModelSelection = selection
                    isPresented = false
                }
                .frame(width: 360)
                .presentedChrome()
            }
            .background { NoWindowDragArea() }
        }
    }
}

private struct NewThreadModelPicker: View {
    @Environment(AppModel.self) private var model
    let selection: NewThreadModelSelection?
    let selectedModelID: String?
    let select: (NewThreadModelSelection?) -> Void
    @State private var selectedProvider: ProviderKind?

    init(
        selection: NewThreadModelSelection?,
        selectedModelID: String?,
        initialProvider: ProviderKind?,
        select: @escaping (NewThreadModelSelection?) -> Void
    ) {
        self.selection = selection
        self.selectedModelID = selectedModelID
        self.select = select
        _selectedProvider = State(initialValue: initialProvider)
    }

    var body: some View {
        let registry = model.providers
        let providers = registry.availableProviders
        let provider = selectedProvider.flatMap { providers.contains($0) ? $0 : nil }
        let providerPrompt = selectedProvider.map {
            String(format: Chrome.localized("%@ (unavailable)"), $0.displayName)
        } ?? Chrome.localized("Choose a provider")
        let providerOptions = (provider == nil ? [(ProviderKind?.none, providerPrompt)] : [])
            + providers.map { (Optional($0), $0.displayName) }
        let options = provider.map { model.pickerModels(for: $0, keeping: selectedModelID.map { Set([$0]) } ?? []) } ?? []
        let selectedOption = selection?.provider == provider
            ? options.first { $0.id == selectedModelID }
            : nil
        let modelTitle = selectedOption?.name ?? Chrome.localized("Choose a model")
        let effortTitle = Chrome.localized(ModelOption.effortTitle(
            selection?.effort.flatMap { selectedOption?.efforts.contains($0) == true ? $0 : nil }
                ?? selectedOption?.defaultEffort ?? ""
        ))
        let isLoading = provider.map { registry.loadingCatalogs.contains($0) } ?? false
        let error = provider.flatMap { registry.status($0).catalogError }
        VStack(alignment: .leading, spacing: 0) {
            PopoverItem("Last selection", isChecked: selection == nil) {
                select(nil)
            }
            .padding(.horizontal, 6)
            .padding(.top, 6)
            Divider()
                .padding(.horizontal, 14)
                .padding(.vertical, 5)
            // Shares the Last selection row's checkmark column so the two choices read as peers.
            HStack(spacing: 8) {
                Image(systemName: "checkmark")
                    .font(.ui(.subheadline, weight: .semibold))
                    .foregroundStyle(Chrome.primaryText)
                    .opacity(selection == nil ? 0 : 1)
                    .frame(width: 14)
                Text(verbatim: Chrome.localized("Custom model"))
                    .font(.ui(.subheadline, weight: .semibold))
                    .foregroundStyle(Chrome.secondaryText)
            }
            .padding(.leading, 14)
            .padding(.top, 2)
            .padding(.bottom, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Custom model"))
            .accessibilityAddTraits(selection == nil ? .isHeader : [.isHeader, .isSelected])
            editorRow("Provider") {
                GlassPickerButton(
                    options: providerOptions,
                    selection: Binding(
                        get: { provider },
                        set: { if let provider = $0 { selectedProvider = provider } }
                    ),
                    asset: { $0?.iconName },
                    maxWidth: 190
                )
                .disabled(providers.isEmpty)
                .help(Text(verbatim: provider?.displayName ?? providerPrompt))
                .accessibilityLabel(Text("Provider"))
                .accessibilityValue(Text(verbatim: provider?.displayName ?? providerPrompt))
            }
            editorRow("Model") {
                GlassPickerButton(
                    options: [(String?.none, "Choose a model")] + options.map { (Optional($0.id), $0.shortName) },
                    selection: Binding(
                        get: { selectedOption?.id },
                        set: { id in
                            guard let provider, selectedProvider == provider,
                                  registry.availableProviders.contains(provider),
                                  let id, let option = options.first(where: { $0.id == id }) else { return }
                            let effort = selection?.effort.flatMap { option.efforts.contains($0) ? $0 : nil }
                            select(NewThreadModelSelection(provider: provider, modelID: id, effort: effort))
                        }
                    ),
                    maxWidth: 190
                )
                .disabled(options.isEmpty)
                .help(Text(verbatim: modelTitle))
                .accessibilityLabel(Text("Model"))
                .accessibilityValue(Text(verbatim: modelTitle))
            }
            if let selectedOption, !selectedOption.efforts.isEmpty {
                editorRow("Reasoning effort") {
                    GlassPickerButton(
                        options: [(String?.none, "Default")] + selectedOption.efforts.map { (Optional($0), ModelOption.effortTitle($0)) },
                        selection: Binding(
                            get: { selection?.effort.flatMap { selectedOption.efforts.contains($0) ? $0 : nil } },
                            set: { effort in
                                guard let selection else { return }
                                select(NewThreadModelSelection(provider: selection.provider, modelID: selection.modelID, effort: effort))
                            }
                        ),
                        maxWidth: 190
                    )
                    .help(Text(verbatim: effortTitle))
                    .accessibilityLabel(Text("Reasoning effort"))
                    .accessibilityValue(Text(verbatim: effortTitle))
                }
            }
            if providers.isEmpty {
                catalogNote(Chrome.localized("No providers available. You can still use Last selection."))
            } else if let provider {
                if isLoading {
                    catalogNote(String(format: Chrome.localized(options.isEmpty ? "Loading %@'s models…" : "Refreshing %@'s models…"), provider.displayName))
                } else if let error {
                    catalogNote(
                        options.isEmpty ? error : String(
                            format: Chrome.localized("Could not refresh %@'s models. You can still use the loaded models.\n%@"),
                            provider.displayName, error
                        ),
                        retryProvider: provider
                    )
                } else if options.isEmpty {
                    catalogNote(
                        String(format: Chrome.localized("No models loaded for %@ yet."), provider.displayName),
                        retryProvider: provider
                    )
                }
            }
        }
        .padding(.bottom, 14)
        .task(id: selectedProvider) {
            guard let provider = selectedProvider, registry.availableProviders.contains(provider), !Task.isCancelled else { return }
            await registry.loadCatalog(provider, force: false)
        }
    }

    private func editorRow<Control: View>(_ title: String, @ViewBuilder control: () -> Control) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Text(verbatim: Chrome.localized(title))
                .font(.ui(.body))
                .foregroundStyle(Chrome.primaryText)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            control()
                .layoutPriority(1)
        }
        // Leading inset lines the label up with the titles beside the checkmark column.
        .padding(.leading, 36)
        .padding(.trailing, 14)
        .padding(.vertical, 5)
    }

    private func catalogNote(_ message: String, retryProvider: ProviderKind? = nil) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: message)
                .font(.ui(.subheadline))
                .foregroundStyle(Chrome.secondaryText)
                .lineLimit(nil)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let provider = retryProvider {
                Button("Retry") {
                    Task {
                        let registry = model.providers
                        guard selectedProvider == provider,
                              registry.availableProviders.contains(provider),
                              !registry.loadingCatalogs.contains(provider) else { return }
                        await registry.loadCatalog(provider, force: true)
                    }
                }
                .buttonStyle(.glass)
                .controlSize(.small)
                .disabled(model.providers.loadingCatalogs.contains(provider))
                .accessibilityLabel(Text(verbatim: String(format: Chrome.localized("Retry loading %@'s models"), provider.displayName)))
            }
        }
        .padding(.leading, 36)
        .padding(.trailing, 14)
        .padding(.top, 8)
    }
}

/// The main interface, font sizes and other appearance settings.
private struct AppearanceSettingsPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        let performanceMode = settings.performanceMode
        let clearerUnavailable = performanceMode || WallpaperStore.shared.hasWallpaper
        ChromeSection(title: "Main interface") {
            ChromeCard {
                ChromeRow(title: "Theme", detail: settings.theme.detail, localizesDetail: false) {
                    ThemePickerButton(selection: $settings.theme)
                }
                ChromeRowDivider()
                ChromeRow(title: "Transparency", detail: "How much shows through the window") {
                    BackdropOpacitySlider(value: $settings.backdropOpacity)
                }
                .disabled(performanceMode)
                .opacity(performanceMode ? 0.5 : 1)
                ChromeRowDivider()
                ChromeRow(
                    title: "Clearer glass",
                    detail: performanceMode
                        ? "Unavailable in Performance Mode"
                        : clearerUnavailable
                            ? "Unavailable while a wallpaper is set"
                            : "Shows more of the desktop through the window with Liquid Glass. Uses more GPU while the window's content changes; off uses a lighter system blur."
                ) {
                    SettingsSwitch(isOn: $settings.clearerBackdrop)
                }
                .disabled(clearerUnavailable)
                .opacity(clearerUnavailable ? 0.5 : 1)
                ChromeRowDivider()
                ChromeRow(title: "Performance Mode", detail: "Disable window transparency, blurs, glows and background effects for lowest GPU usage") {
                    SettingsSwitch(isOn: $settings.performanceMode)
                }
                ChromeRowDivider()
                ChromeRow(title: "Skylight", detail: performanceMode ? "Unavailable in Performance Mode" : "A teru teru bozu at the top of the sidebar keeps you company while agents work, and its weather shows how your threads are doing: it sways in the wind while they run, turns overcast when one needs you, brightens when a reply lands and rains when one fails. It animates only while visible.") {
                    SettingsSwitch(isOn: $settings.showsSkylight)
                }
                .disabled(performanceMode)
                .opacity(performanceMode ? 0.5 : 1)
            }
            WallpaperCard()
        }
        FontSizeSection()
        ChromeSection(title: "Other") {
            ChromeCard {
                ChromeRow(title: "Auto-hide top controls", detail: "Show the upper-right controls only while the pointer is over their area") {
                    SettingsSwitch(isOn: $settings.autoHideTopControls)
                }
            }
        }
    }
}

/// Font sizes use the same section and card spacing as the other settings.
private struct FontSizeSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        ChromeSection(
            title: "Font sizes",
            trailing: AnyView(
                Button("Reset font sizes") { settings.resetFontSizes() }
                    .font(.ui(.body))
                    .buttonStyle(.glass)
                    .controlSize(.small)
                    .disabled(settings.isDefault)
            )
        ) {
            ChromeCard {
                ChromeRow(title: "Interface font size", detail: "Adjust Tivano's base font size") {
                    FontSizeButtons(value: $settings.uiFontSize, range: TypeScale.uiRange)
                }
                ChromeRowDivider()
                ChromeRow(title: "Content font size", detail: "Adjust the base font size of conversations") {
                    FontSizeButtons(value: $settings.contentFontSize, range: TypeScale.contentRange)
                }
                ChromeRowDivider()
                ChromeRow(title: "Code font size", detail: "Adjust the base font size of code in chat and diff views") {
                    FontSizeButtons(value: $settings.codeFontSize, range: TypeScale.codeRange)
                }
            }
        }
    }
}

private struct FontSizeButtons: View {
    @Binding var value: Int
    let range: ClosedRange<Int>

    var body: some View {
        HStack(spacing: 8) {
            ChromeIconButton(symbol: "minus", isEnabled: value > range.lowerBound, help: "Decrease Font Size") {
                value = TypeScale.clamp(value - 1, to: range)
            }

            Text(verbatim: "\(value) pt")
                .font(Font.ui(size: 12).monospacedDigit())
                .frame(width: 56)
                .help(Text(verbatim: "\(range.lowerBound)–\(range.upperBound)"))

            ChromeIconButton(symbol: "plus", isEnabled: value < range.upperBound, help: "Increase Font Size") {
                value = TypeScale.clamp(value + 1, to: range)
            }
        }
    }
}

/// Clear glass on the left, a solid base on the right, the stock look in the middle,
/// with a reset that shows only once the slider has left the stock look.
private struct BackdropOpacitySlider: View {
    @Binding var value: Double

    private var isOffStock: Bool { abs(value - AppSettings.defaultBackdropOpacity) >= 0.005 }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "circle.dotted")
                .font(.ui(.subheadline))
                .foregroundStyle(Chrome.secondaryText)
                .help(Text(verbatim: Chrome.localized("Transparent")))
            Slider(value: $value, in: 0...1)
                .controlSize(.small)
                .frame(width: 140)
            Image(systemName: "circle.fill")
                .font(.ui(.subheadline))
                .foregroundStyle(Chrome.secondaryText)
                .help(Text(verbatim: Chrome.localized("Solid")))
        }
        // The reset takes no room in the row, so the slider ends flush with the card's
        // other controls whether or not it shows; it fades in to the slider's left once
        // the value has left the stock look.
        .overlay(alignment: .leading) {
            if isOffStock {
                Button {
                    withAnimation(.snappy(duration: 0.2)) { value = AppSettings.defaultBackdropOpacity }
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.ui(.subheadline, weight: .medium))
                        .foregroundStyle(Chrome.secondaryText)
                        .frame(width: 22, height: 22)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help(Text(verbatim: Chrome.localized("Back to the stock look")))
                .offset(x: -28)
                .transition(.opacity.combined(with: .offset(x: 6)))
            }
        }
        .animation(.snappy(duration: 0.2), value: isOffStock)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Window transparency"))
    }
}

private struct ProvidersRefreshButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ChromeCapsule {
            ChromeIconButton(
                symbol: "arrow.clockwise",
                isEnabled: !model.providers.isRefreshing,
                help: model.providers.isRefreshing ? "Checking providers…" : "Check providers again"
            ) {
                Task { await model.providers.refreshEverything() }
            }
        }
    }
}

/// Shows provider status plus cached, read-only CLI update checks.
/// The one read it starts on its own is each signed-in account's usage limits, which the registry
/// throttles to once a minute, so the numbers are on screen without a trip through a chat.
private struct ProvidersSettingsPage: View {
    @Environment(AppModel.self) private var model
    /// Manual expansion overrides per provider, kept for the page's lifetime. With no
    /// override the auth default rules — signed-in expands, anything else collapses —
    /// so a provider whose check resolves to signed-in opens on its own until touched.
    @State private var providerExpansion: [ProviderKind: Bool] = [:]

    var body: some View {
        let settings = model.settings
        // Eager on purpose: a handful of sections, and lazy ones were rebuilt while scrolling,
        // which reset their fields and re-ran every check they started on appear.
        VStack(alignment: .leading, spacing: Chrome.pageSectionSpacing) {
            ProviderSelectionSection(settings: settings)
            ForEach(ProviderGroup.allCases) { group in
                let providers = group.providers.filter { settings.isEnabled($0) }
                if !providers.isEmpty {
                    ChromeSection(title: group.title) {
                        VStack(alignment: .leading, spacing: Chrome.unitSpacing) {
                            ForEach(providers) { provider in
                                ProviderSettingsSection(
                                    provider: provider,
                                    expansionOverride: Binding(
                                        get: { providerExpansion[provider] },
                                        set: { providerExpansion[provider] = $0 }
                                    )
                                )
                            }
                        }
                    }
                }
            }
        }
        .task {
            await model.providers.checkCLIUpdates(freshness: ProviderRegistry.cliCheckFreshnessOnOpen)
        }
    }
}

private struct ProviderSettingsSection: View {
    @Environment(AppModel.self) private var model
    let provider: ProviderKind
    /// Nil follows the auth default; an explicit override lasts for the page's lifetime.
    @Binding var expansionOverride: Bool?

    @State private var binaryPath = ""
    @State private var apiKey = ""
    @State private var showsAPIKey = false
    @State private var keyCheck: Task<Void, Never>?
    @State private var signInTask: Task<Void, Never>?
    @State private var signInError: String?

    private var apiKeyDetail: String {
        let settings = model.settings
        if let error = settings.apiKeyStoreErrors[provider] {
            let template = settings.apiKeyMigrationFailures.contains(provider)
                ? "This key from an earlier version is still stored unencrypted because the Keychain refused it (%@). Enter it again to retry."
                : "Couldn't save to your Keychain (%@). The key works until you quit Tivano; enter it again to retry."
            return String(format: Chrome.localized(template), error)
        }
        if apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           case .environment(let name) = settings.apiKeySource(for: provider) {
            return String(format: Chrome.localized("Using %@ from your shell environment."), name)
        }
        return provider == .zai
            ? String(format: Chrome.localized("Use a GLM Coding Plan key; Standard API keys will not work here. Stored in your Keychain. Get one at %@."), provider.apiKeySource ?? Chrome.localized("the provider dashboard"))
            : provider.isAPIKeyBased
            ? String(format: Chrome.localized("Stored in your Keychain. Get one at %@."), provider.apiKeySource ?? Chrome.localized("the provider dashboard"))
            : String(format: Chrome.localized("Instead of `%@`: a Studio key from %@, stored in your Keychain and handed to the CLI."), provider.loginCommand, provider.apiKeySource ?? Chrome.localized("the provider dashboard"))
    }

    private static let regionOptions = ZaiRegion.allCases.map { ($0, $0.title) }

    var body: some View {
        let settings = model.settings
        let registry = model.providers
        let status = registry.status(provider)
        let isSignedIn: Bool = {
            if case .signedIn = status.auth { return true }
            return false
        }()
        let isExpanded = expansionOverride ?? isSignedIn
        let expansion = Binding(
            get: { expansionOverride ?? isSignedIn },
            set: { expansionOverride = $0 }
        )
        let showsUsage = settings.showsProviderUsage
            && (PlanLimitsReader.exposesLimits(provider) || CreditsReader.exposesCredits(provider))
            && status.isInstalled && status.auth != .signedOut
        VStack(alignment: .leading, spacing: Chrome.unitHeaderSpacing) {
            CollapsibleProviderHeader(provider: provider, isExpanded: expansion, subject: "provider settings", detail: provider.routeSummary)
            ChromeReveal(isExpanded: isExpanded) {
                let showsSignIn = !status.isChecking && !isSignedIn && !provider.loginCommand.isEmpty
                let updateState: ProviderUpdateViewState? = provider.isAPIKeyBased ? nil : {
                    let update = registry.cliUpdates[provider]
                    let phase: ProviderUpdateViewState.Phase
                    switch update?.phase {
                    case .checking: phase = .checking
                    case .current: phase = .current
                    case nil: phase = settings.monitorsUpdates(provider) ? .checking : .current
                    case .available: phase = .available
                    case .waiting: phase = .waiting
                    case .updating: phase = .updating
                    case .updated: phase = .updated
                    case .failed: phase = .failed
                    }
                    return ProviderUpdateViewState(
                        phase: phase,
                        installed: update?.installed ?? status.version,
                        latest: update?.latest,
                        command: update?.channel?.command,
                        error: update?.error,
                        updateFailed: update?.updateFailed ?? false,
                        monitoringEnabled: registry.monitorsCLIUpdates(provider),
                        customBinaryPath: !settings.binaryPath(for: provider).isEmpty,
                        channelKnown: update?.channel != nil
                    )
                }()
                ChromeCard {
                    HStack(spacing: 12) {
                        ProviderIcon(provider: provider, size: 18)
                            .foregroundStyle(Chrome.primaryText)
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: Chrome.localized(status.isChecking ? "Checking…" : status.summary))
                                .font(.ui(size: 13))
                            if status.isInstalled, let updateState {
                                ProviderUpdateSubtitle(state: updateState)
                            } else if provider.isAPIKeyBased, status.apiKeyConfigured, let host = provider.apiHost {
                                Text(verbatim: String(format: Chrome.localized("Native API · %@"), host))
                                    .font(.ui(.subheadline))
                                    .foregroundStyle(Chrome.secondaryText)
                            }
                        }
                        Spacer()
                        if status.isInstalled, let updateState {
                            ProviderUpdateAction(
                                state: updateState,
                                onCheck: { Task { await registry.checkCLIUpdate(provider, force: true) } },
                                onUpdate: { Task { await registry.updateCLI(provider) } }
                            )
                        }
                    }
                    .padding(.leading, 16)
                    .padding(.trailing, Chrome.rowControlTrailingPadding)
                    .padding(.vertical, 11)
                    if showsUsage {
                        ChromeRowDivider()
                        VStack(alignment: .leading, spacing: 14) {
                            if PlanLimitsReader.exposesLimits(provider) {
                                PlanLimitsView(provider: provider)
                            }
                            if CreditsReader.exposesCredits(provider) {
                                CreditsView(provider: provider)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                    }
                    if provider == .zai {
                        ChromeRowDivider()
                        ChromeRow(title: "Region", detail: "Where your key was issued. Global uses api.z.ai, China uses open.bigmodel.cn.") {
                            GlassPickerButton(options: Self.regionOptions, selection: Binding(
                                get: { settings.zaiRegion },
                                set: { settings.zaiRegion = $0 }
                            ))
                        }
                    }
                    if provider == .dsh || provider == .minimaxCode, let error = status.catalogError {
                        ChromeRowDivider()
                        ChromeRow(title: "Models", detail: error) {
                            EmptyView()
                        }
                    }
                    if provider == .minimaxCode {
                        ChromeRowDivider()
                        ChromeRow(title: "Authentication", detail: "Tivano uses the authentication route already selected in mcode. Token Plan uses your existing mcode sign-in; API-key users keep their configured key. Local checks and model lists do not verify server authentication.") {
                            Link(destination: URL(string: "https://agent.minimax.io/docs/cli/configuration")!) {
                                Text("Setup guide").frame(height: Chrome.rowButtonLabelHeight)
                            }
                            .buttonStyle(.glass)
                        }
                        ChromeRowDivider()
                        ChromeRow(title: "CLI updates", detail: "Update MiniMax Code with its official installer or the documented npm command.") {
                            Link(destination: provider.installURL) {
                                Text("Setup guide").frame(height: Chrome.rowButtonLabelHeight)
                            }
                            .buttonStyle(.glass)
                        }
                        ChromeRowDivider()
                        ChromeRow(title: "Attachments and usage", detail: "MiniMax Code currently uses text input in Tivano. Image attachments, plan balances and token-spend accounting are not enabled.") {
                            EmptyView()
                        }
                    }
                    if provider.acceptsAPIKey {
                        ChromeRowDivider()
                        ChromeRow(
                            title: provider.isAPIKeyBased ? "API key" : "API key (optional)",
                            detail: apiKeyDetail
                        ) {
                            HStack(spacing: 8) {
                                Group {
                                    if showsAPIKey {
                                        TextField("", text: $apiKey, prompt: Text(verbatim: Chrome.localized(provider == .zai ? ZaiRegion.apiKeyPlaceholder : "sk-…")))
                                    } else {
                                        SecureField("", text: $apiKey, prompt: Text(verbatim: Chrome.localized(provider == .zai ? ZaiRegion.apiKeyPlaceholder : "sk-…")))
                                    }
                                }
                                .textFieldStyle(.roundedBorder)
                                .font(.ui(size: 12, design: .monospaced))
                                .frame(width: 200)
                                Button {
                                    showsAPIKey.toggle()
                                } label: {
                                    Image(systemName: showsAPIKey ? "eye.slash" : "eye")
                                        .font(.ui(size: 12))
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(Chrome.secondaryText)
                                .help(Text(verbatim: Chrome.localized(showsAPIKey ? "Hide the API key" : "Show the API key")))
                                .accessibilityLabel(Text(verbatim: Chrome.localized(showsAPIKey ? "Hide the API key" : "Show the API key")))
                            }
                        }
                        if provider.isAPIKeyBased, !status.isInstalled {
                            ChromeRowDivider()
                            ChromeRow(title: "Get a key", detail: provider == .zai
                                ? "Z.ai needs a GLM Coding Plan key. Standard API keys will not work here. Nothing to install."
                                : String(format: Chrome.localized("%@ needs an API key. Nothing to install."), provider.displayName)) {
                                Link(destination: provider.installURL) {
                                    Text(verbatim: String(format: Chrome.localized("Get a %@ key"), provider.displayName))
                                        .frame(height: Chrome.rowButtonLabelHeight)
                                }
                                .buttonStyle(.glass)
                            }
                        }
                    }
                    if let updateState {
                        ChromeRowDivider()
                        ProviderUpdateMonitoringRow(state: updateState, isOn: Binding(
                            get: { settings.monitorsUpdates(provider) },
                            set: { settings.setMonitorsUpdates($0, for: provider) }
                        ))
                        ChromeRowDivider()
                        ChromeRow(title: "Binary path", detail: status.executable?.path) {
                            TextField("", text: $binaryPath, prompt: Text(provider.executableName))
                                .textFieldStyle(.roundedBorder)
                                .font(.ui(size: 12, design: .monospaced))
                                .frame(width: 200)
                        }
                        if !status.isInstalled {
                            ChromeRowDivider()
                            let missing = String(format: Chrome.localized("%@ was not found on your PATH."), provider.displayName)
                            let detail = LoginEnvironment.diagnostic.map { missing + " " + $0 } ?? missing
                            ChromeRow(title: "Install", detail: detail) {
                                Link(destination: provider.installURL) {
                                    Text(verbatim: String(format: Chrome.localized("Get %@"), provider.displayName))
                                        .frame(height: Chrome.rowButtonLabelHeight)
                                }
                                .buttonStyle(.glass)
                            }
                        } else if showsSignIn {
                            ChromeRowDivider()
                            let signInDetail = provider == .dsh
                                ? (registry.signingIn == .dsh
                                    ? "Waiting for you to sign in to DeepSeek Harness…"
                                    : signInError ?? (FileManager.default.fileExists(atPath: "/Applications/DeepSeek Harness.app")
                                        ? "Opens DeepSeek Harness to sign in to your DeepSeek account."
                                        : "Opens your browser to sign in to your DeepSeek account."))
                                : signInError ?? "Click here to login again."
                            ChromeRow(title: provider == .minimaxCode ? "Token Plan sign-in" : "Sign in", detail: provider == .minimaxCode
                                ? "Use mcode login for Token Plan, or mcode login --region global for Global accounts. If already signed in, refresh the provider. API-key users do not need this step."
                                : signInDetail) {
                                if provider == .dsh {
                                    HStack(spacing: 8) {
                                        if registry.signingIn == .dsh {
                                            ProgressView().controlSize(.mini)
                                            Button("Cancel") { signInTask?.cancel() }
                                                .disabled(signInTask == nil)
                                        } else {
                                            Button {
                                                signInError = nil
                                                signInTask = Task {
                                                    signInError = await registry.signIn(provider)
                                                    signInTask = nil
                                                }
                                            } label: {
                                                Text(verbatim: Chrome.localized("Login")).frame(height: Chrome.rowButtonLabelHeight)
                                            }
                                            .disabled(registry.signingIn != nil)
                                        }
                                    }
                                    .buttonStyle(.glass)
                                } else {
                                    Button {
                                        Workspace.openTerminal(running: provider.loginCommand)
                                    } label: {
                                        Text(verbatim: Chrome.localized("Login")).frame(height: Chrome.rowButtonLabelHeight)
                                    }
                                    .buttonStyle(.glass)
                                }
                            }
                        }
                    }
                }
            }
            // Collapsed content is neither focusable, tappable nor in the accessibility
            // tree; the clip reveals it top-anchored as the fraction slides.
            .clipped()
            .disabled(!isExpanded)
            .allowsHitTesting(isExpanded)
            .accessibilityHidden(!isExpanded)
        }
        .onDisappear { signInTask?.cancel() }
        .onAppear {
            binaryPath = settings.binaryPath(for: provider)
            if provider.acceptsAPIKey { apiKey = settings.apiKeyInput(for: provider) }
        }
        .onChange(of: showsUsage, initial: true) { _, shows in
            // Fires once when the page opens on a signed-in account and again when a check signs
            // one in. Sections are eager, so scrolling never re-fires it, and the registry hands
            // back what it read within the last minute instead of asking the provider again.
            guard shows else { return }
            registry.refreshPlanLimits(provider)
            registry.refreshCredits(provider)
        }
        .onChange(of: binaryPath) { _, value in
            guard value != settings.binaryPath(for: provider) else { return }
            settings.setBinaryPath(value, for: provider)
        }
        .onChange(of: provider == .zai ? settings.zaiRegion : nil) { _, _ in
            guard provider == .zai else { return }
            Task {
                await registry.refresh(provider)
                await registry.loadCatalog(provider, force: true)
            }
        }
        .onChange(of: settings.monitorsUpdates(provider)) { _, _ in
            registry.cliMonitoringChanged(provider)
        }
        .onChange(of: settings.isEnabled(provider)) { _, enabled in
            registry.cliMonitoringChanged(provider)
            if provider == .dsh, enabled {
                Task {
                    await registry.refresh(provider)
                    await registry.loadCatalog(provider)
                }
            }
        }
        .onChange(of: settings.binaryPath(for: provider)) { _, _ in
            registry.cliMonitoringChanged(provider)
        }
        .onChange(of: apiKey) { _, value in
            // Only an edit counts: loading the stored key into the field must not save or check it.
            guard provider.acceptsAPIKey, value != settings.apiKeyInput(for: provider) else { return }
            settings.setAPIKeyInput(value, for: provider)
            // The registry observes DeepSeek changes even when this page is closed.
            guard provider != .deepseek else { return }
            keyCheck?.cancel()
            keyCheck = Task {
                try? await Task.sleep(for: .milliseconds(600))
                guard !Task.isCancelled else { return }
                await registry.refresh(provider)
                await registry.loadCatalog(provider, force: true)
            }
        }
        .onChange(of: provider.acceptsAPIKey ? settings.apiKeyInput(for: provider) : nil) { _, value in
            guard let value, value != apiKey else { return }
            apiKey = value
        }
    }
}

private struct SourceControlSettingsPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        GitHubSettingsSection()
        ChromeSection(title: "Cursor Origin") {
            ChromeCard { CursorOriginStatusRow() }
        }
        ChromeSection(title: "Commit message instructions") {
            ChromeCard {
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $settings.commitInstructions)
                        .font(.ui(.body))
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 90)
                    if settings.commitInstructions.isEmpty {
                        Text("For example: use conventional commit prefixes")
                            .font(.ui(.body))
                            .foregroundStyle(Chrome.secondaryText)
                            .padding(.horizontal, 5)
                            .allowsHitTesting(false)
                    }
                }
                .padding(12)
            }
        }
        ChromeSection(title: "Worktrees and pull requests") {
            ChromeCard {
                ChromeRow(title: "Worktrees", detail: Storage.worktreesDirectory.path) {
                    Button("Reveal") { Workspace.revealInFinder(Storage.worktreesDirectory.path) }
                        .buttonStyle(.glass)
                }
                ChromeRowDivider()
                ChromeRow(title: "Pull requests", detail: "Opened with the GitHub CLI (gh), GitLab CLI (glab), Cursor Origin CLI (origin) or Gitea CLI (tea) from your PATH.") {
                    EmptyView()
                }
            }
        }
    }
}

/// Whether the `origin` CLI that opens and merges Cursor Origin pull requests is installed
/// and signed in, read from `origin auth status`.
private struct CursorOriginStatusRow: View {
    private enum Status: Equatable {
        case checking, missing, signedOut, signedIn(String?)
    }

    @State private var status = Status.checking

    var body: some View {
        ChromeRow(title: "Origin CLI", detail: detail) {
            if status == .signedOut {
                Button("Copy command") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("origin auth login", forType: .string)
                }
                .buttonStyle(.glass)
            }
        }
        .task { status = await Self.check() }
    }

    private var detail: String {
        switch status {
        case .checking: Chrome.localized("Checking…")
        case .missing: Chrome.localized("The origin CLI is not on your PATH.")
        case .signedOut: Chrome.localized("Not signed in. Run `origin auth login` in Terminal.")
        case .signedIn(let account?): String(format: Chrome.localized("Signed in as %@"), account)
        case .signedIn(nil): Chrome.localized("Signed in")
        }
    }

    private static func check() async -> Status {
        guard LoginEnvironment.which("origin") != nil else { return .missing }
        guard let result = try? await Shell.run(tool: "origin", ["auth", "status"], timeout: 20) else { return .signedOut }
        let text = TextCleanup.stripANSI(result.output + "\n" + result.errorOutput)
        guard result.succeeded, text.range(of: "Token:\\s+valid", options: .regularExpression) != nil else { return .signedOut }
        let account = text.firstMatch(of: /Account:[ \t]*(\S+)/).map { String($0.output.1) }
        return .signedIn(account)
    }
}

private struct ArchiveDeleteAllButton: View {
    @Environment(AppModel.self) private var model
    let threadIDs: Set<UUID>
    let isFiltered: Bool
    @State private var isConfirming = false
    @State private var pendingIDs: Set<UUID> = []
    @State private var pendingIsFiltered = false

    var body: some View {
        ChromeTextButton(
            symbol: "trash",
            title: String(format: Chrome.localized(isFiltered ? "Delete matching chats (%lld)" : "Delete all archived chats (%lld)"), threadIDs.count),
            help: isFiltered ? "Delete matching archived chats" : "Delete every archived thread",
            isEnabled: !threadIDs.isEmpty,
            isDestructive: true
        ) {
            if model.settings.confirmBeforeDeleting {
                pendingIDs = threadIDs
                pendingIsFiltered = isFiltered
                isConfirming = true
            } else {
                model.deleteArchivedThreads(ids: threadIDs)
            }
        }
        .popover(isPresented: $isConfirming, arrowEdge: .bottom) {
            PopoverMenu {
                PopoverSectionHeader(pendingIsFiltered ? "Delete matching archived chats?" : "Delete all archived threads?")
                PopoverNote(String(format: Chrome.localized(pendingIsFiltered
                    ? "The histories of the %lld matching chats will be removed. Files in your projects stay as they are."
                    : "The histories of all %lld threads will be removed. Files in your projects stay as they are."), pendingIDs.count))
                PopoverDivider()
                PopoverItem(String(format: Chrome.localized("Delete %lld threads"), pendingIDs.count), symbol: "trash", isDestructive: true) {
                    model.deleteArchivedThreads(ids: pendingIDs)
                    isConfirming = false
                }
            }
        }
    }
}

/// What the archive page shows: lifted into the settings scroll so the chrome row's search
/// field and Delete all act on the same rows as the page.
struct ArchiveFilter: Equatable {
    enum ChatType: CaseIterable {
        case all, chats, heads

        var title: String {
            switch self {
            case .all: "All chats"
            case .chats: "Chats"
            case .heads: "Hydra heads"
            }
        }
    }

    enum ProjectScope: Hashable {
        case all, project(UUID), none
    }

    var query = ""
    var chatType: ChatType = .all
    var project: ProjectScope = .all

    var isActive: Bool { !search.isEmpty || chatType != .all || project != .all }
    private var search: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The archive's projects, by name, for the project picker and the groups.
    static func projects(in archived: [ChatThread], from all: [Project]) -> [Project] {
        let ids = Set(archived.compactMap(\.projectID))
        return all.filter { ids.contains($0.id) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func scope(of thread: ChatThread, known: Set<UUID>) -> ProjectScope {
        thread.projectID.flatMap { known.contains($0) ? .project($0) : nil } ?? .none
    }

    func apply(to archived: [ChatThread], known: Set<UUID>) -> [ChatThread] {
        let search = search
        return archived.filter { thread in
            let matchesType = chatType == .all || (chatType == .heads ? thread.isHydraHead : !thread.isHydraHead)
            let matchesProject = project == .all || project == Self.scope(of: thread, known: known)
            let matchesSearch = search.isEmpty || [thread.title, thread.hydra?.persona.name ?? "", thread.hydra?.task ?? ""].contains {
                $0.range(of: search, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
            return matchesType && matchesProject && matchesSearch
        }
    }
}

/// The archive page's chrome row: its search field and Delete all, which deletes what is shown.
private struct ArchiveChromeControls: View {
    @Environment(AppModel.self) private var model
    @Binding var filter: ArchiveFilter

    var body: some View {
        let archived = model.archivedThreads
        let known = Set(ArchiveFilter.projects(in: archived, from: model.projects).map(\.id))
        ChromeSearchField(query: $filter.query, prompt: "Search archived chats")
        ArchiveDeleteAllButton(threadIDs: Set(filter.apply(to: archived, known: known).map(\.id)), isFiltered: filter.isActive)
    }
}

private struct ArchiveSettingsPage: View {
    @Environment(AppModel.self) private var model
    @Binding var filter: ArchiveFilter
    @State private var pendingDeletion: ArchiveRow?

    private struct ArchiveRow: Identifiable {
        let thread: ChatThread
        let title: String
        var id: UUID { thread.id }
    }

    private struct ArchiveGroup: Identifiable {
        let id: ArchiveFilter.ProjectScope
        let title: String
        let rows: [ArchiveRow]
    }

    var body: some View {
        let archived = model.archivedThreads
        let projects = ArchiveFilter.projects(in: archived, from: model.projects)
        let known = Set(projects.map(\.id))
        let options: [(value: ArchiveFilter.ProjectScope, title: String)] = [(.all, "All projects")]
            + projects.map { (.project($0.id), $0.name) } + [(.none, "No project")]
        let rows = filter.apply(to: archived, known: known).map { thread in
            let title: String
            if let info = thread.hydra, !info.task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                title = "\(info.persona.name) · \(info.task)"
            } else {
                title = thread.title
            }
            return ArchiveRow(thread: thread, title: title)
        }
        let grouped = Dictionary(grouping: rows) { ArchiveFilter.scope(of: $0.thread, known: known) }
        let groups = options.filter { $0.value != .all }.compactMap { option -> ArchiveGroup? in
            guard let rows = grouped[option.value], !rows.isEmpty else { return nil }
            return ArchiveGroup(id: option.value, title: option.title, rows: rows)
        }
        VStack(alignment: .leading, spacing: Chrome.pageSectionSpacing) {
            HStack(spacing: 8) {
                GlassPickerButton(options: ArchiveFilter.ChatType.allCases.map { ($0, $0.title) }, selection: $filter.chatType)
                    .accessibilityLabel(Text("Chat type"))
                GlassPickerButton(options: options, selection: $filter.project, symbol: { _ in "folder" })
                    .accessibilityLabel(Text("Project"))
            }
            if groups.isEmpty {
                Text("No matching chats")
                    .font(.ui(.body))
                    .foregroundStyle(Chrome.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, Chrome.sectionSpacing)
            }
            ForEach(groups) { group in
                ChromeSection(
                    title: group.title,
                    trailing: AnyView(Text(verbatim: String(format: Chrome.localized("%lld chats"), group.rows.count))
                        .font(.ui(.body))
                        .foregroundStyle(Chrome.secondaryText))
                ) {
                    ChromeCard(lazy: true) {
                        ForEach(group.rows) { row in
                            if row.id != group.rows.first?.id { ChromeRowDivider() }
                            ChromeRow(title: row.title) {
                                HStack(spacing: 8) {
                                    Button("Restore") { model.unarchive(row.id) }
                                        .buttonStyle(.glass)
                                    Button("Delete", role: .destructive) {
                                        if model.settings.confirmBeforeDeleting {
                                            pendingDeletion = row
                                        } else {
                                            model.delete(row.id)
                                        }
                                    }
                                    .buttonStyle(.glass)
                                }
                                .controlSize(.small)
                            }
                        }
                    }
                }
            }
        }
        .confirmationDialog(
            pendingDeletion.map { String(format: Chrome.localized("Delete \"%@\"?"), $0.title) } ?? Chrome.localized("Delete the archived thread?"),
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            presenting: pendingDeletion
        ) { row in
            Button("Delete thread", role: .destructive) {
                model.delete(row.id)
                pendingDeletion = nil
            }
        } message: { _ in
            Text("Its history will be removed. Files in your project stay as they are.")
        }
    }
}

private struct AboutSettingsPage: View {
    private static let upstreamURL = URL(string: "https://getdroppycode.app")!
    private static let zeronURL = URL(string: "https://github.com/zeronsh/zeron")!
    private static let swiftTermURL = URL(string: "https://github.com/migueldeicaza/SwiftTerm")!

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Brings its own gap below, and only while it shows a card, so an empty one
            // leaves no hole under the page title; a new release pushes the rest down.
            AboutSoftwareUpdateSection()
            VStack(alignment: .leading, spacing: Chrome.pageSectionSpacing) {
                ChromeSection(title: "Version information") {
                    appCard
                }
                credits
            }
        }
    }

    private var credits: some View {
        ChromeSection(title: "Credits") {
            ChromeCard {
                UpstreamAttributionRow(url: Self.upstreamURL)
                ChromeRowDivider()
                ChromeRow(title: "Working indicators", detail: "Ported from Zeron by Wing, MIT License.") {
                    CreditLink(title: "zeronsh/zeron", url: Self.zeronURL)
                }
                ChromeRowDivider()
                ChromeRow(title: "Terminal", detail: "SwiftTerm by Miguel de Icaza, MIT License.") {
                    CreditLink(title: "SwiftTerm", url: Self.swiftTermURL)
                }
                ChromeRowDivider()
                LicensesRow()
            }
        }
    }

    private var appCard: some View {
        ChromeCard {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Tivano")
                        .font(.ui(.title3, weight: .semibold))
                    Text(verbatim: String(format: Chrome.localized("Version %@ (%@)"), AppInfo.version, AppInfo.build))
                        .font(.ui(.callout))
                        .foregroundStyle(Chrome.secondaryText)
                }
                Spacer()
            }
            .padding(16)
            ChromeRowDivider()
            AboutUpdateCheckRow()
        }
    }
}

/// The license, the third-party notices and the trademark policy, as shipped in the bundle,
/// read in a popover: every copy of the app carries the notices for what it builds on.
private struct LicensesRow: View {
    @State private var isPresented = false

    private static let files: [(title: String, resource: String)] = [
        ("Tivano", "LICENSE"),
        ("Third-party notices", "THIRD_PARTY_NOTICES"),
        ("Trademarks", "TRADEMARK"),
    ]

    var body: some View {
        ChromeRow(title: "Licenses", detail: "AGPL-3.0 with attribution terms, and the notices for what the app builds on.") {
            Button("Show") { isPresented = true }
                .buttonStyle(.glass)
                .controlSize(.small)
                .popover(isPresented: $isPresented, arrowEdge: .bottom) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            ForEach(Self.files, id: \.resource) { file in
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(verbatim: Chrome.localized(file.title))
                                        .font(.ui(.body, weight: .semibold))
                                    MarkdownView(text: Self.text(of: file.resource)).equatable()
                                        .environment(\.markdownPointSize, TypeScale.shared.content(12))
                                        .foregroundStyle(Chrome.secondaryText)
                                        .textSelection(.enabled)
                                }
                            }
                        }
                        .padding(18)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(width: 480, height: 440)
                    .presentedChrome()
                }
        }
    }

    /// Read from the bundle once: the popover's body runs on every hover and scroll, and
    /// the markdown it now renders is parsed from this text each time as it is.
    private static let texts: [String: String] = Dictionary(uniqueKeysWithValues: files.map { file in
        let url = Bundle.main.url(forResource: file.resource, withExtension: file.resource == "LICENSE" ? nil : "md")
        let text = url.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? String(format: Chrome.localized("The %@ file is missing from this copy of the app."), file.resource)
        return (file.resource, text)
    })

    private static func text(of resource: String) -> String {
        texts[resource] ?? String(format: Chrome.localized("The %@ file is missing from this copy of the app."), resource)
    }
}

/// The upstream project, named and linked: the license keeps the credit for Droppy Code
/// with its author, so the fork's About page carries it.
private struct UpstreamAttributionRow: View {
    let url: URL
    @State private var isHovering = false

    var body: some View {
        Link(destination: url) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Based on Droppy Code")
                        .font(.ui(.body, weight: .semibold))
                        .foregroundStyle(Chrome.primaryText)
                    Text("Droppy Code by Jordy Spruit (Droppy)")
                        .font(.ui(.subheadline))
                        .foregroundStyle(Chrome.secondaryText)
                }
                Spacer(minLength: 12)
                HStack(spacing: 4) {
                    Text(verbatim: "getdroppycode.app")
                    Image(systemName: "arrow.up.right")
                        .font(.ui(.footnote, weight: .semibold))
                }
                .font(.ui(.callout, weight: .medium))
                .foregroundStyle(Chrome.accent)
                .opacity(isHovering ? 1 : 0.9)
            }
            .padding(.leading, 16)
            .padding(.trailing, Chrome.rowControlTrailingPadding + 4)
            .padding(.vertical, 12)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(Chrome.hover) { isHovering = hovering }
        }
        .help(Text(verbatim: Chrome.localized("Open getdroppycode.app")))
        .accessibilityLabel(Text("Based on Droppy Code by Jordy Spruit. Open getdroppycode.app"))
    }
}

private struct CreditLink: View {
    let title: String
    let url: URL

    var body: some View {
        Link(destination: url) {
            HStack(spacing: 4) {
                Text(verbatim: title)
                Image(systemName: "arrow.up.right")
                    .font(.ui(.footnote, weight: .semibold))
            }
            .font(.ui(.callout, weight: .medium))
            .foregroundStyle(Chrome.accent)
        }
        .buttonStyle(.plain)
        .help(url.absoluteString)
    }
}

/// The theme menu: Breeze (Tivano's own) and System on top, then the dark and the
/// light themes in their own sections, each with a swatch of its surface and accent.
/// Breeze Dark and Breeze Light lead their sections.
private struct ThemePickerButton: View {
    @Binding var selection: AppTheme

    @State private var isPresented = false
    @State private var isHovering = false

    private static let dark = AppTheme.allCases.filter { $0.scheme == .dark }
    private static let light = AppTheme.allCases.filter { $0.scheme == .light }

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            HStack(spacing: 6) {
                selection.swatch
                    .frame(width: 14, height: 14)
                Text(verbatim: selection.displayName)
                    .font(.ui(size: 12.5, weight: .medium))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Chrome.secondaryText)
            }
            .foregroundStyle(Chrome.primaryText.opacity(isHovering || isPresented ? 1 : 0.92))
            .padding(.horizontal, Chrome.capsuleHorizontalPadding)
            .frame(height: Chrome.capsuleContentHeight)
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .fixedSize()
        .chromeGlassCapsule()
        .onHover { hovering in
            withAnimation(Chrome.hover) { isHovering = hovering }
        }
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            PopoverMenu {
                item(.breeze)
                item(.system)
                PopoverSectionHeader("Dark")
                ForEach(Self.dark) { item($0) }
                PopoverSectionHeader("Light")
                ForEach(Self.light) { item($0) }
            }
        }
    }

    private func item(_ theme: AppTheme) -> some View {
        PopoverItem(theme.displayName, leading: AnyView(theme.swatch), isChecked: theme == selection, localizesTitle: false) {
            selection = theme
        }
    }
}
