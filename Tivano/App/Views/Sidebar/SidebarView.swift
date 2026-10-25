import AppKit
import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    /// Shown from the chat's Threads button while the sidebar is hidden: the same list in a
    /// popover, without the window buttons' clearance or the window-dragging background, and
    /// picking a thread closes it.
    var inPopover = false
    var dismiss: (() -> Void)? = nil

    @State private var search = ""
    @State private var renaming: ChatThread?
    @State private var renameText = ""
    /// The thread whose delete popover is open, by id: the popover's binding compares two
    /// UUIDs and never reaches into a thread snapshot that may since have changed hands.
    @State private var pendingProjectDeletionID: UUID?
    @State private var confirmedProjectDeletion: ConfirmedProjectDeletion?
    @State private var isProjectDeletePopoverShown = false
    @State private var pendingDeletionID: UUID?
    /// The thread whose archive question is open, by id, the same way.
    @State private var pendingArchiveID: UUID?
    /// A delete the popover confirmed, carried out once the popover has closed (see
    /// `confirmDeletion` and `deletePopover`).
    @State private var confirmedDeletion: ConfirmedDeletion?
    /// Whether a delete popover's content is on screen, from its appearance to its
    /// disappearance: a confirmed delete waits for it to go. One flag serves every row,
    /// since only one delete popover is ever open.
    @State private var isDeletePopoverShown = false
    /// Carries context-menu intents (rename, delete) outside any row's @State, so an AppKit
    /// menu's callbacks never retain a row's state storage. The menu posts a value-type
    /// request here (holding this box weakly); the list takes it up below.
    @State private var menuRequests = SidebarMenuRequests()
    /// The live reorder, exactly the queue's: the grabbed row follows the pointer, its
    /// helpers with it, and neighbours slide across as its centre passes theirs.
    @State private var drag = RowDrag<UUID>()
    @State private var projectDrag = RowDrag<UUID>()
    /// Every row's height by its item id. A thread's slot is its own row plus the helper
    /// rows under it, so a dragged row crosses a neighbour with helpers in one go. Kept out
    /// of observation like the frames below: every row reports its height as the list lays
    /// out, and only a drag ever reads them, so a report must not re-run the list.
    @State private var rowHeights = RowHeights()
    /// Every open thread row's frame in the list, by thread id, for the one drag gesture
    /// below to find the row under the pointer at the grab. Kept out of observation like
    /// the heights: the rows report as they lay out, only a grab reads them.
    @State private var rowFrames = RowFrames()
    @State private var projectFrames = RowFrames()
    /// The grabbed row's peers and their slot heights, taken once at the grab and again
    /// after each swap, so a pointer move never rebuilds the list to find them.
    @State private var dragPeers: DragPeers?
    @State private var projectDragPeers: DragPeers?
    /// The built list, kept while its inputs stand (see `SidebarItemCache`): a render
    /// that changed no thread, project or setting hands back the same items.
    @State private var itemCache = SidebarItemCache()
    /// While the list scrolls its rows take no hover and no clicks, the way the timeline's
    /// do: a click cannot land on a moving row anyway, and skipping the hover states keeps
    /// a scroll at one layout pass per frame.
    @State private var isListScrolling = false
    /// Settles `isListScrolling` back to false 150 ms after the last scroll movement, so
    /// wheel ticks (which report no scroll phase) re-arm the freeze instead of flickering it.
    @State private var scrollSettle: Task<Void, Never>?

    private var query: String {
        search.trimmed
    }

    /// The list's own coordinate space: the rows report their frames in it and the drag
    /// gesture reads its locations in it, whatever the scroll position.
    private nonisolated static let listSpace = "sidebar-list"
    private nonisolated static let listTopInset: CGFloat = 0

    var body: some View {
        // Where every thread sits, worked out once per pass: the grouping and the list below
        // are rebuilt only when this changes, not on every field change of every thread.
        let placements = threadPlacements
        let helpers = helpersByParent(placements: placements)
        VStack(alignment: .leading, spacing: 0) {
            if !inPopover {
                HStack(spacing: model.settings.showsSkylightNow ? 6 : nil) {
                    Spacer(minLength: Chrome.trafficLightLeading + Chrome.trafficLightsWidth + Chrome.trafficLightClearance)
                    if model.settings.showsSkylightNow {
                        ChromeIconButton(
                            symbol: "asset:today-ring",
                            isActive: model.settings.sidebarActivityView,
                            prominent: true,
                            glyphSize: SidebarHeaderLayout.glyphWidth,
                            help: model.settings.sidebarActivityView ? "Show all threads" : "Focus on today"
                        ) {
                            withAnimation(Chrome.panelSlide) { model.settings.sidebarActivityView.toggle() }
                        }
                        .accessibilityValue(Text(verbatim: Chrome.localized(model.settings.sidebarActivityView ? "On" : "Off")))
                        SidebarHeaderButton(symbol: "magnifyingglass", help: "Search threads") {
                            model.isCommandPalettePresented = true
                        }
                    }
                    SidebarToggleButton(inSidebar: true)
                }
                .padding(.trailing, Chrome.chromeHorizontalPadding)
                .frame(height: Chrome.capsuleHeight)
                .padding(.top, Chrome.chromeTopPadding)

                if model.settings.showsSkylightNow {
                    SidebarHero()
                        .padding(.top, 2)
                        .padding(.bottom, 6)
                }
            }

            if inPopover || !model.settings.showsSkylightNow {
                HStack(spacing: 6) {
                    if inPopover {
                        SidebarSearchField(
                            text: $search,
                            prompt: Chrome.localized("Search threads"),
                            onSubmit: {
                                if let first = searchResults(helpers: helpers).first?.threads.first {
                                    model.openThread(first.id)
                                }
                            },
                            onMove: { moveSearchSelection(by: $0, helpers: helpers) }
                        )
                    } else {
                        Text(verbatim: Chrome.localized("Thread list"))
                            .font(.ui(.body, weight: .semibold))
                            .foregroundStyle(Chrome.primaryText.opacity(0.85))
                        Spacer()
                        if !model.settings.showsSkylightNow {
                            SidebarHeaderButton(symbol: "plus.bubble", help: Chrome.localized("New thread") + ShortcutStore.hint(for: .newThread)) {
                                model.newThread()
                            }
                        }
                        ChromeIconButton(
                            symbol: "asset:today-ring",
                            isActive: model.settings.sidebarActivityView,
                            prominent: true,
                            glyphSize: SidebarHeaderLayout.glyphWidth,
                            help: model.settings.sidebarActivityView ? "Show all threads" : "Focus on today"
                        ) {
                            withAnimation(Chrome.panelSlide) { model.settings.sidebarActivityView.toggle() }
                        }
                        .accessibilityValue(Text(verbatim: Chrome.localized(model.settings.sidebarActivityView ? "On" : "Off")))
                        SidebarHeaderButton(symbol: "magnifyingglass", help: "Search threads") {
                            model.isCommandPalettePresented = true
                        }
                    }
                }
                .padding(.leading, inPopover ? Chrome.listInset : Chrome.listInset + Chrome.rowHorizontalPadding)
                .padding(.trailing, inPopover ? Chrome.listInset : Chrome.listInset + Chrome.rowHorizontalPadding - (Chrome.capsuleHeight - SidebarHeaderLayout.glyphWidth) / 2)
                .padding(.top, inPopover ? 12 : 18)
            }

            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        if query.isEmpty {
                            ForEach(listItems(placements: placements, helpers: helpers)) { item in
                                itemView(item)
                                    .transition(rowTransition(item))
                            }
                        } else {
                            searchList(helpers: helpers)
                        }
                    }
                    .allowsHitTesting(!isListScrolling)
                    // Adding or deleting a thread opens and closes its space with the same motion as every other row.
                    .animation(Chrome.panelSlide, value: model.threads.count)
                    .animation(Chrome.panelSlide, value: model.projects.map(\.isExpanded))
                    .padding(.horizontal, Chrome.listInset)
                    .padding(.top, Self.listTopInset)
                    .padding(.bottom, 8)
                    .coordinateSpace(name: Self.listSpace)
                    .pointerStyle(drag.id != nil || projectDrag.id != nil ? .grabActive : nil)
                    // One drag gesture for the whole list, ahead of every row's own click: the
                    // row under the pointer at the grab is the one that moves (a helper
                    // row reports no frame, so a drag from one goes nowhere), and a
                    // plain click still reaches the row. Off while searching: nothing to reorder.
                    .highPriorityGesture(
                        DragGesture(minimumDistance: 4, coordinateSpace: .named(Self.listSpace))
                            .onChanged { value in
                                if let id = projectDrag.id {
                                    projectDragChanged(id, translation: value.translation.height)
                                } else if drag.id == nil, rowFrames.row(at: value.startLocation) == nil,
                                          let id = projectFrames.row(at: value.startLocation) {
                                    projectDragChanged(id, translation: value.translation.height)
                                } else {
                                    guard let id = drag.id ?? rowFrames.row(at: value.startLocation) else { return }
                                    dragChanged(id, translation: value.translation.height)
                                }
                            }
                            .onEnded { _ in
                                dragEnded()
                                projectDragEnded()
                            },
                        isEnabled: query.isEmpty && !model.settings.sidebarActivityView
                    )
                }
                .scrollIndicators(.never)
                .onScrollPhaseChange { _, phase in
                    if phase == .idle {
                        scrollSettle?.cancel()
                        isListScrolling = false
                    } else {
                        noteListScroll()
                    }
                }
                .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentOffset.y }) { old, new in
                    if old != new { noteListScroll() }
                }
                // A thread that has just moved to another project is brought into view, so the
                // list shows where it landed instead of only closing up where it was.
                .onChange(of: model.sidebarRevealThreadID) { _, reveal in
                    guard let reveal else { return }
                    model.sidebarRevealThreadID = nil
                    guard let thread = model.thread(reveal) else { return }
                    withAnimation(Chrome.panelSlide) {
                        proxy.scrollTo(SidebarItem.id(for: thread), anchor: .center)
                    }
                }
                .onChange(of: projectDrag.id) { old, new in
                    guard let old, new == nil else { return }
                    withAnimation(Chrome.panelSlide) {
                        proxy.scrollTo("project-\(old)", anchor: .center)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 1) {
                VoiceSidebarTrigger()
                SidebarRow(title: "Settings", action: { WindowManager.shared.showSettings() }) {
                    SidebarIconBadge { SidebarSymbol("gear", scale: 1.15) }
                        .overlay(alignment: .topTrailing) {
                            if UpdateChecker.shared.updateAvailable {
                                UpdateAvailableDot()
                            }
                        }
                }
            }
            .padding(.horizontal, Chrome.listInset)
            .padding(.bottom, 12)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .animation(Chrome.panelSlide, value: model.settings.showsSkylightNow)
        .background { if !inPopover { WindowDragArea() } }
        .popover(isPresented: Binding(
            get: { pendingProjectDeletionID != nil },
            set: { if !$0 { pendingProjectDeletionID = nil } }
        ), arrowEdge: .trailing) {
            if let id = pendingProjectDeletionID, let project = model.project(id) {
                let removedIDs = Set(model.threadsRemovedWithProject(project).map(\.id))
                RemoveProjectPopover(count: removedIDs.count, onRemove: {
                    confirmedProjectDeletion = ConfirmedProjectDeletion(projectID: id, threadIDs: removedIDs)
                    pendingProjectDeletionID = nil
                    if !isProjectDeletePopoverShown { carryOutConfirmedProjectDeletion() }
                }, onCancel: { pendingProjectDeletionID = nil })
                .onAppear { isProjectDeletePopoverShown = true }
                .onDisappear {
                    isProjectDeletePopoverShown = false
                    carryOutConfirmedProjectDeletion()
                }
            }
        }
        .onChange(of: model.projectDeletionRequest) { _, id in
            guard let id else { return }
            model.projectDeletionRequest = nil
            guard model.project(id) != nil else { return }
            pendingProjectDeletionID = id
        }
        // Read only in the popover: the list itself has no reason to re-render on selection.
        .onChange(of: inPopover ? model.selectedThreadID : nil) { if inPopover { dismiss?() } }
        .onChange(of: menuRequests.rename) { _, thread in
            guard let thread else { return }
            menuRequests.rename = nil
            renameText = thread.title
            renaming = thread
        }
        .onChange(of: menuRequests.delete) { _, thread in
            guard let thread else { return }
            menuRequests.delete = nil
            if model.settings.confirmBeforeDeleting {
                pendingDeletionID = thread.id
            } else {
                model.delete(thread.id)
            }
        }
        // The shortcut's question lands on the thread's own row.
        .onChange(of: model.archiveRequest) { _, request in
            guard let request, model.thread(request.threadID) != nil else { return }
            model.archiveRequest = nil
            pendingArchiveID = request.threadID
        }
    }

    /// The delete question, asked in a popover on the row itself rather than a sheet over
    /// the window. Clicking away or pressing Escape keeps the thread.
    ///
    /// The binding is built on the thread's id alone, and the confirmed delete does not run
    /// while the popover is up: the item closes the popover and the delete waits for its
    /// content to have gone (see `confirmDeletion`). Before, the delete ran a turn after
    /// the close, which could be while the popover was still going: it removed the row the
    /// popover hangs on, and in the Threads popover the whole list with it (the delete
    /// selects a neighbour, which dismisses the list); the popover's dismissal then read
    /// this binding on a view already torn down and crashed in the getter.
    private func deletePopover<Row: View>(for thread: ChatThread, on row: Row) -> some View {
        let threadID = thread.id
        return row.popover(
            isPresented: Binding(
                get: { pendingDeletionID == threadID },
                set: { if !$0, pendingDeletionID == threadID { pendingDeletionID = nil } }
            ),
            arrowEdge: .trailing
        ) {
            DeleteThreadPopover(thread: model.thread(threadID) ?? thread) { removeWorktree in
                confirmDeletion(of: threadID, removeWorktree: removeWorktree)
            }
            .onAppear { isDeletePopoverShown = true }
            .onDisappear {
                isDeletePopoverShown = false
                carryOutConfirmedDeletion()
            }
        }
    }

    /// The rename field, asked in a popover on the row itself like the delete question.
    /// Clicking away keeps the thread's title.
    private func renamePopover<Row: View>(for thread: ChatThread, on row: Row) -> some View {
        let threadID = thread.id
        return row.popover(
            isPresented: Binding(
                get: { renaming?.id == threadID },
                set: { if !$0 { renaming = nil } }
            ),
            arrowEdge: .bottom
        ) {
            RenameThreadPopover(title: renameText, onRename: { model.rename(threadID, to: $0); renaming = nil }, onCancel: { renaming = nil })
                .presentedChrome()
        }
    }

    /// The popover's answer. Its item has closed the popover (through the binding above)
    /// and calls here a turn later, so the popover may be on its way out or already gone:
    /// the delete runs now if it is gone, and when it goes otherwise. Clicking away
    /// instead confirms nothing.
    private func confirmDeletion(of id: UUID, removeWorktree: Bool) {
        confirmedDeletion = ConfirmedDeletion(threadID: id, removeWorktree: removeWorktree)
        pendingDeletionID = nil
        pendingArchiveID = nil
        if !isDeletePopoverShown { carryOutConfirmedDeletion() }
    }

    /// The shortcut's question on a row: archive, which Return answers, or delete. The
    /// delete goes the delete popover's way (see `confirmDeletion`), so the row the
    /// question hangs on is gone only once the popover is.
    private func archivePopover<Row: View>(for thread: ChatThread, on row: Row) -> some View {
        let threadID = thread.id
        return row.popover(
            isPresented: Binding(
                get: { pendingArchiveID == threadID },
                set: { if !$0, pendingArchiveID == threadID { pendingArchiveID = nil } }
            ),
            arrowEdge: .trailing
        ) {
            ArchiveThreadPopover(
                thread: model.thread(threadID) ?? thread,
                onArchive: {
                    pendingArchiveID = nil
                    withAnimation(Chrome.panelSlide) { model.archive(threadID) }
                },
                onDelete: { confirmDeletion(of: threadID, removeWorktree: false) },
                onDismiss: { pendingArchiveID = nil }
            )
            .onAppear { isDeletePopoverShown = true }
            .onDisappear {
                isDeletePopoverShown = false
                carryOutConfirmedDeletion()
            }
        }
    }



    /// Runs the delete the popover confirmed, once the popover has closed and a turn
    /// later: the model changes outside the view update that removed the presentation,
    /// and the rows it takes away are no longer anchoring anything. A popover closed by a
    /// click away has nothing confirmed and does nothing here.
    private func carryOutConfirmedDeletion() {
        guard let confirmed = confirmedDeletion else { return }
        confirmedDeletion = nil
        let model = model
        Task { @MainActor in
            model.delete(confirmed.threadID, removeWorktree: confirmed.removeWorktree)
        }
    }

    private struct ConfirmedProjectDeletion {
        let projectID: UUID
        let threadIDs: Set<UUID>
    }

    private func carryOutConfirmedProjectDeletion() {
        guard let confirmed = confirmedProjectDeletion else { return }
        confirmedProjectDeletion = nil
        let model = model
        Task { @MainActor in
            guard let project = model.project(confirmed.projectID) else { return }
            let currentIDs = Set(model.threadsRemovedWithProject(project).map(\.id))
            guard currentIDs.isSubset(of: confirmed.threadIDs) else {
                model.requestProjectDeletion(project)
                return
            }
            model.removeProject(project)
        }
    }

    private func headCards(parent: ChatThread, heads: [ChatThread]) -> some View {
        let ids = Set(heads.map(\.id))
        return HeadCardsRow(parentSnapshot: parent, headSnapshots: heads, menuRequests: menuRequests, onFold: { fold(parent.id) })
            .popover(isPresented: Binding(
                get: { renaming.map { ids.contains($0.id) } ?? false },
                set: { if !$0 { renaming = nil } }
            ), arrowEdge: .bottom) {
                if let thread = renaming {
                    RenameThreadPopover(title: renameText, onRename: { model.rename(thread.id, to: $0); renaming = nil }, onCancel: { renaming = nil })
                        .presentedChrome()
                }
            }
            .popover(isPresented: Binding(
                get: { pendingDeletionID.map { ids.contains($0) } ?? false },
                set: { if !$0 { pendingDeletionID = nil } }
            ), arrowEdge: .trailing) {
                if let id = pendingDeletionID, let thread = model.thread(id) {
                    DeleteThreadPopover(thread: thread) { confirmDeletion(of: id, removeWorktree: $0) }
                        .onAppear { isDeletePopoverShown = true }
                        .onDisappear {
                            isDeletePopoverShown = false
                            carryOutConfirmedDeletion()
                        }
                }
            }
    }

    private struct ConfirmedDeletion {
        let threadID: UUID
        let removeWorktree: Bool
    }

    /// Gaps ride the list's motion; rows keep their entry and exit fades.
    private func rowTransition(_ item: SidebarItem) -> AnyTransition {
        if case .gap = item.kind { return .opacity }
        return .sidebarRow
    }

    @ViewBuilder
    private func itemView(_ item: SidebarItem) -> some View {
        switch item.kind {
        case .gap(let height):
            Color.clear.frame(height: height)
        case .section(let section):
            sectionHeader(section, isFirstInList: section == .projects)
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { rowHeights.note(item.id, $0) }
        case .todayHeader:
            Text(verbatim: Chrome.localized("Today"))
                .font(.ui(.callout, weight: .semibold))
                .foregroundStyle(Chrome.secondaryText)
                .padding(.horizontal, Chrome.rowHorizontalPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: Chrome.rowHeight)
                .modifier(SidebarHeaderLayout(topSpacing: 8))
        case .empty(let title):
            Text(verbatim: Chrome.localized(title))
                .font(.ui(.subheadline))
                .foregroundStyle(Chrome.secondaryText)
                .padding(.horizontal, Chrome.rowHorizontalPadding)
                .padding(.vertical, 4)
        case .project(let project, let count):
            let isDragged = projectDrag.id == project.id
            ProjectRow(snapshot: project, count: count, isDragged: isDragged)
                .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named(Self.listSpace)) }) { frame in
                    rowHeights.note(item.id, frame.height)
                    projectFrames.note(project.id, frame)
                }
                .onDisappear { projectFrames.forget(project.id) }
                .offset(y: isDragged ? projectDrag.visualOffset : 0)
                .zIndex(isDragged ? 1 : 0)
        case .header(let title, _):
            ActivityHeader(title: title)
        case .thread(let thread, let projectName, let projectIcon, let peers, let hasHelpers):
            reorderableRow(thread, projectName: projectName, projectIcon: projectIcon, peers: peers, hasHelpers: hasHelpers, isNested: item.isNested)
                .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named(Self.listSpace)) }) { frame in
                    rowHeights.note(item.id, frame.height)
                    rowFrames.note(thread.id, frame)
                }
                // A row that has left the list (scrolled out or deleted) is not there to grab.
                .onDisappear { rowFrames.forget(thread.id) }
        case .helper(let thread, let isLast):
            archivePopover(for: thread, on: renamePopover(for: thread, on: deletePopover(for: thread, on: SidebarHelperRow(
                snapshot: thread,
                isLast: isLast,
                menuRequests: menuRequests,
                onFold: { fold(thread.parentThreadID) },
                onRename: {
                    // The live record: the item's snapshot does not follow a title change.
                    let live = model.thread(thread.id) ?? thread
                    renameText = live.title
                    renaming = live
                },
                onDelete: {
                    if model.settings.confirmBeforeDeleting {
                        pendingDeletionID = thread.id
                    } else {
                        model.delete(thread.id)
                    }
                }
            ).equatable())))
            .padding(.leading, item.isNested ? ThreadRowMetrics.folderIndent : 0)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { rowHeights.note(item.id, $0) }
            .modifier(RidesWithDraggedParent(parentID: thread.parentThreadID, drag: drag))
        case .headCards(let parent, let heads):
            headCards(parent: parent, heads: heads)
                .padding(.leading, item.isNested ? ThreadRowMetrics.folderIndent : 0)
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { rowHeights.note(item.id, $0) }
                .modifier(RidesWithDraggedParent(parentID: parent.id, drag: drag))
        case .helperStub(let parent, let helpers):
            HelperStubRow(parentSnapshot: parent, helperSnapshots: helpers) { fold(parent.id) }
                .padding(.leading, item.isNested ? ThreadRowMetrics.folderIndent : 0)
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { rowHeights.note(item.id, $0) }
                .modifier(RidesWithDraggedParent(parentID: parent.id, drag: drag))
        }
    }

    private func sectionHeader(_ section: SidebarSection, isFirstInList: Bool = false) -> some View {
        let collapsed = section == .projects ? model.settings.sidebarProjectsCollapsed : model.settings.sidebarTasksCollapsed
        return Button {
            withAnimation(Chrome.panelSlide) {
                switch section {
                case .projects: model.settings.sidebarProjectsCollapsed.toggle()
                case .tasks: model.settings.sidebarTasksCollapsed.toggle()
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .rotationEffect(.degrees(collapsed ? 0 : 90))
                    .accessibilityHidden(true)
                Text(verbatim: Chrome.localized(section.title))
                    .font(.ui(.callout, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(Chrome.secondaryText)
            .padding(.leading, Chrome.rowHorizontalPadding)
            .padding(.trailing, Chrome.rowHorizontalPadding + Chrome.iconSize)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: Chrome.rowHeight)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: Chrome.localized(section.title)))
        .accessibilityValue(Text(verbatim: Chrome.localized(collapsed ? "Collapsed" : "Expanded")))
        .overlay(alignment: .trailing) {
            SidebarHeaderButton(
                symbol: "plus",
                hitSize: Chrome.iconSize,
                help: section == .projects ? "Add project" : "New task"
            ) { add(to: section) }
                .padding(.trailing, Chrome.rowHorizontalPadding - (Chrome.iconSize - SidebarHeaderLayout.glyphWidth) / 2)
        }
        .modifier(SidebarHeaderLayout(
            topSpacing: isFirstInList ? (section == .projects && !inPopover ? 0 : 8) : 7
        ))
    }

    private func add(to section: SidebarSection) {
        switch section {
        case .projects: addProject()
        case .tasks: model.newThread(affiliation: .standalone)
        }
    }

    /// Where every thread sits in the list (see `ThreadPlacement`): the key the grouping and
    /// the list below are kept under. Kept while a cheap fingerprint of the threads stands,
    /// so an unrelated re-render (selection, hover) does not rebuild placements for
    /// hundreds of threads.
    @State private var placementCache = PlacementCache()
    private var threadPlacements: [ThreadPlacement] {
        placementCache.placements(for: model)
    }

    /// A scroll movement (re)arms the list's scroll freeze: rows take no hover or clicks
    /// for 150 ms after the last movement, covering wheel ticks, which report no phase.
    private func noteListScroll() {
        // The list's whole body -- placements, grouping, the row diff -- is what a write to
        // this flag re-evaluates, and scroll geometry reports every wheel tick: set it once
        // per scroll, not once per frame of one. The settle task still re-arms on every
        // movement, so the freeze lifts 150 ms after the last one, as before.
        if !isListScrolling { isListScrolling = true }
        scrollSettle?.cancel()
        scrollSettle = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, isListScrolling else { return }
            isListScrolling = false
        }
    }

    /// Every helper by the thread it hangs under, worked out once for the whole list. Asking
    /// the model per row walked the library once per row, so a long list did that work for
    /// every row in it; the rows are handed their own helpers instead. Kept while the
    /// placements stand: a render that moved no thread reuses the last grouping.
    private func helpersByParent(placements: [ThreadPlacement]) -> [UUID: [ChatThread]] {
        itemCache.helpers(for: placements) {
            var grouped: [UUID: [ChatThread]] = [:]
            // Heads count while they are still in the lead's panel too (see
            // `AppModel.helpers(of:)`).
            for thread in model.threads where !thread.isArchived && (!thread.isInPanel || thread.isHydraHead) {
                guard let parentID = thread.parentThreadID else { continue }
                grouped[parentID, default: []].append(thread)
            }
            // Newest first, like the threads around them (see `AppModel.helpers(of:)`).
            return grouped.mapValues { $0.sorted { $0.createdAt > $1.createdAt } }
        }
    }

    /// The two sections, built only when placements, projects or task attention change. A
    /// title or a head's progress note reaches its row through the model's per-thread cell
    /// (see `SidebarThreadRow.thread`) without the list being built again.
    private func listItems(placements: [ThreadPlacement], helpers: [UUID: [ChatThread]]) -> [SidebarItem] {
        let todayFocus = model.settings.sidebarActivityView
        let tasks = todayFocus ? [] : itemCache.tasks(for: placements) { model.standaloneTasks }
        let parentsShowingHeads: Set<UUID> = todayFocus ? [] : Set(helpers.compactMap { parent, heads in hasRunningHead(heads) ? parent : nil })
        let attention = Set(tasks.lazy.filter { needsAttention($0) }.map(\.id))
        let key = SidebarItemCache.Key(
            placements: placements,
            projects: model.projects,
            reordersProjects: projectDrag.id != nil,
            todayFocus: todayFocus,
            todayTick: todayFocus ? MinuteClock.shared.now : nil,
            projectsCollapsed: model.settings.sidebarProjectsCollapsed,
            tasksCollapsed: model.settings.sidebarTasksCollapsed,
            attention: attention,
            parentsShowingHeads: parentsShowingHeads
        )
        return itemCache.items(for: key) {
            if key.todayFocus {
                let now = Date.now
                let cutoff = Calendar.current.startOfDay(for: now)
                let threads = model.threads.filter {
                    !$0.isArchived && !$0.isHelper && !$0.isInPanel && $0.updatedAt >= cutoff && $0.updatedAt <= now
                }.sorted { $0.updatedAt > $1.updatedAt }
                var items = [SidebarItem(id: "section-today", kind: .todayHeader)]
                items.append(contentsOf: threads.map { thread in
                    SidebarItem(
                        id: SidebarItem.id(for: thread),
                        kind: .thread(thread, projectName: nil, projectIcon: nil, peers: nil, hasHelpers: false)
                    )
                })
                if threads.isEmpty {
                    items.append(SidebarItem(id: "empty-today", kind: .empty("Nothing active today")))
                }
                return items
            }
            var items = [SidebarItem(id: "section-projects", kind: .section(.projects))]
            if !key.projectsCollapsed {
                items.append(contentsOf: projectItems(helpers: helpers))
                if model.projects.isEmpty {
                    items.append(SidebarItem(id: "empty-projects", kind: .empty("No projects yet")))
                }
            }
            items.append(SidebarItem(id: "section-tasks", kind: .section(.tasks)))
            if !key.tasksCollapsed {
                let taskItems = activityItems(tasks: tasks, helpers: helpers, attentionIDs: attention)
                if taskItems.isEmpty {
                    items.append(SidebarItem(id: "empty-tasks", kind: .empty("No tasks yet")))
                } else {
                    items.append(contentsOf: taskItems)
                }
            }
            return items
        }
    }

    /// Whether any of these heads is still running. Read through the model rather than the
    /// snapshot, so a head that has just finished is not counted by a stale copy.
    private func hasRunningHead(_ heads: [ChatThread]) -> Bool {
        heads.contains { (model.thread($0.id) ?? $0).hydra?.status == .running }
    }

    private func visibleHelpers(_ helpers: [ChatThread]) -> [ChatThread] {
        guard !hasRunningHead(helpers.filter(\.isHydraHead)) else { return helpers }
        return helpers.filter { !$0.isHydraHead }
    }

    /// The helpers under a thread: one small row each, or a single line naming them while
    /// they are folded away.
    private func helperItems(under thread: ChatThread, helpers: [ChatThread], isNested: Bool = false) -> [SidebarItem] {
        let helpers = visibleHelpers(helpers)
        guard !helpers.isEmpty else { return [] }
        if thread.foldsHelpers {
            return [SidebarItem(id: "helpers-\(thread.id)", kind: .helperStub(parent: thread, helpers: helpers), isNested: isNested)]
        }
        let plain = helpers.filter { !$0.isHydraHead }
        let heads = Self.orderedHeads(helpers.filter(\.isHydraHead))
        let showsHeads = !heads.isEmpty
        var items = plain.map { helper in
            SidebarItem(id: helper.id.uuidString, kind: .helper(helper, isLast: helper.id == plain.last?.id && !showsHeads), isNested: isNested)
        }
        if showsHeads {
            items.append(SidebarItem(id: "heads-\(thread.id)", kind: .headCards(parent: thread, heads: heads), isNested: isNested))
        }
        return items
    }

    /// Hydra heads in card order: running heads first, newest `createdAt` first among
    /// them, then finished heads, newest first.
    fileprivate static func orderedHeads(_ heads: [ChatThread]) -> [ChatThread] {
        heads.sorted { lhs, rhs in
            let lhsRunning = lhs.hydra?.status == .running
            let rhsRunning = rhs.hydra?.status == .running
            if lhsRunning != rhsRunning { return lhsRunning }
            return lhs.createdAt > rhs.createdAt
        }
    }

    private func fold(_ parentID: UUID?) {
        guard let parentID else { return }
        withAnimation(Chrome.panelSlide) { model.toggleHelpersFold(parentID) }
    }

    // MARK: Adding projects

    /// New projects join from here: a folder picker, one project per folder, then a
    /// thread in the last one added. Adding persists through the model.
    private func addProject() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = Chrome.localized("Add project")
        panel.message = Chrome.localized("Choose a folder for your agents to work in.")
        guard panel.runModal() == .OK else { return }
        var added: Project?
        for url in panel.urls { added = model.addProject(at: url) }
        if let added { model.newThread(in: added) }
    }

    // MARK: Project layout

    private func projectItems(helpers: [UUID: [ChatThread]]) -> [SidebarItem] {
        var items: [SidebarItem] = []
        for (index, project) in model.projects.enumerated() {
            if index > 0 {
                items.append(SidebarItem(id: "gap-\(project.id)", kind: .gap(Chrome.groupGap)))
            }
            let projectThreads = model.threads(in: project)
            // The count a folded project shows: the chats it lists expanded, meaning its
            // top-level threads — the helpers and heads nested under them are not chats.
            let count = projectThreads.count
            items.append(SidebarItem(id: "project-\(project.id)", kind: .project(project, count: count)))
            guard project.isExpanded, projectDrag.id == nil else { continue }
            // Pinned threads lead each project's list.
            let orderedThreads = projectThreads.filter(\.isPinned) + projectThreads.filter { !$0.isPinned }
            for thread in orderedThreads {
                let own = helpers[thread.id] ?? []
                items.append(SidebarItem(
                    id: SidebarItem.id(for: thread),
                    kind: .thread(thread, projectName: nil, projectIcon: nil, peers: nil, hasHelpers: !own.isEmpty),
                    isNested: true
                ))
                items.append(contentsOf: helperItems(under: thread, helpers: own, isNested: true))
            }
        }
        return items
    }

    // MARK: Activity layout

    private func activityItems(tasks: [ChatThread], helpers: [UUID: [ChatThread]], attentionIDs: Set<UUID>) -> [SidebarItem] {
        let attention = Self.placed(tasks.filter { attentionIDs.contains($0.id) })
        let rest = tasks.filter { !attentionIDs.contains($0.id) }
        var items: [SidebarItem] = []
        if !attention.isEmpty {
            items.append(SidebarItem(id: "attention", kind: .header("Needs attention", isFirst: true)))
            items.append(contentsOf: activityThreadItems(attention, helpers: helpers))
        }
        // Pinned threads sit above the day groups, in the activity sort's order.
        let pinned = Self.placed(rest.filter(\.isPinned))
        if !pinned.isEmpty {
            items.append(SidebarItem(id: "day-Pinned", kind: .header("Pinned", isFirst: items.isEmpty)))
            items.append(contentsOf: activityThreadItems(pinned, helpers: helpers))
        }
        for group in Self.activityGroups(rest.filter { !$0.isPinned }) {
            items.append(contentsOf: activityThreadItems(group.threads, helpers: helpers))
        }
        return items
    }

    /// Threads of one activity group, each with the helpers under it. A thread can be dragged
    /// to another place within its own group; its helpers follow it.
    private func activityThreadItems(_ threads: [ChatThread], helpers: [UUID: [ChatThread]]) -> [SidebarItem] {
        let peers = threads.map(\.id)
        return threads.flatMap { thread in
            let own = helpers[thread.id] ?? []
            return [SidebarItem(
                id: thread.id.uuidString,
                kind: .thread(thread, projectName: nil, projectIcon: nil, peers: peers, hasHelpers: !own.isEmpty)
            )] + helperItems(under: thread, helpers: own)
        }
    }

    private func needsAttention(_ thread: ChatThread) -> Bool {
        guard let runtime = model.existingRuntime(for: thread.id) else { return false }
        return !runtime.approvals.isEmpty || !runtime.questions.isEmpty
    }

    private struct ActivityGroup {
        let title: String
        var threads: [ChatThread]
    }

    /// Threads grouped under Today, Yesterday, a weekday within the week, then a date.
    private static func activityGroups(_ threads: [ChatThread]) -> [ActivityGroup] {
        let calendar = Calendar.current
        var groups: [ActivityGroup] = []
        for thread in threads.sorted(by: { $0.updatedAt > $1.updatedAt }) {
            let title = dayTitle(for: thread.updatedAt, calendar: calendar)
            if groups.last?.title == title {
                groups[groups.count - 1].threads.append(thread)
            } else {
                groups.append(ActivityGroup(title: title, threads: [thread]))
            }
        }
        return groups.map { ActivityGroup(title: $0.title, threads: placed($0.threads)) }
    }

    /// Newest first, except threads dragged into place, which keep that place for the rest of their day.
    private static func placed(_ threads: [ChatThread]) -> [ChatThread] {
        ChatThread.orderedByActivity(threads)
    }

    private static func dayTitle(for date: Date, calendar: Calendar) -> String {
        if calendar.isDateInToday(date) { return Chrome.localized("Today") }
        if calendar.isDateInYesterday(date) { return Chrome.localized("Yesterday") }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: .now)).day ?? 0
        if days < 7 { return date.formatted(.dateTime.weekday(.wide)) }
        if calendar.isDate(date, equalTo: .now, toGranularity: .year) {
            return date.formatted(.dateTime.month(.wide).day())
        }
        return date.formatted(.dateTime.month(.wide).day().year())
    }

    // MARK: Search

    @ViewBuilder
    private func searchList(helpers: [UUID: [ChatThread]]) -> some View {
        let results = searchResults(helpers: helpers)
        if results.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("No results")
                    .font(.ui(.body, weight: .semibold))
                    .foregroundStyle(Chrome.primaryText.opacity(0.92))
                Text("Try a thread title or a project name.")
                    .font(.ui(.subheadline))
                    .foregroundStyle(Chrome.secondaryText)
            }
            .padding(.horizontal, 8)
            .padding(.top, 14)
        } else {
            ForEach(Array(results.enumerated()), id: \.element.id) { index, result in
                if index > 0, result.project != nil {
                    Color.clear.frame(height: Chrome.groupGap)
                }
                if let project = result.project {
                    ProjectRow(snapshot: project, count: result.count, togglesExpansion: false)
                    ForEach(result.threads, id: \.id) { thread in
                        threadRow(thread, projectName: nil, projectIcon: nil, hasHelpers: !(helpers[thread.id] ?? []).isEmpty, isNested: true)
                    }
                } else {
                    sectionHeader(.tasks, isFirstInList: index == 0)
                    if !model.settings.sidebarTasksCollapsed {
                        let matchedIDs = Set(result.threads.map(\.id))
                        ForEach(result.threads.filter { !$0.isHelper && !$0.isHydraHead }, id: \.id) { thread in
                            let own = (helpers[thread.id] ?? []).filter { matchedIDs.contains($0.id) }
                            threadRow(thread, projectName: nil, projectIcon: nil, hasHelpers: !own.isEmpty)
                            ForEach(helperItems(under: thread, helpers: own)) { item in
                                itemView(item)
                            }
                        }
                    }
                }
            }
        }
    }

    /// Up and down in the search field walk the results without leaving the keyboard; the
    /// row highlights exactly as a clicked one does.
    private func moveSearchSelection(by offset: Int, helpers: [UUID: [ChatThread]]) {
        guard !query.isEmpty else { return }
        let results = searchResults(helpers: helpers).flatMap(\.threads)
        guard !results.isEmpty else { return }
        guard let current = model.selectedThreadID,
              let index = results.firstIndex(where: { $0.id == current }) else {
            if let next = offset < 0 ? results.last : results.first { model.openThread(next.id) }
            return
        }
        let next = min(max(index + offset, 0), results.count - 1)
        model.openThread(results[next].id)
    }

    /// The projects and threads matching the query, kept for the query and library they
    /// were found in: the field's submit, arrows and list all ask, and only a keystroke or
    /// a thread change looks again. Titles are matched lowercased, from a table the cache
    /// keeps per thread, so a keystroke lowercases the query once and nothing else.
    private func searchResults(helpers: [UUID: [ChatThread]]) -> [SidebarSearchResult] {
        let key = SidebarItemCache.SearchKey(threads: model.threads, projects: model.projects, query: query)
        return itemCache.search(for: key) { titles in
            let needle = query.lowercased()
            var results: [SidebarSearchResult] = model.projects.compactMap { project in
                let topLevel = model.threads(in: project)
                let all = topLevel.flatMap { [$0] + (helpers[$0.id] ?? []) }
                let threads = project.name.lowercased().contains(needle)
                    ? all
                    : all.filter { titles[$0.id]?.contains(needle) ?? $0.title.lowercased().contains(needle) }
                return threads.isEmpty ? nil : SidebarSearchResult(project: project, threads: threads, count: topLevel.count)
            }
            let tasks = model.standaloneTasks
            let matchesSection = "Tasks".lowercased().contains(needle) || Chrome.localized("Tasks").lowercased().contains(needle)
            let matches: [ChatThread] = tasks.flatMap { thread in
                let own = helpers[thread.id] ?? []
                if matchesSection || (titles[thread.id]?.contains(needle) ?? thread.title.lowercased().contains(needle)) {
                    return [thread] + own
                }
                let children = own.filter { titles[$0.id]?.contains(needle) ?? $0.title.lowercased().contains(needle) }
                return children.isEmpty ? [] : [thread] + children
            }
            if !matches.isEmpty {
                results.append(SidebarSearchResult(project: nil, threads: matches, count: tasks.count))
            }
            return results
        }
    }

    // MARK: Rows

    /// Drag a row up or down the list and it moves live: within its project in the project
    /// layout, within its group in the activity layout. The list's one gesture drives it
    /// (see `body`), ahead of the row's own click, so a drag never selects the thread on
    /// release; a plain click still does. The row only lifts and follows here.
    private func reorderableRow(_ thread: ChatThread, projectName: String?, projectIcon: ProjectIcon?, peers: [UUID]?, hasHelpers: Bool, isNested: Bool = false) -> some View {
        let isDragged = drag.id == thread.id
        return threadRow(thread, projectName: projectName, projectIcon: projectIcon, hasHelpers: hasHelpers, isDragged: isDragged, isNested: isNested)
            .offset(y: isDragged ? drag.visualOffset : 0)
            .zIndex(isDragged ? 1 : 0)
    }

    // MARK: Reorder

    /// Neighbours sliding out of the grabbed row's way.
    private static let slide = Animation.spring(response: 0.28, dampingFraction: 0.82)

    /// The pointer has moved `translation` since the grab. The grabbed row follows it
    /// exactly and `RowDrag` swaps it past every neighbour whose centre it has crossed.
    private func dragChanged(_ id: UUID, translation: CGFloat) {
        if drag.id != id {
            drag = RowDrag(id: id)
            // Taken once at the grab: the peers and their slots stand until a swap.
            dragPeers = DragPeers(peers(of: id), heights: slotHeights)
        }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { drag.translation = translation }

        guard let snapshot = dragPeers else { return }
        let (order, group) = (snapshot.order, snapshot.group)
        let moved = drag.settle(order: order, heights: snapshot.heights, fallbackHeight: Chrome.rowHeight + 1) { neighbour, placeAfter in
            guard let moving = model.thread(id), let target = model.thread(neighbour),
                  moving.affiliation == target.affiliation else { return false }
            // The neighbour slides and the grabbed row's slot moves in the same animation
            // as its compensation, so it stays put under the pointer while the list flows
            // around it.
            return withAnimation(Self.slide) {
                if let group {
                    guard sameTaskGroup(moving, target) else { return false }
                    let validGroup = group.filter { peer in
                        model.thread(peer).map { sameTaskGroup(moving, $0) } ?? false
                    }
                    return model.moveInActivity(id, to: neighbour, placeAfter: placeAfter, among: validGroup)
                } else {
                    return model.moveThread(id, to: neighbour, placeAfter: placeAfter)
                }
            }
        }
        if moved {
            // The row's peers as the list stands now, not as it stood at the grab: every
            // swap reorders them. The slots are by id and stand.
            dragPeers = DragPeers(peers(of: id), heights: slotHeights)
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
    }

    private func dragEnded() {
        guard drag.id != nil else { return }
        dragPeers = nil
        // The offset animates from wherever the pointer let go to the row's slot, so the
        // row settles instead of snapping.
        withAnimation(.spring(response: 0.32, dampingFraction: 0.8)) { drag = RowDrag() }
    }

    private func projectDragChanged(_ id: UUID, translation: CGFloat) {
        if projectDrag.id != id {
            guard let expandedTop = projectFrames.frame(of: id)?.minY,
                  let index = model.projects.firstIndex(where: { $0.id == id }) else { return }
            let collapsedTop = Self.listTopInset + (rowHeights.values["section-projects"] ?? Chrome.rowHeight) + 1 + model.projects.prefix(index).reduce(CGFloat.zero) {
                $0 + (rowHeights.values["project-\($1.id)"] ?? Chrome.rowHeight) + 1
            } + CGFloat(index) * (Chrome.groupGap + 1)
            var grab = RowDrag<UUID>(id: id)
            // Compensate for the rows above disappearing without moving the grip.
            grab.settled = collapsedTop - expandedTop
            withAnimation(Chrome.panelSlide) { projectDrag = grab }
            projectDragPeers = DragPeers((model.projects.map(\.id), nil), heights: projectSlotHeights)
        }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { projectDrag.translation = translation }

        guard let snapshot = projectDragPeers else { return }
        let moved = projectDrag.settle(order: snapshot.order, heights: snapshot.heights, fallbackHeight: Chrome.rowHeight + Chrome.groupGap + 2) { neighbour, placeAfter in
            withAnimation(Self.slide) {
                model.moveProject(id, to: neighbour, placeAfter: placeAfter)
            }
        }
        if moved {
            projectDragPeers = DragPeers((model.projects.map(\.id), nil), heights: projectSlotHeights)
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
    }

    private func projectDragEnded() {
        guard projectDrag.id != nil else { return }
        projectDragPeers = nil
        withAnimation(.spring(response: 0.32, dampingFraction: 0.8)) { projectDrag = RowDrag() }
    }

    private func projectSlotHeights(for order: [UUID]) -> [UUID: CGFloat] {
        var heights: [UUID: CGFloat] = [:]
        for id in order {
            heights[id] = (rowHeights.values["project-\(id)"] ?? Chrome.rowHeight) + 1 + Chrome.groupGap + 1
        }
        return heights
    }

    /// The threads a row can be reordered among, in their current order: its activity group
    /// (returned as `group` too, for the move) or its project's top-level threads.
    private func peers(of id: UUID) -> (order: [UUID], group: [UUID]?) {
        guard let thread = model.thread(id) else { return ([], nil) }
        if thread.affiliation == .standalone {
            let placements = threadPlacements
            for item in listItems(placements: placements, helpers: helpersByParent(placements: placements)) {
                if case .thread(let thread, _, _, let peers, _) = item.kind, thread.id == id, let peers {
                    return (peers, peers)
                }
            }
            return ([], nil)
        }
        guard let project = model.project(thread.projectID) else { return ([], nil) }
        return (model.threads(in: project).map(\.id), nil)
    }

    private func sameTaskGroup(_ lhs: ChatThread, _ rhs: ChatThread) -> Bool {
        guard lhs.affiliation == .standalone, rhs.affiliation == .standalone,
              lhs.isStandaloneListCandidate, rhs.isStandaloneListCandidate,
              !lhs.isHelper, !rhs.isHelper else { return false }
        let attention = needsAttention(lhs)
        guard attention == needsAttention(rhs) else { return false }
        if attention { return true }
        guard lhs.isPinned == rhs.isPinned else { return false }
        return lhs.isPinned || Calendar.current.isDate(lhs.updatedAt, inSameDayAs: rhs.updatedAt)
    }

    /// Each peer's slot: its row, the helper rows or folded line under it, and the list's
    /// spacing after each.
    private func slotHeights(for order: [UUID]) -> [UUID: CGFloat] {
        let grouped = helpersByParent(placements: threadPlacements)
        var heights: [UUID: CGFloat] = [:]
        for id in order {
            var height = (rowHeights.values[id.uuidString] ?? Chrome.rowHeight) + 1
            let helpers = visibleHelpers(grouped[id] ?? [])
            if !helpers.isEmpty {
                if model.thread(id)?.foldsHelpers == true {
                    height += (rowHeights.values["helpers-\(id)"] ?? ThreadRowMetrics.helperHeight) + 1
                } else {
                    for helper in helpers where !helper.isHydraHead {
                        height += (rowHeights.values[helper.id.uuidString] ?? ThreadRowMetrics.helperHeight) + 1
                    }
                    let headCount = helpers.count(where: \.isHydraHead)
                    if headCount > 0 {
                        let rows = (headCount + 5) / 6
                        height += (rowHeights.values["heads-\(id)"] ?? ThreadRowMetrics.headCardHeight(rows: rows)) + 1
                    }
                }
            }
            heights[id] = height
        }
        return heights
    }

    /// What a drag reuses between pointer moves: the grabbed row's peers in their order,
    /// the group they form in the activity layout, and each peer's slot height.
    private struct DragPeers {
        let order: [UUID]
        let group: [UUID]?
        let heights: [UUID: CGFloat]

        init(_ peers: (order: [UUID], group: [UUID]?), heights: ([UUID]) -> [UUID: CGFloat]) {
            order = peers.order
            group = peers.group
            self.heights = heights(peers.order)
        }
    }

    /// Today focus mixes projects and tasks, so each row names where it belongs in the time's place.
    private func todayTag(for thread: ChatThread) -> String? {
        guard model.settings.sidebarActivityView, !inPopover else { return nil }
        return model.project(thread.projectID)?.name ?? Chrome.localized("Task")
    }

    private func threadRow(_ thread: ChatThread, projectName: String?, projectIcon: ProjectIcon?, hasHelpers: Bool, isDragged: Bool = false, isNested: Bool = false) -> some View {
        // A thread with helpers under it gets the fold button.
        // `.equatable()` skips the parent's re-evaluation for rows whose value inputs did
        // not change; the row still observes the model's per-thread cells inside its body.
        return archivePopover(for: thread, on: renamePopover(for: thread, on: deletePopover(for: thread, on: SidebarThreadRow(
            snapshot: thread,
            projectName: projectName,
            projectIcon: projectIcon,
            tag: todayTag(for: thread),
            menuRequests: menuRequests,
            isDragged: isDragged,
            onToggleFold: hasHelpers ? { fold(thread.id) } : nil,
            onRename: {
                // The live record: the item's snapshot does not follow a title change.
                let live = model.thread(thread.id) ?? thread
                renameText = live.title
                renaming = live
            },
            onDelete: {
                if model.settings.confirmBeforeDeleting {
                    pendingDeletionID = thread.id
                } else {
                    model.delete(thread.id)
                }
            }
        ).equatable())))
    }
}

struct RemoveProjectPopover: View {
    let count: Int
    let onRemove: @MainActor @Sendable () -> Void
    let onCancel: @MainActor @Sendable () -> Void

    var body: some View {
        PopoverMenu {
            PopoverSectionHeader("Remove this project?")
            PopoverNote(String(format: Chrome.localized("This permanently deletes %lld chats, including linked heads and helpers in other projects. Project source files will not be deleted."), Int64(count)))
            PopoverDivider()
            PopoverItem("Remove project", symbol: "trash", isDestructive: true, action: onRemove)
            PopoverItem("Cancel", symbol: "xmark", action: onCancel)
        }
        .frame(width: 280)
    }
}

struct SidebarToggleButton: View {
    let inSidebar: Bool
    @Environment(AppModel.self) private var model

    var body: some View {
        if !SettingsNavigation.shared.isPresented {
            ChromeCircleButton(symbol: "sidebar.left", help: Chrome.localized("Toggle sidebar") + ShortcutStore.hint(for: .toggleSidebar), glass: !inSidebar) {
                model.sidebar.toggle()
            }
        }
    }
}

/// The shortcut's question: the thread by name, with Delete beside Archive under it.
/// Return archives and Escape asks nothing. Archive takes focus as the popover opens,
/// which makes the popover key; when that is late or lost and the keys land on the chat
/// window behind it instead, the monitor answers them, so Return never goes on to the
/// composer.
private struct ArchiveThreadPopover: View {
    let thread: ChatThread
    let onArchive: () -> Void
    let onDelete: () -> Void
    let onDismiss: () -> Void

    @FocusState private var isFocused: Bool
    @State private var keyMonitor: Any?

    var body: some View {
        PopoverMenu {
            VStack(alignment: .leading, spacing: 9) {
                Text("Archive \(Text(verbatim: "\u{201C}\(thread.title)\u{201D}").fontWeight(.semibold))?")
                    .font(.ui(.callout))
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 6) {
                    Spacer(minLength: 0)
                    Button(action: onDelete) {
                        Text("Delete").foregroundStyle(.red)
                    }
                    .buttonStyle(.glass)
                    .help(Text(verbatim: Chrome.localized("Remove the thread and its history")))
                    Button("Archive", action: onArchive)
                        .buttonStyle(.glassProminent)
                        .keyboardShortcut(.defaultAction)
                        .focusable()
                        .focused($isFocused)
                        .focusEffectDisabled()
                        .help(Text(verbatim: Chrome.localized("Move it to Archived (Return)")))
                }
                .controlSize(.small)
            }
            .padding(.horizontal, 8)
            .padding(.top, 6)
            .padding(.bottom, 4)
        }
        .frame(width: 272)
        .onAppear {
            isFocused = true
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                guard event.window is ThreadWindow,
                      event.modifierFlags.intersection(KeyChord.allowedModifiers).isEmpty else { return event }
                switch event.keyCode {
                case 36, 76: onArchive() // Return, keypad Enter
                case 53: onDismiss() // Escape
                default: return event
                }
                return nil
            }
        }
        .onDisappear {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            keyMonitor = nil
        }
    }
}

