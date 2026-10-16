import AppKit
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var voiceReveal: CGFloat = 0
    @State private var voiceStageShown = false

    var body: some View {
        let sidebar = model.sidebar
        let settingsShown = WindowManager.shared.usesFullWindowSettings && SettingsNavigation.shared.isPresented
        let settingsSidebarWidth = max(sidebar.width, 212)
        HStack(spacing: 0) {
            ZStack(alignment: .leading) {
                // Keep the chat sidebar mounted so its search and scroll survive Settings.
                // The rows are laid out at the sidebar's width once, and the slide moves the clip
                // alone, so no row re-wraps per frame.
                SidebarView()
                    .frame(width: sidebar.width)
                    .frame(width: sidebar.renderedWidth, alignment: .trailing)
                    .clipped()
                    .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { sidebar.noteLaidOutWidth($0) }
                    .overlay(alignment: .trailing) {
                        SidebarResizeHandle(
                            isActive: sidebar.isVisible && !settingsShown,
                            onBegin: { sidebar.beginDrag() },
                            onChange: { sidebar.drag(by: $0) },
                            onEnd: { sidebar.endDrag() }
                        )
                        .frame(width: SidebarResizeHandle.hitWidth)
                        .padding(.top, Chrome.trafficLightTop + Chrome.trafficLightDiameter)
                    }
                    .opacity(settingsShown ? 0 : 1)
                    .disabled(settingsShown)
                    .allowsHitTesting(!settingsShown)
                    .accessibilityHidden(settingsShown)
                if settingsShown {
                    SettingsSidebar()
                        .frame(width: settingsSidebarWidth)
                        .transition(.offset(x: -16).combined(with: .opacity))
                }
            }
            .frame(width: settingsShown ? settingsSidebarWidth : nil, alignment: .leading)

            ZStack {
                // The chat stays built underneath, including the streaming runtime and draft.
                DetailView()
                    .frame(minWidth: 0, maxWidth: .infinity)
                    .opacity(1 - voiceReveal)
                    .allowsHitTesting(!model.voice.stageOpen)
                    .accessibilityHidden(model.voice.stageOpen)
                    // The sheet keeps to its own bounds. A conversation gliding sideways to make
                    // room for a panel (`ReserveSlide` carries it on an offset), a panel settling
                    // into a corner of a pane that just changed size, and rows re-wrapping in a
                    // live resize all reach past the sheet for a few frames, and drew over the
                    // sidebar or off the window's edge until they landed.
                    .clipped()
                    .opacity(settingsShown ? 0 : 1)
                    .disabled(settingsShown)
                    .allowsHitTesting(!settingsShown)
                    .accessibilityHidden(settingsShown)
                if voiceStageShown {
                    VoiceStage(reveal: voiceReveal)
                        .disabled(settingsShown || !model.voice.stageOpen)
                        .allowsHitTesting(model.voice.stageOpen && !settingsShown)
                        .opacity(settingsShown ? 0 : 1)
                        .accessibilityHidden(settingsShown || !model.voice.stageOpen)
                }
                if settingsShown {
                    SettingsDetail(page: SettingsNavigation.shared.page)
                        .transition(.offset(x: 24).combined(with: .opacity))
                }
            }
            .padding(.leading, settingsShown || sidebar.isVisible ? 0 : Chrome.sheetInset)
            .padding(.trailing, Chrome.sheetInset)
            .padding(.vertical, Chrome.sheetInset)
        }
        // While the sidebar is hidden, dragging the window's leading edge pulls it back out.
        .overlay(alignment: .leading) {
            SidebarResizeHandle(
                isActive: !sidebar.isVisible && !settingsShown,
                onBegin: { sidebar.beginDrag() },
                onChange: { sidebar.drag(by: $0) },
                onEnd: { sidebar.endDrag() }
            )
            .frame(width: SidebarResizeHandle.hitWidth)
            .padding(.top, Chrome.trafficLightTop + Chrome.trafficLightDiameter)
        }
        .overlay(alignment: .topLeading) {
            if !settingsShown, !sidebar.holdsTrafficLights,
               model.selectedThreadID.flatMap({ model.thread($0) }) == nil {
                SidebarToggleButton()
                    .padding(.leading, Chrome.trafficLightsWidth + Chrome.trafficLightClearance + Chrome.chromeHorizontalPadding)
                    .padding(.top, Chrome.chromeTopPadding)
            }
        }
        // Initial library restoration must not dismiss an About deep link after relaunch.
        .onChange(of: model.selectedThreadID) { old, _ in
            if old != nil { WindowManager.shared.hideSettings() }
            model.voice.setStageOpen(false)
        }
        .background { WindowBackdrop(opacity: model.settings.backdropOpacity, wallpaper: WallpaperStore.shared.image) }
        .background { WindowChromeConfigurator(sidebarVisible: settingsShown || sidebar.holdsTrafficLights, sidebarDragging: sidebar.isDragging && !settingsShown, performanceMode: model.settings.performanceMode) }
        .ignoresSafeArea()
        .coordinateSpace(.named(GenieAnimator.coordinateSpace))
        .overlay { GenieLayer() }
        .overlay {
            if model.isCommandPalettePresented {
                CommandPalette()
            }
        }
        .onChange(of: model.voice.stageOpen, initial: true) { _, open in
            if open {
                voiceStageShown = true
                withAnimation(reduceMotion ? nil : VoiceStageMetrics.enter) { voiceReveal = 1 }
            } else if reduceMotion {
                voiceReveal = 0
                voiceStageShown = false
            } else {
                withAnimation(VoiceStageMetrics.exit) { voiceReveal = 0 } completion: {
                    if !model.voice.stageOpen { voiceStageShown = false }
                }
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard !settingsShown else { return false }
            return handleDrop(urls)
        }
        .alert(
            Chrome.localized(model.alert?.title ?? ""),
            isPresented: Binding(
                get: { model.alert != nil },
                set: { if !$0 { model.alert = nil } }
            ),
            presenting: model.alert
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { alert in
            Text(verbatim: Chrome.localized(alert.message))
        }
    }

    @discardableResult
    private func handleDrop(_ urls: [URL]) -> Bool {
        var folders: [URL] = []
        var files: [URL] = []
        for url in urls {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue { folders.append(url) } else { files.append(url) }
        }
        var lastProject: Project?
        for folder in folders { lastProject = model.addProject(at: folder) }
        if let lastProject { model.newThread(in: lastProject) }
        if !files.isEmpty, let threadID = model.selectedThreadID {
            Storage.attach(files.map(AttachmentSource.file), to: Bindable(model.runtime(for: threadID)).draft.attachments)
        }
        return !folders.isEmpty || !files.isEmpty
    }
}

/// Whether the chat column a view sits in is the one on screen. The columns of the threads
/// visited last stay built behind the selected one (see `ThreadColumns`), so a view that
/// would react to appearing or disappearing reacts to this instead.
extension EnvironmentValues {
    @Entry var chatColumnIsShown = true
}

struct DetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(WindowLiveResize.self) private var liveResize
    /// Threads whose columns are built behind the selection, ahead of a click on them.
    @State private var prebuilt: [UUID] = []
    @State private var hasPrebuiltTopRows = false
    /// `kCGAnyInputEventType`, which Quartz leaves out of the Swift enum.
    private static let anyInput = CGEventType(rawValue: ~0)!

    var body: some View {
        if let threadID = model.selectedThreadID, model.thread(threadID) != nil {
            let running = Set(model.threads.compactMap { model.existingRuntime(for: $0.id)?.isRunning == true ? $0.id : nil })
            ThreadColumns(threadID: threadID, prebuilt: prebuilt, running: running, isCovered: (WindowManager.shared.usesFullWindowSettings && SettingsNavigation.shared.isPresented) || model.voice.stageOpen, model: model, liveResize: liveResize)
                .onChange(of: threadID) { _, _ in prebuilt = [] }
                .task(id: threadID) {
                    // The neighbours, and at launch the sidebar's top rows, one at a time, once
                    // the reader has settled on the thread and nothing streams in it: each is a
                    // frame's worth of building.
                    try? await Task.sleep(for: .milliseconds(1500))
                    var candidates = model.neighbors(of: threadID)
                    if !hasPrebuiltTopRows {
                        hasPrebuiltTopRows = true
                        candidates += model.sidebarThreads.prefix(ThreadColumns.topRowsBuiltAtLaunch).map(\.id)
                    }
                    for id in candidates where !Task.isCancelled {
                        // Never under the reader's hands: a build holds the main thread for a
                        // frame or a few, which a keystroke would wait on.
                        while !Task.isCancelled, CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: Self.anyInput) < 1 {
                            try? await Task.sleep(for: .milliseconds(300))
                        }
                        guard !Task.isCancelled, !(model.existingRuntime(for: threadID)?.isRunning ?? false) else { return }
                        if id != threadID, !prebuilt.contains(id) { prebuilt.append(id) }
                        try? await Task.sleep(for: .milliseconds(400))
                    }
                }
        } else {
            Group {
                // The library decodes off the main thread at launch: until it lands, an empty
                // project list says nothing, and the welcome screen would flash.
                if !model.isLibraryLoaded {
                    Color.clear
                } else if model.projects.isEmpty {
                    WelcomeView()
                } else {
                    NoThreadView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .detailSheet()
        }
    }
}

/// The chat column, hosted on its own per thread. The columns of the threads visited last
/// stay in the pane, hidden, so switching back to one is a change of visibility rather
/// than a rebuild of the timeline, the composer and the panels: the rows of a long thread
/// took a quarter of a second to build each time. Hosting each column apart also keeps
/// every view tree small: SwiftUI walks a tree whole whenever a focusable view appears in
/// it or the pointer moves over it. Hidden rather than detached, because a hosting view
/// taken out of the window disappears to its views, and every task of the column starts
/// over when it comes back.
private struct ThreadColumns: NSViewRepresentable {
    /// How many of the sidebar's top rows are built behind the first thread shown.
    static let topRowsBuiltAtLaunch = 6

    let threadID: UUID
    let prebuilt: [UUID]
    /// Threads with a turn under way. A hidden column of one goes: its rows would stream
    /// unseen, at the same cost as on screen.
    let running: Set<UUID>
    let isCovered: Bool
    let model: AppModel
    let liveResize: WindowLiveResize

    func makeNSView(context: Context) -> NSView {
        NSView()
    }

    func updateNSView(_ pane: NSView, context: Context) {
        let columns = context.coordinator
        columns.cover(pane, isCovered, model: model, liveResize: liveResize)
        columns.show(threadID, in: pane, model: model, liveResize: liveResize)
        columns.dropHidden(where: { running.contains($0) || model.thread($0) == nil || model.existingRuntime(for: $0) == nil })
        columns.prebuild(prebuilt.filter { model.thread($0) != nil && !running.contains($0) }, in: pane, model: model, liveResize: liveResize)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    static func dismantleNSView(_ pane: NSView, coordinator: Coordinator) {
        coordinator.stopRendering()
    }

    @MainActor final class Coordinator {
        func stopRendering() {
            covering?.cancel()
            retirement?.cancel()
            for scope in scopes.values { scope.setVisible(false) }
        }

        /// How many columns stay built behind the shown one.
        private static let keptLimit = 8
        /// Hidden columns keep the size they were built at and take the pane's size only
        /// when shown: resizing every hidden column per frame during a sidebar slide or
        /// live resize is what made them lag.
        private var columns: [UUID: FrameHostingView] = [:]
        /// Each column's veil render scope: the column's own fade clock and its pane
        /// visibility, so a column that is not drawn stops veiling. Created with the
        /// column, paused and resumed as the column hides and shows, dropped with it.
        private var scopes: [UUID: VeilRenderScope] = [:]
        /// The threads with a column, the one to drop first at the front and the shown one
        /// last. A column built ahead of a click goes in at the front: it is the first to
        /// make room for the columns the reader has been to.
        private var order: [UUID] = []
        private var shown: UUID?
        /// What was asked for ahead of a click, so a column dropped since is not built over
        /// and over on every update.
        private var requested: Set<UUID> = []
        /// Columns dropped, kept until the switch that dropped them has been drawn: taking
        /// a view tree down costs a frame's worth of time, better spent after the frame.
        private var retired: [FrameHostingView] = []
        private var retirement: Task<Void, Never>?
        private var covering: Task<Void, Never>?

        private var isCovered = false

        // Block input now; delayed hiding only finishes the visible transition.
        func cover(_ pane: NSView, _ isCovered: Bool, model: AppModel, liveResize: WindowLiveResize) {
            if self.isCovered != isCovered {
                self.isCovered = isCovered
                for (id, column) in columns {
                    let isInteractive = id == shown && !isCovered
                    column.acceptsInteraction = isInteractive
                    column.rootView = Self.root(id, isShown: isInteractive, model: model, liveResize: liveResize, scope: scopes[id])
                }
            }
            guard isCovered else {
                covering?.cancel()
                covering = nil
                // The column's veils resume — repainting at the real time — before the
                // pane can show a stale frame.
                if let shown, pane.isHidden {
                    scopes[shown]?.setVisible(true)
                    columns[shown]?.layoutSubtreeIfNeeded()
                }
                pane.isHidden = false
                return
            }
            guard !pane.isHidden, covering == nil else { return }
            covering = Task { [weak pane, weak self] in
                try? await Task.sleep(for: .milliseconds(450))
                guard !Task.isCancelled else { return }
                pane?.isHidden = true
                // The pane is truly hidden now: the column it shows stops veiling.
                if let self, let shown = self.shown { self.scopes[shown]?.setVisible(false) }
            }
        }

        func show(_ id: UUID, in pane: NSView, model: AppModel, liveResize: WindowLiveResize) {
            guard id != shown else { return }
            if let shown, let previous = columns[shown] {
                previous.acceptsInteraction = false
                previous.isHidden = true
                scopes[shown]?.setVisible(false)
                previous.autoresizingMask = []
                previous.rootView = Self.root(shown, isShown: false, model: model, liveResize: liveResize, scope: scopes[shown])
            }
            if let kept = columns[id] {
                kept.acceptsInteraction = !isCovered
                kept.rootView = Self.root(id, isShown: !isCovered, model: model, liveResize: liveResize, scope: scopes[id])
                kept.frame = pane.bounds
                kept.autoresizingMask = [.width, .height]
                // In view before the column shows, so its first frame carries the real
                // alpha; under a cover that has hidden the pane it stays paused.
                scopes[id]?.setVisible(!pane.isHidden)
                kept.layoutSubtreeIfNeeded()
                kept.isHidden = false
            } else {
                make(id, isShown: true, in: pane, model: model, liveResize: liveResize)
            }
            shown = id
            order.removeAll { $0 == id }
            order.append(id)
            while order.count > Self.keptLimit + 1 { drop(order[0]) }
        }

        /// Drops the hidden columns the test names; each is built afresh when its thread is
        /// next selected.
        func dropHidden(where goes: (UUID) -> Bool) {
            for id in Array(columns.keys) where id != shown && goes(id) { drop(id) }
        }

        /// Builds the columns asked for, hidden and laid out at the pane's size, so a click
        /// on one of the threads finds its rows made. Each is built once per request: one
        /// dropped to make room for the columns visited since stays dropped.
        func prebuild(_ ids: [UUID], in pane: NSView, model: AppModel, liveResize: WindowLiveResize) {
            for id in ids where !requested.contains(id) && columns[id] == nil {
                let started = ContinuousClock.now
                make(id, isShown: false, in: pane, model: model, liveResize: liveResize).layoutSubtreeIfNeeded()
                SwitchLatency.note("prebuilt \(model.thread(id)?.title.prefix(24) ?? "?") in \(started.duration(to: .now))")
                order.insert(id, at: 0)
                while order.count > Self.keptLimit + 1 { drop(order[0]) }
            }
            requested = Set(ids)
        }

        @discardableResult
        private func make(_ id: UUID, isShown: Bool, in pane: NSView, model: AppModel, liveResize: WindowLiveResize) -> FrameHostingView {
            let scope = VeilRenderScope()
            scopes[id] = scope
            // A column built hidden (a prebuild, or a switch under a hidden pane) never
            // runs its fade clock; one the pane is showing starts live.
            scope.setVisible(isShown && !pane.isHidden)
            let column = FrameHostingView(rootView: Self.root(id, isShown: isShown && !isCovered, model: model, liveResize: liveResize, scope: scope))
            column.acceptsInteraction = isShown && !isCovered
            column.frame = pane.bounds
            column.isHidden = !isShown
            column.autoresizingMask = isShown ? [.width, .height] : []
            pane.addSubview(column)
            columns[id] = column
            return column
        }

        private static func root(_ id: UUID, isShown: Bool, model: AppModel, liveResize: WindowLiveResize, scope: VeilRenderScope?) -> AnyView {
            AnyView(
                ChatView(runtime: model.runtime(for: id))
                    .environment(\.chatColumnIsShown, isShown)
                    .environment(\.veilRenderScope, scope)
                    .disabled(!isShown)
                    .allowsHitTesting(isShown)
                    .modifier(HostedEnvironment(model: model, liveResize: liveResize))
            )
        }

        private func drop(_ id: UUID) {
            order.removeAll { $0 == id }
            // The scope goes with the column: its clock stops, its veils are told, and
            // the retiring tree's environment is the last reference to it.
            if let scope = scopes.removeValue(forKey: id) { scope.setVisible(false) }
            guard let column = columns.removeValue(forKey: id) else { return }
            retired.append(column)
            retirement?.cancel()
            retirement = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled, let self else { return }
                for column in retired { column.removeFromSuperview() }
                retired.removeAll()
            }
        }
    }
}

struct WelcomeView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(spacing: 30) {
                VStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 104, height: 104)
                    Text("Tivano")
                        .font(.system(size: 34, weight: .semibold))
                    Text("A calm, native home for your coding agents.")
                        .font(.ui(.title3))
                        .foregroundStyle(Chrome.secondaryText)
                }
                VStack(spacing: 10) {
                    HStack(spacing: 10) {
                        Button {
                            model.chooseProjectFolder()
                        } label: {
                            Label("Add a project", systemImage: "folder.badge.plus")
                                .padding(.horizontal, 6)
                        }
                        .buttonStyle(.glassProminent)
                        .controlSize(.extraLarge)
                        Button {
                            GitHubClonePanel.shared.present(model: model)
                        } label: {
                            Label {
                                Text("Clone from GitHub")
                            } icon: {
                                Image("mcp-github").resizable().scaledToFit()
                                    .frame(width: 16, height: 16)
                            }
                            .padding(.horizontal, 6)
                        }
                        .buttonStyle(.glass)
                        .controlSize(.extraLarge)
                    }
                    Text("Or drop a folder anywhere in this window.")
                        .font(.ui(.callout))
                        .foregroundStyle(Chrome.secondaryText)
                }
                ChromeSection(title: "Providers") {
                    ProviderChecklist()
                }
                .frame(maxWidth: 480)
            }
            .padding(48)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.never)
        .scrollBounceBehavior(.basedOnSize)
    }
}

