import AppKit
import SwiftUI

struct ChatView: View {
    @Environment(AppModel.self) private var model
    @Environment(WindowLiveResize.self) private var liveResize
    @Bindable var runtime: ThreadRuntime

    @State private var git = GitStatusModel()
    @State private var scrollChrome = ChromeScrollModel()
    @State private var scrollState = TimelineScrollState()
    /// Full column height. The timeline rail centres in this, so composer and
    /// queue growth never shifts it.
    @State private var columnHeight: CGFloat = 0
    /// The conversation pane (the timeline with the chat box, above any terminal), which
    /// the helper panel floats in.
    @State private var paneSize: CGSize = .zero
    /// The chat box with its tabs and cards, so a helper panel above it clears them.
    @State private var composerAreaHeight: CGFloat = 0
    /// The helper panel under the pointer while its handle is held; the same for the Hydra
    /// panel, and for the head popped out of it. Objects, so a move re-lays out one panel.
    @State private var subagentDrag = PanelDragState()
    @State private var hydraDrag = PanelDragState()
    @State private var poppedDrag = PanelDragState()
    @State private var usageDrag = PanelDragState()
    /// The automatic panels never move (their spot is the layout's), so one resting
    /// drag state serves them all.
    @State private var autoDrag = PanelDragState()
    /// One drag state per head with its own panel, made as they appear.
    @State private var autoDrags: [UUID: PanelDragState] = [:]
    /// What the usage panel's content asked for, so the panel is no taller than its rows
    /// (see `usagePanel`).
    @State private var usageContentHeight: CGFloat?
    /// One grip held at a time, whichever panel it is on.
    @State private var panelResize = PanelResizeState()
    /// Whether a panel is under the pointer right now, on any of the drag states above.
    ///
    /// While one is, the conversation stops answering hit tests. Every pointer move during
    /// a drag is a hover event, and SwiftUI answers one by walking the responder tree and
    /// rendering the view graph again — through the timeline, which is the largest tree in
    /// the window. With several panels open that walk is what makes a drag stutter: a spin
    /// report taken mid-drag spends 326 of 364 samples under NSHostingView.layout(), most
    /// of it in ViewGraphRootValueUpdater.render, reached from
    /// EventBindingManager.enqueueHoverUpdateIfNeeded.
    ///
    /// Nothing in the conversation needs to answer a hover while a panel is being moved,
    /// so for the length of the drag it does not.
    private var isMovingAPanel: Bool {
        subagentDrag.position != nil || hydraDrag.position != nil
            || poppedDrag.position != nil || usageDrag.position != nil
            || autoDrags.values.contains { $0.position != nil }
    }
    /// When the team's panel came on screen, and whether it is lingering past its heads.
    /// Heads that go out and fall at the door leave the panel within a frame or two of
    /// its arrival, and a panel that flashed on and straight off again read as a glitch:
    /// once shown it stays at least `hydraMinimumPresence`, then goes with the same slide
    /// a finished head's panel goes with.
    /// Whether the panels and the room the chat makes for them follow the pointer with
    /// no spring: a panel grip, the sidebar's edge or the terminal's divider is held. A
    /// sidebar drag or a terminal-divider drag moves the pane every frame the way a live
    /// resize does; a spring restarted per frame lagged the panels behind and swam. The
    /// sidebar's open or close slide is held the same way for its run.
    private var panelsHeld: Bool {
        panelResize.isActive || model.sidebar.isDragging || model.sidebar.isSliding || runtime.isTerminalResizing
    }
    @State private var hydraShownSince: Date?
    @State private var hydraLingers = false
    @State private var hydraLingerTask: Task<Void, Never>?
    /// The thread the scene was last laid out for. A body pass on a different thread is a
    /// switch: panels and reserves snap to the new thread's layout rather than glide from
    /// the old one's, and the Hydra panel's linger is dropped rather than carried across.
    @State private var sceneThreadID: UUID?

    private static let hydraMinimumPresence: TimeInterval = 1.6