/// What the delete popover asks: the thread by name, what stays, and the destructive choice
/// as a red row like the ellipsis menu's, with a second one for a thread's worktree.
private struct DeleteThreadPopover: View {
    let thread: ChatThread
    let onDelete: (_ removeWorktree: Bool) -> Void

    var body: some View {
        PopoverMenu {
            PopoverSectionHeader("Delete this thread?")
            PopoverNote(String(format: Chrome.localized("“%@” and its history will be removed. Files in your project stay as they are."), thread.title))
            PopoverDivider()
            PopoverItem("Delete thread", symbol: "trash", isDestructive: true) { onDelete(false) }
            if thread.worktreePath != nil, !thread.isHelper || thread.hydra?.hasOwnCopy == true {
                PopoverItem("Delete thread and worktree", symbol: "trash", isDestructive: true) { onDelete(true) }
            }
        }
        .frame(width: 280)
    }
}

/// What the rename popover asks: the title field and the choice, on the row itself
/// like the delete question. Clicking away keeps the thread's title.
private struct RenameThreadPopover: View {
    let title: String
    let onRename: (String) -> Void
    let onCancel: () -> Void

    @State private var text: String
    @FocusState private var isFocused: Bool

    init(title: String, onRename: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        self.title = title
        self.onRename = onRename
        self.onCancel = onCancel
        _text = State(initialValue: title)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Rename thread")
                .font(.ui(.body, weight: .semibold))
            TextField("Title", text: $text)
                .textFieldStyle(.roundedBorder)
                .focused($isFocused)
                .onSubmit { onRename(text) }
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .buttonStyle(.bordered)
                Button("Rename") { onRename(text) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .controlSize(.regular)
        }
        .padding(14)
        .frame(width: 300)
        .onAppear { isFocused = true }
    }
}

