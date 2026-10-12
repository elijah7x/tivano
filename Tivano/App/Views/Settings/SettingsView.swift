import AppKit
import SwiftUI

enum SettingsPage: String, CaseIterable, Identifiable {
    case general
    // Second in the sidebar: Hydra is what the app is about, so it sits right under General.
    case hydra
    case appearance
    case providers
    case models
    case mcp
    case sourceControl
    case shortcuts
    case archive
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .appearance: "Appearance"
        case .providers: "Providers"
        case .mcp: "MCP"
        case .models: "Models"
        case .hydra: "Hydra"
        case .sourceControl: "Source control"
        case .shortcuts: "Shortcuts"
        case .archive: "Archive"
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
        // Never drawn: the sidebar gives the Hydra row the dragon mark instead. Kept so
        // the switch stays exhaustive and anything else that asks gets a sane symbol.
        case .hydra: "point.3.connected.trianglepath.dotted"
        case .sourceControl: "arrow.triangle.branch"
        case .shortcuts: "command"
        case .archive: "archivebox"
        case .about: "info.circle"
        }
    }

    var tint: Color {
        switch self {
        case .general: Chrome.gray
        case .appearance: Color(red: 0.85, green: 0.44, blue: 0.36)
        case .providers: Chrome.blue
        case .mcp: Color(red: 0.95, green: 0.55, blue: 0.20)
        case .models: Color(red: 0.686, green: 0.322, blue: 0.871)
        case .hydra: Color(red: 0.188, green: 0.690, blue: 0.780)
        case .sourceControl: Color(red: 0.345, green: 0.337, blue: 0.839)
        case .shortcuts: Color(red: 0.32, green: 0.48, blue: 0.93)
        case .archive: Chrome.orange
        case .about: Color(red: 0.204, green: 0.780, blue: 0.349)
        }
    }

    var keywords: [String] {
        switch self {
        case .general: ["permissions", "worktree", "reasoning", "thinking", "notifications", "token", "tokens", "activity", "usage", "panel", "limits", "credits", "heatmap", "daily", "weekly", "cumulative", "settle", "settled", "finish", "finished", "done", "sound", "chime", "icon", "icons", "emoji", "symbol", "symbols", "project mark", "compact", "concise", "anti-slop", "slop", "verbose", "comments", "replies"]
        case .appearance: ["appearance", "theme", "transparency", "transparent", "opacity", "glass", "clear", "clearer", "liquid glass", "blur", "dark", "light", "accent", "tint", "catppuccin", "dracula", "tokyo", "nord", "gruvbox", "solarized", "github", "claude", "codex", "cursor", "matrix", "text", "size", "font", "zoom", "wallpaper", "sidebar", "performance", "gpu"]
        case .models: ["model", "effort", "reasoning", "fast", "slider", "picker"]
        case .hydra: ["hydra", "heads", "subagents", "sub-agents", "agents", "team", "orchestrator", "worker", "pair", "pairs", "parallel", "delegate", "queue"]
        case .providers: ["kimi", "pi", "codex", "claude", "cursor", "opencode", "opencode zen", "opencode go", "zen", "grok", "deepseek", "meta", "muse", "spark", "zai", "z.ai", "glm", "coding plan", "devin", "cognition", "antigravity", "agy", "google", "gemini", "copilot", "github", "command code", "commandcode", "cmd", "binary", "path", "sign in", "login", "api key", "usage", "limits", "limit", "plan", "quota", "credits", "balance"]
        case .mcp: ["mcp", "model context protocol", "servers", "tools", "connect", "integrations", "github", "playwright", "notion", "linear", "slack", "figma", "supabase", "stripe", "resend", "email", "context7", "sentry", "postgres", "browser", "netlify", "deploy", "hosting"]
        case .sourceControl: ["git", "commit", "pull request", "titles", "text generation", "github", "clone", "repository", "repositories", "repo", "sign in", "token", "connect", "account"]
        case .shortcuts: ["keyboard", "keys"]
        case .archive: ["archived", "restore"]
        case .about: ["version", "license"]
        }
    }
}