struct ProviderChecklist: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ChromeCard {
            ForEach(Array(ProviderKind.allCases.enumerated()), id: \.element) { index, provider in
                if index > 0 { ChromeRowDivider() }
                ProviderStatusRow(provider: provider)
            }
        }
    }
}

private struct ProviderStatusRow: View {
    @Environment(AppModel.self) private var model
    let provider: ProviderKind

    var body: some View {
        let status = model.providers.status(provider)
        HStack(spacing: 12) {
            ProviderIcon(provider: provider, size: 18)
                .foregroundStyle(Chrome.primaryText)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: provider.displayName)
                    .font(.ui(.body))
                Text(verbatim: status.isChecking ? Chrome.localized("Checking…") : status.summary)
                    .font(.ui(.subheadline))
                    .foregroundStyle(Chrome.secondaryText)
            }
            Spacer()
            if status.isChecking {
                ProgressView()
                    .controlSize(.small)
            } else if !status.isInstalled {
                if provider.isAPIKeyBased {
                    // Nothing to install: the key is typed in Settings, so the row opens it
                    // rather than sending the reader to a web page for it.
                    OpenProvidersSettingsButton()
                } else {
                    Link("Install", destination: provider.installURL)
                        .buttonStyle(.glass)
                }
            } else if status.auth == .signedOut {
                if provider.isAPIKeyBased {
                    OpenProvidersSettingsButton()
                } else {
                    Button("Login") { Workspace.openTerminal(running: provider.loginCommand) }
                        .buttonStyle(.glass)
                }
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Chrome.success)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }
}

/// Takes the reader to the Providers page, where a key-based provider's key is typed.
private struct OpenProvidersSettingsButton: View {
    var body: some View {
        Button("Add key") {
            WindowManager.shared.showSettings(page: .providers)
        }
        .buttonStyle(.glass)
        .help(Text(verbatim: Chrome.localized("Open Settings > Providers")))
    }
}

struct NoThreadView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "bubble.left.and.text.bubble.right")
                .font(.system(size: 46, weight: .light))
                .foregroundStyle(Chrome.secondaryText)
            Text("Pick a thread or start a new one")
                .font(.ui(.title2, weight: .medium))
            Button {
                model.newThread()
            } label: {
                Label("New thread", systemImage: "plus.bubble")
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            // The chord as the store has it now, so a remap never leaves a stale key here.
            if let chord = ShortcutStore.label(for: .newThread) {
                Text(verbatim: chord)
                    .font(.ui(.subheadline))
                    .foregroundStyle(Chrome.secondaryText)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