private enum SidebarSection {
    case projects
    case tasks

    var title: String {
        switch self {
        case .projects: "Projects"
        case .tasks: "Tasks"
        }
    }
}

/// One entry of the sidebar list. Thread entries keep their id across affiliations.
private struct SidebarItem: Identifiable {
    enum Kind {
        case gap(CGFloat)
        case section(SidebarSection)
        case todayHeader
        case empty(String)
        /// A project, with what a folded one shows: its threads and their helpers.
        case project(Project, count: Int)
        case header(String, isFirst: Bool)
        /// A thread, with its project's name in the activity layout, the threads it can be
        /// reordered among, and whether it has helpers to fold away.
        case thread(ChatThread, projectName: String?, projectIcon: ProjectIcon?, peers: [UUID]?, hasHelpers: Bool)
        /// A helper under its parent thread; the last one ends the connector.
        case helper(ChatThread, isLast: Bool)
        /// The parent's Hydra heads as glyph cards, ending the connector.
        case headCards(parent: ChatThread, heads: [ChatThread])
        /// A parent's folded helpers, as one line that unfolds them.
        case helperStub(parent: ChatThread, helpers: [ChatThread])
    }

    let id: String
    let kind: Kind
    var isNested: Bool = false

    static func id(for thread: ChatThread) -> String {
        thread.id.uuidString
    }
}

