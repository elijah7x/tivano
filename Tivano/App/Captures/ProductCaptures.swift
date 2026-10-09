#if DEBUG
import AppKit
import SwiftUI

/// The development product screenshots: eight scenes (plus four theme variants) photographed
/// over a fixed generated gradient as 16:10 images:
///
///     open -n -W "Tivano.app" --args --website-captures <folder>
///
/// Same isolation contract as WebsiteCaptures: own storage folder, own defaults suite,
/// quits when the last file is written. The Hydra scene itself lives in
/// `ProductCaptures+Hydra.swift`.
@MainActor
enum ProductCaptures {
    enum Backdrop: CaseIterable {
        case welcome, hydra, pairs, slider, panels, themes
    }

    static func backdropView(_ backdrop: Backdrop) -> some View {
        let alignment: Alignment
        switch backdrop {
        case .welcome:
            alignment = .center
        case .hydra:
            alignment = .top
        case .pairs:
            alignment = .bottomLeading
        case .slider:
            alignment = .bottomTrailing
        case .panels:
            alignment = .topLeading
        case .themes:
            alignment = .center
        }
        return BackdropWallpaper(screen: NSScreen.main ?? NSScreen.screens[0], alignment: alignment).ignoresSafeArea()
    }

    /// One quarter of a double-size gradient, so four stills tile into one seamless
    /// image: `quadrant` is (0, 0) top-left, (1, 0) top-right, (0, 1) bottom-left,
    /// (1, 1) bottom-right.
    static func backdropView(_ backdrop: Backdrop, quadrant: (x: Int, y: Int)) -> some View {
        GeometryReader { proxy in
            backdropView(backdrop)
                .frame(width: proxy.size.width * 2, height: proxy.size.height * 2)
                .offset(x: -CGFloat(quadrant.x) * proxy.size.width, y: -CGFloat(quadrant.y) * proxy.size.height)
        }
        .ignoresSafeArea()
    }