    var body: some View {
        let thread = model.thread(runtime.threadID)
        let project = thread.flatMap { model.project($0.projectID) }
        // The thread and project are read here, once, and passed down as values: the timeline
        // rows and the composer never observe them, so a change to either re-renders this
        // body alone and the children only where what they were handed changed.
        let workingDirectory = thread.flatMap { thread in project.map { thread.executionDirectory(projectPath: $0.path) } }
        let directory = workingDirectory ?? LoginEnvironment.homeDirectory
        let title = thread?.title ?? ""
        // Who is in a panel comes from the model and changes rarely; the geometry
        // comes from the measured pane and changes every frame of a live resize.
        // Split, so a resize frame recomputes docks and reserves only, never the
        // thread lists.
        let members = PanelMembers(runtime: runtime, model: model)
        let scene = PanelScene(members: members, runtime: runtime, model: model, paneSize: paneSize, composerAreaHeight: composerAreaHeight, usageContentHeight: usageContentHeight, holdsHydra: hydraLingers, preferredSize: livePreferredSize, usageHeightOverride: panelResize.liveUsageHeight)
        // The team's panel as the model has it, before the linger below: what decides
        // whether the panel is held on a beat after its heads leave.
        let hydraPresent = !members.heads.isEmpty && scene.isMeasured
        let holds = panelsHeld
        let switching = sceneThreadID != runtime.threadID
        VStack(spacing: 0) {
            ThreadTimeline(
                runtime: runtime,
                scrollChrome: scrollChrome,
                scrollState: scrollState,
                projectName: project?.name,
                workingDirectory: workingDirectory,
                supportsRewind: thread?.provider.supportsRewind ?? false,
                columnHeight: columnHeight,
                // A panel docked on the left takes the rail's edge; the rail goes with it. So
                // does a pane too narrow for both: the column reads at up to 820 points and the
                // rail floats over its gutter, so under about 900 the two would overlap.
                showsMinimap: !scene.dockedSides.contains(.leading)
                    && (paneSize == .zero || paneSize.width - scene.reserve.leading - scene.reserve.trailing >= 900),
                usesTimelineTopFade: true
            )
            .equatable()
            // Hover costs a responder walk and a render of this whole tree; a panel being
            // dragged sends one per pointer move and needs none of them (see
            // `isMovingAPanel`).
            .allowsHitTesting(!isMovingAPanel)
            // The timeline is the one part swapped per thread: the column around it (chrome
            // row, chat box, panels, git status, measured sizes) stays mounted, so a switch
            // re-lays out nothing else.
            .id(runtime.threadID)
            // The room the docked panels take from either side; the conversation and the
            // box centre in the rest, so they stay lined up with each other (see
            // `ReserveSlide` for how they get there without laying out on every frame).
            .modifier(ReserveSlide(reserve: scene.reserve, slides: scene.isMeasured && !liveResize.isActive && !holds && !switching))
            .safeAreaInset(edge: .bottom, spacing: 0) {
                ComposerArea(runtime: runtime, workingDirectory: workingDirectory)
                    .overlay(alignment: .top) {
                        JumpToLatestButton(scrollState: scrollState)
                    }
                    .onGeometryChange(for: CGFloat.self, of: { $0.size.height.rounded() }) {
                        if composerAreaHeight != $0 { composerAreaHeight = $0 }
                    }
                    .onChange(of: composerAreaHeight) { oldValue, newValue in
                        // The area growing (the queued follow-ups tab expanding, a
                        // follow-up being queued, an approval card arriving) shrinks the
                        // timeline's viewport from its bottom edge. The timeline pulls its
                        // end to the new edge for a reader who is at it, and leaves a
                        // reader who scrolled up to read exactly where they are: the
                        // growth is the composer's, never the reader's cue to jump. Not off
                        // the first measurement or a thread switch's fresh scroll state.
                        guard newValue > oldValue + 0.5, !liveResize.isActive, oldValue > 0 else { return }
                        scrollState.noteComposerAreaGrowth()
                    }
                    .modifier(ReserveSlide(reserve: scene.reserve, slides: scene.isMeasured && !liveResize.isActive && !holds && !switching, animatesWidth: true))
            }
            .overlay(alignment: .top) {
                ChatChromeRow(
                    runtime: runtime,
                    scrollChrome: scrollChrome,
                    title: title,
                    project: project,
                    directory: directory,
                    git: git,
                    titleLeading: scene.reserve.leading + max(20, (paneSize.width - scene.reserve.leading - scene.reserve.trailing - 820) / 2)
                )
            }
            .overlay(alignment: .topLeading) {
                ZStack(alignment: .topLeading) {
                    // Not before the pane has a size: the panel's spot comes from it.
                    if let subagent = scene.subagent, scene.isMeasured {
                        subagentPanel(subagent, scene: scene, project: project)
                    }
                }
                .animation(switching ? nil : Chrome.panelSlide, value: scene.subagent?.id)
            }
            .overlay(alignment: .topLeading) {
                let showsHydraPanel = scene.showsHydra
                ZStack(alignment: .topLeading) {
                    if showsHydraPanel {
                        hydraPanel(scene: scene, workingDirectory: workingDirectory, project: project)
                            // Two threads with a team panel each: the panel is replaced,
                            // never one thread's heads morphed into the other's.
                            .id(runtime.threadID)
                    }
                }
                // Toggled from the Hydra button, dismissed, or its heads gone, the panel
                // fades and scales in place, whatever flipped it: keyed to the same flag
                // that shows it, so it can never leave in a frame under some other
                // transaction. The room the chat makes for it is animated by
                // `ReserveSlide` on its own, so nothing here reaches the column.
                .animation(switching ? nil : Chrome.panelSlide, value: showsHydraPanel)
                .onChange(of: HydraPresence(threadID: runtime.threadID, present: hydraPresent)) { old, new in
                    hydraLingerTask?.cancel()
                    // A switch: whatever the last thread's panel was doing stays with it.
                    if old.threadID != new.threadID {
                        hydraLingers = false
                        hydraShownSince = new.present ? .now : nil
                        return
                    }
                    if new.present {
                        hydraShownSince = .now
                        hydraLingers = false
                        return
                    }
                    // Hidden by the reader (the Hydra button, within a beat of the panel
                    // showing): nothing to hold. The members leave the hidden panel's heads
                    // out, so a held panel here was an empty one with a zero on it.
                    guard !runtime.isHydraPanelHidden else {
                        hydraLingers = false
                        return
                    }
                    let shown = hydraShownSince.map { Date.now.timeIntervalSince($0) } ?? .infinity
                    let remaining = Self.hydraMinimumPresence - shown
                    guard remaining > 0 else { return }
                    hydraLingers = true
                    hydraLingerTask = Task { @MainActor in
                        try? await Task.sleep(for: .seconds(remaining))
                        guard !Task.isCancelled else { return }
                        withAnimation(Chrome.panelSlide) { hydraLingers = false }
                    }
                }
                // The same tap while a held panel is still fading: it goes with the tap.
                .onChange(of: runtime.isHydraPanelHidden) { _, hidden in
                    guard hidden, hydraLingers else { return }
                    hydraLingerTask?.cancel()
                    withAnimation(Chrome.panelSlide) { hydraLingers = false }
                }
            }
            .overlay(alignment: .topLeading) {
                ZStack(alignment: .topLeading) {
                    if let popped = scene.popped, scene.showsPopped {
                        poppedPanel(popped, scene: scene, workingDirectory: workingDirectory, project: project)
                    }
                }
                .animation(switching ? nil : Chrome.panelSlide, value: scene.popped?.id)
            }
            .overlay(alignment: .topLeading) {
                ZStack(alignment: .topLeading) {
                    ForEach(scene.autoPopped) { auto in
                        autoPoppedPanel(auto, scene: scene, workingDirectory: workingDirectory, project: project)
                    }
                }
                .animation(switching ? nil : Chrome.panelSlide, value: scene.autoPopped.map(\.id))
            }
            .overlay(alignment: .topLeading) {
                ZStack(alignment: .topLeading) {
                    if let usage = scene.usage, scene.showsUsage {
                        usagePanel(usage, scene: scene)
                    }
                }
                .animation(switching ? nil : Chrome.panelSlide, value: scene.usage)
            }
            .onGeometryChange(for: CGSize.self, of: { $0.size }) { paneSize = $0 }
            // Free-floating panels are kept inside the pane while it shrinks, with no
            // animation; when the resize ends they land docked exactly (see below).
            .onChange(of: paneSize) {
                guard liveResize.isActive else { return }
                // The scene above was worked out for this pane size already.
                let layout = scene.layout
                subagentDrag.reclamp(in: layout)
                hydraDrag.reclamp(in: layout)
                poppedDrag.reclamp(in: layout)
                usageDrag.reclamp(in: layout)
                for drag in autoDrags.values { drag.reclamp(in: layout) }
            }
            // A sidebar or terminal-divider drag reshapes the pane per frame the way a
            // live resize does; the sidebar's toggle slide reshapes the pane per frame too;
            // the timeline and composer read one signal for both.
            .onChange(of: model.sidebar.isDragging || model.sidebar.isSliding || runtime.isTerminalResizing, initial: true) { _, dragging in
                liveResize.isPaneResizing = dragging
            }
            // The pane's final size: docked panels land on their new docked spot, and
            // a free spot left outside is pulled back inside.
            .onChange(of: liveResize.isActive) { _, resizing in
                guard !resizing else { return }
                subagentDrag.reclamp(in: scene.layout)
                hydraDrag.reclamp(in: scene.layout)
                poppedDrag.reclamp(in: scene.layout)
                usageDrag.reclamp(in: scene.layout)
                for drag in autoDrags.values { drag.reclamp(in: scene.layout) }
            }
            .onChange(of: scene.autoPopped.map(\.id), initial: true) { _, ids in
                for id in ids where autoDrags[id] == nil { autoDrags[id] = PanelDragState() }
                for id in autoDrags.keys where !ids.contains(id) { autoDrags[id] = nil }
            }

            if runtime.isTerminalVisible {
                TerminalPanel(runtime: runtime, directory: directory)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
        .detailSheet()
        // The column stays mounted across a thread switch; only the timeline is swapped
        // (see its `.id(runtime.threadID)`). That swap must replace in place, never
        // slide or fade. Any transition here displaces every row, the composer and
        // the chrome row mid-flight, clips leading text, unseats the traffic lights
        // the chrome keeps room for, and doubles the title against itself.
        .transition(.identity)
        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { columnHeight = $0 }
        .animation(switching ? nil : Chrome.panelSlide, value: runtime.isTerminalVisible)
        // A merge or pull request link in this chat can hand its request to a helper, which
        // opens in the panel and lands it on the same provider and model as this thread.
        .environment(\.mergeRequestTarget, MergeRequestTarget(chatID: runtime.threadID) { link in
            model.spawnSubagent(from: runtime.threadID, title: link.title, prompt: link.prompt)
        })
        .task(id: directory) {
            await git.refresh(directory, force: false)
        }
        .onChange(of: runtime.diffRevision) {
            Task { await git.refresh(directory) }
        }
        // The column is not rebuilt on a thread switch, so what belonged to the previous
        // thread's timeline and panels starts fresh here. The measured sizes
        // (`columnHeight`, `paneSize`, `composerAreaHeight`) are the pane's, not the
        // thread's, and stay.
        .onChange(of: runtime.threadID) {
            sceneThreadID = runtime.threadID
            hydraLingerTask?.cancel()
            hydraLingers = false
            scrollChrome = ChromeScrollModel()
            scrollState = TimelineScrollState()
            subagentDrag = PanelDragState()
            hydraDrag = PanelDragState()
            poppedDrag = PanelDragState()
            usageDrag = PanelDragState()
            autoDrag = PanelDragState()
            autoDrags = [:]
            panelResize = PanelResizeState()
        }
        .onAppear { sceneThreadID = runtime.threadID }
    }

    // MARK: - Floating panels

    /// The helper's panel, in its corner.
    private func subagentPanel(_ subagent: ChatThread, scene: PanelScene, project: Project?) -> some View {
        let slot = scene.slots[.subagent] ?? PanelScene.PanelSlot(corner: runtime.subagentPanelDock, below: 0, lift: 0)
        let rest = Self.rest(for: slot, scene: scene)
        return PlacedPanel(drag: subagentDrag, rest: rest, size: scene.layout.panelSize, content: SubagentPanel(
            thread: subagent,
            size: scene.layout.panelSize,
            // The helper works in the project folder, whatever this thread's worktree.
            workingDirectory: model.project(subagent.projectID).map { subagent.executionDirectory(projectPath: $0.path) },
            projectName: project?.name,
            onDrag: { translation in
                let position = subagentDrag.move(by: translation, from: rest, in: scene.layout)
                dock(.subagent, \.subagentPanelDock, nearest: position, scene: scene)
                reorder(.subagent, at: position, corner: runtime.subagentPanelDock, scene: scene)
            },
            onDragEnd: {
                if let heading = subagentDrag.release() {
                    dock(.subagent, \.subagentPanelDock, nearest: heading, scene: scene)
                    reorder(.subagent, at: heading, corner: runtime.subagentPanelDock, scene: scene)
                }
            },
            close: {
                // The helper moves to the sidebar under this thread; its row opens with the
                // same slide as the panel leaving.
                withAnimation(Chrome.panelSlide) {
                    model.closeSubagent(subagent.id)
                }
            }
        )
        // Inside the offset, so the panel grows in and fades out in place.
        .transition(Self.panelTransition), resize: resizer(for: runtime.subagentPanelDock, scene: scene), isResizing: panelsHeld)
    }

    /// The team's panel: next to the helper panel when that one is in the same corner.
    private func hydraPanel(scene: PanelScene, workingDirectory: String?, project: Project?) -> some View {
        let slot = scene.slots[.hydra] ?? PanelScene.PanelSlot(corner: runtime.hydraPanelDock, below: 0, lift: 0)
        let corner = slot.corner
        let rest = Self.rest(for: slot, scene: scene)
        return PlacedPanel(drag: hydraDrag, rest: rest, size: scene.layout.panelSize, content: HydraPanel(
            runtime: runtime,
            heads: scene.heads,
            size: scene.layout.panelSize,
            workingDirectory: workingDirectory,
            projectName: project?.name,
            onDrag: { translation in
                let position = hydraDrag.move(by: translation, from: rest, in: scene.layout)
                dock(.hydra, \.hydraPanelDock, nearest: position, scene: scene)
                reorder(.hydra, at: position, corner: runtime.hydraPanelDock, scene: scene)
            },
            onDragEnd: {
                if let heading = hydraDrag.release() {
                    dock(.hydra, \.hydraPanelDock, nearest: heading, scene: scene)
                    reorder(.hydra, at: heading, corner: runtime.hydraPanelDock, scene: scene)
                }
            },
            popOut: { id in
                // The head's own panel opens docked across the column from the team
                // panel, so the two sit apart.
                withAnimation(Chrome.panelSlide) {
                    runtime.hydraPoppedHeadID = id
                    runtime.hydraPoppedPanelDock = runtime.hydraPanelDock.acrossTheColumn
                    if runtime.hydraSelectedHeadID == id { runtime.hydraSelectedHeadID = nil }
                }
            },
            dismiss: {
                withAnimation(Chrome.panelSlide) {
                    model.dismissHydraHeads(of: runtime.threadID)
                }
            }
        )
        .modifier(HydraCaptureFrame(threadID: runtime.threadID, liveResize: liveResize))
        .transition(Self.panelTransition), resize: resizer(for: corner, scene: scene), isResizing: panelsHeld)
    }

    /// Where the team's panel sits, for the tour's captures only: the Hydra page zooms on
    /// it. Attached only when captures are on, so the everyday panel carries no geometry
    /// reader. Skipped while the window is resized: the frame moves every frame and the
    /// capture map is never read mid-drag.
    private struct HydraCaptureFrame: ViewModifier {
        let threadID: UUID
        let liveResize: WindowLiveResize

        func body(content: Content) -> some View {
            #if DEBUG
            if CaptureRun.isEnabled {
                content.onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                    guard !liveResize.isActive else { return }
                    WebsiteCaptures.hydraPanelFrames[threadID] = frame
                }
            } else {
                content
            }
            #else
            content
            #endif
        }
    }

    /// The popped-out head's panel: beyond whichever panels are in the same corner.
    private func poppedPanel(_ popped: ChatThread, scene: PanelScene, workingDirectory: String?, project: Project?) -> some View {
        let slot = scene.slots[.popped] ?? PanelScene.PanelSlot(corner: runtime.hydraPoppedPanelDock, below: 0, lift: 0)
        let corner = slot.corner
        let rest = Self.rest(for: slot, scene: scene)
        return PlacedPanel(drag: poppedDrag, rest: rest, size: scene.layout.panelSize, content: HydraPanel(
            runtime: runtime,
            heads: [popped],
            size: scene.layout.panelSize,
            workingDirectory: workingDirectory,
            projectName: project?.name,
            isPoppedOut: true,
            onDrag: { translation in
                let position = poppedDrag.move(by: translation, from: rest, in: scene.layout)
                dock(.popped, \.hydraPoppedPanelDock, nearest: position, scene: scene)
                reorder(.popped, at: position, corner: runtime.hydraPoppedPanelDock, scene: scene)
            },
            onDragEnd: {
                if let heading = poppedDrag.release() {
                    dock(.popped, \.hydraPoppedPanelDock, nearest: heading, scene: scene)
                    reorder(.popped, at: heading, corner: runtime.hydraPoppedPanelDock, scene: scene)
                }
            },
            dismiss: {
                // Back into the team panel, and onto its stage.
                withAnimation(Chrome.panelSlide) {
                    runtime.hydraSelectedHeadID = popped.id
                    runtime.hydraPoppedHeadID = nil
                }
            }
        )
        .transition(Self.panelTransition), resize: resizer(for: corner, scene: scene), isResizing: panelsHeld)
        .id(popped.id)
    }

    /// A head popped out because there was room; its X sends it back into the team
    /// panel and holds it there.
    private func autoPoppedPanel(_ head: ChatThread, scene: PanelScene, workingDirectory: String?, project: Project?) -> some View {
        let slot = scene.slots[.auto(head.id)] ?? PanelScene.PanelSlot(corner: runtime.hydraPanelDock.acrossTheColumn, below: 0, lift: 0)
        let rest = Self.rest(for: slot, scene: scene)
        let drag = autoDrags[head.id] ?? autoDrag
        return PlacedPanel(drag: drag, rest: rest, size: scene.layout.panelSize, content: HydraPanel(
            runtime: runtime,
            heads: [head],
            size: scene.layout.panelSize,
            workingDirectory: workingDirectory,
            projectName: project?.name,
            isPoppedOut: true,
            onDrag: { translation in
                let position = drag.move(by: translation, from: rest, in: scene.layout)
                dockAuto(head.id, nearest: position, scene: scene)
                reorder(.auto(head.id), at: position, corner: runtime.hydraAutoPanelDocks[head.id] ?? slot.corner, scene: scene)
            },
            onDragEnd: {
                if let heading = drag.release() {
                    dockAuto(head.id, nearest: heading, scene: scene)
                    reorder(.auto(head.id), at: heading, corner: runtime.hydraAutoPanelDocks[head.id] ?? slot.corner, scene: scene)
                }
            },
            dismiss: {
                withAnimation(Chrome.panelSlide) {
                    runtime.hydraAutoPopHeld.insert(head.id)
                    runtime.hydraSelectedHeadID = head.id
                }
            }
        )
        .transition(Self.panelTransition), resize: resizer(for: slot.corner, scene: scene), isResizing: panelsHeld)
        .id(head.id)
    }

    /// The usage panel: beyond whichever panels are in the same corner, so it is the last
    /// of a stack. Across the column from the heads by default, at the left.
    private func usagePanel(_ usage: PanelUsage, scene: PanelScene) -> some View {
        let slot = scene.slots[.usage] ?? PanelScene.PanelSlot(corner: model.settings.usagePanelDock, below: 0, lift: 0)
        let corner = slot.corner
        let rest = Self.rest(for: slot, scene: scene)
        let full = scene.layout.panelSize
        let minimum = PanelScene.usageMinimumHeight
        // The panel's own height, worked out with the scene (see `PanelScene.usageHeight`).
        let height = scene.usageHeight ?? full.height
        let size = CGSize(width: full.width, height: height)
        // A bottom-docked panel keeps its bottom edge where the full-height one would
        // sit; a top-docked one keeps its top.
        let origin = corner.isTop ? rest : CGPoint(x: rest.x, y: rest.y + (full.height - height))
        return PlacedPanel(drag: usageDrag, rest: origin, size: size, content: UsageFloatingPanel(
            runtime: runtime,
            provider: usage.provider,
            headsProvider: usage.headsProvider,
            size: size,
            onContentHeight: { wanted in if usageContentHeight != wanted { usageContentHeight = wanted } },
            onDrag: { translation in
                let position = usageDrag.move(by: translation, from: origin, in: scene.layout)
                dockUsage(nearest: position, scene: scene)
                reorder(.usage, at: position, corner: model.settings.usagePanelDock, scene: scene)
            },
            onDragEnd: {
                if let heading = usageDrag.release() {
                    dockUsage(nearest: heading, scene: scene)
                    reorder(.usage, at: heading, corner: model.settings.usagePanelDock, scene: scene)
                }
            },
            dismiss: {
                // For every chat; the usage popover's pop-out button brings it back.
                withAnimation(Chrome.panelSlide) {
                    model.settings.showsUsagePanel = false
                }
            }
        )
        .transition(Self.panelTransition), resize: usageResizer(for: corner, scene: scene, size: size, minimum: minimum), isResizing: panelsHeld)
    }

    /// The grips of a panel docked in `corner`. A pull on a free edge grows the panel away
    /// from its corner; the size is kept in Settings for every chat's panels, fitted to
    /// this pane's room, so it follows the pointer here and the window's size after.
    private func resizer(for corner: PanelDockCorner, scene: PanelScene) -> PanelResize {
        PanelResize(
            corner: corner,
            onResize: { translation, axes in
                let start = panelResize.begin(at: scene.layout.panelSize)
                // The pointer's travel runs right and down; a panel docked at the right
                // grows leftwards, one docked at the bottom grows upwards.
                let acrossSign: CGFloat = corner.side == .trailing ? -1 : 1
                let downSign: CGFloat = corner.isTop ? 1 : -1
                var next = start
                if axes.contains(.width) { next.width += translation.width * acrossSign }
                if axes.contains(.height) { next.height += translation.height * downSign }
                panelResize.liveSize = scene.layout.fitted(next)
            },
            onResizeEnd: commitPanelResize,
            onReset: {
                withAnimation(Chrome.panelSlide) { model.settings.panelSize = nil }
            }
        )
    }

    /// The usage panel's grips: its width is the panels' shared width, its height its own
    /// (see `AppSettings.usagePanelHeight`); a double-click puts it back to fitting its rows.
    private func usageResizer(for corner: PanelDockCorner, scene: PanelScene, size: CGSize, minimum: CGFloat) -> PanelResize {
        PanelResize(
            corner: corner,
            onResize: { translation, axes in
                let start = panelResize.begin(at: size)
                // The pointer's travel runs right and down; a panel docked at the right
                // grows leftwards, one docked at the bottom grows upwards.
                let acrossSign: CGFloat = corner.side == .trailing ? -1 : 1
                let downSign: CGFloat = corner.isTop ? 1 : -1
                if axes.contains(.width) {
                    var next = scene.layout.panelSize
                    next.width = start.width + translation.width * acrossSign
                    panelResize.liveSize = scene.layout.fitted(next)
                }
                if axes.contains(.height) {
                    panelResize.liveUsageHeight = max(minimum, start.height + translation.height * downSign)
                }
            },
            onResizeEnd: commitPanelResize,
            onReset: {
                withAnimation(Chrome.panelSlide) { model.settings.usagePanelHeight = nil }
            }
        )
    }

    /// The grip let go: the size it was pulled to is written to Settings once, exact.
    /// While the grip was held only `panelResize` changed, so the pointer moved the
    /// panel and the room it takes, not every chat's stored size.
    private func commitPanelResize() {
        if let size = panelResize.liveSize { model.settings.panelSize = size }
        if let height = panelResize.liveUsageHeight { model.settings.usagePanelHeight = height }
        panelResize.liveSize = nil
        panelResize.liveUsageHeight = nil
        panelResize.end()
    }

    /// The size the layout prefers while a grip is held, else nil for the stored one. The
    /// width is stepped to 12pt while held, so the timeline re-wraps a few times over a
    /// drag rather than every frame; the committed size keeps the exact value.
    private var livePreferredSize: CGSize? {
        guard panelResize.isActive, let live = panelResize.liveSize else { return nil }
        return CGSize(width: (live.width / 12).rounded() * 12, height: live.height)
    }

    /// A panel grows in and fades out in place.
    private static var panelTransition: AnyTransition {
        .asymmetric(
            insertion: .scale(scale: 0.92).combined(with: .opacity),
            removal: .scale(scale: 0.96).combined(with: .opacity)
        )
    }

    /// Docks a panel in the corner nearest to `position`. Called as the panel is held as
    /// well as when it is let go, so the chat makes room on the new side while the panel
    /// is still under the pointer, and the panel has its spot the moment it is dropped.
    private func dock(_ id: FloatingPanelID, _ corner: ReferenceWritableKeyPath<ThreadRuntime, PanelDockCorner>, nearest position: CGPoint, scene: PanelScene) {
        let wanted = scene.layout.dockCorner(nearest: position, keeping: runtime[keyPath: corner], docks: scene.docks)
        let locked = scene.lockedSide(excluding: id)
        let next = locked.map { PanelDockCorner.make(side: $0, isTop: wanted.isTop) } ?? wanted
        guard next != runtime[keyPath: corner] else { return }
        runtime[keyPath: corner] = next
    }

    /// The usage panel's corner is one for every chat (see `AppSettings.usagePanelDock`).
    private func dockUsage(nearest position: CGPoint, scene: PanelScene) {
        let wanted = scene.layout.dockCorner(nearest: position, keeping: model.settings.usagePanelDock, docks: scene.docks)
        let locked = scene.lockedSide(excluding: .usage)
        let next = locked.map { PanelDockCorner.make(side: $0, isTop: wanted.isTop) } ?? wanted
        guard next != model.settings.usagePanelDock else { return }
        model.settings.usagePanelDock = next
    }

    private func dockAuto(_ id: UUID, nearest position: CGPoint, scene: PanelScene) {
        let current = runtime.hydraAutoPanelDocks[id] ?? scene.slots[.auto(id)]?.corner ?? runtime.hydraPanelDock.acrossTheColumn
        let wanted = scene.layout.dockCorner(nearest: position, keeping: current, docks: scene.docks)
        let locked = scene.lockedSide(excluding: .auto(id))
        let next = locked.map { PanelDockCorner.make(side: $0, isTop: wanted.isTop) } ?? wanted
        if runtime.hydraAutoPanelDocks[id] != next { runtime.hydraAutoPanelDocks[id] = next }
    }

    /// The held panel takes the slot it is over on its side, live: a free slot
    /// is taken, a taken one on a full side is swapped for the panel's old
    /// slot, otherwise the occupant and the rest move one slot along; the
    /// corners and the order are rewritten from the slots.
    private func reorder(_ id: FloatingPanelID, at position: CGPoint, corner: PanelDockCorner, scene: PanelScene) {
        let side = corner.side
        let others = scene.slots.filter { $0.value.corner.side == side && $0.key != id }
        let n = max(scene.slotsOnSide[side] ?? 1, others.count + 1)
        let target = scene.layout.slotIndex(at: position, slots: n, docks: scene.docks)
        var occupancy: [Int: FloatingPanelID] = [:]
        for (panelID, slot) in others {
            occupancy[slot.corner.isTop ? slot.below : n - 1 - slot.below] = panelID
        }
        let previous: Int? = scene.slots[id].flatMap { $0.corner.side == side ? ($0.corner.isTop ? $0.below : n - 1 - $0.below) : nil }
        let full = !(others.count + 1 > (scene.slotsOnSide[side] ?? 1))
        if let other = occupancy[target], previous != nil, full {
            occupancy[previous!] = other
            occupancy[target] = id
        } else if let other = occupancy[target] {
            occupancy.removeValue(forKey: target)
            occupancy[target] = id
            let forward = previous == nil || previous! < target
            var displaced = other
            var next = target + (forward ? 1 : -1)
            while true {
                if next < 0 || next >= n {
                    let free = forward ? (0..<n).first(where: { occupancy[$0] == nil }) : (0..<n).reversed().first(where: { occupancy[$0] == nil })
                    if let free { occupancy[free] = displaced }
                    break
                }
                if occupancy[next] == nil {
                    occupancy[next] = displaced
                    break
                }
                let occupant = occupancy[next]!
                occupancy[next] = displaced
                displaced = occupant
                next += forward ? 1 : -1
            }
        } else {
            occupancy[target] = id
        }
        for (index, panelID) in occupancy {
            let (corner, _) = PanelDocks.corner(forSlot: index, of: n, side: side)
            setCorner(panelID, corner)
        }
        let occupiedCorners = Dictionary(uniqueKeysWithValues: occupancy.map { ($0.value, PanelDocks.corner(forSlot: $0.key, of: n, side: side).corner) })
        let top = occupancy.filter { occupiedCorners[$0.value]?.isTop == true }.sorted { $0.key < $1.key }.map(\.value)
        let bottom = occupancy.filter { occupiedCorners[$0.value]?.isTop == false }.sorted { $0.key > $1.key }.map(\.value)
        let sideOrder = top + bottom
        let onSide = Set(occupancy.values)
        let kept = runtime.panelStackOrder.filter { !onSide.contains($0) && $0 != id }
        let next = kept + sideOrder
        if next != runtime.panelStackOrder { runtime.panelStackOrder = next }
    }

    private func setCorner(_ id: FloatingPanelID, _ corner: PanelDockCorner) {
        switch id {
        case .subagent:
            if runtime.subagentPanelDock != corner { runtime.subagentPanelDock = corner }
        case .hydra:
            if runtime.hydraPanelDock != corner { runtime.hydraPanelDock = corner }
        case .popped:
            if runtime.hydraPoppedPanelDock != corner { runtime.hydraPoppedPanelDock = corner }
        case .usage:
            if model.settings.usagePanelDock != corner { model.settings.usagePanelDock = corner }
        case .auto(let head):
            if runtime.hydraAutoPanelDocks[head] != corner { runtime.hydraAutoPanelDocks[head] = corner }
        }
    }

    private static func rest(for slot: PanelScene.PanelSlot, scene: PanelScene) -> CGPoint {
        let stacked = scene.docks.stacked(slot.corner, below: slot.below, slots: scene.slotsOnSide[slot.corner.side] ?? 1, layout: scene.layout)
        return CGPoint(x: stacked.x, y: slot.corner.isTop ? stacked.y + slot.lift : stacked.y - slot.lift)
    }
}

/// Makes room for the docked panels on either side and slides the content to its new
/// place, without laying it out at every width in between. Animating the padding itself
/// re-wrapped every visible message and the chat box on each frame of the spring, which
/// stuttered on a long conversation; here the padding snaps (one layout, at the final
/// width) and the content starts where it was and glides over on a transform, which
/// costs nothing per frame. The slide is keyed to a change in the room, never to a
/// measurement: a pane measured for the first time lays out in place, and a window resize
/// or a panel's width grip moves things at once, as they should (`slides` is off then).
/// What the Hydra linger watches: the team panel's presence, and which thread it is on.
private struct HydraPresence: Equatable {
    let threadID: UUID
    let present: Bool
}

extension EnvironmentValues {
    /// How far `ReserveSlide` has pushed its content off the column's leading edge right
    /// now: the leading room a docked panel takes plus the glide that carries the rows
    /// there. The minimap rail cancels it, so it stays on the edge while the rows move.
    @Entry var reserveSlideLeading: CGFloat = 0
    /// The glide alone, so a view can follow the snap and the glide with the rows but
    /// ignore the padding.
    @Entry var reserveSlideOffset: CGFloat = 0
}

private struct ReserveSlide: ViewModifier {
    let reserve: PanelReserve
    let slides: Bool
    /// Whether the padding itself glides. The box is one pill and cheap to lay out, so
    /// its width follows the room; the conversation's rows are not, so its padding
    /// snaps and the offset below carries it.
    var animatesWidth = false