private extension AnyTransition {
    /// A row leaves at once and arrives once its neighbours have mostly made room, so rows moving past
    /// each other never draw over one another.
    static var sidebarRow: AnyTransition {
        .asymmetric(
            insertion: .opacity.animation(.easeIn(duration: 0.18).delay(0.12)),
            removal: .opacity.animation(.easeOut(duration: 0.06))
        )
    }
}

private struct ProjectRow: View {
    @Environment(AppModel.self) private var model
    /// The project as the list last built it; `project` below is the live record.
    let snapshot: Project
    /// The row reads its own project through the model's per-project cell, so a change to
    /// it re-renders this row alone and a change to any other project does not reach it.
    /// The snapshot is the fallback for a project that has just been removed.
    private var project: Project { model.project(snapshot.id) ?? snapshot }
    /// What a folded project shows: its threads and the helpers under them, counted by the
    /// list once for every row rather than here, per row, over the whole library.
    let count: Int
    var togglesExpansion = true
    var isDragged = false

    @State private var isMenuPresented = false
    @State private var iconEditor = ProjectIconEditorRequest()
    @AppStorage("performanceMode", store: CaptureRun.defaults ?? .standard) private var performanceMode = false

    var body: some View {
        @Bindable var iconEditor = iconEditor
        let shape = RoundedRectangle(cornerRadius: Chrome.rowCornerRadius, style: .continuous)
        SidebarRow(
            title: project.name,
            accessoryWidth: 40,
            action: {
                guard togglesExpansion else { return }
                withAnimation(Chrome.panelSlide) {
                    model.updateProject(project.id) { $0.isExpanded.toggle() }
                }
            },
            icon: {
                SidebarIconBadge {
                    if let icon = project.icon {
                        ProjectIconMark(icon: icon, size: 12)
                    } else {
                        SidebarSymbol("asset:sidebar-folder")
                    }
                }
            },
            accessory: { hovering in
                if (hovering || isMenuPresented) && !isDragged {
                    HStack(spacing: 0) {
                        RowActionsButton(actions: actions(), isPresented: $isMenuPresented)
                        Button {
                            model.newThread(in: project)
                        } label: {
                            RowAccessoryIcon("plus")
                        }
                        .buttonStyle(.plain)
                        .help(Text(verbatim: String(format: Chrome.localized("New thread in %@"), project.name)))
                    }
                } else if !project.isExpanded, count > 0 {
                    Text(verbatim: "\(count)")
                        .font(.ui(.subheadline).monospacedDigit())
                        .foregroundStyle(Chrome.secondaryText)
                        .padding(.trailing, Chrome.rowHorizontalPadding - 6)
                }
            }
        )
        .background {
            if isDragged {
                shape
                    .fill(Chrome.overlay(0.12))
                    .shadow(color: .black.opacity(performanceMode ? 0 : 0.28), radius: performanceMode ? 0 : 10, y: performanceMode ? 0 : 4)
            }
        }
        .scaleEffect(isDragged ? 1.02 : 1)
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isDragged)
        .popover(isPresented: $iconEditor.isPresented, arrowEdge: .bottom) {
            if let projectID = iconEditor.projectID, projectID == snapshot.id {
                ProjectIconPicker(icon: Self.iconBinding(for: projectID, model: model))
            }
        }
        // Snapshots only: the menu builder must not capture the row, so the AppKit menu it
        // builds cannot pin the row's state storage (and its responder with it) after dismiss.
        .contextMenu { [project, model, iconEditor] in
            let projectSnapshot = project
            let modelSnapshot = model
            RowActionMenuButtons(actions: Self.contextMenuActions(
                project: projectSnapshot,
                model: modelSnapshot,
                iconEditor: iconEditor
            ))
            // The pair that new chats in this project start on. The menu shows only when
            // there is a pair to choose. Value snapshots only, as above.
            let pairsSnapshot = modelSnapshot.hydraPickerPairs.map { pair in
                ProjectPairChoice(id: pair.id, title: HydraPairSummary.title(pair, registry: modelSnapshot.providers))
            }
            if !pairsSnapshot.isEmpty {
                Divider()
                Menu {
                    ProjectPairMenuItems(projectID: projectSnapshot.id, selectedID: projectSnapshot.hydraPairID, pairs: pairsSnapshot, model: modelSnapshot)
                } label: {
                    Label("Start new chats on", systemImage: "point.3.connected.trianglepath.dotted")
                }
            }
        }
    }

    /// The context menu's items, built from value snapshots with weak model captures: the
    /// AppKit menu outlives the right-click, so its callbacks must not retain the row.
    /// (The ellipsis popover keeps `actions()`; it is not an AppKit menu.)
    private static func contextMenuActions(project: Project, model: AppModel, iconEditor: ProjectIconEditorRequest) -> [RowAction] {
        [
            RowAction(title: "New thread", symbol: "plus.bubble") { [weak model, project] in
                guard let model else { return }
                model.newThread(in: project)
            },
            RowAction(title: "New thread in worktree", symbol: "square.stack.3d.up") { [weak model, project] in
                guard let model else { return }
                model.newThread(in: project, workspace: .worktree)
            },
            RowAction(title: "Reveal in Finder", symbol: "folder", startsGroup: true) { [weak model, path = project.path] in
                guard model != nil else { return }
                Workspace.revealInFinder(path)
            },
            changeIconAction(projectID: project.id, model: model, iconEditor: iconEditor),
            RowAction(title: "Remove project", symbol: "trash", isDestructive: true, startsGroup: true) { [weak model, project] in
                guard let model else { return }
                model.requestProjectDeletion(project)
            },
        ]
    }

    private func actions() -> [RowAction] {
        [
            RowAction(title: "New thread", symbol: "plus.bubble") { model.newThread(in: project) },
            RowAction(title: "New thread in worktree", symbol: "square.stack.3d.up") {
                model.newThread(in: project, workspace: .worktree)
            },
            RowAction(title: "Reveal in Finder", symbol: "folder", startsGroup: true) { Workspace.revealInFinder(project.path) },
            Self.changeIconAction(projectID: project.id, model: model, iconEditor: iconEditor),
            RowAction(title: "Remove project", symbol: "trash", isDestructive: true, startsGroup: true) {
                model.requestProjectDeletion(project)
            },
        ]
    }

    private static func iconBinding(for projectID: UUID, model: AppModel) -> Binding<ProjectIcon?> {
        Binding(
            get: { [weak model] in model?.project(projectID)?.icon },
            set: { [weak model] icon in model?.updateProject(projectID) { $0.icon = icon } }
        )
    }

    private static func changeIconAction(projectID: UUID, model: AppModel, iconEditor: ProjectIconEditorRequest) -> RowAction {
        RowAction(title: "Change icon…", symbol: "face.smiling") { [weak model, weak iconEditor] in
            // Let the menu dismiss before presenting from the persistent project row.
            Task { @MainActor [weak model, weak iconEditor] in
                guard model?.project(projectID) != nil, let iconEditor else { return }
                iconEditor.projectID = projectID
                iconEditor.isPresented = true
            }
        }
    }
}