extension SettingsPage {
    var startsNavGroup: Bool { self == .providers || self == .shortcuts }
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
    @State private var page: SettingsPage = .general
    @State private var search = ""
    @State private var scrollTracker = SettingsScrollTracker()

    private var visiblePages: [SettingsPage] {
        let query = search.trimmed
        guard !query.isEmpty else { return SettingsPage.allCases }
        return SettingsPage.allCases.filter { page in
            page.title.localizedCaseInsensitiveContains(query)
                || page.keywords.contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 212)
            SettingsDetail(page: page, fullWindow: false)
                .padding(.trailing, Chrome.sheetInset)
                .padding(.vertical, Chrome.sheetInset)
        }
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

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear
                .frame(height: Chrome.trafficLightDiameter)
                .padding(.top, Chrome.trafficLightTop)
            SidebarSearchField(text: $search) {
                if let first = visiblePages.first { page = first }
            }
            .padding(.horizontal, Chrome.listInset)
            .padding(.top, 14)
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(visiblePages) { item in
                        SidebarRow(title: item.title, isSelected: page == item, action: { page = item }) {
                            SidebarIconBadge {
                                if item == .hydra {
                                    // The Hydra page wears the dragon mark, the same one as the composer button.
                                    HydraMarkImage()
                                        .frame(width: Chrome.symbolSize * 1.15, height: Chrome.symbolSize * 1.15)
                                } else {
                                    SidebarSymbol(item.symbol, scale: item == .general ? 1.15 : 1)
                                }
                            }
                            .overlay(alignment: .topTrailing) {
                                if item == .about, UpdateChecker.shared.updateAvailable {
                                    UpdateAvailableDot()
                                }
                            }
                        }
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

struct SettingsSidebar: View {
    @Bindable private var navigation = SettingsNavigation.shared
    @State private var search = ""
    @State private var scrollTracker = SettingsScrollTracker()

    private var page: SettingsPage { navigation.page }

    private var visiblePages: [SettingsPage] {
        let query = search.trimmed
        guard !query.isEmpty else { return SettingsPage.allCases }
        return SettingsPage.allCases.filter { page in
            Chrome.localized(page.title).localizedCaseInsensitiveContains(query)
                || page.title.localizedCaseInsensitiveContains(query)
                || page.keywords.contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear
                .frame(height: Chrome.trafficLightDiameter)
                .padding(.top, Chrome.trafficLightTop)
            SidebarRow(title: "Back", action: { WindowManager.shared.hideSettings() }) {
                SidebarIconBadge { SidebarSymbol("arrow.left") }
            }
            .help("Back to your threads")
            .padding(.horizontal, Chrome.listInset)
            .padding(.top, 10)
            SidebarSearchField(text: $search) {
                if let first = visiblePages.first { navigation.page = first }
            }
            .padding(.horizontal, Chrome.listInset)
            .padding(.top, 14)
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(visiblePages) { item in
                        SidebarRow(title: item.title, isSelected: page == item, action: { navigation.page = item }) {
                            SidebarIconBadge {
                                if item == .hydra {
                                    // The Hydra page wears the dragon mark, the same one as the composer button.
                                    HydraMarkImage()
                                        .frame(width: Chrome.symbolSize * 1.15, height: Chrome.symbolSize * 1.15)
                                } else {
                                    SidebarSymbol(item.symbol, scale: item == .general ? 1.15 : 1)
                                }
                            }
                            .overlay(alignment: .topTrailing) {
                                if item == .about, UpdateChecker.shared.updateAvailable {
                                    UpdateAvailableDot()
                                }
                            }
                        }
                        .padding(.top, item.startsNavGroup && search.trimmed.isEmpty ? Chrome.sectionHeaderSpacing : 0)
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
    @Environment(AppModel.self) private var model
    let page: SettingsPage
    var fullWindow = true
    @State private var modelSearch = ""
    @State private var mcpSearch = ""
    @State private var scrollChrome = ChromeScrollModel()
    @State private var scrollTracker = SettingsScrollTracker()

    var body: some View {
        Group {
            if page == .archive, model.archivedThreads.isEmpty {
                // An empty archive is one symbol in the middle of the pane: no sentence, no chrome,
                // no button with nothing to delete.
                Image(systemName: "archivebox")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(Chrome.secondaryText.opacity(0.6))
                    .accessibilityLabel(Text("No archived threads"))
            } else {
                pageScroll
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .detailSheet()
        .onDisappear { scrollTracker.end() }
        .onChange(of: page, initial: true) {
            scrollChrome.update(travel: 0)
            modelSearch = ""
            mcpSearch = ""
        }
    }

    private var pageScroll: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Chrome.sectionSpacing) {
                if fullWindow {
                    Text(verbatim: Chrome.localized(page.title))
                        .font(.ui(.title2, weight: .medium))
                        .foregroundStyle(Chrome.primaryText)
                        .accessibilityAddTraits(.isHeader)
                }
                pageContent
            }
            .frame(maxWidth: fullWindow ? 680 : .infinity, alignment: .leading)
            .padding(.horizontal, fullWindow ? Chrome.contentHorizontalPadding * 2 : Chrome.contentHorizontalPadding + 8)
            .frame(maxWidth: .infinity)
            // Full-window pages clear the titlebar; the old window keeps its existing inset.
            .padding(.top, fullWindow || pageHasChromeControls ? Chrome.chromeTopPadding + Chrome.capsuleHeight + 16 : 22)
            .padding(.bottom, fullWindow ? Chrome.contentHorizontalPadding * 2 : 24)
            .allowsHitTesting(!scrollTracker.isFrozen)
        }
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
            HStack(spacing: 10) {
                ChromeCompactTitle(title: page.title, model: scrollChrome)
                if page == .models {
                    ChromeSearchField(query: $modelSearch, prompt: "Search models")
                }
                if page == .mcp {
                    ChromeSearchField(query: $mcpSearch, prompt: "Search servers")
                }
                if page == .providers {
                    ProvidersRefreshButton()
                }
                if page == .archive {
                    ArchiveDeleteAllButton()
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
        case .sourceControl: SourceControlSettingsPage()
        case .shortcuts: ShortcutsSettingsPage()
        case .archive: ArchiveSettingsPage()
        case .about: AboutSettingsPage()
        }
    }

    private nonisolated static func travel(_ geometry: ScrollGeometry) -> CGFloat {
        geometry.contentOffset.y + geometry.contentInsets.top
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

    var body: some View {
        @Bindable var settings = model.settings
        // The Token activity heatmap leads the page: it summarizes what the
        // settings below configure, rather than configuring anything itself.
        TokenActivitySection()
        ChromeSection(title: "New threads") {
            ChromeCard {
                // No picker: a new thread follows the one it is made from, and the composer's
                // model picker is where the provider is chosen (see `AppModel.newThread`).
                ChromeRow(title: "Provider and model", detail: "A new thread follows the one you are in: its provider, model, effort and Hydra pair. With no thread open it starts on the provider you last chose.") {
                    EmptyView()
                }
                ChromeRowDivider()
                ChromeRow(title: "Permissions", detail: settings.defaultRuntimeMode.summary) {
                    GlassPickerButton(options: RuntimeMode.allCases.map { ($0, $0.title) }, selection: $settings.defaultRuntimeMode, symbol: { $0.symbol })
                }
                ChromeRowDivider()
                ChromeRow(title: "Workspace", detail: "Where a new thread makes its changes") {
                    ChromeVisualPicker(options: WorkspaceMode.allCases.map { ($0, $0.title) }, selection: $settings.defaultWorkspaceMode) { mode in
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
                        GlassPickerButton(options: TimelineHapticStyle.allCases.map { ($0, $0.title) }, selection: $settings.timelineHapticStyle)
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
                ChromeRowDivider()
                ChromeRow(
                    title: "Show a usage panel",
                    detail: "The plan's limits and credits in a floating panel beside every chat, for the model in use or a pair's two; the usage popover's pop-out button switches it on as well, and it keeps the corner it was last dragged to"
                ) {
                    SettingsSwitch(isOn: $settings.showsUsagePanel)
                }
            }
        }
        ChromeSection(title: "Projects") {
            ChromeCard {
                ChromeRow(title: "Projects", detail: "Activates every project at once unless explicitly overridden") {
                    SettingsSwitch(isOn: $settings.projectsEnabled)
                }
                ChromeRowDivider()
                ChromeRow(title: "Marks", detail: "An emoji or symbol for each project, drawn before the thread's name in the activity list and on the project's own row") {
                    ProjectMarksRow()
                }
            }
        }
        ChromeSection(title: "Finished threads") {
            ChromeCard {
                ChromeRow(title: "Done with a thread", detail: settings.threadFinishAction.detail) {
                    ChromeVisualPicker(options: ThreadFinishAction.allCases.map { ($0, $0.title) }, selection: $settings.threadFinishAction) { action in
                        Image(systemName: action == .settle ? "checkmark" : "archivebox")
                    }
                }
                ChromeRowDivider()
                ChromeRow(title: "Sound when settling", detail: "A small note as the thread settles") {
                    SettingsSwitch(isOn: $settings.settleSound)
                }
                // Switching it on plays the note once, so you hear what you are getting.
                .onChange(of: settings.settleSound) { _, isOn in
                    if isOn { SettleChime.play() }
                }
                .disabled(settings.threadFinishAction != .settle)
                .opacity(settings.threadFinishAction == .settle ? 1 : 0.5)
            }
        }
        ChromeSection(title: "Power") {
            ChromeCard {
                ChromeRow(
                    title: "Prevent sleep while tasks are running",
                    detail: "Keep your Mac awake while Tivano runs tasks. The display can turn off, and you can still sleep manually or close the lid."
                ) {
                    SettingsSwitch(isOn: $settings.preventSleepDuringTasks)
                }
            }
        }
        ChromeSection(title: "Languages") {
            ChromeCard {
                ChromeRow(title: "App language", detail: "Changes apply after the app restarts.") {
                    GlassPickerButton(options: AppLanguage.allCases.map { ($0, $0.title) }, selection: $settings.appLanguage)
                }
            }
        }
    }
}

/// The main interface, font sizes and other appearance settings.
private struct AppearanceSettingsPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        ChromeSection(title: "Main interface") {
            ChromeCard {
                ChromeRow(title: "Theme", detail: settings.theme.detail) {
                    ThemePickerButton(selection: $settings.theme)
                }
                ChromeRowDivider()
                ChromeRow(title: "Transparency", detail: "How much shows through the window") {
                    BackdropOpacitySlider(value: $settings.backdropOpacity)
                }
                .disabled(settings.performanceMode)
                .opacity(settings.performanceMode ? 0.5 : 1)
                ChromeRowDivider()
                ChromeRow(
                    title: "Clearer glass",
                    detail: settings.performanceMode
                        ? "Unavailable in Performance Mode"
                        : WallpaperStore.shared.hasWallpaper
                            ? "Unavailable while a wallpaper is set"
                            : "Shows more of the desktop through the window with Liquid Glass. Uses more GPU while the window's content changes; off uses a lighter system blur."
                ) {
                    SettingsSwitch(isOn: $settings.clearerBackdrop)
                }
                .disabled(settings.performanceMode || WallpaperStore.shared.hasWallpaper)
                .opacity(settings.performanceMode || WallpaperStore.shared.hasWallpaper ? 0.5 : 1)
                ChromeRowDivider()
                ChromeRow(title: "Performance Mode", detail: "Disable window transparency, blurs, glows and background effects for lowest GPU usage") {
                    SettingsSwitch(isOn: $settings.performanceMode)
                }
            }
            WallpaperCard()
        }
        FontSizeSection()
        ChromeSection(title: "Other") {
            ChromeCard {
                ChromeRow(title: "Auto-hide top controls", detail: "Show the upper-right controls only while the pointer is over their area") {
                    SettingsSwitch(isOn: $settings.autoHideTopControls)
                }
                ChromeRowDivider()
                ChromeRow(title: "Open the sidebar at launch", detail: "Collapsed otherwise; the list button in the toolbar shows and hides it any time") {
                    SettingsSwitch(isOn: Binding(
                        get: { model.sidebar.startsOpen },
                        set: { model.sidebar.startsOpen = $0 }
                    ))
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
                .help("Transparent")
            Slider(value: $value, in: 0...1)
                .controlSize(.small)
                .frame(width: 140)
            Image(systemName: "circle.fill")
                .font(.ui(.subheadline))
                .foregroundStyle(Chrome.secondaryText)
                .help("Solid")
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
                .help("Back to the stock look")
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
        /// "Configured" means authenticated: a signed-in provider.
        let configured: (ProviderKind) -> Bool = { provider in
            if case .signedIn = model.providers.status(provider).auth { return true }
            return false
        }
        let enabledProviders = ProviderKind.allCases.filter { model.settings.isEnabled($0) }
        // Eager on purpose: a handful of sections, and lazy ones were rebuilt while scrolling,
        // which reset their fields and re-ran every check they started on appear.
        VStack(alignment: .leading, spacing: Chrome.sectionSpacing) {
            ProviderSelectionSection(settings: model.settings)
            // Configured providers lead, the rest follow; each group keeps allCases' own
            // order (a stable split, not a sort). An auth refresh reorders instantly —
            // only header clicks animate.
            ForEach(enabledProviders.filter(configured) + enabledProviders.filter { !configured($0) }) { provider in
                ProviderSettingsSection(
                    provider: provider,
                    isExpanded: Binding(
                        get: { providerExpansion[provider] ?? configured(provider) },
                        set: { providerExpansion[provider] = $0 }
                    )
                )
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
    /// The page's call: its `providerExpansion` override if the header was touched,
    /// else the auth default (signed-in expands).
    @Binding var isExpanded: Bool

    @State private var binaryPath = ""
    @State private var apiKey = ""
    @State private var showsAPIKey = false
    @State private var keyCheck: Task<Void, Never>?

    /// Limits and credits belong to a signed-in account, so a missing or signed-out provider shows none.
    private var showsUsage: Bool {
        guard PlanLimitsReader.exposesLimits(provider) || CreditsReader.exposesCredits(provider) else { return false }
        let status = model.providers.status(provider)
        return status.isInstalled && status.auth != .signedOut
    }

    /// Whether the page offers a sign-in row: hidden while the provider is signed in and
    /// working, and while a check runs, so it never flashes in before the answer.
    private var showsSignIn: Bool {
        let status = model.providers.status(provider)
        if case .signedIn = status.auth { return false }
        return !status.isChecking
    }

    private var updateState: ProviderUpdateViewState {
        let update = model.providers.cliUpdates[provider]
        let phase: ProviderUpdateViewState.Phase
        switch update?.phase {
        case .checking: phase = .checking
        case .current: phase = .current
        case nil: phase = model.settings.monitorsUpdates(provider) ? .checking : .current
        case .available: phase = .available
        case .waiting: phase = .waiting
        case .updating: phase = .updating
        case .updated: phase = .updated
        case .failed: phase = .failed
        }
        return ProviderUpdateViewState(
            phase: phase,
            installed: update?.installed ?? model.providers.status(provider).version,
            latest: update?.latest,
            command: update?.channel?.command,
            error: update?.error,
            updateFailed: update?.updateFailed ?? false,
            monitoringEnabled: model.providers.monitorsCLIUpdates(provider),
            customBinaryPath: !model.settings.binaryPath(for: provider).isEmpty,
            channelKnown: update?.channel != nil
        )
    }

    var body: some View {
        let status = model.providers.status(provider)
        VStack(alignment: .leading, spacing: Chrome.sectionHeaderSpacing) {
            CollapsibleProviderHeader(provider: provider, isExpanded: $isExpanded, subject: "provider settings")
            ChromeRevealLayout(fraction: isExpanded ? 1 : 0) {
                ChromeCard {
                    HStack(spacing: 12) {
                        ProviderIcon(provider: provider, size: 18)
                            .foregroundStyle(Chrome.primaryText)
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: Chrome.localized(status.isChecking ? "Checking…" : status.summary))
                                .font(.ui(size: 13))
                            if status.isInstalled, !provider.isAPIKeyBased {
                                ProviderUpdateSubtitle(state: updateState)
                            } else if provider.isAPIKeyBased, status.apiKeyConfigured, let host = provider.apiHost {
                                Text(verbatim: String(format: Chrome.localized("Native API · %@"), host))
                                    .font(.ui(size: 11))
                                    .foregroundStyle(Chrome.secondaryText)
                            }
                        }
                        Spacer()
                        if status.isInstalled, !provider.isAPIKeyBased {
                            ProviderUpdateAction(
                                state: updateState,
                                onCheck: { Task { await model.providers.checkCLIUpdate(provider, force: true) } },
                                onUpdate: { Task { await model.providers.updateCLI(provider) } }
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
                    if provider.acceptsAPIKey {
                        ChromeRowDivider()
                        ChromeRow(
                            title: provider.isAPIKeyBased ? "API key" : "API key (optional)",
                            detail: provider.isAPIKeyBased
                                ? String(format: Chrome.localized("Stored in your Keychain. Get one at %@."), provider.apiKeySource ?? Chrome.localized("the provider dashboard"))
                                : String(format: Chrome.localized("Instead of `%@`: a Studio key from %@, stored in your Keychain and handed to the CLI."), provider.loginCommand, provider.apiKeySource ?? Chrome.localized("the provider dashboard"))
                        ) {
                            HStack(spacing: 8) {
                                Group {
                                    if showsAPIKey {
                                        TextField("", text: $apiKey, prompt: Text("sk-…"))
                                    } else {
                                        SecureField("", text: $apiKey, prompt: Text("sk-…"))
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
                            }
                        }
                        if provider.isAPIKeyBased, !status.isInstalled {
                            ChromeRowDivider()
                            ChromeRow(title: "Get a key", detail: String(format: Chrome.localized("%@ needs an API key. Nothing to install."), provider.displayName)) {
                                Link(destination: provider.installURL) {
                                    Text(verbatim: String(format: Chrome.localized("Get a %@ key"), provider.displayName))
                                        .frame(height: Chrome.rowButtonLabelHeight)
                                }
                                .buttonStyle(.glass)
                            }
                        }
                    }
                    if !provider.isAPIKeyBased {
                        ChromeRowDivider()
                        ProviderUpdateMonitoringRow(state: updateState, isOn: Binding(
                            get: { model.settings.monitorsUpdates(provider) },
                            set: { model.settings.setMonitorsUpdates($0, for: provider) }
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
                            ChromeRow(title: "Sign in", detail: "Click here to login again.") {
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
            // Collapsed content is neither focusable, tappable nor in the accessibility
            // tree; the clip reveals it top-anchored as the fraction slides.
            .clipped()
            .disabled(!isExpanded)
            .allowsHitTesting(isExpanded)
            .accessibilityHidden(!isExpanded)
        }
        .onAppear {
            binaryPath = model.settings.binaryPath(for: provider)
            if provider.acceptsAPIKey { apiKey = model.settings.apiKeyInput(for: provider) }
        }
        .onChange(of: showsUsage, initial: true) { _, shows in
            // Fires once when the page opens on a signed-in account and again when a check signs
            // one in. Sections are eager, so scrolling never re-fires it, and the registry hands
            // back what it read within the last minute instead of asking the provider again.
            guard shows else { return }
            model.providers.refreshPlanLimits(provider)
            model.providers.refreshCredits(provider)
        }
        .onChange(of: binaryPath) { _, value in
            guard value != model.settings.binaryPath(for: provider) else { return }
            model.settings.setBinaryPath(value, for: provider)
        }
        .onChange(of: model.settings.monitorsUpdates(provider)) { _, _ in
            model.providers.cliMonitoringChanged(provider)
        }
        .onChange(of: model.settings.isEnabled(provider)) { _, _ in
            model.providers.cliMonitoringChanged(provider)
        }
        .onChange(of: model.settings.binaryPath(for: provider)) { _, _ in
            model.providers.cliMonitoringChanged(provider)
        }
        .onChange(of: apiKey) { _, value in
            // Only an edit counts: loading the stored key into the field must not save or check it.
            guard provider.acceptsAPIKey, value != model.settings.apiKeyInput(for: provider) else { return }
            model.settings.setAPIKeyInput(value, for: provider)
            keyCheck?.cancel()
            keyCheck = Task {
                try? await Task.sleep(for: .milliseconds(600))
                guard !Task.isCancelled else { return }
                await model.providers.refresh(provider)
                await model.providers.loadCatalog(provider, force: true)
            }
        }
        .onChange(of: model.settings.apiKeyInput(for: provider)) { _, value in
            guard provider.acceptsAPIKey, value != apiKey else { return }
            apiKey = value
        }
    }
}

private struct SourceControlSettingsPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        GitHubSettingsSection()
        ChromeSection(title: "Text generation") {
            ChromeCard {
                ChromeRow(
                    title: "Thread titles and commit messages",
                    detail: "Automatic uses the thread's own provider. Claude uses Haiku, Codex your default model."
                ) {
                    GlassPickerButton(options: TextGenerationChoice.allCases.map { ($0, $0.title) }, selection: $settings.textGeneration, asset: { ProviderKind(rawValue: $0.rawValue)?.iconName })
                }
            }
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
                ChromeRow(title: "Pull requests", detail: "Opened with the GitHub CLI (gh) or GitLab CLI (glab) from your PATH.") {
                    EmptyView()
                }
            }
        }
    }
}

/// Clears the whole archive from the page's chrome row, asking first the way a single
/// delete does when the setting is on. The question hangs off the button as a popover,
/// like the sidebar's delete menu, rather than a sheet over the whole window.
private struct ArchiveDeleteAllButton: View {
    @Environment(AppModel.self) private var model
    @State private var isConfirming = false

    var body: some View {
        let count = model.archivedThreads.count
        ChromeTextButton(
            symbol: "trash",
            title: "Delete all",
            help: "Delete every archived thread",
            isEnabled: count > 0,
            isDestructive: true
        ) {
            if model.settings.confirmBeforeDeleting {
                isConfirming = true
            } else {
                model.deleteArchivedThreads()
            }
        }
        .popover(isPresented: $isConfirming, arrowEdge: .bottom) {
            PopoverMenu {
                PopoverSectionHeader(count == 1 ? "Delete the archived thread?" : "Delete all archived threads?")
                PopoverNote(count == 1
                    ? "Its history will be removed. Files in your project stay as they are."
                    : String(format: Chrome.localized("The histories of all %lld threads will be removed. Files in your projects stay as they are."), count))
                PopoverDivider()
                PopoverItem(count == 1 ? "Delete thread" : String(format: Chrome.localized("Delete %lld threads"), count), symbol: "trash", isDestructive: true) {
                    model.deleteArchivedThreads()
                }
            }
        }
    }
}

/// The archived threads. The empty archive never reaches this page: the pane shows its symbol instead.
private struct ArchiveSettingsPage: View {
    @Environment(AppModel.self) private var model

    /// The row waiting on its confirmation, or nil. One deletion is ever in flight, so one
    /// dialog on the card serves every row.
    @State private var pendingDeletion: ChatThread?

    var body: some View {
        let archived = model.archivedThreads
        ChromeCard(lazy: true) {
            ForEach(Array(archived.enumerated()), id: \.element.id) { index, thread in
                if index > 0 { ChromeRowDivider() }
                ChromeRow(title: thread.title, detail: model.project(thread.projectID)?.name) {
                    HStack(spacing: 8) {
                        Button("Restore") { model.unarchive(thread.id) }
                            .buttonStyle(.glass)
                        // The same check the sidebar and Delete all honour: a row here
                        // used to delete a history on the first click.
                        Button("Delete", role: .destructive) {
                            if model.settings.confirmBeforeDeleting {
                                pendingDeletion = thread
                            } else {
                                model.delete(thread.id)
                            }
                        }
                        .buttonStyle(.glass)
                    }
                    .controlSize(.small)
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
        ) { thread in
            Button("Delete thread", role: .destructive) {
                model.delete(thread.id)
                pendingDeletion = nil
            }
        } message: { _ in
            Text("Its history will be removed. Files in your project stay as they are.")
        }
    }
}

private struct AboutSettingsPage: View {
    private static let upstreamURL = URL(string: "https://getdroppycode.app")!

    var body: some View {
        VStack(alignment: .leading, spacing: Chrome.sectionSpacing) {
            AboutSoftwareUpdateSection()
            appCard
            ChromeSection(title: "Credits") {
                ChromeCard {
                    UpstreamAttributionRow(url: Self.upstreamURL)
                    ChromeRowDivider()
                    ChromeRow(title: "Working indicators", detail: "Ported from Zeron by Wing, MIT License.") {
                        CreditLink(title: "zeronsh/zeron", url: URL(string: "https://github.com/zeronsh/zeron")!)
                    }
                    ChromeRowDivider()
                    ChromeRow(title: "Terminal", detail: "SwiftTerm by Miguel de Icaza, MIT License.") {
                        CreditLink(title: "SwiftTerm", url: URL(string: "https://github.com/migueldeicaza/SwiftTerm")!)
                    }
                    ChromeRowDivider()
                    LicensesRow()
                }
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
        .help("Open getdroppycode.app")
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

/// The per-project marks behind one button: the Projects card stays two rows long, and the
/// list of projects with their marks opens in a popover off this row.
private struct ProjectMarksRow: View {
    @Environment(AppModel.self) private var model

    @State private var isPresented = false

    var body: some View {
        Button("Edit") { isPresented = true }
            .buttonStyle(.glass)
            .controlSize(.small)
            .disabled(model.projects.isEmpty)
            .help("Choose a mark for each project")
            .popover(isPresented: $isPresented, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(model.projects.enumerated()), id: \.element.id) { index, project in
                        if index > 0 { ChromeRowDivider() }
                        ChromeRow(title: project.name, detail: project.path) {
                            ProjectIconButton(icon: icon(for: project.id))
                        }
                    }
                }
                .frame(width: 400)
            }
    }

    private func icon(for id: UUID) -> Binding<ProjectIcon?> {
        Binding(
            get: { model.project(id)?.icon },
            set: { newIcon in model.updateProject(id) { $0.icon = newIcon } }
        )
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
                Text(verbatim: Chrome.localized(selection.displayName))
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
        PopoverItem(theme.displayName, leading: AnyView(theme.swatch), isChecked: theme == selection) {
            selection = theme
        }
    }
}