    @State private var offset: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .environment(\.reserveSlideLeading, reserve.leading)
            .environment(\.reserveSlideOffset, offset)
            .padding(.leading, reserve.leading)
            .padding(.trailing, reserve.trailing)
            // Only a dock or undock glides; while a panel is dragged or resized the room
            // changes every frame, and the box follows the pointer without a spring.
            .animation(animatesWidth && slides ? Chrome.panelSlide : nil, value: reserve)
            .offset(x: offset)
            .onChange(of: reserve) { old, new in
                // The column centres in the room left, so its centre moves by half the
                // change in the room on either side: start from where it was and glide.
                let shift = ((new.leading - new.trailing) - (old.leading - old.trailing)) / 2
                guard slides, !animatesWidth, shift != 0 else {
                    offset = 0
                    return
                }
                var snap = Transaction()
                snap.disablesAnimations = true
                withTransaction(snap) { offset -= shift }
                withAnimation(Chrome.panelSlide) { offset = 0 }
            }
    }
}

/// Which threads sit in the chat's floating panels. Read from the model once per
/// body, apart from the pane measurements: a live resize then re-lays out geometry
/// without walking any thread list again.
@MainActor
private struct PanelMembers {
    let subagent: ChatThread?
    let isDocked: Bool
    let heads: [ChatThread]
    let popped: ChatThread?
    let isHydraHidden: Bool
    /// The usage panel's providers, when this chat shows one: the chat's own, and the
    /// pair's heads provider when that is another, so both plans' limits stack.
    let usage: PanelUsage?