@Observable
private final class ProjectIconEditorRequest {
    var projectID: UUID?
    var isPresented = false
}

/// One pair as the submenu shows it: its id and its title.
private struct ProjectPairChoice: Identifiable {
    let id: UUID
    let title: String
}

/// The items of the project row's pair submenu: one per pair the picker offers, plus one
/// that removes the rule. A check mark shows the current choice. The view is a value and
/// holds the model it draws, so the callbacks capture it directly; there is no cycle.
private struct ProjectPairMenuItems: View {
    let projectID: UUID
    let selectedID: UUID?
    let pairs: [ProjectPairChoice]
    let model: AppModel

    var body: some View {
        Button { [projectID] in
            model.setHydraPair(nil, forProject: projectID)
        } label: {
            if selectedID == nil {
                Label("The chat's last pair", systemImage: "checkmark")
            } else {
                Text("The chat's last pair")
            }
        }
        Divider()
        ForEach(pairs) { pair in
            Button { [projectID, pairID = pair.id] in
                model.setHydraPair(pairID, forProject: projectID)
            } label: {
                if selectedID == pair.id {
                    Label(Chrome.localized(pair.title), systemImage: "checkmark")
                } else {
                    Text(verbatim: Chrome.localized(pair.title))
                }
            }
        }
    }
}

private enum ThreadRowMetrics {
    /// Indentation for thread rows and helpers under their project folder.
    static let folderIndent: CGFloat = 12
    static let detailedVerticalPadding: CGFloat = 7
    /// A two-line activity row: title, project line and their padding.
    static let detailedHeight: CGFloat = 48
    /// A helper's row under its parent: one small line, in either layout.
    static let helperHeight: CGFloat = 24
    /// Where the fold button sits, past the ellipsis and archive button.
    static let foldInset: CGFloat = 46
    /// The connector's column: the dotted line runs down it, under the parent's badge.
    static let connectorWidth: CGFloat = 28
    static let connectorLineX: CGFloat = 18
    /// A head's mark is the size of the project icon that leads a thread title, so one
    /// mark size reads down the whole sidebar.
    static let headGlyphSize: CGFloat = 14
    /// A head glyph plus the gap a card row keeps at its tightest.
    static let headGlyphPitch: CGFloat = 22
    /// The room a glyph's outcome badge takes past its frame: HydraGlyph rides the disc
    /// `0.3 × its diameter` out, a shade under 3 pt at this glyph size. A card row keeps
    /// it clear on its trailing side, so a badge never eats the card's own padding.
    static let headBadgeOverhang: CGFloat = 3
    /// Between a head card's glyph rows, and the card's own padding all round.
    static let headRowGap: CGFloat = 6
    static let headCardPadding: CGFloat = 6
    /// A head card's height for `rows` rows of glyphs: the rows, the gaps between them
    /// and the padding. The card reports its own height as it lays out; this stands in
    /// until the first measurement lands.
    static func headCardHeight(rows: Int) -> CGFloat {
        let rows = max(1, rows)
        return 2 * headCardPadding + CGFloat(rows) * headGlyphSize + CGFloat(rows - 1) * headRowGap
    }
}

/// A helper under the thread it was spawned from: one small line, joined to its parent by a
/// dotted connector that runs down the rows and ends at the last. The connector folds the
/// helpers away; the folded line (HelperStubRow) unfolds them.
private struct SidebarHelperRow: View, Equatable {
    @Environment(AppModel.self) private var model
    /// The helper as the list last built it; `thread` below is the live record.
    let snapshot: ChatThread
    /// The row reads its own thread through the model's per-thread cell, so a change to it
    /// re-renders this row alone and a change to any other thread does not reach it. The
    /// snapshot is the fallback for a thread that has just been deleted.
    private var thread: ChatThread { model.thread(snapshot.id) ?? snapshot }
    /// The last helper under its parent: the connector ends at this row.
    let isLast: Bool
    /// Carries rename/delete intents out of the AppKit menu without retaining row state.
    /// Held strongly: the box is the list's, not the row's, so holding it pins no row
    /// state, and a weak one could go nil under a menu still on screen.
    let menuRequests: SidebarMenuRequests
    let onFold: () -> Void
    let onRename: () -> Void
    let onDelete: () -> Void

    var body: some View {
        // Through the thread's own cell: a selection change re-renders the two rows it
        // touches, not every row in the list.
        let isSelected = model.isSelected(thread.id)
        HStack(spacing: 0) {
            HelperConnector(endsHere: isLast, action: onFold)
                .frame(width: ThreadRowMetrics.connectorWidth, height: ThreadRowMetrics.helperHeight)
            SidebarHelperInteraction(
                isSelected: isSelected,
                onSelect: { model.openThread(thread.id) },
                onWarm: { model.warmDocuments([thread.id], urgent: true) },
                actions: makeActions,
                label:
                HStack(spacing: 6) {
                    // A head keeps its glyph, so the team reads at a glance under its lead,
                    // at the same size the card draws it.
                    if let head = thread.hydra {
                        HydraGlyph(persona: head.persona, size: ThreadRowMetrics.headGlyphSize, status: head.status)
                    }
                    ThreadBadge(thread: thread)
                    Text(verbatim: thread.title)
                        .font(.ui(.callout, weight: isSelected || thread.hasUnread ? .medium : .regular))
                        .foregroundStyle(Chrome.primaryText.opacity(isSelected ? 0.96 : 0.8))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                }
            )
            // Snapshots only: the menu builder must not capture the row, so the AppKit menu
            // it builds cannot pin the row's state storage (and its responder with it).
            .contextMenu { [thread, model, menuRequests] in
                let threadSnapshot = thread
                let modelSnapshot = model
                let requestsSnapshot = menuRequests
                RowActionMenuButtons(actions: ThreadActions.makeContextMenu(
                    model: modelSnapshot,
                    thread: threadSnapshot,
                    requests: requestsSnapshot
                ))
            }
            .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
        }
    }

    static func == (lhs: SidebarHelperRow, rhs: SidebarHelperRow) -> Bool {
        lhs.snapshot.id == rhs.snapshot.id
            && lhs.snapshot.title == rhs.snapshot.title
            && lhs.snapshot.updatedAt == rhs.snapshot.updatedAt
            && lhs.snapshot.isPinned == rhs.snapshot.isPinned
            && lhs.isLast == rhs.isLast
    }