    static func run(model: AppModel) async {
        guard let output = CaptureRun.outputDirectory else { return }
        // Library loading moved out of AppModel.init; the normal launch performs this
        // separately, while capture launch skips that path.
        await model.bootstrap()
        guard model.isLibraryLoaded, !model.threads.isEmpty else {
            WebsiteCaptures.log("capture library failed to load")
            exit(1)
        }
        // Each still waits for activation; ten minutes is the capture budget.
        Task {
            try? await Task.sleep(for: .seconds(600))
            WebsiteCaptures.log("out of time, quitting")
            exit(0)
        }
        // The first Hydra chat must not present an intro over the staged screenshot.
        model.settings.hasSeenHydraIntro = true
        let stage = Stage(model: model)
        stage.show(size: NSSize(width: 1200, height: 660))
        await stage.ensureActive()
        let recorder = Recorder(output: output, stage: stage)
        try? await Task.sleep(for: .milliseconds(1_400))

        // 1. capture-welcome: the whole window in one overview — large 16:10 stage,
        // sidebar hidden (the chat alone on the glass; the list has a scene of its own),
        // settled after the scene lands so nothing important is cropped.
        await capture(model, stage, recorder, name: "capture-welcome", backdrop: .welcome, size: NSSize(width: 1280, height: 800)) {
            if model.sidebar.isVisible { model.sidebar.toggle() }
            model.settings.theme = .dark
            model.selectedThreadID = WebsiteCaptures.composerThreadID
            await WebsiteCaptures.editingScene(model, stage, recorder)
            try? await Task.sleep(for: .milliseconds(900))
            return nil
        }
        // 2. capture-hydra.
        await ProductCaptures.hydraScene(model, stage, recorder)
        // 3. capture-pairs: zoomed on the model switcher hanging from the composer's
        // chip. Narrow 16:10 stage, sidebar hidden, chip settled before hanging.
        await capture(model, stage, recorder, name: "capture-pairs", backdrop: .pairs, size: NSSize(width: 960, height: 600)) {
            if model.sidebar.isVisible { model.sidebar.toggle() }
            model.selectedThreadID = WebsiteCaptures.freshThreadID
            // The chip reports where it sits once the thread has laid out; the popover
            // hangs from that.
            try? await Task.sleep(for: .milliseconds(1_200))
            await model.providers.loadCatalog(.claude)
            await model.providers.loadCatalog(.antigravity)
            await model.providers.loadCatalog(.opencode)
            model.settings.hydraEnabled = true
            await ensurePairs(model)
            guard let thread = model.thread(WebsiteCaptures.freshThreadID) else { return nil }
            let list = ModelList(thread: thread, hasHistory: false, onChoose: { _ in }, onBack: {})
            let popover = stage.presentPopover(list.environment(model), width: 330, chipOf: WebsiteCaptures.freshThreadID)
            await stage.holdPopover(popover, seconds: 2.0)
            WebsiteCaptures.log("pairs popover shown=\(popover.isShown) size=\(popover.contentSize)")
            return popover
        }
        // 4. capture-slider: zoomed on the effort card hanging from the composer's chip.
        await capture(model, stage, recorder, name: "capture-slider", backdrop: .slider, size: NSSize(width: 960, height: 600)) {
            if let pair = model.settings.hydraPairs.first {
                model.enterHydraPair(pair, for: WebsiteCaptures.freshThreadID)
            }
            model.updateThread(WebsiteCaptures.freshThreadID) { $0.effort = "max" }
            guard let thread = model.thread(WebsiteCaptures.freshThreadID) else { return nil }
            let option = model.providers.model(thread.model, for: thread.provider)
            let pair = model.settings.hydraPair(thread.hydraPairID).map { EffortPairLook($0, registry: model.providers, resolvedHeadsEffort: nil) }
            let card = EffortSliderCard(
                modelName: option?.shortName ?? thread.model ?? thread.provider.displayName,
                provider: thread.provider,
                pair: pair,
                efforts: option?.efforts ?? [],
                defaultEffort: option?.defaultEffort,
                supportsFast: option?.supportsFast ?? false,
                effort: Binding(get: { model.thread(WebsiteCaptures.freshThreadID)?.effort }, set: { effort in model.updateThread(WebsiteCaptures.freshThreadID) { $0.effort = effort } }),
                fastMode: Binding(get: { model.thread(WebsiteCaptures.freshThreadID)?.fastMode ?? false }, set: { on in model.updateThread(WebsiteCaptures.freshThreadID) { $0.fastMode = on } }),
                onTitleTap: {},
                onReset: {}
            )
            let popover = stage.presentPopover(card.environment(model), width: 330, chipOf: WebsiteCaptures.freshThreadID)
            await stage.holdPopover(popover, seconds: 2.0)
            return popover
        }
        // 4a. capture-threads: the hidden sidebar's list floating from the toolbar's Threads
        // button, at the sidebar's own width.
        await capture(model, stage, recorder, name: "capture-threads", backdrop: .panels, size: NSSize(width: 960, height: 600)) {
            if model.sidebar.isVisible { model.sidebar.toggle() }
            model.selectedThreadID = WebsiteCaptures.composerThreadID
            try? await Task.sleep(for: .milliseconds(900))
            let width = model.sidebar.width
            let list = SidebarView(inPopover: true, dismiss: {}).frame(width: width, height: 560).presentedChrome().environment(model)
            let popover = stage.presentPopover(list, width: width, chipOf: WebsiteCaptures.composerThreadID, at: WebsiteCaptures.threadsButtonFrame)
            await stage.holdPopover(popover, seconds: 2.0)
            return popover
        }
        // 4b. capture-recipes: Hydra's cookbook hanging from the composer's chip.
        await capture(model, stage, recorder, name: "capture-recipes", backdrop: .hydra, size: NSSize(width: 960, height: 600)) {
            if model.sidebar.isVisible { model.sidebar.toggle() }
            model.selectedThreadID = WebsiteCaptures.freshThreadID
            model.settings.hydraEnabled = true
            try? await Task.sleep(for: .milliseconds(900))
            // The panel sizes itself (460 by 540); the popover takes that width whole.
            let panel = HydraCookbookPanel().environment(model)
            let popover = stage.presentPopover(panel, width: 460, chipOf: WebsiteCaptures.freshThreadID)
            await stage.holdPopover(popover, seconds: 2.0)
            return popover
        }
        // 5. capture-panels: the team's panel and a popped-out head over the lead's chat.
        await ProductCaptures.panelsScene(model, stage, recorder)
        // 6. capture-theme-<rawValue>: four themes far apart, one of them light. Each shows
        // one quarter of a double-size gradient, so the four tile into one seamless image.
        let quadrantThemes = [AppTheme.tokyoNight, .gruvbox, .catppuccinLatte, .rosePine]
        for (index, theme) in quadrantThemes.enumerated() {
            let quadrant = (x: index % 2, y: index / 2)
            WebsiteCaptures.log("scene capture-theme-\(theme.rawValue)")
            stage.setBackdrop(backdropView(.themes, quadrant: quadrant))
            stage.resize(to: NSSize(width: 960, height: 600))
            await stage.ensureActive()
            try? await Task.sleep(for: .milliseconds(1_100))
            if model.sidebar.isVisible { model.sidebar.toggle() }
            model.selectedThreadID = WebsiteCaptures.composerThreadID
            model.settings.theme = theme
            try? await Task.sleep(for: .milliseconds(900))
            await recorder.still("capture-theme-\(theme.rawValue)", stage.productCaptureRect)
        }
        model.settings.theme = .dark

        WebsiteCaptures.log("captures done")
        exit(0)
    }

