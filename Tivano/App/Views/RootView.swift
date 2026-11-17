import AppKit
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var voiceReveal: CGFloat = 0
    @State private var voiceStageShown = false

    var body: some View {
        let sidebar = model.sidebar
        let settingsShown = SettingsNavigation.shared.isPresented
        let settingsSidebarWidth = max(sidebar.width, 212)
        ZStack {
            GlobalWeatherLayer()
            standardLayout(settingsShown: settingsShown, settingsSidebarWidth: settingsSidebarWidth)
        }
        // Initial library restoration must not dismiss an About deep link after relaunch.
        .onChange(of: model.selectedThreadID) { old, _ in
            if old != nil { WindowManager.shared.hideSettings() }
            if model.appSpace != .session { model.appSpace = .session }
            model.voice.setStageOpen(false)
        }
        .onChange(of: SettingsNavigation.shared.isPresented) { _, presented in
            if presented, model.appSpace != .session { model.appSpace = .session }
        }
        .background {
            let _ = model.settings.themeStyle
            WindowBackdrop(opacity: model.settings.backdropOpacity, wallpaper: WallpaperStore.shared.image)
        }
        .background {
            WindowChromeConfigurator(
                sidebarVisible: settingsShown || sidebar.holdsTrafficLights,
                sidebarDragging: sidebar.isDragging && !settingsShown,
                placement: .standard
            )
        }
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
        .alert(
            String(format: Chrome.localized("Allow %@ to control Tivano?"), model.remoteMCP.pendingApprovals.first?.clientName ?? ""),
            isPresented: Binding(
                get: { model.remoteMCP.pendingApprovals.first != nil },
                set: { _ in }
            ),
            presenting: model.remoteMCP.pendingApprovals.first
        ) { request in
            if request.requestedScopes.contains(.write) {
                Button("Allow full control") { model.remoteMCP.decide(request, .allow(request.requestedScopes)) }
            }
            Button("Allow read only") { model.remoteMCP.decide(request, .allow([.read])) }
            Button("Deny", role: .cancel) { model.remoteMCP.decide(request, .deny) }
        } message: { request in
            Text(verbatim: String(format: Chrome.localized("Code %@. Check that it matches the page in your browser. It returns to %@. Full control can create threads and send messages; approvals and questions still wait for you in Tivano."), request.code, request.redirectHost))
        }
    }

    private func standardLayout(settingsShown: Bool, settingsSidebarWidth: CGFloat) -> some View {
        let sidebar = model.sidebar
        let trayShown = settingsShown || (sidebar.isVisible && sidebar.renderedWidth > 0)
        return HStack(spacing: 0) {
            ZStack(alignment: .leading) {
                // Keep the chat sidebar mounted so its search and scroll survive Settings.
                // The rows are laid out at the sidebar's width once, and the slide moves the clip
                // alone, so no row re-wraps per frame.
                SidebarView()
                    .frame(width: sidebar.width)
                    .frame(width: sidebar.renderedWidth, alignment: .trailing)
                    .clipped()
                    .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { sidebar.noteLaidOutWidth($0) }
                    .opacity(settingsShown ? 0 : 1)
                    .disabled(settingsShown)
                    .allowsHitTesting(!settingsShown)
                    .accessibilityHidden(settingsShown)
                if settingsShown {
                    SettingsSidebar()
                        .frame(width: settingsSidebarWidth)
                        .transition(.opacity)
                }
            }
            .frame(width: settingsShown ? settingsSidebarWidth : nil, alignment: .leading)
            .sidebarTray()
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
            .padding([.top, .bottom], Chrome.sidebarTrayInset)
            .padding(.leading, trayShown ? Chrome.sidebarTrayInset : 0)
            .opacity(trayShown ? 1 : 0)
            .allowsHitTesting(trayShown)
            .accessibilityHidden(!trayShown)

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
                    .opacity(settingsShown || model.appSpace == .tokens ? 0 : 1)
                    .allowsHitTesting(!settingsShown && !(model.appSpace == .tokens))
                        .accessibilityHidden(settingsShown || model.appSpace == .tokens)
                if model.appSpace == .tokens {
                    TokenUsagePage(model: model.tokenUsage, isActive: true)
                        .padding(.top, 52)
                        .padding([.horizontal, .bottom], Chrome.contentHorizontalPadding)
                        .overlay(alignment: .topLeading) {
                            HStack(spacing: 8) {
                                if !sidebar.holdsTrafficLights, !sidebar.isSliding {
                                    SidebarToggleButton(inSidebar: false)
                                        .transition(.softAppear)
                                }
                                ChromeTextButton(symbol: "chevron.left", title: "Back", help: "Back") {
                                    model.appSpace = .session
                                }
                            }
                            .padding(.leading, sidebar.holdsTrafficLights ? Chrome.chromeHorizontalPadding : WindowChrome.collapsedTrafficLightClearance)
                            .padding(.top, Chrome.chromeTopPadding)
                        }
                        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
                        .opacity(1 - voiceReveal)
                        .allowsHitTesting(!model.voice.stageOpen)
                        .accessibilityHidden(model.voice.stageOpen)
                        .opacity(settingsShown ? 0 : 1)
                        .allowsHitTesting(!settingsShown)
                        .accessibilityHidden(settingsShown)
                }
                if voiceStageShown {
                    VoiceStage(reveal: voiceReveal)
                        .disabled(settingsShown || !model.voice.stageOpen)
                        .allowsHitTesting(model.voice.stageOpen && !settingsShown)
                        .opacity(settingsShown ? 0 : 1)
                        .accessibilityHidden(settingsShown || !model.voice.stageOpen)
                }
                if settingsShown {
                    SettingsDetail(page: SettingsNavigation.shared.page)
                        .transition(.opacity)
                }
            }
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
            .padding(.top, WindowChrome.collapsedTrafficLightTop + Chrome.trafficLightDiameter)
        }
        .overlay(alignment: .topLeading) {
            // Waiting out the slide like the chat chrome's copy does, so it never
            // doubles the header's own toggle still riding the edge.
            if !settingsShown, !sidebar.holdsTrafficLights, !sidebar.isSliding,
               model.appSpace == .session,
               model.selectedThreadID.flatMap({ model.thread($0) }) == nil {
                SidebarToggleButton(inSidebar: false)
                    .padding(.leading, WindowChrome.collapsedTrafficLightClearance)
                    .padding(.top, Chrome.chromeTopPadding)
            }
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

    private struct PrebuildTaskID: Equatable {
        let threadID: UUID
        let isCovered: Bool
    }

    private var isCovered: Bool {
        SettingsNavigation.shared.isPresented || model.voice.stageOpen
    }

    var body: some View {
        if let threadID = model.selectedThreadID, model.thread(threadID) != nil {
            ThreadColumns(threadID: threadID, prebuilt: prebuilt, isCovered: isCovered, model: model, liveResize: liveResize)
                .onChange(of: threadID) { _, _ in prebuilt = [] }
                .task(id: PrebuildTaskID(threadID: threadID, isCovered: isCovered)) {
                    guard !isCovered else { return }
                    // The neighbours, and at launch the sidebar's top rows, one at a time, once
                    // the reader has settled on the thread and nothing streams in it: each is a
                    // frame's worth of building.
                    try? await Task.sleep(for: .milliseconds(1500))
                    guard !Task.isCancelled else { return }
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
                        guard !Task.isCancelled, !isCovered, !(model.existingRuntime(for: threadID)?.isRunning ?? false) else { return }
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
                } else if model.projects.isEmpty && model.threads.isEmpty {
                    WelcomeView()
                } else {
                    NoThreadView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Without a thread there is no chat top bar, so Settings keeps its corner here.
            .overlay(alignment: .topTrailing) {
                if model.isLibraryLoaded {
                    ChromeCapsule {
                        ChromeIconButton(symbol: "gearshape", help: "Settings") {
                            WindowManager.shared.showSettings()
                        }
                        .overlay(alignment: .topTrailing) {
                            if UpdateChecker.shared.updateAvailable {
                                UpdateAvailableDot()
                                    .allowsHitTesting(false)
                            }
                        }
                    }
                    .padding(.horizontal, Chrome.chromeHorizontalPadding)
                    .padding(.top, Chrome.chromeTopPadding)
                }
            }
            // Covered by Settings: the thread columns block their own input, this does it here.
            .disabled(SettingsNavigation.shared.isPresented)
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
    let isCovered: Bool
    let model: AppModel
    let liveResize: WindowLiveResize

    func makeNSView(context: Context) -> NSView {
        NSView()
    }

    func updateNSView(_ pane: NSView, context: Context) {
        let columns = context.coordinator
        columns.cover(pane, isCovered, model: model, liveResize: liveResize)
        let selectedRunning = model.existingRuntime(for: threadID)?.isRunning == true
        // Before showing: a hidden column whose runtime was released (idle or under memory
        // pressure) still holds the old one, so it is built afresh rather than reused.
        columns.dropHidden(where: { model.thread($0) == nil || model.existingRuntime(for: $0) == nil })
        columns.show(threadID, in: pane, model: model, liveResize: liveResize, rebuildsIfResized: selectedRunning)
        // A running thread's hidden column is kept; a deleted or unloaded thread's goes.
        columns.dropHidden(where: { model.thread($0) == nil || model.existingRuntime(for: $0) == nil })
        // Prebuild skips running threads: building ahead of a click is not spent on a thread that streams.
        let candidates = prebuilt.isEmpty ? [] : prebuilt.filter { model.thread($0) != nil && model.existingRuntime(for: $0)?.isRunning != true }
        columns.prebuild(candidates, in: pane, model: model, liveResize: liveResize)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    static func dismantleNSView(_ pane: NSView, coordinator: Coordinator) {
        coordinator.stopRendering()
    }

    @MainActor final class Coordinator {
        nonisolated(unsafe) private var memoryPressureObserver: (any NSObjectProtocol)?
        nonisolated(unsafe) private var themeObserver: (any NSObjectProtocol)?
        /// Hidden columns taken out of the window by a theme style switch. In the window,
        /// every hidden column re-laid out its text on the switch's frame (Creation swaps
        /// fonts and surfaces); out of it, each catches up only when it is next shown.
        private var detached: Set<UUID> = []
        private var lastThemeStyle = ThemeManager.style

        init() {
            // No queue: the post comes from the settings setter on the main thread, and the
            // columns must leave the window before that change's first update.
            themeObserver = NotificationCenter.default.addObserver(forName: ThemeManager.didChange, object: nil, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.themeDidChange()
                }
            }
            memoryPressureObserver = NotificationCenter.default.addObserver(forName: .memoryPressure, object: nil, queue: .main) { [weak self] notification in
                let critical = (notification.userInfo?["critical"] as? Bool) == true
                MainActor.assumeIsolated {
                    self?.handleMemoryPressure(critical: critical)
                }
            }
        }

        deinit {
            if let memoryPressureObserver {
                NotificationCenter.default.removeObserver(memoryPressureObserver)
            }
            if let themeObserver {
                NotificationCenter.default.removeObserver(themeObserver)
            }
        }

        func stopRendering() {
            covering?.cancel()
            covering = nil
            retirement?.cancel()
            retirement = nil
            initialExpansionTask?.cancel()
            initialExpansionTask = nil
            pendingInitialExpansionID = nil
            if let memoryPressureObserver {
                NotificationCenter.default.removeObserver(memoryPressureObserver)
                self.memoryPressureObserver = nil
            }
            if let themeObserver {
                NotificationCenter.default.removeObserver(themeObserver)
                self.themeObserver = nil
            }
            if let shown { resizeState?.releasePane(shown) }
            for scope in scopes.values { scope.setVisible(false) }
        }

        private weak var resizeState: WindowLiveResize?

        /// How many columns stay built behind the shown one.
        private static let keptLimit = 8
        /// Hidden columns keep the size they were built at and take the pane's size only
        /// when shown: resizing every hidden column per frame during a sidebar slide or
        /// live resize is what made them lag.
        private var columns: [UUID: FrameHostingView] = [:]
        private var states: [UUID: ColumnHostState] = [:]
        /// Each column's veil render scope: the column's own fade clock and its pane
        /// visibility, so a column that is not drawn stops veiling. Created with the
        /// column, paused and resumed as the column hides and shows, dropped with it.
        private var scopes: [UUID: VeilRenderScope] = [:]
        /// The threads with a column, the one to drop first at the front and the shown one
        /// last. A column built ahead of a click goes in at the front: it is the first to
        /// make room for the columns the reader has been to.
        private var order: [UUID] = []
        private var shown: UUID?
        private var pendingInitialExpansionID: UUID?
        private var initialExpansionTask: Task<Void, Never>?
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
            let wasCovered = self.isCovered
            if wasCovered != isCovered {
                self.isCovered = isCovered
                liveResize.setPaneOwner(isCovered ? nil : shown, resizing: paneIsResizing(shown, model: model))
                if let id = shown, let column = columns[id] {
                    let isInteractive = !isCovered
                    column.acceptsInteraction = isInteractive
                    if isInteractive { column.frame = pane.bounds }
                    column.autoresizingMask = isInteractive ? [.width, .height] : []
                    if isCovered {
                        scopes[id]?.setVisible(false)
                    }
                }
            }
            guard isCovered else {
                let wasCovering = covering != nil
                covering?.cancel()
                covering = nil
                if wasCovered || wasCovering || pane.isHidden, let shown {
                    states[shown]?.paneSize = pane.bounds.size
                    states[shown]?.isShown = true
                    // The column's veils resume — repainting at the real time — before the
                    // pane can show a stale frame.
                    scopes[shown]?.setVisible(true)
                    columns[shown]?.layoutSubtreeIfNeeded()
                }
                pane.isHidden = false
                return
            }
            if pane.isHidden {
                if let shown {
                    scopes[shown]?.setVisible(false)
                    states[shown]?.isShown = false
                }
                return
            }
            guard covering == nil else { return }
            covering = Task { [weak pane, weak self] in
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled, let self else { return }
                self.covering = nil
                pane?.isHidden = true
                // The pane is truly hidden now: the column it shows stops veiling.
                if let shown = self.shown {
                    self.scopes[shown]?.setVisible(false)
                    self.states[shown]?.isShown = false
                }
            }
        }

        /// `rebuildsIfResized`: a running thread's column kept at another pane size is built
        /// afresh. Its ChatView still holds the old pane size and would lay out its Hydra
        /// panels for it in the first frames shown; a new column measures before it shows them.
        func show(_ id: UUID, in pane: NSView, model: AppModel, liveResize: WindowLiveResize, rebuildsIfResized: Bool = false) {
            guard id != shown else { return }
            initialExpansionTask?.cancel()
            initialExpansionTask = nil
            pendingInitialExpansionID = nil
            let outgoingID = shown
            resizeState = liveResize
            liveResize.setPaneOwner(isCovered ? nil : id, resizing: paneIsResizing(id, model: model))
            if let oldID = shown, let previous = columns[oldID] {
                previous.acceptsInteraction = false
                // Hiding a view holding the first responder makes AppKit search the whole
                // window for the next key view, querying every kept column; the shown
                // column's composer takes focus itself.
                if let window = previous.window,
                   let responder = window.firstResponder as? NSView,
                   responder.isDescendant(of: previous) {
                    window.makeFirstResponder(nil)
                }
                previous.isHidden = true
                scopes[oldID]?.setVisible(false)
                previous.autoresizingMask = []
                states[oldID]?.isShown = false
            }
            if rebuildsIfResized, let kept = columns[id], kept.frame.size != pane.bounds.size {
                drop(id)
            }
            var columnBranch = ""
            var columnElapsed: Duration?
            if let kept = columns[id] {
                let started: ContinuousClock.Instant? = SwitchLatency.isActive ? .now : nil
                reattachIfNeeded(id, in: pane)
                kept.acceptsInteraction = !isCovered
                kept.frame = pane.bounds
                kept.autoresizingMask = isCovered ? [] : [.width, .height]
                if let state = states[id] {
                    state.paneSize = pane.bounds.size
                    state.initialFrame = false
                    state.isShown = !isCovered
                }
                // In view before the column shows, so its first frame carries the real
                // alpha; under a cover that has hidden the pane it stays paused.
                scopes[id]?.setVisible(!isCovered && !pane.isHidden)
                kept.layoutSubtreeIfNeeded()
                kept.isHidden = false
                if let started {
                    columnBranch = "cached"
                    columnElapsed = started.duration(to: .now)
                }
            } else if order.count >= Self.keptLimit + 1,
                      let victimID = order.first,
                      victimID != id,
                      victimID != shown,
                      victimID != outgoingID,
                      let victimColumn = columns[victimID],
                      !(rebuildsIfResized && victimColumn.frame.size != pane.bounds.size) {
                let started: ContinuousClock.Instant? = SwitchLatency.isActive ? .now : nil
                let column = recycle(from: victimID, to: id, in: pane, model: model, liveResize: liveResize)
                if let started {
                    columnBranch = "recycled"
                    columnElapsed = started.duration(to: .now)
                }
                scheduleInitialExpansion(for: id, column: column)
            } else {
                let started: ContinuousClock.Instant? = SwitchLatency.isActive ? .now : nil
                let column = make(id, isShown: true, initialFrame: true, in: pane, model: model, liveResize: liveResize)
                if let started {
                    columnBranch = "made"
                    columnElapsed = started.duration(to: .now)
                }
                scheduleInitialExpansion(for: id, column: column)
            }
            if SwitchLatency.isActive, let columnElapsed {
                let title = model.thread(id)?.title.prefix(24) ?? "?"
                SwitchLatency.note("column \(title): \(columnBranch) in \(SwitchLatency.ms(columnElapsed)) ms")
            }
            shown = id
            order.removeAll { $0 == id }
            order.append(id)
            while order.count > Self.keptLimit + 1 { drop(order[0]) }
        }

        private func scheduleInitialExpansion(for id: UUID, column: FrameHostingView) {
            pendingInitialExpansionID = id
            initialExpansionTask?.cancel()
            initialExpansionTask = Task { @MainActor [weak self, weak column] in
                try? await Task.sleep(for: .milliseconds(90))
                guard !Task.isCancelled, let self, self.pendingInitialExpansionID == id else { return }
                self.pendingInitialExpansionID = nil
                self.initialExpansionTask = nil
                guard self.shown == id, let column, self.columns[id] === column else { return }
                self.states[id]?.initialFrame = false
            }
        }

        private func themeDidChange() {
            guard ThemeManager.style != lastThemeStyle else { return }
            lastThemeStyle = ThemeManager.style
            for (id, column) in columns where id != shown && !detached.contains(id) {
                if let window = column.window,
                   let responder = window.firstResponder as? NSView,
                   responder.isDescendant(of: column) {
                    window.makeFirstResponder(nil)
                }
                column.removeFromSuperview()
                detached.insert(id)
            }
        }

        private func reattachIfNeeded(_ id: UUID, in pane: NSView) {
            guard detached.remove(id) != nil, let column = columns[id] else { return }
            pane.addSubview(column)
        }

        private func handleMemoryPressure(critical: Bool) {
            let hiddenLimit = critical ? 0 : 2
            let hidden = order.filter { $0 != shown }
            if hidden.count > hiddenLimit {
                for id in hidden.prefix(hidden.count - hiddenLimit) {
                    drop(id)
                }
            }
            if !retired.isEmpty {
                retirement?.cancel()
                retirement = nil
                for column in retired { column.removeFromSuperview() }
                retired.removeAll()
            }
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
            guard !isCovered,
                  !SettingsNavigation.shared.isPresented,
                  !model.voice.stageOpen else { return }
            for id in ids where !requested.contains(id) && columns[id] == nil {
                let started = ContinuousClock.now
                make(id, isShown: false, initialFrame: false, in: pane, model: model, liveResize: liveResize).layoutSubtreeIfNeeded()
                SwitchLatency.note("prebuilt \(model.thread(id)?.title.prefix(24) ?? "?") in \(started.duration(to: .now))")
                order.insert(id, at: 0)
                while order.count > Self.keptLimit + 1 { drop(order[0]) }
            }
            requested = Set(ids)
        }

        @discardableResult
        private func recycle(from victimID: UUID, to id: UUID, in pane: NSView, model: AppModel, liveResize: WindowLiveResize) -> FrameHostingView {
            order.removeAll { $0 == victimID }
            reattachIfNeeded(victimID, in: pane)
            guard let column = columns.removeValue(forKey: victimID),
                  let state = states.removeValue(forKey: victimID),
                  let scope = scopes.removeValue(forKey: victimID) else {
                return make(id, isShown: true, initialFrame: true, in: pane, model: model, liveResize: liveResize)
            }
            scope.setVisible(!isCovered && !pane.isHidden)
            state.runtime = model.runtime(for: id)
            state.paneSize = pane.bounds.size
            state.initialFrame = true
            state.isShown = !isCovered
            states[id] = state
            scopes[id] = scope
            columns[id] = column
            column.acceptsInteraction = !isCovered
            column.frame = pane.bounds
            column.autoresizingMask = isCovered ? [] : [.width, .height]
            column.layoutSubtreeIfNeeded()
            column.isHidden = false
            return column
        }

        @discardableResult
        private func make(_ id: UUID, isShown: Bool, initialFrame: Bool = false, in pane: NSView, model: AppModel, liveResize: WindowLiveResize) -> FrameHostingView {
            let scope = VeilRenderScope()
            scopes[id] = scope
            // A column built hidden (a prebuild, or a switch under a hidden pane) never
            // runs its fade clock; one the pane is showing starts live.
            scope.setVisible(isShown && !isCovered && !pane.isHidden)
            let state = ColumnHostState(
                runtime: model.runtime(for: id),
                isShown: isShown && !isCovered,
                initialFrame: initialFrame,
                paneSize: pane.bounds.size
            )
            states[id] = state
            let column = FrameHostingView(rootView: AnyView(
                HostedChatColumn(
                    state: state,
                    model: model,
                    liveResize: liveResize,
                    scope: scope
                )
            ))
            column.acceptsInteraction = isShown && !isCovered
            column.frame = pane.bounds
            column.isHidden = !isShown
            column.autoresizingMask = isShown && !isCovered ? [.width, .height] : []
            pane.addSubview(column)
            columns[id] = column
            return column
        }

        private func paneIsResizing(_ id: UUID?, model: AppModel) -> Bool {
            guard !isCovered, let id else { return false }
            return model.sidebar.isDragging || model.sidebar.isSliding
                || model.existingRuntime(for: id)?.isTerminalResizing == true
        }

        private func drop(_ id: UUID) {
            order.removeAll { $0 == id }
            detached.remove(id)
            states.removeValue(forKey: id)
            // The scope goes with the column: its clock stops, its veils are told, and
            // the retiring tree's environment is the last reference to it.
            if let scope = scopes.removeValue(forKey: id) { scope.setVisible(false) }
            guard let column = columns.removeValue(forKey: id) else { return }
            column.acceptsInteraction = false
            column.isHidden = true
            retired.append(column)
            guard retirement == nil else { return }
            retirement = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(500))
                while let self, !Task.isCancelled, !self.retired.isEmpty {
                    while !Task.isCancelled, ScrollActivity.shared.isScrolling {
                        try? await Task.sleep(for: .milliseconds(60))
                    }
                    guard !Task.isCancelled, !self.retired.isEmpty else { break }
                    self.retired.removeFirst().removeFromSuperview()
                    if !self.retired.isEmpty {
                        try? await Task.sleep(for: .milliseconds(60))
                    }
                }
                if !Task.isCancelled { self?.retirement = nil }
            }
        }
    }
}