    private func makeActions() -> [RowAction] {
        ThreadActions.make(model: model, thread: thread, onRename: onRename, onDelete: onDelete)
    }
}

private struct SidebarHelperInteraction<Label: View>: View {
    let isSelected: Bool
    let onSelect: () -> Void
    let onWarm: () -> Void
    let actions: () -> [RowAction]
    let label: Label

    @State private var isHovering = false
    @State private var isMenuPresented = false

    var body: some View {
        let showsActions = isHovering || isMenuPresented
        let shape = RoundedRectangle(cornerRadius: Chrome.rowCornerRadius, style: .continuous)
        Button(action: onSelect) {
            label
                .padding(.leading, 6)
                .padding(.trailing, Chrome.rowHorizontalPadding + (showsActions ? 26 : 18))
                .frame(height: ThreadRowMetrics.helperHeight)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    shape
                        .fill(isSelected ? Chrome.overlay(0.12) : (isHovering ? Chrome.overlay(0.06) : Color.clear))
                        .animation(Chrome.hover, value: isSelected)
                }
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .overlay(alignment: .trailing) {
            Group {
                if showsActions {
                    RowActionsButton(actions: actions(), isPresented: $isMenuPresented)
                }
            }
            .padding(.trailing, 6)
        }
        .onHover { hovering in
            guard isHovering != hovering else { return }
            withAnimation(Chrome.hover) { isHovering = hovering }
            if hovering { onWarm() }
        }
    }
}

private struct HeadCardsRow: View {
    @Environment(AppModel.self) private var model
    let parentSnapshot: ChatThread
    let headSnapshots: [ChatThread]
    let menuRequests: SidebarMenuRequests
    let onFold: () -> Void

    @State private var width: CGFloat = 0
    /// The card shows the first twelve faces and keeps the rest behind the chevron: a
    /// long-running chat's team must not push the card half the sidebar tall.
    @State private var showsAllHeads = false

    var body: some View {
        let heads = SidebarView.orderedHeads(headSnapshots.map { model.thread($0.id) ?? $0 })
        let capped = heads.count > 12
        let visible = showsAllHeads ? heads : Array(heads.prefix(12))
        // The glyphs' room: the row's width less the connector's column and the card's
        // own padding, which is the same on both sides, less the room the last mark's
        // badge needs. The last glyph of a row needs its own 14 pt, not a whole 22 pt
        // pitch, so seven glyphs (7 x 14 + 6 x 8 = 146) and the badge's 3 pt fit the
        // 170 pt the card has at the sidebar's 210 pt minimum. Seven to a row until
        // the row has been measured.
        let cardInner = width - ThreadRowMetrics.connectorWidth - 2 * ThreadRowMetrics.headCardPadding
        let usable = cardInner - ThreadRowMetrics.headBadgeOverhang
        let perRow = width == 0 ? 7 : max(1, Int((usable + ThreadRowMetrics.headGlyphPitch - ThreadRowMetrics.headGlyphSize) / ThreadRowMetrics.headGlyphPitch))
        // The marks share the card's inner width: a row stretches its gaps past the
        // tightest one until the last mark's badge sits on the card's padding, so the
        // room left of the first mark and right of the last one come out the same. A
        // short last row keeps the step of the rows above it.
        let tightGap = ThreadRowMetrics.headGlyphPitch - ThreadRowMetrics.headGlyphSize
        let rowGap = perRow > 1 && width > 0
            ? max(tightGap, (usable - CGFloat(perRow) * ThreadRowMetrics.headGlyphSize) / CGFloat(perRow - 1))
            : tightGap
        let rows = Self.chunk(visible, by: perRow)
        let cardRows = rows.count + (capped ? 1 : 0)
        HStack(spacing: 0) {
            HelperConnector(endsHere: true, action: onFold)
                .frame(
                    width: ThreadRowMetrics.connectorWidth,
                    height: ThreadRowMetrics.headCardHeight(rows: cardRows)
                )
            VStack(alignment: .leading, spacing: ThreadRowMetrics.headRowGap) {
                ForEach(rows, id: \.first?.id) { row in
                    HStack(spacing: rowGap) {
                        ForEach(row, id: \.id) { head in
                            if let info = head.hydra {
                                Button {
                                    model.openThread(head.id)
                                } label: {
                                    HydraGlyph(persona: info.persona, size: ThreadRowMetrics.headGlyphSize, isRunning: info.status == .running, status: info.status)
                                        .background {
                                            if model.isSelected(head.id) {
                                                Circle().fill(Chrome.overlay(0.14)).padding(-3)
                                            }
                                        }
                                }
                                .buttonStyle(.plain)
                                .modifier(HeadGlyphHover(onWarm: { model.warmDocuments([head.id], urgent: true) }))
                                .help(Text(verbatim: "\(info.persona.name) · \(info.task)"))
                                // Snapshots only: the menu builder must not capture the row, so the AppKit menu
                                // it builds cannot pin the row's state storage (and its responder with it).
                                .contextMenu { [head, model, menuRequests] in
                                    let threadSnapshot = head
                                    let modelSnapshot = model
                                    let requestsSnapshot = menuRequests
                                    RowActionMenuButtons(actions: ThreadActions.makeContextMenu(
                                        model: modelSnapshot,
                                        thread: threadSnapshot,
                                        requests: requestsSnapshot
                                    ))
                                }
                                .accessibilityLabel(Text("\(info.persona.name), \(info.task)"))
                                .accessibilityAddTraits(.isButton)
                            }
                        }
                    }
                    // The last mark's badge rides past its frame: the row trails it so the
                    // card's padding stays whole on that side.
                    .padding(.trailing, ThreadRowMetrics.headBadgeOverhang)
                }
                if capped {
                    Button {
                        withAnimation(.snappy(duration: 0.18)) { showsAllHeads.toggle() }
                    } label: {
                        Image(systemName: showsAllHeads ? "chevron.up" : "chevron.down")
                            .font(.ui(.caption2, weight: .semibold))
                            .foregroundStyle(Chrome.secondaryText)
                            .frame(width: ThreadRowMetrics.headGlyphSize, height: ThreadRowMetrics.headGlyphSize)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(Text(verbatim: showsAllHeads ? Chrome.localized("Show fewer heads") : String(format: Chrome.localized("Show all %d heads"), heads.count)))
                }
            }
            .padding(ThreadRowMetrics.headCardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: ThreadRowMetrics.headCardHeight(rows: cardRows), alignment: .top)
            .background {
                RoundedRectangle(cornerRadius: Chrome.rowCornerRadius, style: .continuous).fill(Chrome.overlay(0.04))
            }
            .clipShape(RoundedRectangle(cornerRadius: Chrome.rowCornerRadius, style: .continuous))
            .animation(.snappy(duration: 0.18), value: cardRows)
        }
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width = $0 }
        .animation(Chrome.panelSlide, value: heads.map(\.id))
    }

    /// The heads in rows of `size`, in the order given; the last row takes the rest.
    private static func chunk(_ heads: [ChatThread], by size: Int) -> [[ChatThread]] {
        stride(from: 0, to: heads.count, by: size).map { Array(heads[$0 ..< min($0 + size, heads.count)]) }
    }
}

private struct HeadGlyphHover: ViewModifier {
    let onWarm: () -> Void
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(isHovering ? 1.18 : 1)
            .animation(Chrome.hover, value: isHovering)
            .onHover { hovering in
                guard isHovering != hovering else { return }
                withAnimation(Chrome.hover) { isHovering = hovering }
                if hovering { onWarm() }
            }
    }
}

/// A parent's folded helpers as one small line: the connector's stub, a chevron and their
/// count, with a pulse when any of them is still working. Clicking it unfolds them.
private struct HelperStubRow: View {
    @Environment(AppModel.self) private var model
    /// The parent as the list last built it; `parent` below is the live record.
    let parentSnapshot: ChatThread
    /// Handed in by the list, which groups every helper once per pass; the body reads each
    /// one's live record through the model's per-thread cell.
    let helperSnapshots: [ChatThread]
    let action: () -> Void

    /// The row reads its parent through the model's per-thread cell, so a change to it
    /// re-renders this row alone and a change to any other thread does not reach it. The
    /// snapshot is the fallback for a thread that has just been deleted.
    private var parent: ChatThread { model.thread(parentSnapshot.id) ?? parentSnapshot }

    var body: some View {
        // Each helper's live record, read once per render through its own cell.
        let helpers = helperSnapshots.map { model.thread($0.id) ?? $0 }
        let count = helpers.count
        let working = helpers.contains { helper in
            let runtime = model.existingRuntime(for: helper.id)
            return runtime?.isRunning == true || runtime?.isHydraMerging == true || !(runtime?.backgroundTasks.isEmpty ?? true)
        }
        // A team of heads is called that; merges alone stay "helpers".
        let isHeads = helpers.allSatisfy(\.isHydraHead)
        HelperStubFace(count: count, working: working, isHeads: isHeads, action: action)
    }
}

private struct HelperStubFace: View {
    let count: Int
    let working: Bool
    let isHeads: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Chrome.rowCornerRadius, style: .continuous)
        Button(action: action) {
            HStack(spacing: 0) {
                HelperConnectorShape(endsHere: true)
                    .stroke(HelperConnector.color(hovering: isHovering), style: HelperConnector.style)
                    .frame(width: ThreadRowMetrics.connectorWidth, height: ThreadRowMetrics.helperHeight)
                HStack(spacing: 5) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                    Text(verbatim: count == 1 ? Chrome.localized(isHeads ? "1 head" : "1 helper") : String(format: Chrome.localized(isHeads ? "%d heads" : "%d helpers"), count))
                        .font(.ui(.subheadline))
                    Spacer(minLength: 4)
                    if working {
                        MiniSpinner(cellSize: 2.4)
                            .padding(.trailing, 4)
                    }
                }
                .foregroundStyle(Chrome.secondaryText.opacity(isHovering ? 1 : 0.85))
                .padding(.leading, 6)
                .padding(.trailing, Chrome.rowHorizontalPadding)
                .frame(height: ThreadRowMetrics.helperHeight)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    shape.fill(isHovering ? Chrome.overlay(0.06) : Color.clear)
                }
                .contentShape(shape)
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            guard isHovering != hovering else { return }
            withAnimation(Chrome.hover) { isHovering = hovering }
        }
        .help(Text(verbatim: count == 1 ? Chrome.localized(isHeads ? "Show the head" : "Show the helper") : String(format: Chrome.localized(isHeads ? "Show %d heads" : "Show %d helpers"), count)))
        .accessibilityLabel(Text(verbatim: count == 1 ? Chrome.localized(isHeads ? "1 folded head" : "1 folded helper") : String(format: Chrome.localized(isHeads ? "%d folded heads" : "%d folded helpers"), count)))
    }
}

/// A helper row or the folded line under a thread being dragged moves with it, lifted the
/// same way, so the thread and its helpers travel as one block.
private struct RidesWithDraggedParent: ViewModifier {
    let parentID: UUID?
    let drag: RowDrag<UUID>

    func body(content: Content) -> some View {
        let rides = parentID != nil && drag.id == parentID
        content
            .offset(y: rides ? drag.visualOffset : 0)
            .zIndex(rides ? 1 : 0)
    }
}

/// The dotted connector beside a helper's row: down from the row above, and a tick to the
/// row. Where the helpers end it stops at the tick. The whole column folds the helpers away.
private struct HelperConnector: View {
    let endsHere: Bool
    let action: () -> Void

    @State private var isHovering = false

    static let style = StrokeStyle(lineWidth: 1, lineCap: .round, dash: [0.1, 3.6])

    static func color(hovering: Bool) -> Color {
        Chrome.secondaryText.opacity(hovering ? 0.9 : 0.45)
    }

    var body: some View {
        Button(action: action) {
            HelperConnectorShape(endsHere: endsHere)
                .stroke(Self.color(hovering: isHovering), style: Self.style)
                .animation(Chrome.hover, value: isHovering)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            guard isHovering != hovering else { return }
            isHovering = hovering
        }
        .help(Text(verbatim: Chrome.localized("Hide helpers")))
        .accessibilityLabel(Text("Hide helpers"))
    }
}

private struct HelperConnectorShape: Shape {
    let endsHere: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let x = ThreadRowMetrics.connectorLineX
        let midY = rect.midY
        path.move(to: CGPoint(x: x, y: rect.minY))
        path.addLine(to: CGPoint(x: x, y: endsHere ? midY : rect.maxY))
        path.move(to: CGPoint(x: x, y: midY))
        path.addLine(to: CGPoint(x: rect.maxX - 2, y: midY))
        return path
    }
}

/// A thread in either sidebar layout. In the project layout it is one line with the thread's badge; in
/// the activity layout the project it belongs to shows underneath. It is the same row in both, so
/// switching layouts animates its height and contents rather than swapping one row for another.
private struct SidebarThreadRow: View, Equatable {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme
    /// The thread as the list last built it; `thread` below is the live record.
    let snapshot: ChatThread
    /// The row reads its own thread through the model's per-thread cell, so a change to it
    /// re-renders this row alone and a change to any other thread does not reach it. The
    /// snapshot is the fallback for a thread that has just been deleted.
    private var thread: ChatThread { model.thread(snapshot.id) ?? snapshot }
    /// The project shown under the title in the activity layout; nil in the project layout.
    let projectName: String?
    /// The project's mark in the icon style: the folder or the picked emoji or symbol, in
    /// the slot in front of the title. Nil in the project-name style and the project layout.
    let projectIcon: ProjectIcon?
    /// Where the thread belongs, in the time's place at the row's end; set in today focus only.
    var tag: String? = nil
    /// Carries rename/delete intents out of the AppKit menu without retaining row state.
    /// Held strongly: the box is the list's, not the row's, so holding it pins no row
    /// state, and a weak one could go nil under a menu still on screen.
    let menuRequests: SidebarMenuRequests
    /// Lifted and following the pointer in a reorder.
    var isDragged = false
    /// Folds the helpers under this thread away or brings them back; nil when it has none.
    var onToggleFold: (() -> Void)?
    let onRename: () -> Void
    let onDelete: () -> Void