    /// The two pairs staged for the model picker.
    static func ensurePairs(_ model: AppModel) async {
        guard model.settings.hydraPairs.isEmpty else { return }
        let fableID = model.providers.model("claude-fable-5-1[1m]", for: .claude)?.id ?? "claude-fable-5-1[1m]"
        var first = HydraPair(provider: .claude)
        first.orchestratorModel = fableID
        first.workerProvider = .antigravity
        first.workerModel = "gemini-3.8-flash"
        let opencodeID = model.providers.catalogs[.opencode]?.first(where: {
            $0.name.localizedCaseInsensitiveContains("Muse Spark") && $0.name.localizedCaseInsensitiveContains("Contributor")
        })?.id ?? model.providers.defaultModel(for: .opencode)?.id
        var second = HydraPair(provider: .claude)
        second.orchestratorModel = fableID
        second.workerProvider = .opencode
        second.workerModel = opencodeID
        model.settings.addHydraPair(first)
        model.settings.addHydraPair(second)
    }

    /// A site scene over a gradient: sidebar hidden, settled, then the scene stages
    /// itself and takes its own still.
    private static func capture(
        _ model: AppModel, _ stage: Stage, _ recorder: Recorder,
        name: String, backdrop: Backdrop, size: NSSize,
        body: () async -> NSPopover?,
        after: () -> Void = {}
    ) async {
        WebsiteCaptures.log("scene \(name)")
        stage.setBackdrop(backdropView(backdrop))
        stage.resize(to: size)
        await stage.ensureActive()
        try? await Task.sleep(for: .milliseconds(1_100))
        let popover = await body()
        await stage.ensureActive()
        try? await Task.sleep(for: .milliseconds(400))
        // The still is framed around the window and the popover together; the recorder
        // writes the window's place in it beside the PNG, and the import cuts from that.
        // The popover and its chip are the focus, so the page zooms on them.
        await recorder.still(name, stage.productCaptureRect(including: popover), focus: stage.popoverFocus(popover))
        popover?.close()
        after()
    }
}
#endif