    init(runtime: ThreadRuntime, model: AppModel) {
        // Both lists come from this chat's own children (see `panelHeads(of:)`), so a head
        // of another chat writing its status leaves this whole body alone.
        subagent = model.panelSubagent(of: runtime.threadID)
        isDocked = subagent != nil
        isHydraHidden = runtime.isHydraPanelHidden
        let team = isHydraHidden ? [] : model.panelHeads(of: runtime.threadID)
        let poppedHead = team.count > 1 ? team.first { $0.id == runtime.hydraPoppedHeadID } : nil
        popped = poppedHead
        heads = team.filter { $0.id != poppedHead?.id }
        if let thread = model.thread(runtime.threadID), model.settings.showsUsagePanel {
            var headsProvider: ProviderKind?
            if model.hydraIsOn(thread), let pair = model.hydraPair(for: thread) {
                let provider = model.hydraHeadsProvider(of: pair)
                headsProvider = provider == thread.provider ? nil : provider
            }
            usage = PanelUsage(provider: thread.provider, headsProvider: headsProvider)
        } else {
            usage = nil
        }
    }
}

/// Whose limits the usage panel shows: the chat's provider, and the heads' when a pair
/// sends them out on another.
struct PanelUsage: Equatable {
    let provider: ProviderKind
    let headsProvider: ProviderKind?
}