    @State private var windowFrame = FrameHolder()
    @AppStorage("performanceMode", store: CaptureRun.defaults ?? .standard) private var performanceMode = false

    var body: some View {
        // Through the thread's own cell (see `AppModel.isSelected`): a selection change
        // re-renders the row that lost it and the row that gained it, no other. The
        // runtime read below is this thread's alone; `existingRuntime` observes nothing
        // of the model, and the runtime's fields are observed per runtime.
        let isSelected = model.isSelected(thread.id)
        let isDetailed = projectName != nil
        // Read here, in the body, so the row follows the merge as it moves from stage to stage.
        let mergeStage = Self.mergeStage(of: model.existingRuntime(for: thread.id))
        let shape = RoundedRectangle(cornerRadius: Chrome.rowCornerRadius, style: .continuous)
        SidebarThreadInteraction(
            isSelected: isSelected,
            isDetailed: isDetailed,
            tag: tag,
            isPinned: thread.isPinned,
            isDragged: isDragged,
            foldsHelpers: thread.foldsHelpers,
            updatedAt: thread.updatedAt,
            windowFrame: windowFrame,
            onSelect: { model.openThread(thread.id) },
            onWarm: { model.warmDocuments([thread.id], urgent: true) },
            onArchive: archiveWithGenie,
            onToggleFold: onToggleFold,
            actions: makeActions,
            label:
            ThreadRowFace(
                thread: thread,
                projectName: projectName,
                projectIcon: projectIcon,
                isSelected: isSelected,
                trailingClearance: 0,
                mergeStage: mergeStage
            ) {
                ThreadBadge(thread: thread)
            }
        )
        // Lifted: a touch larger with a shadow, over an opaque fill so the rows sliding
        // underneath never show through. The queue's rows lift the same way.
        .background {
            if isDragged {
                shape
                    .fill(Chrome.overlay(0.12))
                    .shadow(color: .black.opacity(performanceMode ? 0 : 0.28), radius: performanceMode ? 0 : 10, y: performanceMode ? 0 : 4)
            }
        }
        .scaleEffect(isDragged ? 1.02 : 1)
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isDragged)
        // Snapshots only: the AppKit menu must not retain the row's state after dismiss.
        .contextMenu { [thread, model, menuRequests] in
            let threadSnapshot = thread
            let modelSnapshot = model
            let requestsSnapshot = menuRequests
            RowActionMenuButtons(actions: ThreadActions.makeContextMenu(
                model: modelSnapshot,
                thread: threadSnapshot,
                requests: requestsSnapshot
            ))
        }
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    /// Value inputs only: closures and the frame holder are ignored, so the parent's
    /// re-evaluation skips rows whose thread did not change. Live state still reaches the
    /// body through the model's per-thread cells.
    static func == (lhs: SidebarThreadRow, rhs: SidebarThreadRow) -> Bool {
        lhs.snapshot.id == rhs.snapshot.id
            && lhs.snapshot.title == rhs.snapshot.title
            && lhs.snapshot.updatedAt == rhs.snapshot.updatedAt
            && lhs.snapshot.isPinned == rhs.snapshot.isPinned
            && lhs.projectName == rhs.projectName
            && lhs.tag == rhs.tag
            && lhs.isDragged == rhs.isDragged
            && (lhs.onToggleFold != nil) == (rhs.onToggleFold != nil)
    }

    /// Built when the ellipsis shows or the context menu opens, never on a plain render.
    private func makeActions() -> [RowAction] {
        ThreadActions.make(model: model, thread: thread, onRename: onRename, onDelete: onDelete)
    }

    /// What the team's merge is doing, with an ellipsis, while it runs; nil otherwise.
    static func mergeStage(of runtime: ThreadRuntime?) -> String? {
        guard let runtime, runtime.isHydraMerging else { return nil }
        return MergeStageText.localized(runtime.hydraMergeStage ?? "Merging") + "\u{2026}"
    }

    // MARK: Archiving

    private func archiveWithGenie() {
        let isSelected = model.selectedThreadID == thread.id
        // The ghost mirrors the row's label — same text, badge, padding and
        // translucent fill — so the row hands over to it without a visible change.
        let fill = Chrome.overlay(isSelected ? 0.12 : 0.06)
        let shape = RoundedRectangle(cornerRadius: Chrome.rowCornerRadius, style: .continuous)
        let badge = ThreadGhostBadge(thread: thread, runtime: model.existingRuntime(for: thread.id))
        GenieAnimator.shared.launch(frame: windowFrame.frame, colorScheme: colorScheme) {
            ThreadRowFace(thread: thread, projectName: projectName, projectIcon: projectIcon, isSelected: isSelected, trailingClearance: 52) { badge }
                .background { shape.fill(fill) }
        }
        withAnimation(Chrome.panelSlide) { model.archive(thread.id) }
    }
}

private struct SidebarThreadInteraction<Label: View>: View {
    let isSelected: Bool
    let isDetailed: Bool
    let tag: String?
    let isPinned: Bool
    let isDragged: Bool
    let foldsHelpers: Bool
    let updatedAt: Date
    let windowFrame: FrameHolder
    let onSelect: () -> Void
    let onWarm: () -> Void
    let onArchive: () -> Void
    let onToggleFold: (() -> Void)?
    let actions: () -> [RowAction]
    let label: Label

    @State private var isHovering = false
    @State private var isMenuPresented = false
    /// The tag's drawn width: the title runs up to the tag it has, not to the widest one could be.
    @State private var tagWidth = SidebarTagLabel.maxWidth

    var body: some View {
        let showsActions = (isHovering || isMenuPresented) && !isDragged
        let showsFold = showsActions && onToggleFold != nil
        let clearance: CGFloat = showsActions ? 52 + (showsFold ? 20 : 0) : (isDetailed ? 18 : tag != nil ? tagWidth + 10 : 52)
        let shape = RoundedRectangle(cornerRadius: Chrome.rowCornerRadius, style: .continuous)
        Button(action: onSelect) {
            label.padding(.trailing, clearance)
            .background {
                // Only the fill animates with selection; the row's place is never animated from here.
                shape
                    .fill(isPinned && !isSelected ? Chrome.danger.opacity(0.10) : Chrome.overlay(fill))
                    .animation(Chrome.hover, value: isSelected)
            }
            .overlay {
                if isPinned && isSelected {
                    shape.fill(Chrome.danger.opacity(0.06))
                }
            }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .overlay(alignment: .trailing) {
            Group {
                if showsActions {
                    HStack(spacing: 0) {
                        Button {
                            onArchive()
                        } label: {
                            RowAccessoryIcon("archivebox")
                        }
                        .buttonStyle(.plain)
                        .help(Text(verbatim: Chrome.localized("Archive thread")))
                        RowActionsButton(actions: actions(), isPresented: $isMenuPresented)
                    }
                } else if let tag {
                    SidebarTagLabel(text: tag, date: updatedAt)
                        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { tagWidth = $0 }
                } else if !isDetailed {
                    RelativeTimeLabel(date: updatedAt)
                }
            }
            .padding(.trailing, 6)
        }
        // The helpers under the thread fold away and come back from here, as they do from the
        // connector beside them. The button sits before the archive and the ellipsis.
        .overlay(alignment: .trailing) {
            if showsFold, let onToggleFold {
                let folded = foldsHelpers
                Button(action: onToggleFold) {
                    RowAccessoryIcon(folded ? "chevron.right" : "chevron.down")
                }
                .buttonStyle(.plain)
                .padding(.trailing, ThreadRowMetrics.foldInset)
                .help(Text(verbatim: folded ? Chrome.localized("Show helpers") : Chrome.localized("Hide helpers")))
                .accessibilityLabel(Text(verbatim: folded ? Chrome.localized("Show helpers") : Chrome.localized("Hide helpers")))
            }
        }
        .onHover { hovering in
            guard isHovering != hovering else { return }
            withAnimation(Chrome.hover) { isHovering = hovering }
            // The pointer resting on a row usually means a click is coming: decode its history now.
            if hovering { onWarm() }
        }
        .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named(GenieAnimator.coordinateSpace)) }) { frame in
            guard isDragged || isHovering else { return }
            windowFrame.note(frame)
        }
    }

    private var fill: Double {
        if isSelected { return 0.12 }
        return isHovering ? 0.06 : 0
    }
}

/// A thread row's badge, title and project line. The archive ghost draws the same face.
private struct ThreadRowFace<Badge: View>: View {
    let thread: ChatThread
    /// The project under the title in the activity layout; nil in the project layout.
    let projectName: String?
    var projectIcon: ProjectIcon? = nil
    let isSelected: Bool
    /// The room left at the trailing end for the row's status, time or buttons.
    let trailingClearance: CGFloat
    /// What the team's merge is doing, shown in the project line's place while it runs.
    var mergeStage: String? = nil
    /// The badge at the front of an open row in the project layout.
    @ViewBuilder let badge: Badge

    var body: some View {
        let isDetailed = projectName != nil
        HStack(spacing: 8) {
            badge
            .frame(width: Chrome.iconSize)
            .transition(.opacity)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if let projectIcon, !isDetailed {
                        ProjectIconMark(icon: projectIcon, size: 12)
                    }
                    Text(verbatim: thread.title)
                        .font(.ui(size: 13, weight: thread.hasUnread || isSelected ? .medium : .regular))
                        .foregroundStyle(Chrome.primaryText.opacity(isSelected ? 1 : 0.92))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if thread.isPinned {
                        SidebarSymbol("pin.fill", scale: 0.9)
                            .foregroundStyle(Chrome.secondaryText)
                    }
                }
                if let projectName {
                    HStack(spacing: 4) {
                        Image(systemName: thread.worktreePath == nil ? "folder" : "arrow.triangle.branch")
                            .font(.ui(.footnote))
                        Text(verbatim: mergeStage ?? projectName)
                            .font(.ui(.callout))
                            .lineLimit(1)
                    }
                    .foregroundStyle(Chrome.secondaryText)
                    .transition(.opacity)
                }
            }
            Spacer(minLength: 4)
        }
        .padding(.leading, Chrome.rowHorizontalPadding)
        .padding(.trailing, Chrome.rowHorizontalPadding + trailingClearance)
        .padding(.vertical, isDetailed ? ThreadRowMetrics.detailedVerticalPadding : 0)
        .frame(minHeight: Chrome.rowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

}

/// The badge as a ghost carries it: the same marks as ThreadBadge, from a snapshot of the
/// runtime, with the spinner held still because a ghost is an image and cannot animate.
private struct ThreadGhostBadge: View {
    let thread: ChatThread
    let status: ThreadActivityStatus

    init(thread: ChatThread, runtime: ThreadRuntime?) {
        self.thread = thread
        status = threadActivityStatus(thread, runtime: runtime)
    }

    var body: some View {
        ThreadStatusMark(status: status, isStill: true)
    }
}

private struct ThreadBadge: View {
    @Environment(AppModel.self) private var model
    let thread: ChatThread

    var body: some View {
        let runtime = model.existingRuntime(for: thread.id)
        let mergeStage = SidebarThreadRow.mergeStage(of: runtime)
        let backgroundCount = runtime?.backgroundTasks.count ?? 0
        let runningHelp = mergeStage ?? (runtime?.isRunning != true && backgroundCount > 0 ? (backgroundCount == 1 ? Chrome.localized("Waiting on a background task") : String(format: Chrome.localized("Waiting on %lld background tasks"), backgroundCount)) : nil)
        ThreadStatusMark(status: threadActivityStatus(thread, runtime: runtime), runningHelp: runningHelp)
    }
}

/// Carries sidebar context-menu intents outside any row's @State. An AppKit context menu
/// outlives the right-click that opened it, so its callbacks must never retain a row's
/// state storage: menu -> closure -> row state -> view node -> menu responder is the back
/// edge that pinned ContextMenuResponder/NSMenu pairs after dismiss. Menu actions post a
/// value-type request here; the list takes it up. The rows and the menu hold this box
/// strongly: it belongs to the list, so nothing of a row hangs off it, and there is no
/// cycle back to the menu. Owned by the list's @State, touched on the main thread only.
@Observable
private final class SidebarMenuRequests {
    var rename: ChatThread?
    var delete: ChatThread?
}

/// What a thread row offers from its ellipsis popover and its context menu, in both sidebar layouts.
@MainActor
private enum ThreadActions {
    static func make(
        model: AppModel,
        thread: ChatThread,
        onRename: @escaping () -> Void,
        onDelete: @escaping () -> Void
    ) -> [RowAction] {
        var items = [RowAction(title: "Rename", symbol: "pencil") { onRename() }]
        // A helper keeps its place under its parent.
        if !thread.isHelper {
            items.append(RowAction(title: thread.isPinned ? "Unpin" : "Pin", symbol: thread.isPinned ? "pin.slash" : "pin") {
                withAnimation(Chrome.panelSlide) {
                    model.updateThread(thread.id) { $0.isPinned.toggle() }
                }
            })
        }
        items.append(RowAction(title: "Forward to new thread", symbol: "arrowshape.turn.up.right") {
            Task { await model.forwardThread(thread.id) }
        })
        if let path = thread.worktreePath {
            items.append(RowAction(title: "Reveal worktree in Finder", symbol: "folder") { Workspace.revealInFinder(path) })
        }
        items.append(RowAction(title: "Archive", symbol: "archivebox", startsGroup: true) {
            withAnimation(Chrome.panelSlide) { model.archive(thread.id) }
        })
        items.append(RowAction(title: "Delete…", symbol: "trash", isDestructive: true) { onDelete() })
        return items
    }