@MainActor
@Observable
private final class ColumnHostState {
    var runtime: ThreadRuntime
    var isShown: Bool
    var initialFrame: Bool
    var paneSize: CGSize
    var paneHeight: CGFloat { paneSize.height }

    init(runtime: ThreadRuntime, isShown: Bool, initialFrame: Bool, paneSize: CGSize) {
        self.runtime = runtime
        self.isShown = isShown
        self.initialFrame = initialFrame
        self.paneSize = paneSize
    }
}

private struct HostedChatColumn: View {
    let state: ColumnHostState
    let model: AppModel
    let liveResize: WindowLiveResize
    let scope: VeilRenderScope

    var body: some View {
        ChatView(runtime: state.runtime)
            .environment(\.chatColumnIsShown, state.isShown)
            .environment(\.chatColumnInitialFrame, state.initialFrame)
            .environment(\.chatColumnInitialPaneSize, state.paneSize)
            .environment(\.chatColumnInitialPaneHeight, state.paneHeight)
            .environment(\.veilRenderScope, scope)
            .disabled(!state.isShown)
            .allowsHitTesting(state.isShown)
            .modifier(HostedEnvironment(model: model, liveResize: liveResize, isLayoutActive: state.isShown))
    }
}

struct WelcomeView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(spacing: 30) {
                VStack(spacing: 14) {
                    Image(nsImage: AppIconManager.shared.image)
                        .resizable()
                        .frame(width: 104, height: 104)
                    Text("Tivano")
                        .font(TypeScale.shared.serif ? Font(ThemeTypeface.nsFont(size: 34, weight: .semibold) as CTFont) : .system(size: 34, weight: .semibold))
                    Text("A calm, native home for your coding agents.")
                        .font(.ui(.title3))
                        .foregroundStyle(Chrome.secondaryText)
                }
                VStack(spacing: 10) {
                    Button {
                        model.newThread(affiliation: .standalone)
                    } label: {
                        Label("Work without a project", systemImage: "bubble.left")
                            .padding(.horizontal, 6)
                    }
                    .themedGlassButton(prominent: true)
                    .controlSize(.extraLarge)
                    HStack(spacing: 10) {
                        Button {
                            model.chooseProjectFolder()
                        } label: {
                            Label("Add a project", systemImage: "folder.badge.plus")
                                .padding(.horizontal, 6)
                        }
                        .themedGlassButton(prominent: true)
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
            ForEach(Array(ProviderKind.alphabetical.enumerated()), id: \.element) { index, provider in
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
                Text(verbatim: provider.routeSummary + " · " + (status.isChecking ? Chrome.localized("Checking…") : status.summary))
                    .font(.ui(.subheadline))
                    .foregroundStyle(Chrome.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
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
                        .themedGlassButton()
                }
            } else if status.auth == .signedOut {
                // ZCode signs in with the Z.ai key typed in Settings; it has no login command.
                if provider.isAPIKeyBased || provider == .zcode {
                    OpenProvidersSettingsButton()
                } else {
                    Button("Login") { Workspace.openTerminal(running: provider.loginCommand) }
                        .themedGlassButton()
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
        .themedGlassButton()
        .help(Text(verbatim: Chrome.localized("Open Settings › Providers")))
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
            .themedGlassButton(prominent: true)
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

extension EnvironmentValues {
    /// True on the first frame of a cold-switched column, so the timeline mounts only
    /// a screenful slice and expands to its resting window on the next runloop turn.
    @Entry var chatColumnInitialFrame = false
    /// The hosting pane's size when a column is created or shown, before SwiftUI geometry settles.
    @Entry var chatColumnInitialPaneSize: CGSize = .zero
    /// The hosting pane's height when a column is created, before SwiftUI geometry settles.
    @Entry var chatColumnInitialPaneHeight: CGFloat = 0
}