/// Everything the chat's floating panels need in one place, worked out once per body:
/// which panels there are, which are docked where, the room they take, and their spots.
@MainActor
private struct PanelScene {
    let layout: SubagentPanelLayout
    /// The helper this thread spawned, if it still has its panel open. It sits in a corner
    /// and takes room from that side of the chat column, so the conversation and the box
    /// centre in the rest and sit beside it.
    let subagent: ChatThread?
    let isDocked: Bool
    /// The team, in its own panel: next to the helper panel when both dock in one corner.
    /// One head can be popped out into a second panel, which leaves the team panel's
    /// list; it only stays out while another head is left behind to keep that panel.
    let heads: [ChatThread]
    let popped: ChatThread?
    /// A panel's place: its corner, how many panels sit under it in that corner's
    /// stack, and how much further from the edge it sits when a usage panel taller
    /// than one slot is under it.
    struct PanelSlot {
        let corner: PanelDockCorner
        let below: Int
        let lift: CGFloat
    }
    /// The heads with a panel of their own.
    let autoPopped: [ChatThread]
    let slots: [FloatingPanelID: PanelSlot]
    let slotsOnSide: [PanelDockSide: Int]

    /// The one side every panel must take when the pane cannot hold both (see
    /// `SubagentPanelLayout.fitsBothSides`): the side the other docked panels are on,
    /// the team panel's own when it is among them. Nil when both sides fit or no other
    /// panel is docked, so the panel being placed is free.
    func lockedSide(excluding id: FloatingPanelID) -> PanelDockSide? {
        guard !layout.fitsBothSides else { return nil }
        let others = slots.filter { $0.key != id }
        guard !others.isEmpty else { return nil }
        if let hydra = others[.hydra] { return hydra.corner.side }
        let leading = others.values.count { $0.corner.side == .leading }
        let trailing = others.count - leading
        return leading >= trailing ? .leading : .trailing
    }
    /// The usage panel's own height: what it was dragged to, else its rows, capped at the
    /// room left in its corner under the panels stacked below it (never the heads' compact
    /// height); nil without a usage panel.
    let usageHeight: CGFloat?
    /// The usage panel's providers, when the chat shows one (see `PanelMembers`).
    let usage: PanelUsage?
    let isMeasured: Bool
    let showsHydra: Bool
    let showsPopped: Bool
    let showsUsage: Bool
    let isHydraDocked: Bool
    /// The sides with a panel docked on them, in a fixed order, as the key for the slides
    /// that make room: it changes with a dock, never with a measurement.
    let dockedSides: [PanelDockSide]
    let reserve: PanelReserve
    let docks: PanelDocks

    var hasHeads: Bool { !heads.isEmpty }

    /// `preferredSize` and `usageHeightOverride` stand in for the stored sizes while a
    /// grip is held (see `PanelResizeState.liveSize`); nil reads Settings.
    init(members: PanelMembers, runtime: ThreadRuntime, model: AppModel, paneSize: CGSize, composerAreaHeight: CGFloat, usageContentHeight: CGFloat?, holdsHydra: Bool = false, preferredSize: CGSize? = nil, usageHeightOverride: CGFloat? = nil) {
        let geometry = Self.geometry(members: members, runtime: runtime, model: model, paneSize: paneSize, composerAreaHeight: composerAreaHeight, usageContentHeight: usageContentHeight, holdsHydra: holdsHydra, preferredSize: preferredSize, usageHeightOverride: usageHeightOverride)
        subagent = members.subagent
        isDocked = members.isDocked
        autoPopped = geometry.autoPopped
        slots = geometry.slots
        slotsOnSide = geometry.slotsOnSide
        usageHeight = geometry.usageHeight
        heads = members.heads.filter { head in !geometry.autoPopped.contains { $0.id == head.id } }
        popped = members.popped
        usage = members.usage
        isMeasured = geometry.isMeasured
        showsHydra = geometry.showsHydra
        showsPopped = geometry.showsPopped
        showsUsage = geometry.showsUsage
        isHydraDocked = geometry.isHydraDocked
        dockedSides = geometry.dockedSides
        layout = geometry.layout
        reserve = geometry.reserve
        docks = geometry.docks
    }

    /// The geometry alone, from the members and the measured pane: what a resize frame
    /// recomputes, with no model reads of its own.
    struct Geometry {
        let layout: SubagentPanelLayout
        let autoPopped: [ChatThread]
        let slots: [FloatingPanelID: PanelSlot]
        let slotsOnSide: [PanelDockSide: Int]
        let usageHeight: CGFloat?
        let isMeasured: Bool
        let showsHydra: Bool
        let showsPopped: Bool
        let showsUsage: Bool
        let isHydraDocked: Bool
        let dockedSides: [PanelDockSide]
        let reserve: PanelReserve
        let docks: PanelDocks
    }

    /// The smallest usage panel: its strip and one row.
    static let usageMinimumHeight = HydraPanel.stripHeight + 44