    /// Built from value snapshots with weak model captures: the AppKit menu must not
    /// retain row state. Rename and delete post to the list's request box.
    static func makeContextMenu(
        model: AppModel,
        thread: ChatThread,
        requests: SidebarMenuRequests
    ) -> [RowAction] {
        let threadID = thread.id
        var items = [RowAction(title: "Rename", symbol: "pencil") { [weak model, requests, thread] in
            guard model != nil else { return }
            requests.rename = thread
        }]
        // A helper keeps its place under its parent.
        if !thread.isHelper {
            let isPinned = thread.isPinned
            items.append(RowAction(title: isPinned ? "Unpin" : "Pin", symbol: isPinned ? "pin.slash" : "pin") { [weak model, threadID] in
                guard let model else { return }
                withAnimation(Chrome.panelSlide) {
                    model.updateThread(threadID) { $0.isPinned.toggle() }
                }
            })
        }
        items.append(RowAction(title: "Forward to new thread", symbol: "arrowshape.turn.up.right") { [weak model, threadID] in
            guard let model else { return }
            Task { await model.forwardThread(threadID) }
        })
        if let path = thread.worktreePath {
            items.append(RowAction(title: "Reveal worktree in Finder", symbol: "folder") { [weak model, path] in
                guard model != nil else { return }
                Workspace.revealInFinder(path)
            })
        }
        items.append(RowAction(title: "Archive", symbol: "archivebox", startsGroup: true) { [weak model, threadID] in
            guard let model else { return }
            withAnimation(Chrome.panelSlide) { model.archive(threadID) }
        })
        items.append(RowAction(title: "Delete…", symbol: "trash", isDestructive: true) { [weak model, requests, thread] in
            guard model != nil else { return }
            requests.delete = thread
        })
        return items
    }
}

private struct SidebarHeaderLayout: ViewModifier {
    static let glyphWidth: CGFloat = 13
    var topSpacing: CGFloat = 17

    func body(content: Content) -> some View {
        content
            // The list contributes the remaining 1pt between items.
            .padding(.top, topSpacing)
            .padding(.bottom, 3)
    }
}

private struct SidebarHeaderButton: View {
    let symbol: String
    var hitSize: CGFloat = Chrome.capsuleHeight
    let help: String
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(Chrome.iconFont)
                // The same ink as the toolbar's other glyphs (ChromeIconLabel, ChromeCircleButton).
                .foregroundStyle(Chrome.primaryText.opacity(isHovering ? 1 : 0.92))
                .frame(width: hitSize, height: hitSize)
                .background {
                    if isHovering, hitSize == Chrome.capsuleHeight {
                        Circle()
                            .fill(Chrome.overlay(0.08))
                            .shadow(color: Chrome.primaryText.opacity(0.1), radius: Chrome.capsuleVerticalPadding * 2, y: Chrome.capsuleVerticalPadding)
                            .padding(1)
                    }
                }
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(Text(verbatim: Chrome.localized(help)))
        .accessibilityLabel(Text(verbatim: Chrome.localized(help)))
        .background { NoWindowDragArea() }
        .onHover { hovering in
            withAnimation(Chrome.hover) { isHovering = hovering }
        }
    }
}

private struct ActivityHeader: View {
    let title: String

    var body: some View {
        Text(verbatim: Chrome.localized(title))
            .font(.ui(.callout, weight: .semibold))
            .foregroundStyle(Chrome.secondaryText)
            .padding(.horizontal, Chrome.rowHorizontalPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .modifier(SidebarHeaderLayout())
    }
}

@MainActor
func threadActivityStatus(_ thread: ChatThread, runtime: ThreadRuntime?) -> ThreadActivityStatus {
    ThreadActivityStatus.resolve(
        lastStatus: thread.unreadStatus ?? thread.lastStatus,
        hasUnread: thread.hasUnread,
        needsApproval: !(runtime?.approvals.isEmpty ?? true),
        needsAnswer: !(runtime?.questions.isEmpty ?? true),
        isWorking: runtime?.isRunning == true || runtime?.isHydraMerging == true || runtime?.hasWorkingHelpers == true || !(runtime?.backgroundTasks.isEmpty ?? true) || runtime?.isWaitingForLimit == true
    )
}

/// A row's latest frame, kept out of SwiftUI's observation: scrolling updates it on every frame,
/// and only an archive tap ever reads it. Writes skip when unchanged, so a resize frame
/// that moved nothing in the row costs nothing.
private final class FrameHolder {
    var frame: CGRect = .zero

    func note(_ frame: CGRect) {
        guard frame != self.frame else { return }
        self.frame = frame
    }
}

/// Every row's measured height, kept out of observation for the same reason: the list writes
/// one on every layout pass, and only a drag reads them. Unchanged reports are skipped,
/// so a width-only pass never touches the table.
private final class RowHeights {
    var values: [String: CGFloat] = [:]

    func note(_ id: String, _ height: CGFloat) {
        guard values[id] != height else { return }
        values[id] = height
    }
}

/// Every row's frame in the list's space, kept out of observation like the
/// heights: the rows write as they lay out, and only the grab of a drag reads them.
private final class RowFrames {
    private var frames: [UUID: CGRect] = [:]

    func note(_ id: UUID, _ frame: CGRect) {
        guard frames[id] != frame else { return }
        frames[id] = frame
    }

    func forget(_ id: UUID) {
        frames[id] = nil
    }

    func frame(of id: UUID) -> CGRect? {
        frames[id]
    }

    /// The row under `point`, if a visible one is.
    func row(at point: CGPoint) -> UUID? {
        frames.first { $0.value.contains(point) }?.key
    }
}

/// Search hits belonging to a project, or to Tasks when the project is nil.
private struct SidebarSearchResult: Identifiable {
    let project: Project?
    let threads: [ChatThread]
    let count: Int

    var id: String { project.map { "project-\($0.id)" } ?? "tasks" }
}

/// An unchanged thread revision skips the full fingerprint. On a metadata change the
/// fingerprint still covers every placement field, preserving the narrower cache hit.
private final class PlacementCache {
    private struct Fingerprint: Equatable {
        let id: UUID
        let projectID: UUID?
        let parentThreadID: UUID?
        let isArchived: Bool
        let isInPanel: Bool
        let isPinned: Bool
        let sortOrder: Double?
        let activityOrder: Double?
        let activityOrderDay: Date?
        let createdAt: Date
        let updatedAt: Date
        let foldsHelpers: Bool
        let isHydraHead: Bool
        let hydraIndex: Int?
        let hasUnread: Bool

        init(_ thread: ChatThread) {
            id = thread.id
            projectID = thread.projectID
            parentThreadID = thread.parentThreadID
            isArchived = thread.isArchived
            isInPanel = thread.isInPanel
            isPinned = thread.isPinned
            sortOrder = thread.sortOrder
            activityOrder = thread.activityOrder
            activityOrderDay = thread.activityOrderDay
            createdAt = thread.createdAt
            updatedAt = thread.updatedAt
            foldsHelpers = thread.foldsHelpers
            isHydraHead = thread.isHydraHead
            hydraIndex = thread.hydra?.index
            hasUnread = thread.hasUnread
        }
    }

    private weak var source: AppModel?
    private var revision: UInt64?
    private var fingerprint: [Fingerprint]?
    private var cached: [ThreadPlacement] = []

    @MainActor
    func placements(for model: AppModel) -> [ThreadPlacement] {
        let nextRevision = model.threadsRevision
        if source === model, revision == nextRevision { return cached }
        // Both collection replacement and updateThread advance this revision, including unread changes.
        source = model
        revision = nextRevision
        let threads = model.threads
        let next = threads.map(Fingerprint.init)
        if next == fingerprint { return cached }
        fingerprint = next
        cached = threads.map(ThreadPlacement.init)
        return cached
    }
}

/// The fields that decide where a thread sits in the list and how its group is ordered:
/// which project or parent it is under, whether it is shown at all, pinned or
/// folded, unread, and the dates and orders the sorts read. A title or a head's
/// progress note changes none of them, so those never rebuild the list; the rows read
/// them through the model's per-thread cells instead.
private struct ThreadPlacement: Equatable {
    let id: UUID
    let projectID: UUID?
    let parentThreadID: UUID?
    let isArchived: Bool
    let isInPanel: Bool
    let isPinned: Bool
    let sortOrder: Double?
    /// The activity layout's own order within a day (see `placed`).
    let activityOrder: Double?
    let activityOrderDay: Date?
    let createdAt: Date
    let updatedAt: Date
    let foldsHelpers: Bool
    let isHydraHead: Bool
    let hydraIndex: Int?
    let hasUnread: Bool

    init(_ thread: ChatThread) {
        id = thread.id
        projectID = thread.projectID
        parentThreadID = thread.parentThreadID
        isArchived = thread.isArchived
        isInPanel = thread.isInPanel
        isPinned = thread.isPinned
        sortOrder = thread.sortOrder
        activityOrder = thread.activityOrder
        activityOrderDay = thread.activityOrderDay
        createdAt = thread.createdAt
        updatedAt = thread.updatedAt
        foldsHelpers = thread.foldsHelpers
        isHydraHead = thread.isHydraHead
        hydraIndex = thread.hydra?.index
        hasUnread = thread.hasUnread
    }
}

/// The sidebar's built list, kept while its inputs stand, the way `TimelineBlockCache`
/// keeps a chat's blocks. The key holds each thread's placement (not the thread: a title
/// or a progress note is the row's to pick up) and the project array itself, so a render
/// that moved nothing costs one pass of comparisons and no filter or sort, and one that
/// did rebuilds exactly once. Owned by the list's @State, main thread only.
private final class SidebarItemCache {
    struct Key: Equatable {
        var placements: [ThreadPlacement]
        var projects: [Project]
        var reordersProjects: Bool
        var todayFocus: Bool
        var todayTick: Date?
        var projectsCollapsed: Bool
        var tasksCollapsed: Bool
        /// The tasks heading their section under "Needs attention".
        var attention: Set<UUID>
        /// Parents whose cards or folded summaries include heads.
        var parentsShowingHeads: Set<UUID>
    }

    struct SearchKey: Equatable {
        var threads: [ChatThread]
        var projects: [Project]
        var query: String
    }

    private var key: Key?
    private var built: [SidebarItem] = []
    private var helpersFor: [ThreadPlacement]?
    private var helpers: [UUID: [ChatThread]] = [:]
    private var tasksFor: [ThreadPlacement]?
    private var standaloneTasks: [ChatThread] = []
    private var searchKey: SearchKey?
    private var found: [SidebarSearchResult] = []
    /// Each thread's title lowercased once, for the search to match against; a thread
    /// keeps its entry until its title changes.
    private var titlesFor: [ChatThread]?
    private var titles: [UUID: String] = [:]

    func items(for wanted: Key, build: () -> [SidebarItem]) -> [SidebarItem] {
        if wanted == key { return built }
        built = build()
        key = wanted
        return built
    }

    func tasks(for placements: [ThreadPlacement], find: () -> [ChatThread]) -> [ChatThread] {
        if placements == tasksFor { return standaloneTasks }
        standaloneTasks = find()
        tasksFor = placements
        return standaloneTasks
    }

    /// The helper grouping, kept while the placements stand; `group` runs only when they changed.
    func helpers(for placements: [ThreadPlacement], group: () -> [UUID: [ChatThread]]) -> [UUID: [ChatThread]] {
        if placements == helpersFor { return helpers }
        helpers = group()
        helpersFor = placements
        return helpers
    }

    func search(for wanted: SearchKey, find: ([UUID: String]) -> [SidebarSearchResult]) -> [SidebarSearchResult] {
        if wanted == searchKey { return found }
        found = find(lowercasedTitles(for: wanted.threads))
        searchKey = wanted
        return found
    }

    private func lowercasedTitles(for threads: [ChatThread]) -> [UUID: String] {
        if threads == titlesFor { return titles }
        var next: [UUID: String] = [:]
        next.reserveCapacity(threads.count)
        // Only a title that changed is lowercased again; the rest carry over.
        let previous = titlesFor.map { Dictionary($0.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first }) } ?? [:]
        for thread in threads {
            if previous[thread.id] == thread.title, let kept = titles[thread.id] {
                next[thread.id] = kept
            } else {
                next[thread.id] = thread.title.lowercased()
            }
        }
        titles = next
        titlesFor = threads
        return titles
    }
}

/// The minute hand behind the sidebar's relative times. One tick for the whole list, read by
/// the time labels and nothing else, so an idle app keeps "3m" truthful without re-rendering
/// the rows around it.
@MainActor
@Observable
final class MinuteClock {
    static let shared = MinuteClock()

    private(set) var now = Date.now

    @ObservationIgnored private var tick: Task<Void, Never>?

    private init() {
        tick = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard let self else { return }
                self.now = .now
            }
        }
    }
}

/// The project or task a thread belongs to, at the trailing end of its row in today focus.
/// The time it was last active moves to the tooltip.
private struct SidebarTagLabel: View {
    static let maxWidth: CGFloat = 76
    let text: String
    let date: Date

    var body: some View {
        Text(verbatim: text)
            .font(.ui(.subheadline))
            .foregroundStyle(Chrome.secondaryText.opacity(0.8))
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: Self.maxWidth, alignment: .trailing)
            .padding(.trailing, Chrome.rowHorizontalPadding - 6)
            .help(Text(verbatim: "\(text) · \(RelativeTime.short(date, now: .now))"))
    }
}

/// How long ago a thread was last active, at the trailing end of its row. A view of its own,
/// so the minute's tick re-renders this label alone.
private struct RelativeTimeLabel: View {
    let date: Date

    var body: some View {
        Text(verbatim: RelativeTime.short(date, now: MinuteClock.shared.now))
            .font(.ui(.subheadline).monospacedDigit())
            .foregroundStyle(Chrome.secondaryText.opacity(0.8))
            .padding(.trailing, Chrome.rowHorizontalPadding - 6)
    }
}