    /// `holdsHydra` keeps the team's panel in the scene after its heads have gone (see
    /// `ChatView.hydraLingers`), so the conversation keeps its room and the panel fades
    /// out over it rather than the column sliding out from under a panel still showing.
    static func geometry(members: PanelMembers, runtime: ThreadRuntime, model: AppModel, paneSize: CGSize, composerAreaHeight: CGFloat, usageContentHeight: CGFloat?, holdsHydra: Bool = false, preferredSize: CGSize? = nil, usageHeightOverride: CGFloat? = nil) -> Geometry {
        let isMeasured = paneSize != .zero
        let preferred = preferredSize ?? model.settings.panelSize
        let showsHydra = (!members.heads.isEmpty || holdsHydra) && isMeasured
        let showsPopped = members.popped != nil && showsHydra
        let showsUsage = members.usage != nil && isMeasured
        let isHydraDocked = showsHydra
        let helperShowsProgress = members.subagent?.isHydraHead ?? true
        let compact = !model.settings.hydraShowsHeadDetails && helperShowsProgress && (showsHydra || members.subagent != nil)
        // One panel at its natural height is a slot; the usage panel is measured against
        // it, since it has a height of its own and may take more than one.
        let single = SubagentPanelLayout(pane: paneSize, composerAreaHeight: composerAreaHeight, stackDepth: 1, preferred: preferred, compact: compact)
        let slotHeight = single.panelHeight
        let gap = SubagentPanelLayout.gap
        var placed: [(id: FloatingPanelID, corner: PanelDockCorner)] = []
        if members.isDocked { placed.append((.subagent, runtime.subagentPanelDock)) }
        if isHydraDocked { placed.append((.hydra, runtime.hydraPanelDock)) }
        if showsPopped { placed.append((.popped, runtime.hydraPoppedPanelDock)) }
        if showsUsage { placed.append((.usage, model.settings.usagePanelDock)) }
        let usageCorner = model.settings.usagePanelDock
        var usageHeight: CGFloat?
        if showsUsage {
            let under = Self.order(placed, by: runtime.panelStackOrder)[.usage]?.below ?? 0
            let room = single.verticalRoom - CGFloat(under) * (slotHeight + gap)
            let wanted = usageHeightOverride ?? model.settings.usagePanelHeight ?? usageContentHeight ?? slotHeight
            usageHeight = min(max(Self.usageMinimumHeight, room), max(Self.usageMinimumHeight, wanted))
        }
        // The room the usage panel takes past its slot, which a panel stacked beyond it
        // steps over.
        let usageLift = max(0, (usageHeight ?? 0) - slotHeight)
        var autoPopped: [ChatThread] = []
        let layoutFitsBothSides = single.fitsBothSides
        // How many panels a side can hold at the smallest they shrink to, three at most:
        // the slots a panel can be dropped in. Counted at the ideal height a tall pane
        // gave one slot a side, and a second panel could only ever take the other corner.
        let smallest = compact ? SubagentPanelLayout.compactHeight : SubagentPanelLayout.minHeight
        let natural = min(3, max(1, Int((single.verticalRoom + gap) / (smallest + gap))))
        if model.settings.hydraAutoPopsHeads, showsHydra, members.heads.count > 1 {
            var candidates = Array(members.heads.dropFirst()).filter { !runtime.hydraAutoPopHeld.contains($0.id) }
            for candidate in candidates where runtime.hydraAutoPanelDocks[candidate.id] != nil {
                let corner = runtime.hydraAutoPanelDocks[candidate.id]!
                placed.append((.auto(candidate.id), corner))
                autoPopped.append(candidate)
            }
            candidates.removeAll { runtime.hydraAutoPanelDocks[$0.id] != nil }
            // Slots the usage panel takes beyond its own: a tall one is worth more than one.
            let usageExtra = usageLift > 0 ? Int(ceil(usageLift / (slotHeight + gap))) : 0
            // A pane too narrow for panels on both sides keeps the heads on the team's side.
            for corner in (layoutFitsBothSides ? [runtime.hydraPanelDock.acrossTheColumn, runtime.hydraPanelDock] : [runtime.hydraPanelDock]) {
                let other = Self.flippedVertically(corner)
                let usageOnSide = showsUsage && (usageCorner == corner || usageCorner == other)
                let used = placed.count { $0.corner == corner } + placed.count { $0.corner == other } + (usageOnSide ? usageExtra : 0)
                let free = max(0, natural - used)
                for _ in 0..<min(free, candidates.count) {
                    let head = candidates.removeFirst()
                    placed.append((.auto(head.id), corner))
                    autoPopped.append(head)
                }
            }
        }
        // Too narrow for both sides: every panel goes to the side the team panel is on,
        // else the fuller side, each keeping its top or bottom.
        if !layoutFitsBothSides {
            let sides = Set(placed.map(\.corner.side))
            if sides.count > 1 {
                let home: PanelDockSide = placed.first { $0.id == .hydra }?.corner.side
                    ?? (placed.count { $0.corner.side == .leading } >= placed.count { $0.corner.side == .trailing } ? .leading : .trailing)
                placed = placed.map { ($0.id, PanelDockCorner.make(side: home, isTop: $0.corner.isTop)) }
            }
        }
        var slotsByID: [FloatingPanelID: PanelSlot] = [:]
        let ordered = Self.order(placed, by: runtime.panelStackOrder)
        let usageBelow = ordered[.usage]?.below
        for (id, entry) in ordered {
            let lift: CGFloat
            if let usageBelow, entry.corner == usageCorner, showsUsage, id != .usage, entry.below > usageBelow {
                lift = usageLift
            } else {
                lift = 0
            }
            slotsByID[id] = PanelSlot(corner: entry.corner, below: entry.below, lift: lift)
        }
        let corners = placed.map(\.corner)
        let sides = Set(corners.map(\.side))
        let dockedSides = [PanelDockSide.leading, .trailing].filter(sides.contains)
        var slotsOnSide: [PanelDockSide: Int] = [:]
        for side in [PanelDockSide.leading, PanelDockSide.trailing] {
            slotsOnSide[side] = max(natural, placed.count { $0.corner.side == side })
        }
        // The height the panels share comes from how tightly a side's slots are taken:
        // slots are spread evenly between the top and bottom spots, so the closest two
        // occupied slots set the tallest panel that leaves them clear. Neighbours share
        // the room by the slot count; panels a slot apart keep half each; one alone keeps
        // its full height. The larger of the two sides' depths, since one layout serves both.
        var stackDepth = 1
        for side in [PanelDockSide.leading, PanelDockSide.trailing] {
            let n = slotsOnSide[side] ?? 1
            let indices = slotsByID.values
                .filter { $0.corner.side == side }
                .map { $0.corner.isTop ? $0.below : n - 1 - $0.below }
                .sorted()
            guard indices.count > 1 else { continue }
            let closest = zip(indices, indices.dropFirst()).map { $1 - $0 }.min() ?? 1
            let depth = Int((Double(n - 1) / Double(max(1, closest))).rounded(.up)) + 1
            stackDepth = max(stackDepth, depth)
        }
        let layout = SubagentPanelLayout(pane: paneSize, composerAreaHeight: composerAreaHeight, stackDepth: stackDepth, preferred: preferred, compact: compact)
        let reserve = PanelReserve(
            leading: sides.contains(.leading) ? layout.composerReserve : 0,
            trailing: sides.contains(.trailing) ? layout.composerReserve : 0
        )
        return Geometry(
            layout: layout,
            autoPopped: autoPopped,
            slots: slotsByID,
            slotsOnSide: slotsOnSide,
            usageHeight: usageHeight,
            isMeasured: isMeasured,
            showsHydra: showsHydra,
            showsPopped: showsPopped,
            showsUsage: showsUsage,
            isHydraDocked: isHydraDocked,
            dockedSides: dockedSides,
            reserve: reserve,
            docks: PanelDocks(layout: layout, reserve: reserve)
        )
    }

    static func order(_ placed: [(id: FloatingPanelID, corner: PanelDockCorner)], by stackOrder: [FloatingPanelID]) -> [FloatingPanelID: (corner: PanelDockCorner, below: Int)] {
        var rank: [FloatingPanelID: Int] = [:]
        for id in stackOrder where rank[id] == nil {
            rank[id] = rank.count
        }
        var out: [FloatingPanelID: (corner: PanelDockCorner, below: Int)] = [:]
        let corners = Set(placed.map(\.corner))
        for corner in corners {
            let inCorner = placed.enumerated().filter { $0.element.corner == corner }
                .sorted {
                    let left = (rank[$0.element.id] ?? Int.max, $0.offset)
                    let right = (rank[$1.element.id] ?? Int.max, $1.offset)
                    return left < right
                }
                .map(\.element)
            for (below, entry) in inCorner.enumerated() {
                out[entry.id] = (entry.corner, below)
            }
        }
        return out
    }

    private static func flippedVertically(_ corner: PanelDockCorner) -> PanelDockCorner {
        switch corner {
        case .topLeading: .bottomLeading
        case .bottomLeading: .topLeading
        case .topTrailing: .bottomTrailing
        case .bottomTrailing: .topTrailing
        }
    }
}

/// The "jump to latest" button floating above the chat box while the reader is scrolled up.
struct JumpToLatestButton: View {
    let scrollState: TimelineScrollState

    var body: some View {
        if scrollState.showsJumpButton {
            ChromeCircleButton(symbol: "arrow.down", help: "Jump to latest") {
                scrollState.jumpToLatest()
            }
            .padding(.bottom, 10)
            .frame(height: 0, alignment: .bottom)
            .transition(
                .asymmetric(
                    insertion: .scale(scale: 0.6).combined(with: .opacity).combined(with: .offset(y: 10)),
                    removal: .scale(scale: 0.85).combined(with: .opacity).combined(with: .offset(y: 6))
                )
            )
        }
    }
}

/// The sticky glass controls across the top of the conversation.
private struct ChatChromeRow: View {
    @Environment(AppModel.self) private var model
    @AppStorage("performanceMode", store: CaptureRun.defaults ?? .standard) private var performanceMode = false
    let runtime: ThreadRuntime
    let scrollChrome: ChromeScrollModel
    let title: String
    let project: Project?
    let directory: String
    let git: GitStatusModel
    let titleLeading: CGFloat
    @State private var isTopControlsHovered = false
    @State private var isTopControlPresented = false
    @State private var chromeRowWidth: CGFloat = 0
    @State private var topControlsWidth: CGFloat = 0

    var body: some View {
        // Follows the buttons, not the sidebar's state: they leave for the sidebar only once it
        // is wide enough to hold them, and the row closes up as they go.
        let sidebarVisible = model.sidebar.holdsTrafficLights
        chromeRowContent(sidebarVisible: sidebarVisible)
        // With the sidebar hidden the native window buttons sit over this row, so it steps clear of them.
        .padding(.leading, sidebarVisible ? 0 : Chrome.trafficLightsWidth + Chrome.trafficLightClearance)
        .padding(.horizontal, Chrome.chromeHorizontalPadding)
        .padding(.top, Chrome.chromeTopPadding)
        .animation(Chrome.panelSlide, value: sidebarVisible)
    }

    @ViewBuilder
    private func chromeRowContent(sidebarVisible: Bool) -> some View {
        HStack(alignment: .center, spacing: 10) {
            // With the sidebar away, its toggle and thread list remain available.
            if !sidebarVisible {
                SidebarToggleButton()
                    .transition(.softAppear)
                ThreadsButton()
                    .transition(.softAppear)
            }
            ChatChromeTitle(runtime: runtime, title: title)
                // The thread's title cuts on a switch; it must never crossfade.
                // Animated, the old and new titles ghost over each other
                // mid-flight. Scroll progress still drives it per frame.
                .animation(nil, value: title)
                .padding(.leading, titleInset(sidebarVisible: sidebarVisible))
            Group {
                if performanceMode {
                    topControls
                } else {
                    GlassEffectContainer(spacing: 2) {
                        topControls
                    }
                }
            }
            // Keep the reveal area and title layout stable while the controls are hidden.
            .opacity(showsTopControls ? 1 : 0)
            .allowsHitTesting(showsTopControls)
            .accessibilityHidden(!showsTopControls)
            .background(Color.clear)
            .contentShape(.rect)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { topControlsWidth = $0 }
            .onPreferenceChange(ChromePresentationPreference.self) { isTopControlPresented = $0 }
            .animation(performanceMode ? nil : .softAppear, value: showsTopControls)
        }
        .contentShape(.rect)
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { chromeRowWidth = $0 }
        // The reveal region stays wide even when repository controls are absent.
        // onContinuousHover reports positions in the row's local coordinate space:
        // https://developer.apple.com/documentation/swiftui/view/oncontinuoushover(coordinatespace:perform:)
        .onContinuousHover { phase in
            let isHovered: Bool
            switch phase {
            case .active(let location):
                let revealWidth = max(topControlsWidth, Chrome.capsuleHeight * 15)
                isHovered = location.x >= max(0, chromeRowWidth - revealWidth)
            case .ended:
                isHovered = false
            }
            if isTopControlsHovered != isHovered { isTopControlsHovered = isHovered }
        }
    }

    private var topControls: some View {
        HStack(spacing: 8) {
            if let thread = model.thread(runtime.threadID), model.settings.hydraEnabled, !thread.isHelper {
                HydraButton(thread: thread, runtime: runtime)
                    .transition(.softAppear)
            }
            if git.isRepository {
                BranchMenu(runtime: runtime, directory: directory, git: git)
            }
            ChromeCapsule {
                OpenInMenu(directory: directory)
                if let project {
                    ChromeDivider()
                    ScriptsMenu(project: project, runtime: runtime)
                }
                if git.isRepository {
                    ChromeDivider()
                    GitActionsMenu(runtime: runtime, directory: directory, git: git)
                }
            }
            ChromeCapsule {
                ChromeIconButton(symbol: "terminal", isActive: runtime.isTerminalVisible, help: Chrome.localized("Terminal") + ShortcutStore.hint(for: .toggleTerminal)) {
                    runtime.isTerminalVisible.toggle()
                }
                ChromeDivider()
                ChromeIconButton(symbol: "plusminus", isActive: runtime.isDiffVisible, help: Chrome.localized("Changes") + ShortcutStore.hint(for: .toggleChanges)) {
                    runtime.toggleDiff()
                }
            }
        }
    }

    private var showsTopControls: Bool {
        !model.settings.autoHideTopControls || isTopControlsHovered || isTopControlPresented
    }

    private func titleInset(sidebarVisible: Bool) -> CGFloat {
        var leading = Chrome.chromeHorizontalPadding
        if !sidebarVisible {
            leading += Chrome.trafficLightsWidth + Chrome.trafficLightClearance
            leading += 2 * (Chrome.capsuleHeight + 10)
        }
        return max(0, titleLeading - leading)
    }
}

/// The thread title in the chrome row, next to the branch picker. A real Button so the
/// extended title bar (which drags the window from this row's gaps) never swallows the
/// click: buttons take their presses while the gaps around them still move the window.
/// Always visible; the scroll-faded compact title it replaces stayed invisible and
/// untappable at rest.
private struct ChatChromeTitle: View {
    @Environment(AppModel.self) private var model
    let runtime: ThreadRuntime
    let title: String

    @State private var isPresented = false
    @State private var isRenaming = false
    @State private var renameText = ""

    var body: some View {
        Button {
            renameText = title
            isPresented.toggle()
        } label: {
            Text(verbatim: title.isEmpty ? Chrome.localized("New thread") : title)
                .font(.ui(size: 16, weight: .semibold))
                .foregroundStyle(title.isEmpty ? Chrome.secondaryText : Chrome.primaryText)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.vertical, 6)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help("Thread title — click to copy or rename")
        .accessibilityLabel(Text("Thread title"))
        .accessibilityAddTraits(.isButton)
        // The popover hangs off the title's own width, so it opens under the words;
        // the row's leftover width (below) is not the button's, or a short title
        // opened its menu far off to the right, over the middle of the chat.
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            PopoverMenu {
                PopoverSectionHeader("Thread title")
                PopoverItem("Copy title", symbol: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(title, forType: .string)
                }
                PopoverItem("Rename…", symbol: "pencil") {
                    renameText = title
                    isRenaming = true
                }
            }
        }
        .alert("Rename thread", isPresented: $isRenaming) {
            TextField("Title", text: $renameText)
            Button("Rename") {
                model.rename(runtime.threadID, to: renameText)
            }
            Button("Cancel", role: .cancel) {}
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The sidebar's list in a popover, for a hidden sidebar: the same search, the same rows,
/// the same footer, at the sidebar's own width. Picking a thread closes it.
private struct ThreadsButton: View {
    @Environment(AppModel.self) private var model
    @State private var isPresented = false

    var body: some View {
        ChromeCircleButton(symbol: "list.bullet", help: "Threads") {
            isPresented.toggle()
        }
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            SidebarView(inPopover: true, dismiss: { isPresented = false })
                .frame(width: model.sidebar.width, height: 560)
                .presentedChrome()
        }
        // The capture run hangs the list's still from the button, where the app shows it.
        #if DEBUG
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
            if CaptureRun.isEnabled { WebsiteCaptures.threadsButtonFrame = frame }
        }
        #endif
    }
}

@MainActor
@Observable
final class GitStatusModel {
    private(set) var isRepository = false
    private(set) var status: GitStatus?
    private(set) var branches: [GitBranch] = []
    private(set) var remoteURL: URL?
    private(set) var activity: String?

    private struct Snapshot {
        var isRepository = false
        var status: GitStatus?
        var branches: [GitBranch] = []
        var remoteURL: URL?
        var fetchedAt = Date.now
    }

    /// The last read per directory, shared by every chat. Switching threads shows the branch at
    /// once and only runs git again when the read is stale, a turn changed files, or forced.
    private static var snapshots: [String: Snapshot] = [:]
    private static let freshness: TimeInterval = 30

    func refresh(_ directory: String, force: Bool = true) async {
        if let cached = Self.snapshots[directory] {
            apply(cached)
            if !force, Date.now.timeIntervalSince(cached.fetchedAt) < Self.freshness { return }
        }
        let git = Git(directory)
        var snapshot = Snapshot(isRepository: await git.isRepository())
        if snapshot.isRepository {
            async let status = git.status()
            async let branches = git.branches()
            async let remoteURL = git.remoteWebURL()
            snapshot.status = await status
            snapshot.branches = await branches
            snapshot.remoteURL = await remoteURL
        }
        snapshot.fetchedAt = .now
        Self.snapshots[directory] = snapshot
        apply(snapshot)
    }

    private func apply(_ snapshot: Snapshot) {
        isRepository = snapshot.isRepository
        status = snapshot.status
        branches = snapshot.branches
        remoteURL = snapshot.remoteURL
    }

    func perform(_ activity: String, _ work: () async throws -> Void) async -> Error? {
        self.activity = activity
        defer { self.activity = nil }
        do {
            try await work()
            return nil
        } catch {
            return error
        }
    }
}

private struct BranchMenu: View {
    @Environment(AppModel.self) private var model
    let runtime: ThreadRuntime
    let directory: String
    let git: GitStatusModel

    @State private var isNamingBranch = false
    @State private var branchName = ""

    var body: some View {
        ChromeTextMenu(
            symbol: "arrow.triangle.branch",
            title: git.activity ?? git.status?.branch ?? "Detached",
            help: "Branch"
        ) {
            PopoverSectionHeader("Switch branch")
            ForEach(git.branches.prefix(25)) { branch in
                PopoverItem(
                    branch.name,
                    isChecked: branch.isCurrent,
                    isEnabled: !branch.isCurrent && !runtime.isRunning
                ) {
                    switchBranch(branch.name)
                }
            }
            PopoverDivider()
            PopoverItem("New branch…", symbol: "plus") {
                branchName = ""
                isNamingBranch = true
            }
            if runtime.thread?.worktreePath == nil, runtime.turns.isEmpty {
                PopoverItem("Use a new worktree for this thread", symbol: "square.stack.3d.up") {
                    Task { await model.createWorktree(for: runtime.threadID) }
                }
            }
        }
        .alert("New branch", isPresented: $isNamingBranch) {
            TextField("Branch name", text: $branchName)
            Button("Create") { createBranch() }
            Button("Cancel", role: .cancel) {}
        }
        .transformPreference(ChromePresentationPreference.self) { $0 = $0 || isNamingBranch }
    }

    private func switchBranch(_ name: String) {
        Task {
            let repository = Git(directory)
            if let error = await git.perform("Switching", { try await repository.switchBranch(name) }) {
                model.alert = AppAlert(title: "Could not switch branch", message: error.localizedDescription)
            }
            await git.refresh(directory)
        }
    }

    private func createBranch() {
        let name = branchName.trimmed.replacingOccurrences(of: " ", with: "-")
        guard !name.isEmpty else { return }
        Task {
            let repository = Git(directory)
            if let error = await git.perform("Creating", { try await repository.createBranch(name) }) {
                model.alert = AppAlert(title: "Could not create branch", message: error.localizedDescription)
            }
            await git.refresh(directory)
        }
    }
}

private struct OpenInMenu: View {
    let directory: String

    var body: some View {
        ChromeMenuButton(symbol: "arrow.up.forward.app", help: "Open in another app") {
            PopoverSectionHeader("Open in")
            PopoverItem("Finder", image: Workspace.finderIcon) {
                NSWorkspace.shared.open(URL(fileURLWithPath: directory))
            }
            ForEach(Workspace.installedEditors) { editor in
                PopoverItem(editor.name, symbol: "chevron.left.forwardslash.chevron.right", image: Workspace.icon(for: editor)) {
                    Workspace.open(directory, with: editor)
                }
            }
            PopoverDivider()
            PopoverItem("Copy path", symbol: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(directory, forType: .string)
            }
        }
    }
}

private struct ScriptsMenu: View {
    @Environment(AppModel.self) private var model
    let project: Project
    let runtime: ThreadRuntime

    @State private var isEditing = false

    var body: some View {
        ChromeMenuButton(symbol: "play", help: "Run a project script") {
            if !project.scripts.isEmpty {
                PopoverSectionHeader("Scripts")
                ForEach(project.scripts) { script in
                    PopoverItem(script.name, symbol: script.symbol) {
                        model.runScript(script, threadID: runtime.threadID)
                    }
                }
                PopoverDivider()
            }
            PopoverItem(project.scripts.isEmpty ? "Add a script…" : "Edit scripts…", symbol: project.scripts.isEmpty ? "plus" : "pencil") {
                isEditing = true
            }
        }
        .sheet(isPresented: $isEditing) {
            ScriptsEditor(projectID: project.id)
                .presentedChrome()
                // The system sheet owns its corners; its backdrop follows that container.
                .presentationBackground { WindowBackdrop(opacity: model.settings.backdropOpacity) }
        }
        .transformPreference(ChromePresentationPreference.self) { $0 = $0 || isEditing }
    }
}

private struct GitActionsMenu: View {
    @Environment(AppModel.self) private var model
    let runtime: ThreadRuntime
    let directory: String
    let git: GitStatusModel

    @State private var isCommitting = false

    var body: some View {
        let changed = git.status?.changedFiles ?? 0
        ChromeMenuButton(symbol: "arrow.triangle.pull", help: changed == 0 ? "Commit, push and open pull requests" : String(format: Chrome.localized("%d changed files"), changed)) {
            PopoverNote(changed == 1 ? "1 changed file" : String(format: Chrome.localized("%d changed files"), changed))
            PopoverDivider()
            PopoverItem("Commit…", symbol: "checkmark.circle", isEnabled: changed > 0) { isCommitting = true }
            PopoverItem("Push", symbol: "arrow.up.circle") { push() }
            PopoverItem("Create pull request", symbol: "arrow.triangle.pull") { openPullRequest() }
            if let url = git.remoteURL {
                PopoverDivider()
                PopoverItem("Open repository", symbol: "safari") { NSWorkspace.shared.open(url) }
            }
        }
        .sheet(isPresented: $isCommitting) {
            CommitSheet(runtime: runtime, directory: directory, git: git)
                .presentedChrome()
        }
        .transformPreference(ChromePresentationPreference.self) { $0 = $0 || isCommitting }
    }

    private func push() {
        Task {
            let repository = Git(directory)
            if let error = await git.perform("Pushing", { try await repository.push() }) {
                model.alert = AppAlert(title: "Push failed", message: error.localizedDescription)
            }
            await git.refresh(directory)
        }
    }

    private func openPullRequest() {
        Task {
            let repository = Git(directory)
            var url: URL?
            let error = await git.perform("Opening pull request") {
                try await repository.push()
                let subject = (try? await repository.output(["log", "-1", "--pretty=%s"]))?
                    .trimmed ?? ""
                let body = (try? await repository.output(["log", "-1", "--pretty=%b"]))?
                    .trimmed ?? ""
                url = try await repository.createPullRequest(
                    title: subject.isEmpty ? "Update" : subject,
                    body: body.isEmpty ? "Opened from Tivano." : body
                )
            }
            if let error {
                model.alert = AppAlert(title: "Could not open a pull request", message: error.localizedDescription)
            } else if let url {
                NSWorkspace.shared.open(url)
            }
            await git.refresh(directory)
        }
    }
}

private struct CommitSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let runtime: ThreadRuntime
    let directory: String
    let git: GitStatusModel

    @State private var message = ""
    @State private var summary = ""
    @State private var isGenerating = false
    @State private var isCommitting = false
    @State private var pushesAfterCommit = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Commit changes")
                .font(.ui(.title2, weight: .semibold))
            if !summary.isEmpty {
                ScrollView {
                    Text(summary)
                        .font(.ui(.subheadline, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 110)
                .padding(10)
                .background(Chrome.overlay(0.05), in: .rect(cornerRadius: 12, style: .continuous))
            }
            ZStack(alignment: .topLeading) {
                TextEditor(text: $message)
                    .font(.ui(.body))
                    .scrollContentBackground(.hidden)
                    .padding(8)
                if message.isEmpty {
                    Text(verbatim: isGenerating ? Chrome.localized("Writing a message…") : Chrome.localized("Commit message"))
                        .foregroundStyle(Chrome.secondaryText)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
            }
            .frame(minHeight: 130)
            .background(Chrome.overlay(0.05), in: .rect(cornerRadius: 12, style: .continuous))
            HStack(spacing: 12) {
                // Nothing writes the message with text generation off or its provider signed
                // out, so the button says where to turn it on instead of doing nothing.
                let canGenerate = model.textEngine(preferring: runtime.thread?.provider) != nil
                Button {
                    Task { await generate() }
                } label: {
                    Label {
                        Text("Write for me")
                    } icon: {
                        if isGenerating {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "sparkles")
                        }
                    }
                }
                .buttonStyle(.glass)
                .disabled(isGenerating || !canGenerate)
                .help(Text(verbatim: canGenerate ? Chrome.localized("Write a commit message from these changes") : Chrome.localized("Turn on text generation in Settings > Source control")))
                Toggle("Push after committing", isOn: $pushesAfterCommit)
                    .toggleStyle(.checkbox)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .buttonStyle(.glass)
                Button("Commit") { Task { await commit() } }
                    .buttonStyle(.glassProminent)
                    .disabled(message.trimmed.isEmpty || isCommitting)
            }
        }
        .padding(20)
        .frame(width: 560)
        .task {
            let changes = await Git(directory).workingChanges()
            summary = changes.summary
            if message.isEmpty { await generate(changes: changes) }
        }
    }

    private func generate(changes: (summary: String, patch: String)? = nil) async {
        guard let engine = model.textEngine(preferring: runtime.thread?.provider) else { return }
        isGenerating = true
        defer { isGenerating = false }
        let resolved: (summary: String, patch: String)
        if let changes {
            resolved = changes
        } else {
            resolved = await Git(directory).workingChanges()
        }
        if let text = await TextGeneration.commitMessage(
            summary: resolved.summary,
            patch: resolved.patch,
            instructions: model.settings.commitInstructions,
            engine: engine,
            directory: URL(fileURLWithPath: directory)
        ) {
            message = text
        }
    }

    private func commit() async {
        isCommitting = true
        defer { isCommitting = false }
        let repository = Git(directory)
        let text = message.trimmed
        let pushes = pushesAfterCommit
        let error = await git.perform("Committing") {
            try await repository.commitAll(message: text)
            if pushes { try await repository.push() }
        }
        await git.refresh(directory)
        if let error {
            model.alert = AppAlert(title: "Commit failed", message: error.localizedDescription)
        } else {
            dismiss()
        }
    }
}

private struct ScriptsEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let projectID: UUID

    @State private var scripts: [ProjectScript] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Project scripts")
                .font(.ui(.title2, weight: .semibold))
            Text("Scripts run in a terminal at the project root. Tivano also picks up scripts from tivano.json.")
                .font(.ui(.callout))
                .foregroundStyle(Chrome.secondaryText)
            ScrollView {
                VStack(spacing: 10) {
                    ForEach($scripts) { $script in
                        ChromeCard {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    TextField("Name", text: $script.name)
                                        .textFieldStyle(.roundedBorder)
                                    Button(role: .destructive) {
                                        scripts.removeAll { $0.id == script.id }
                                    } label: {
                                        Image(systemName: "trash")
                                    }
                                    .buttonStyle(.borderless)
                                }
                                TextField("Command", text: $script.command)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.ui(.callout, design: .monospaced))
                                    // A script with no command used to be dropped on save
                                    // without a word; the row says what it is missing.
                                    .overlay {
                                        if Self.isIncomplete(script) {
                                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                                .strokeBorder(Chrome.danger.opacity(0.65), lineWidth: 1)
                                        }
                                    }
                                Toggle("Run when a worktree is created", isOn: $script.runOnWorktreeCreate)
                                    .toggleStyle(.checkbox)
                            }
                            .padding(14)
                        }
                    }
                }
            }
            .frame(minHeight: 220)
            HStack {
                Button {
                    scripts.append(ProjectScript(name: "New script", command: ""))
                } label: {
                    Label("Add script", systemImage: "plus")
                }
                .buttonStyle(.glass)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .buttonStyle(.glass)
                let incomplete = scripts.contains(where: Self.isIncomplete)
                Button("Save") {
                    model.updateProject(projectID) { $0.scripts = scripts }
                    dismiss()
                }
                .buttonStyle(.glassProminent)
                .disabled(incomplete)
                .help(Text(verbatim: incomplete ? Chrome.localized("Every script needs a command.") : Chrome.localized("Save these scripts")))
            }
        }
        .padding(20)
        .frame(width: 580, height: 460)
        .onAppear { scripts = model.project(projectID)?.scripts ?? [] }
    }

    /// A script with nothing to run. Saving is held until every row has a command.
    private static func isIncomplete(_ script: ProjectScript) -> Bool {
        script.command.trimmingCharacters(in: .whitespaces).isEmpty
    }
}
