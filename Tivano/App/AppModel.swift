import AppKit
import SwiftUI
import UserNotifications

struct AppAlert: Identifiable {
    let id = UUID()
    var title: String
    var message: String
}

/// The app's library of projects and threads, plus everything that spans threads.
@MainActor
@Observable
final class AppModel {
    let settings: AppSettings
    let providers: ProviderRegistry
    /// The user's MCP connections, handed to every provider session at launch.
    let mcp: MCPStore
    let terminals: TerminalStore
    let sidebar: SidebarLayout
    /// Picks chats back up once a spent usage limit resets, with the setting on.
    @ObservationIgnored private(set) var autoContinue: AutoContinue!
    /// How often each Tivano-run head has been started again after failing at the door
    /// (see `hydraHeadTurnFinished`); a head gets two more goes.
    @ObservationIgnored var hydraHeadRetries: [UUID: Int] = [:]

    /// The lists are the source of truth for anything that shows several items at once. Single
    /// lookups go through the cells below, so the timeline rows, composer and chat header of one
    /// thread are left alone when another thread's title, status or unread flag changes.
    private(set) var projects: [Project] = [] {
        didSet { Self.write(Self.sync(&projectCells, with: projects)) }
    }
    @ObservationIgnored private var threadStorage: [ChatThread] = []
    private(set) var threadsRevision: UInt64 = 0
    private(set) var threads: [ChatThread] {
        get {
            _ = threadsRevision
            return threadStorage
        }
        set {
            threadStorage = newValue
            synchronizeThreads()
        }
    }

    private func synchronizeThreads() {
        // Finish storage/index borrows before any observed write can rebuild Commands.
        threadIndex = ThreadIndex(threadStorage)
        let writes = Self.sync(&threadCells, with: threadStorage)
        Self.write(writes)
        syncChildCells()
        threadsRevision &+= 1
    }
    private var threadIndex = ThreadIndex([])

    /// Where each thread sits in `threads`, and each project's threads by position, so a
    /// lookup or an update never scans the list.
    private struct ThreadIndex {
        var positions: [UUID: Int] = [:]
        var projects: [UUID: [Int]] = [:]

        init(_ threads: [ChatThread]) {
            positions.reserveCapacity(threads.count)
            for (index, thread) in threads.enumerated() {
                if positions[thread.id] == nil { positions[thread.id] = index }
                projects[thread.projectID, default: []].append(index)
            }
        }
    }
    @ObservationIgnored private var projectCells: [UUID: ObservedValue<Project?>] = [:]
    @ObservationIgnored private var threadCells: [UUID: ObservedValue<ChatThread?>] = [:]
    /// The children of one thread, by that thread's id: the ids alone, so a view showing a
    /// chat's panels depends on which children it has and on each of those children, never
    /// on the rest of the library. A head's status write leaves every other chat alone.
    @ObservationIgnored private var childCells: [UUID: ObservedValue<[UUID]>] = [:]
    /// Whether one thread is the selected one, observed on its own: a sidebar row reads its
    /// flag here rather than `selectedThreadID`, so a selection change re-renders the row
    /// that lost it and the row that gained it, not every row in the list.
    @ObservationIgnored private var selectionCells: [UUID: ObservedValue<Bool>] = [:]
    var selectedThreadID: UUID? {
        didSet {
            if oldValue != selectedThreadID {
                if let oldValue { selectionCells[oldValue]?.value = false }
                if let selectedThreadID { selectionCell(selectedThreadID).value = true }
                SwitchLatency.noteSwitch(to: selectedThreadID.flatMap(thread)?.title ?? "none")
            }
            if let selectedThreadID {
                // A helper or head under the selected thread is on screen with it, so
                // reading the thread reads them too; otherwise their unread mark would
                // stick on the dock after the thread that set it is back in view.
                // The write waits for the selection to paint, so the click itself
                // never rewrites the library.
                let ids = [selectedThreadID] + children(of: selectedThreadID).map(\.id)
                Task { @MainActor [weak self] in self?.markRead(ids) }
            }
            if oldValue != selectedThreadID {
                scheduleIdleSessionStop(leaving: oldValue)
                if let id = selectedThreadID {
                    Task { @MainActor [weak self] in self?.warmNeighbors(of: id) }
                }
            }
            if let selectedThreadID, let thread = thread(selectedThreadID) {
                rememberLastProject(thread.projectID)
            }
        }
    }

    /// The thread the sidebar should bring into view on its next pass, set when a thread
    /// lands somewhere new (moved to another project from the new-thread prompt, say): the
    /// list scrolls to that row and clears this. Never persisted, and nil at rest.
    var sidebarRevealThreadID: UUID?

    var isCommandPalettePresented = false
    var alert: AppAlert?

    @ObservationIgnored private var runtimes: [UUID: ThreadRuntime] = [:]
    @ObservationIgnored private var runtimeLastAccess: [UUID: ContinuousClock.Instant] = [:]
    @ObservationIgnored private var runtimeCapacityScheduled = false
    @ObservationIgnored private var idleSessionStops: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var lastLibrarySave: ContinuousClock.Instant?
    /// The repeating merge sweep started at bootstrap. A chat whose automatic merge never
    /// got its moment while the app stayed open (a report batch left half-finished, a
    /// dialog never answered, a turn that ended in a way the trigger skipped) would sit on
    /// its files forever, with the merge note still promising they go out. The sweep asks
    /// again every few minutes; it skips anything still running, so a busy chat is left alone.
    @ObservationIgnored private var hydraMergeSweepTask: Task<Void, Never>?
    private(set) var isLibraryLoaded = false
    @ObservationIgnored private var libraryLoad: Task<Library, Never>?
    @ObservationIgnored private var restoreSelectionAfterLoad = false
    @ObservationIgnored private var persistenceEnabled = true
    @ObservationIgnored private var didRequestNotifications = false

    init() {
        settings = AppSettings()
        providers = ProviderRegistry(settings: settings)
        mcp = MCPStore()
        terminals = TerminalStore()
        sidebar = SidebarLayout()
        autoContinue = AutoContinue(app: self)
    }

    /// Mirrors a list into its cells: values that changed are written to their cell (and only
    /// those, so an untouched item's observers never fire), new items get a cell, and a removed
    /// item's cell is emptied as it goes, so whoever was showing it re-renders to nothing.
    ///
    /// Only the dictionary is settled here; the cell writes are handed back for `write` to make
    /// once the caller's exclusive access to the dictionary is over. A cell write is observed,
    /// and inside `withAnimation` SwiftUI rebuilds the menu bar's commands on the spot, from
    /// within the write: they read the selected thread back through `thread(_:)`, which traps
    /// on exclusivity if the dictionary is still borrowed then.
    private static func sync<Value: Identifiable & Equatable>(
        _ cells: inout [Value.ID: ObservedValue<Value?>],
        with values: [Value]
    ) -> [(cell: ObservedValue<Value?>, value: Value?)] {
        var writes: [(cell: ObservedValue<Value?>, value: Value?)] = []
        var seen = Set<Value.ID>(minimumCapacity: values.count)
        for value in values {
            seen.insert(value.id)
            if let cell = cells[value.id] {
                if cell.value != value { writes.append((cell, value)) }
            } else {
                cells[value.id] = ObservedValue(value)
            }
        }
        guard cells.count != seen.count else { return writes }
        for (id, cell) in cells where !seen.contains(id) {
            writes.append((cell, nil))
            cells[id] = nil
        }
        return writes
    }

    /// Makes the writes `sync` handed back, with no access to the cell dictionaries open.
    private static func write<Value>(_ writes: [(cell: ObservedValue<Value?>, value: Value?)]) {
        for (cell, value) in writes { cell.value = value }
    }

    /// Mirrors who hangs under whom into the child cells, with the same no-op-write
    /// discipline as the item cells: a parent whose children are unchanged is not written,
    /// so the chat showing them is left alone. A parent that still exists keeps its cell
    /// even with nothing under it, because that is exactly the cell a chat with no heads
    /// yet is watching for its first one; only a parent that is gone loses its cell.
    private func syncChildCells() {
        var children: [UUID: [UUID]] = [:]
        for thread in threads {
            guard let parent = thread.parentThreadID else { continue }
            children[parent, default: []].append(thread.id)
        }
        for (parent, cell) in childCells {
            let ids = children[parent] ?? []
            if cell.value != ids { cell.value = ids }
        }
        for (parent, ids) in children where childCells[parent] == nil {
            childCells[parent] = ObservedValue(ids)
        }
        guard childCells.count != children.count else { return }
        let live = Set(threads.map(\.id))
        for parent in childCells.keys where !live.contains(parent) && children[parent] == nil {
            childCells[parent] = nil
        }
    }

    /// The ids under a thread, observed on their own. A thread with nothing under it yet
    /// gets its cell here, on the first read, so the caller hears about the first child
    /// that arrives; the cell is not observed state, so making it re-renders nothing.
    private func childIDs(of parentID: UUID) -> [UUID] {
        if let cell = childCells[parentID] { return cell.value }
        let cell = ObservedValue<[UUID]>([])
        childCells[parentID] = cell
        return cell.value
    }

    /// A thread's selection cell, made on the first ask; the cell is not observed state, so
    /// making it re-renders nothing.
    private func selectionCell(_ id: UUID) -> ObservedValue<Bool> {
        if let cell = selectionCells[id] { return cell }
        let cell = ObservedValue(selectedThreadID == id)
        selectionCells[id] = cell
        return cell
    }

    /// Whether the thread is selected, depending on this thread's flag alone.
    func isSelected(_ id: UUID) -> Bool {
        selectionCell(id).value
    }

    /// The threads under a thread, each read through its own cell: the caller depends on
    /// which children this thread has and on those children alone.
    func children(of parentID: UUID) -> [ChatThread] {
        childIDs(of: parentID).compactMap(thread)
    }

    func bootstrap() async {
        guard !isLibraryLoaded else { return }
        if let libraryLoad {
            _ = await libraryLoad.value
            return
        }
        let load = Task.detached(priority: .userInitiated) { Storage.loadLibrary() }
        libraryLoad = load
        var library = await load.value
        let originalThreads = library.threads
        for index in library.threads.indices where !CaptureRun.isEnabled && (library.threads[index].lastStatus == .running || library.threads[index].hydra?.status == .running) {
            if library.threads[index].lastStatus == .running {
                library.threads[index].lastStatus = .interrupted
            }
            if library.threads[index].hydra?.status == .running {
                library.threads[index].hydra?.status = .stopped
                library.threads[index].hydra?.finishedAt = .now
            }
        }
        // Anything made in the moments before the library landed (a project opened from
        // the Finder, a chat from the menu) joins it rather than being written over.
        let knownProjects = Set(library.projects.map(\.id))
        let knownThreads = Set(library.threads.map(\.id))
        projects = library.projects + projects.filter { !knownProjects.contains($0.id) }
        threads = library.threads + threads.filter { !knownThreads.contains($0.id) }
        isLibraryLoaded = true
        libraryLoad = nil
        if threads != originalThreads || projects != library.projects { scheduleSave() }
        // Capture seeds retain their staged statuses and never start account or merge services.
        if CaptureRun.isEnabled { return }
        if let lastID = settings.lastProjectID, project(lastID) == nil {
            settings.lastProjectID = nil
        }
        if restoreSelectionAfterLoad { openThreadOnLaunch() }
        // The threads most likely to be opened first decode in the background from the start,
        // so the first click into a conversation never parses its history on the main thread.
        let recent = threads.filter { !$0.isArchived && !$0.isInPanel }.sorted { $0.updatedAt > $1.updatedAt }.prefix(12).map(\.id)
        warmDocuments(recent)
        await settings.loadKeychainInBackground()
        await LoginEnvironment.load()
        // Needs the login PATH for gh and gives every later process the account's token.
        GitHubConnection.shared.start()
        // After the login environment, so git runs with the user's PATH.
        sweepHydraCopies()
        // A merge the last run did not finish (the app was quit under it) goes out now.
        await resumeHydraMerges()
        // The launch sweep alone is not enough: a merge can also be missed while the app
        // stays up, and then nothing asks again until the next launch. This task asks every
        // five minutes for as long as the app runs; the sweep itself skips chats with a turn
        // or a head still running, so it is safe to repeat.
        hydraMergeSweepTask?.cancel()
        hydraMergeSweepTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(300))
                guard !Task.isCancelled, let self else { return }
                await self.resumeHydraMerges()
            }
        }
        await providers.refreshAll()
        // The catalogs a fresh install starts without, or with only a seed of: one CLI and
        // two HTTPS calls, overlapped. Claude's brings its slash commands too, so the picker
        // and the composer are complete before any turn.
        await withTaskGroup(of: Void.self) { group in
            for provider in [ProviderKind.claude, .codex, .deepseek, .meta] where providers.status(provider).isInstalled {
                group.addTask { await self.providers.loadCatalog(provider) }
            }
        }
        if providers.status(.zai).isInstalled {
            await providers.loadCatalog(.zai)
        }
        // The CLIs Tivano runs headless never update themselves, and a model newer
        // than the installed CLI fails outright. Their own updaters run here, in the
        // background, at most every twelve hours; a newer version reloads its catalog.
        Task { [providers] in
            for provider in [ProviderKind.claude, .codex] where providers.status(provider).isInstalled {
                await providers.updateCLIIfDue(provider)
            }
        }
        // Last, once nothing the first click needs is waiting on the disk: the attachment
        // files no thread refers to any more go, a day after they were written.
        await Storage.sweepOrphanedAttachments()
    }

    // MARK: - Lookup

    /// One project, observed on its own: only a change to this project re-renders the caller.
    func project(_ id: UUID) -> Project? {
        projectCells[id]?.value ?? nil
    }

    /// One thread, observed on its own: only a change to this thread re-renders the caller.
    func thread(_ id: UUID) -> ChatThread? {
        threadCells[id]?.value ?? nil
    }

    var selectedThread: ChatThread? {
        selectedThreadID.flatMap(thread)
    }

    var currentProject: Project? {
        if let selectedThread, let current = project(selectedThread.projectID) { return current }
        if let lastID = settings.lastProjectID, let last = project(lastID) { return last }
        // No selection (for example after relaunch): stay in the folder you last worked in
        // instead of jumping back to the first project ever added.
        if let recent = threads.filter({ !$0.isArchived && !$0.isInPanel }).max(by: { $0.updatedAt < $1.updatedAt }),
           let recentProject = project(recent.projectID) { return recentProject }
        return projects.first
    }

    private func rememberLastProject(_ id: UUID) {
        guard project(id) != nil else { return }
        if settings.lastProjectID != id { settings.lastProjectID = id }
    }

    /// The project's top-level threads, in sidebar order: the settled ones last, latest
    /// settled first. A helper whose parent is among them sits under that parent instead
    /// (see `helpers(of:)`); an ordinary helper whose parent is gone or archived stands
    /// on its own. Hydra heads only appear under their lead, even across projects.
    func threads(in project: Project) -> [ChatThread] {
        let shown = (threadIndex.projects[project.id] ?? []).map { threads[$0] }
            .filter(\.isStandaloneListCandidate)
        let shownIDs = Set(shown.map(\.id))
        return shown
            .filter { $0.parentThreadID.map { !shownIDs.contains($0) } ?? true }
            .sorted { lhs, rhs in
                if lhs.isSettled != rhs.isSettled { return rhs.isSettled }
                if lhs.isSettled { return Self.settledFirst(lhs, rhs) }
                if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
                switch (lhs.sortOrder, rhs.sortOrder) {
                case let (left?, right?) where left != right: return left < right
                // Threads created after a reorder have no place yet and stay on top.
                case (nil, .some): return true
                case (.some, nil): return false
                default: return lhs.createdAt > rhs.createdAt
                }
            }
    }

    /// Places a thread directly above or below another thread in the same project.
    /// Places a thread directly above or below another in its project. Returns whether the
    /// order changed, for a live drag that swaps one neighbour at a time.
    @discardableResult
    func moveThread(_ id: UUID, to targetID: UUID, placeAfter: Bool) -> Bool {
        guard id != targetID, let moving = thread(id), let target = thread(targetID),
              moving.projectID == target.projectID, let project = project(moving.projectID),
              !moving.isSettled, !target.isSettled else { return false }
        let before = threads(in: project).filter { !$0.isSettled }.map(\.id)
        var order = before
        order.removeAll { $0 == id }
        guard let index = order.firstIndex(of: targetID) else { return false }
        order.insert(id, at: placeAfter ? index + 1 : index)
        guard order != before else { return false }
        updateThreads(order) { position, thread in
            if thread.id == id { thread.isPinned = target.isPinned }
            thread.sortOrder = Double(position)
        }
        return true
    }

    /// Places a thread directly above or below another within the same group of the activity
    /// layout. Returns whether the order changed.
    @discardableResult
    func moveInActivity(_ id: UUID, to targetID: UUID, placeAfter: Bool, among peers: [UUID]) -> Bool {
        guard id != targetID, peers.contains(id), peers.contains(targetID) else { return false }
        var order = peers
        order.removeAll { $0 == id }
        guard let index = order.firstIndex(of: targetID) else { return false }
        order.insert(id, at: placeAfter ? index + 1 : index)
        guard order != peers else { return false }
        let calendar = Calendar.current
        updateThreads(order) { position, thread in
            thread.activityOrder = Double(position)
            thread.activityOrderDay = calendar.startOfDay(for: thread.updatedAt)
        }
        return true
    }

    var archivedThreads: [ChatThread] {
        threads.filter(\.isArchived).sorted { $0.updatedAt > $1.updatedAt }
    }

    /// The order among settled threads: the one settled last comes first.
    nonisolated static func settledFirst(_ lhs: ChatThread, _ rhs: ChatThread) -> Bool {
        (lhs.settledAt ?? lhs.updatedAt) > (rhs.settledAt ?? rhs.updatedAt)
    }

    /// Threads in the order the sidebar shows them, for keyboard navigation: each thread
    /// followed by the helpers under it, unless they are folded away.
    var sidebarThreads: [ChatThread] {
        projects.filter(\.isExpanded).flatMap { project in
            threads(in: project).flatMap { thread in
                thread.foldsHelpers || thread.isSettled ? [thread] : [thread] + helpers(of: thread.id)
            }
        }
    }

    /// The helpers that sit under a thread in the sidebar: spawned from it and not archived.
    /// Heads are there from the moment they go out, still in the lead's panel or not, so a
    /// chat with a team at work shows it; a helper popped out into its own panel is the
    /// one kind that leaves the list. Newest first, like the threads around them.
    func helpers(of parentID: UUID) -> [ChatThread] {
        children(of: parentID)
            .filter { !$0.isArchived && (!$0.isInPanel || $0.isHydraHead) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    /// The heads a lead still shows in its floating panel, in the order they were sent out.
    /// The same list as `hydraHeads(of:)`, read through this thread's own cells: a write to
    /// a head of some other chat never re-renders this one.
    func panelHeads(of parentID: UUID) -> [ChatThread] {
        children(of: parentID)
            .filter { $0.isInPanel && !$0.isArchived && $0.isHydraHead }
            // A head sits in its roster place, in the order they were sent out.
            .sorted {
                let places = ($0.hydra?.index ?? Int.max, $1.hydra?.index ?? Int.max)
                return places.0 == places.1 ? $0.createdAt < $1.createdAt : places.0 < places.1
            }
    }

    /// The helper a thread spawned and still shows in its floating panel, if any, read
    /// through this thread's own cells. Heads have a panel of their own (`panelHeads(of:)`).
    func panelSubagent(of parentID: UUID) -> ChatThread? {
        children(of: parentID).first { $0.isInPanel && !$0.isArchived && !$0.isHydraHead }
    }

    func toggleHelpersFold(_ parentID: UUID) {
        updateThread(parentID) { $0.foldsHelpers.toggle() }
    }

    func runtime(for id: UUID) -> ThreadRuntime {
        runtimeLastAccess[id] = ContinuousClock.now
        if let runtime = runtimes[id] { return runtime }
        let runtime = ThreadRuntime(threadID: id, app: self)
        runtimes[id] = runtime
        if !runtimeCapacityScheduled {
            runtimeCapacityScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.runtimeCapacityScheduled = false
                self.releaseExcessIdleRuntimes()
            }
        }
        return runtime
    }

    private func releaseExcessIdleRuntimes() {
        guard runtimes.count > 12 else { return }
        let fallback = ContinuousClock.now
        let candidates = runtimes.keys.sorted {
            (runtimeLastAccess[$0] ?? fallback) < (runtimeLastAccess[$1] ?? fallback)
        }
        for id in candidates {
            guard runtimes.count > 12 else { break }
            releaseIdleRuntime(id)
        }
    }

    func existingRuntime(for id: UUID) -> ThreadRuntime? {
        runtimes[id]
    }

    /// Every runtime alive right now, for checks that span chats (a merge still in flight at quit).
    var liveRuntimes: [ThreadRuntime] { Array(runtimes.values) }

    /// Decodes threads' histories ahead of time, off the main thread, so opening one costs no
    /// parse on the click. Threads already open have their history in memory and are skipped.
    func warmDocuments(_ ids: [UUID]) {
        let cold = ids.filter { runtimes[$0] == nil }
        guard !cold.isEmpty else { return }
        DocumentPrefetch.shared.warm(cold)
    }

    /// The rows either side of the selection within the thread's project, for the
    /// arrow keys and the next click.
    private func warmNeighbors(of id: UUID?) {
        warmDocuments(neighbors(of: id))
    }

    /// The rows either side of a thread within its project: what the arrow keys and the
    /// next click are most likely to open.
    func neighbors(of id: UUID?) -> [UUID] {
        guard let id, let thread = thread(id), let project = project(thread.projectID) else { return [] }
        let order = threads(in: project)
        guard let index = order.firstIndex(where: { $0.id == id }) else { return [] }
        var neighbors: [UUID] = []
        if index > 0 { neighbors.append(order[index - 1].id) }
        if index + 1 < order.count { neighbors.append(order[index + 1].id) }
        return neighbors
    }

    /// A thread left alone for ten minutes gives its agent process back, and its history
    /// with it when nothing but the saved document would be lost: the runtime goes, and
    /// opening the thread again reads it back from disk, with the provider session id on
    /// the thread resuming the conversation. A thread with a draft, an edit under way, work
    /// still owed to it or a terminal keeps its runtime, session stopped.
    private func scheduleIdleSessionStop(leaving id: UUID?) {
        guard isLibraryLoaded else { return }
        if let selectedThreadID {
            idleSessionStops.removeValue(forKey: selectedThreadID)?.cancel()
        }
        guard let id, runtimes[id] != nil else { return }
        idleSessionStops[id]?.cancel()
        idleSessionStops[id] = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(600))
                guard !Task.isCancelled, let self, self.selectedThreadID != id, let runtime = self.runtimes[id] else { return }
                // A turn still working keeps its session; check again after the next interval.
                guard !runtime.isRunning else { continue }
                runtime.stopSession()
                self.idleSessionStops[id] = nil
                self.releaseIdleRuntime(id)
                return
            }
        }
    }

    /// Drops an idle thread's runtime once its document is on its way to disk. Returns
    /// whether it did; a runtime holding anything the document does not stays.
    @discardableResult
    func releaseIdleRuntime(_ id: UUID) -> Bool {
        guard let runtime = runtimes[id], selectedThreadID != id, let thread = thread(id),
              // A thread shown beside the selection, in its panel, is on screen.
              thread.parentThreadID == nil || thread.parentThreadID != selectedThreadID,
              !thread.isInPanel, thread.hydra?.status != .running,
              !runtime.isRunning, runtime.draft.isEmpty, runtime.followUps.isEmpty,
              runtime.holdsOnlyPersistedState, !sessionsToRelease.contains(id),
              autoContinue.resumesAt[id] == nil, terminals.sessions(for: id).isEmpty,
              !children(of: id).contains(where: {
                  $0.hydra?.status == .running || existingRuntime(for: $0.id)?.isRunning == true
              }) else { return false }
        // The save is queued before the runtime goes; a read that follows waits for it
        // (see `Storage.readDocument`), so the thread can never come back older than it left.
        runtime.saveNow()
        runtime.cancelPersistence()
        runtimes[id] = nil
        runtimeLastAccess[id] = nil
        idleSessionStops.removeValue(forKey: id)?.cancel()
        return true
    }

    var workingDirectory: String? {
        guard let thread = selectedThread, let project = project(thread.projectID) else { return nil }
        return thread.worktreePath ?? project.path
    }

    // MARK: - Projects

    @discardableResult
    func addProject(at url: URL) -> Project {
        let path = url.standardizedFileURL.path
        if let existing = projects.first(where: { $0.path == path }) { return existing }
        var project = Project(name: url.lastPathComponent, path: path)
        project.scripts = ProjectFile.scripts(at: url)
        projects.append(project)
        scheduleSave()
        return project
    }

    func chooseProjectFolder() {
        guard let added = addProjectsFromPanel() else { return }
        newThread(in: added)
    }

    /// The folder panel: every chosen folder joins the sidebar as a project and the last
    /// one added comes back, or nil when the panel was cancelled. Nothing else is made
    /// here, so a caller that already has a thread on screen (the new-thread prompt) can
    /// move that thread into the folder instead of leaving a second empty thread behind.
    @discardableResult
    func addProjectsFromPanel() -> Project? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add project"
        panel.message = "Choose a folder for your agents to work in."
        guard panel.runModal() == .OK else { return nil }
        var added: Project?
        for url in panel.urls { added = addProject(at: url) }
        return added
    }

    func updateProject(_ id: UUID, _ change: (inout Project) -> Void) {
        guard let index = projects.firstIndex(where: { $0.id == id }) else { return }
        var project = projects[index]
        change(&project)
        guard project != projects[index] else { return }
        projects[index] = project
        scheduleSave()
    }

    func removeProject(_ project: Project) {
        for thread in threads where thread.projectID == project.id {
            discardThreadState(thread)
        }
        threads.removeAll { $0.projectID == project.id }
        projects.removeAll { $0.id == project.id }
        if settings.lastProjectID == project.id { settings.lastProjectID = nil }
        if selectedThread == nil { selectedThreadID = nil }
        scheduleSave()
    }

    // MARK: - Threads

    /// Restores the most relevant existing chat in the last project without making launch
    /// an implicit "New thread" action. A chat interrupted by the previous process wins;
    /// otherwise the last active user chat does. With no chat, the existing empty state
    /// remains on screen until the user explicitly starts one.
    func openThreadOnLaunch() {
        guard isLibraryLoaded else {
            restoreSelectionAfterLoad = true
            return
        }
        restoreSelectionAfterLoad = false
        guard let project = currentProject else { return }
        let restored = threads
            .filter {
                $0.projectID == project.id && !$0.isArchived && !$0.isInPanel && !$0.isHelper && !$0.isHydraHead
            }
            .max { lhs, rhs in
                let lhsInterrupted = lhs.lastStatus == .interrupted
                let rhsInterrupted = rhs.lastStatus == .interrupted
                if lhsInterrupted != rhsInterrupted { return !lhsInterrupted }
                return lhs.updatedAt < rhs.updatedAt
            }
        selectedThreadID = restored?.id
    }

    @discardableResult
    func newThread(in project: Project? = nil, workspace: WorkspaceMode? = nil) -> ChatThread? {
        guard let project = project ?? currentProject else {
            chooseProjectFolder()
            return nil
        }
        let thread = makeThread(in: project, carrying: selectedThread)
        threads.append(thread)
        updateProject(project.id) { $0.isExpanded = true }
        rememberLastProject(project.id)
        selectedThreadID = thread.id
        scheduleSave()
        if (workspace ?? settings.defaultWorkspaceMode) == .worktree {
            Task { await createWorktree(for: thread.id) }
        }
        return thread
    }

    /// Copies conversation context into an unsent thread with independent provider state.
    @discardableResult
    func forwardThread(_ sourceID: UUID) async -> ChatThread? {
        guard let source = thread(sourceID), project(source.projectID) != nil else { return nil }
        let sourceRuntime = runtime(for: sourceID)
        await sourceRuntime.ensureLoaded()
        // The source can be renamed or removed while its history loads.
        guard let resolved = thread(sourceID), let project = project(resolved.projectID) else { return nil }
        let continuation = ThreadContinuation.capture(
            sourceID: sourceID,
            title: resolved.title,
            document: sourceRuntime.snapshotForPersistence()
        )
        var thread = makeThread(in: project, carrying: resolved)
        thread.title = "Continued: " + resolved.title
        thread.hasCustomTitle = true
        threads.append(thread)
        updateProject(project.id) { $0.isExpanded = true }
        rememberLastProject(project.id)
        let newRuntime = runtime(for: thread.id)
        guard await newRuntime.installContinuation(continuation), self.thread(thread.id) != nil else { return nil }
        selectedThreadID = thread.id
        scheduleSave()
        return thread
    }

    /// A chat as it would start in `project`: on `current`'s provider, model and pair when
    /// made from an open chat, otherwise on what was last used. Not yet in `threads`.
    private func makeThread(in project: Project, carrying current: ChatThread?) -> ChatThread {
        let installed = ProviderKind.allCases.filter { providers.status($0).isInstalled && settings.isEnabled($0) }
        // The project's own pair, when it has one, sets the provider before anything else.
        let projectPair = HydraPair.projectPair(project.hydraPairID, hydraOn: settings.hydraEnabled, in: hydraPickerPairs)
        // With no chat to carry from (a fresh launch), the pair last entered from the
        // picker is where the new chat starts. Before any pair has been entered since
        // this was remembered, the chat last worked in stands in: its pair if it led one,
        // and none if it had left its pair for a model of its own.
        let lastPairID = settings.lastHydraPairID
            ?? threads.filter { !$0.isHelper }.max { $0.updatedAt < $1.updatedAt }?.hydraPairID
        let lastPair = current == nil && settings.hydraEnabled
            ? lastPairID.flatMap { id in hydraPickerPairs.first { $0.id == id } }
            : nil
        var provider = projectPair?.provider ?? current?.provider ?? lastPair?.provider ?? settings.defaultProvider
        if !installed.isEmpty, !installed.contains(provider) { provider = installed[0] }
        // A chat that starts on the project's pair takes that pair's lead model. A pair with
        // no lead model keeps the current chat's model, as the picker does.
        let carriesModel = projectPair?.orchestratorModel == nil && current?.provider == provider
        let model = carriesModel ? current?.model : providers.defaultModel(for: provider)?.id
        let preference = settings.preference(for: provider, model: model)
        let effort = carriesModel ? current?.effort : (preference.effort ?? settings.lastEffort(for: provider))
        let fastMode = carriesModel ? (current?.fastMode ?? false) : preference.fastMode
        var thread = ChatThread(
            projectID: project.id,
            provider: provider,
            model: model,
            effort: effort,
            runtimeMode: settings.defaultRuntimeMode,
            fastMode: fastMode
        )
        // A chat made from one that leads a pair carries the pair along with the model.
        // With no chat to carry from, the last pair is where the new chat starts, on its
        // lead model and effort, provided its provider is still installed. The project's
        // pair wins over all of that: the user set it as the rule for this project, so
        // every new chat here starts on it.
        if let pair = projectPair {
            let lead = hydraLead(of: pair, for: thread)
            thread.model = lead.model
            thread.effort = lead.effort
            thread.fastMode = lead.fastMode
            thread.hydraPairID = pair.id
            thread.hydraEnabled = true
        } else if carriesModel {
            thread.hydraPairID = current?.hydraPairID
        } else if let pair = lastPair, pair.provider == provider {
            let lead = hydraLead(of: pair, for: thread)
            thread.model = lead.model
            thread.effort = lead.effort
            thread.fastMode = lead.fastMode
            thread.hydraPairID = pair.id
            thread.hydraEnabled = true
        }
        return thread
    }

    func updateThread(_ id: UUID, _ change: (inout ChatThread) -> Void) {
        guard let index = threadIndex.positions[id] else { return }
        let previous = threadStorage[index]
        var thread = previous
        change(&thread)
        guard thread != previous else { return }
        threadStorage[index] = thread
        if Self.structureChanged(previous, thread) {
            synchronizeThreads()
        } else {
            let cell = threadCells[id]
            cell?.value = thread
            threadsRevision &+= 1
        }
        scheduleSave()
    }

    private static func structureChanged(_ previous: ChatThread, _ thread: ChatThread) -> Bool {
        previous.id != thread.id || previous.projectID != thread.projectID
            || previous.parentThreadID != thread.parentThreadID
            || previous.isArchived != thread.isArchived || previous.isSettled != thread.isSettled
            || previous.isInPanel != thread.isInPanel || previous.isHydraHead != thread.isHydraHead
            || previous.hydra?.index != thread.hydra?.index
            || previous.isPinned != thread.isPinned || previous.sortOrder != thread.sortOrder
            || previous.createdAt != thread.createdAt || previous.updatedAt != thread.updatedAt
            || previous.settledAt != thread.settledAt || previous.activityOrder != thread.activityOrder
            || previous.activityOrderDay != thread.activityOrderDay
            || previous.foldsHelpers != thread.foldsHelpers
    }

    /// Moves a thread to another project's folder: what the old folder's session and
    /// worktree left on it goes, the destination project opens so the row has a place to
    /// land, the last-worked-in project follows, and the sidebar is asked to bring the
    /// moved row into view. The runtime stops first, so no turn carries on against a
    /// folder the chat has left. Wrap the call in `withAnimation` to make the move glide
    /// in the sidebar; the model itself never animates.
    func moveThread(_ id: UUID, toProject project: Project) {
        existingRuntime(for: id)?.stopSession()
        updateThread(id) { thread in
            thread.projectID = project.id
            thread.worktreePath = nil
            thread.branch = nil
            thread.providerSessionID = nil
            thread.providerResumeAt = nil
        }
        updateProject(project.id) { $0.isExpanded = true }
        rememberLastProject(project.id)
        sidebarRevealThreadID = id
    }

    private func updateThreads(_ ids: [UUID], _ change: (Int, inout ChatThread) -> Void) {
        var updated = threads
        var changed = false
        for (position, id) in ids.enumerated() {
            guard let index = threadIndex.positions[id] else { continue }
            let previous = updated[index]
            change(position, &updated[index])
            changed = changed || previous != updated[index]
        }
        guard changed else { return }
        threads = updated
        scheduleSave()
    }

    func rename(_ id: UUID, to title: String) {
        let trimmed = title.trimmed
        guard !trimmed.isEmpty else { return }
        updateThread(id) {
            $0.title = trimmed
            $0.hasCustomTitle = true
        }
    }

    func archive(_ id: UUID) {
        // The helpers under a thread go with it, and come back with it.
        for helper in helpers(of: id) { archive(helper.id) }
        if selectedThreadID == id { selectNeighbor(of: id) }
        existingRuntime(for: id)?.stopSession()
        releaseHydraCopy(of: id)
        updateThread(id) {
            $0.isArchived = true
            $0.isPinned = false
            // Restored, it is a thread again, not a settled one.
            $0.isSettled = false
            $0.settledAt = nil
        }
        // An archived thread is out of the list, so its unread mark leaves the dock with it.
        updateDockBadge()
    }

    func unarchive(_ id: UUID) {
        updateThread(id) { $0.isArchived = false }
        for helper in threads where helper.parentThreadID == id && helper.isArchived {
            updateThread(helper.id) { $0.isArchived = false }
        }
        // Back in the list, an unread thread counts again.
        updateDockBadge()
    }

    /// Marks a thread finished: it drops to the bottom of its list as a small grey row,
    /// its helpers folded away with it, and stays a click away until it is reopened. Its
    /// session keeps running if it is; only the sidebar's view of it changes. The settle
    /// note sounds here unless the caller already played it on the click.
    func settle(_ id: UUID, sounds: Bool = true) {
        guard let thread = thread(id), !thread.isSettled, !thread.isHelper else { return }
        let now = Date.now
        updateThread(id) {
            $0.isSettled = true
            $0.settledAt = now
            $0.isPinned = false
            // Done with it means read.
            $0.hasUnread = false
        }
        for helper in helpers(of: id) {
            updateThread(helper.id) {
                $0.isSettled = true
                $0.settledAt = now
            }
        }
        updateDockBadge()
        if sounds, settings.settleSound { SettleChime.play() }
        // A settled thread stays settled across relaunch: write now, not on the debounce.
        saveLibrary()
    }

    /// Brings a settled thread back among the others, on top: reopened counts as activity.
    func reopen(_ id: UUID) {
        guard let thread = thread(id), thread.isSettled else { return }
        let now = Date.now
        updateThread(id) {
            $0.isSettled = false
            $0.settledAt = nil
            $0.updatedAt = now
            // A place dragged into before it settled no longer applies.
            $0.activityOrder = nil
            $0.activityOrderDay = nil
        }
        updateThreads(children(of: id).filter(\.isSettled).map(\.id)) { _, helper in
            helper.isSettled = false
            helper.settledAt = nil
        }
        saveLibrary()
    }

    /// Settles the thread with the sidebar's motion: the rows around it make room as it goes.
    func settleAnimated(_ id: UUID, sounds: Bool = true) {
        withAnimation(Chrome.settleFlight) { settle(id, sounds: sounds) }
    }

    /// Reopens the thread with the sidebar's motion.
    func reopenAnimated(_ id: UUID) {
        withAnimation(Chrome.settleFlight) { reopen(id) }
    }

    /// A settled thread that starts a turn is at work again, so it comes back up the list.
    func reopenIfSettled(_ id: UUID) {
        guard thread(id)?.isSettled == true else { return }
        reopenAnimated(id)
    }

    /// What the menu's, the shortcut's and the palette's finish command does to the selected
    /// thread: settles or archives it as Settings chose, and reopens a settled one.
    var finishActionTitle: String {
        if settings.threadFinishAction == .settle, selectedThread?.isSettled == true { return "Reopen thread" }
        return "\(settings.threadFinishAction.title) thread"
    }

    var finishActionSymbol: String {
        if settings.threadFinishAction == .settle, selectedThread?.isSettled == true { return "arrow.uturn.backward" }
        return settings.threadFinishAction == .settle ? "checkmark.circle" : "archivebox"
    }

    func finishSelectedThread() {
        guard let id = selectedThreadID, let thread = thread(id) else { return }
        switch settings.threadFinishAction {
        // A helper has no place of its own to settle into; it goes the archive's way.
        case .settle where thread.isHelper, .archive:
            withAnimation(Chrome.panelSlide) { archive(id) }
        case .settle:
            let request = FinishRequest(threadID: id, reopens: thread.isSettled)
            finishRequest = request
            Task {
                // No row took it up (the sidebar is hidden, say): the thread just moves.
                try? await Task.sleep(for: .milliseconds(80))
                guard finishRequest == request else { return }
                finishRequest = nil
                if request.reopens { reopenAnimated(id) } else { settleAnimated(id) }
            }
        }
    }

    /// Settles the selected thread, or reopens it when it is settled already: the shortcut's
    /// toggle, whatever General chose for Finish. A helper has no place of its own to settle
    /// into, so it stays as it is.
    func settleSelectedThread() {
        guard let id = selectedThreadID, let thread = thread(id), !thread.isHelper else { return }
        let request = FinishRequest(threadID: id, reopens: thread.isSettled)
        finishRequest = request
        Task {
            // No row took it up (the sidebar is hidden, say): the thread just moves.
            try? await Task.sleep(for: .milliseconds(80))
            guard finishRequest == request else { return }
            finishRequest = nil
            if request.reopens { reopenAnimated(id) } else { settleAnimated(id) }
        }
    }

    /// Asks before archiving the selected thread: its row shows the question, with
    /// Archive the answer Return gives and Delete beside it.
    func askToArchiveSelectedThread() {
        guard let id = selectedThreadID, thread(id) != nil else { return }
        // Nothing in it, nothing typed for it: there is nothing to keep, so it goes the way
        // an empty tab does, with no question. A history still being read is not "nothing".
        if let runtime = existingRuntime(for: id), !runtime.isLoadingHistory, runtime.turns.isEmpty,
           runtime.continuation == nil, runtime.draft.isEmpty, runtime.followUps.isEmpty, !runtime.isRunning {
            withAnimation(Chrome.panelSlide) { delete(id) }
            return
        }
        let request = ArchiveRequest(threadID: id)
        archiveRequest = request
        Task {
            // No row to ask on (the sidebar is hidden, say): the thread is archived, which
            // is what Return would have done.
            try? await Task.sleep(for: .milliseconds(80))
            guard archiveRequest == request else { return }
            archiveRequest = nil
            withAnimation(Chrome.panelSlide) { archive(id) }
        }
    }

    /// A settle or reopen asked for away from the row: the menu, the shortcut, the palette.
    /// The thread's row takes it up and settles the way a click on its check does, pop, note
    /// and glide included.
    struct FinishRequest: Equatable {
        let id = UUID()
        let threadID: UUID
        let reopens: Bool
    }

    var finishRequest: FinishRequest?

    /// An archive asked for with the shortcut, which the thread's row takes up as a
    /// question on itself.
    struct ArchiveRequest: Equatable {
        let id = UUID()
        let threadID: UUID
    }

    var archiveRequest: ArchiveRequest?

    func delete(_ id: UUID, removeWorktree: Bool = false) {
        guard let thread = thread(id) else { return }
        // A helper still in its panel goes with the thread it belongs to.
        for helper in children(of: id) { delete(helper.id) }
        if selectedThreadID == id { selectNeighbor(of: id) }
        // A head deleted mid-job reports to its lead as stopped, so the batch it was in
        // settles and the lead's waiting heads and merge go on rather than waiting for it.
        if thread.isHydraHead, thread.hydra?.isFinished == false {
            finishHydraHead(id, status: .interrupted, summary: nil)
        }
        discardThreadState(thread)
        threads.removeAll { $0.id == id }
        if let project = project(thread.projectID) {
            let git = Git(project.path)
            // A head's copy of the checkout was Tivano's to make, so it always goes.
            let worktree = removeWorktree || thread.hydra?.hasOwnCopy == true ? thread.worktreePath : nil
            Task {
                await git.deleteCheckpoints(thread: id)
                if let worktree { try? await git.removeWorktree(at: worktree) }
            }
        }
        updateDockBadge()
        saveLibrary()
    }

    /// Deletes every archived thread at once: histories, terminals and checkpoints go with them.
    /// Worktrees stay on disk, exactly as they do after a single delete.
    func deleteArchivedThreads() {
        let archived = threads.filter(\.isArchived)
        guard !archived.isEmpty else { return }
        // Helpers still in an archived thread's panel go with it.
        let archivedIDs = Set(archived.map(\.id))
        let removed = archived + threads.filter { helper in
            guard let parent = helper.parentThreadID else { return false }
            return archivedIDs.contains(parent) && !archivedIDs.contains(helper.id)
        }
        if let selectedThreadID, removed.contains(where: { $0.id == selectedThreadID }) {
            self.selectedThreadID = nil
        }
        var cleanup: [(directory: String, threadID: UUID, copy: String?)] = []
        cleanup.reserveCapacity(removed.count)
        for thread in removed {
            discardThreadState(thread, deletingDocument: false)
            if let project = project(thread.projectID) {
                cleanup.append((project.path, thread.id, thread.hydra?.hasOwnCopy == true ? thread.worktreePath : nil))
            }
        }
        Storage.deleteDocuments(removed.map(\.id))
        Task {
            for item in cleanup {
                let git = Git(item.directory)
                await git.deleteCheckpoints(thread: item.threadID)
                if let copy = item.copy { try? await git.removeWorktree(at: copy) }
            }
        }
        let removedIDs = Set(removed.map(\.id))
        threads.removeAll { removedIDs.contains($0.id) }
        updateDockBadge()
        scheduleSave()
    }

    // MARK: - Subagents

    /// Helpers whose panel closed while they worked: their session goes once the
    /// interrupted turn has finished (see turnFinished).
    @ObservationIgnored private var sessionsToRelease: Set<UUID> = []

    /// The helper a thread spawned and still shows in its floating panel, if any. Hydra
    /// heads have a panel of their own (see `hydraHeads(of:)`).
    func subagent(of parentID: UUID) -> ChatThread? {
        panelSubagent(of: parentID)
    }

    /// Adds a thread the app made for another thread: a head, say. The caller selects it
    /// or leaves it in a panel as it sees fit.
    func insertThread(_ thread: ChatThread) {
        threads.append(thread)
        scheduleSave()
    }

    /// Spawns a helper thread beside `parentID` and sends it `prompt` at once. The helper
    /// runs on its parent's provider, model, effort and permissions, so it works exactly as
    /// the chat that spawned it would, in the project folder itself: a merge lands on the
    /// main checkout, never in a thread's worktree. A parent already showing a helper hands
    /// the prompt to that one instead: sent now when it is idle, queued behind its running
    /// turn otherwise.
    @discardableResult
    func spawnSubagent(from parentID: UUID, title: String, prompt: String) -> ChatThread? {
        guard let parent = thread(parentID) else { return nil }
        if let existing = subagent(of: parentID) {
            let runtime = runtime(for: existing.id)
            if runtime.isRunning {
                runtime.enqueueFollowUp(text: prompt, attachments: [])
            } else {
                runtime.draft = ComposerDraft(text: prompt)
                runtime.send()
            }
            return existing
        }
        var thread = ChatThread(
            projectID: parent.projectID,
            provider: parent.provider,
            model: parent.model,
            effort: parent.effort,
            runtimeMode: parent.runtimeMode,
            fastMode: parent.fastMode
        )
        thread.parentThreadID = parentID
        thread.isInPanel = true
        thread.title = title
        thread.hasCustomTitle = true
        threads.append(thread)
        scheduleSave()
        let runtime = runtime(for: thread.id)
        runtime.draft = ComposerDraft(text: prompt)
        runtime.send()
        return thread
    }

    /// Closes a helper's panel: its turn stops, and it moves to the sidebar under the thread
    /// that spawned it, as a smaller row, so what it did stays a click away.
    func closeSubagent(_ id: UUID) {
        guard thread(id) != nil else { return }
        if let runtime = existingRuntime(for: id) {
            // A running turn ends as interrupted and releases its session once it has
            // (see turnFinished); an idle one has nothing to wait for.
            if runtime.isRunning {
                sessionsToRelease.insert(id)
                runtime.interrupt()
            } else {
                runtime.stopSession()
            }
        }
        updateThread(id) { $0.isInPanel = false }
    }

    private func discardThreadState(_ thread: ChatThread, deletingDocument: Bool = true) {
        idleSessionStops.removeValue(forKey: thread.id)?.cancel()
        runtimes[thread.id]?.cancelPersistence()
        runtimes[thread.id]?.stopSession()
        runtimes[thread.id] = nil
        terminals.closeAll(for: thread.id)
        if deletingDocument { Storage.deleteDocument(thread.id) }
    }

    private func selectNeighbor(of id: UUID) {
        let order = sidebarThreads
        guard let index = order.firstIndex(where: { $0.id == id }) else {
            selectedThreadID = nil
            return
        }
        let neighbor = order.indices.contains(index + 1) ? order[index + 1] : (index > 0 ? order[index - 1] : nil)
        selectedThreadID = neighbor?.id
    }

    var topScript: ProjectScript? {
        guard let selectedThreadID, let thread = thread(selectedThreadID) else { return nil }
        return project(thread.projectID)?.scripts.first
    }

    func runScript(_ script: ProjectScript, threadID: UUID) {
        guard let thread = thread(threadID), let project = project(thread.projectID) else { return }
        terminals.run(script, threadID: threadID, directory: thread.worktreePath ?? project.path)
        runtime(for: threadID).isTerminalVisible = true
    }

    func selectThread(offset: Int) {
        let order = sidebarThreads
        guard !order.isEmpty else { return }
        guard let current = selectedThreadID, let index = order.firstIndex(where: { $0.id == current }) else {
            selectedThreadID = order.first?.id
            return
        }
        selectedThreadID = order[(index + offset + order.count) % order.count].id
    }

    func selectThread(number: Int) {
        let order = sidebarThreads
        guard order.indices.contains(number - 1) else { return }
        selectedThreadID = order[number - 1].id
    }

    func createWorktree(for threadID: UUID) async {
        guard let thread = thread(threadID), thread.worktreePath == nil, let project = project(thread.projectID) else { return }
        let git = Git(project.path)
        guard await git.isRepository(), await git.hasCommits() else {
            alert = AppAlert(title: "Worktree unavailable", message: "New worktrees need a git repository with at least one commit.")
            return
        }
        let suffix = String(threadID.uuidString.lowercased().prefix(8))
        let folder = project.name.replacingOccurrences(of: " ", with: "-").lowercased()
        let path = Storage.worktreesDirectory.appendingPathComponent("\(folder)-\(suffix)").path
        let branch = "tivano/\(suffix)"
        let base = await git.status()?.branch
        do {
            try await git.addWorktree(at: path, branch: branch, base: base)
            updateThread(threadID) {
                $0.worktreePath = path
                $0.branch = branch
            }
            for script in project.scripts where script.runOnWorktreeCreate {
                terminals.run(script, threadID: threadID, directory: path)
                runtime(for: threadID).isTerminalVisible = true
            }
        } catch {
            alert = AppAlert(title: "Could not create a worktree", message: error.localizedDescription)
        }
    }

    // MARK: - Attention

    /// Whether a thread is on screen right now: the selected thread itself, a helper in
    /// its parent's floating panel, or a sidebar helper shown inline beneath its selected
    /// parent. Sidebar helpers count only while the parent is unfolded (`foldsHelpers == false`)
    /// and not settled, which is the same condition `SidebarView` uses to show them inline.
    private func isOnScreen(_ thread: ChatThread) -> Bool {
        if selectedThreadID == thread.id { return true }
        guard let parent = thread.parentThreadID, parent == selectedThreadID else { return false }
        if thread.isInPanel { return !thread.isArchived }
        guard !thread.isArchived, let parentThread = self.thread(parent) else { return false }
        return !parentThread.isArchived && !parentThread.isInPanel
            && !parentThread.foldsHelpers && !parentThread.isSettled
    }

    func threadNeedsAttention(_ id: UUID) {
        guard !CaptureRun.isEnabled, let thread = thread(id) else { return }
        // Already in view with the app frontmost: the approval or question is on
        // screen, so no banner and no dock bounce. Seen too, so no unread mark is
        // left behind to stick on the dock.
        if NSApp.isActive && isOnScreen(thread) {
            markRead(id)
            return
        }
        notify(threadID: id, title: thread.title, body: "Waiting for your decision.")
        NSApp.requestUserAttention(.informationalRequest)
    }

    /// A turn ended. `continues` means a queued message picks up right away, so the agent is
    /// still at work and neither the chime nor a notification claims otherwise.
    func turnFinished(_ id: UUID, status: TurnStatus, continues: Bool) {
        // The thread itself selected, or its panel helper or Hydra head on screen with
        // the selected parent, while the app is frontmost: in view.
        let onScreen = thread(id).map(isOnScreen) ?? false
        let isVisible = NSApp.isActive && onScreen
        let isHead = thread(id)?.isHydraHead == true
        updateThread(id) {
            $0.lastStatus = status
            $0.updatedAt = .now
            // Out of view the thread goes unread, for the dock; in view it is read,
            // which also clears an unread mark from an earlier finish while away so
            // the badge cannot stick around after the chat is back on screen. Heads
            // report to their lead and never mark themselves.
            if !isHead { $0.hasUnread = !isVisible }
        }
        updateDockBadge()
        // A helper panel closed mid-turn kept its session alive to finish stopping cleanly;
        // it has now.
        if sessionsToRelease.remove(id) != nil { existingRuntime(for: id)?.stopSession() }
        // A turn stopped by a spent usage limit waits for the reset and goes on by itself:
        // no chime and no "stopped with an error", the wait says what is happening.
        if autoContinue.turnFinished(id, status: status, continues: continues) { return }
        // A head reports to its lead, which is the chat that chimes and notifies when
        // the whole job is done. A head with another turn coming (its report, after its
        // budget ran out) reports at the end of that one.
        if isHead, let head = thread(id) {
            if !continues { hydraHeadTurnFinished(head, status: status) }
            return
        }
        guard !continues else { return }
        // A stop the user asked for needs no chime; the agent finishing on its own gets one,
        // whether or not the thread is in view.
        let chimed = settings.chimeWhenFinished && status != .interrupted
        if chimed { FinishChime.play() }
        guard !isVisible, settings.notifyWhenFinished, let thread = thread(id) else { return }
        let body = switch status {
        case .completed: "Finished."
        case .interrupted: "Stopped."
        case .failed: "Stopped with an error."
        case .running: ""
        }
        // The chime has already sounded, so the banner stays quiet rather than doubling it.
        notify(threadID: id, title: thread.title, body: body, sound: chimed ? nil : .default)
    }

    func markRead(_ id: UUID) {
        guard thread(id)?.hasUnread == true else { return }
        updateThread(id) { $0.hasUnread = false }
        updateDockBadge()
    }

    /// Several threads read at once cost one write to the library, so the cells and
    /// the sidebar see one change, not one per thread.
    func markRead(_ ids: [UUID]) {
        let wanted = Set(ids.filter { thread($0)?.hasUnread == true })
        var copy = threads
        var changed = false
        for index in copy.indices where wanted.contains(copy[index].id) && copy[index].hasUnread {
            copy[index].hasUnread = false
            changed = true
        }
        guard changed else { return }
        threads = copy
        scheduleSave()
        updateDockBadge()
    }

    func requestNotificationPermission() {
        guard !didRequestNotifications, !CaptureRun.isEnabled else { return }
        didRequestNotifications = true
        Task {
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        }
    }

    func notify(threadID: UUID, title: String, body: String, sound: UNNotificationSound? = .default) {
        guard !CaptureRun.isEnabled else { return }
        if NSApp.isActive, let thread = thread(threadID), isOnScreen(thread) { return }
        requestNotificationPermission()
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = sound
        content.userInfo = ["threadID": threadID.uuidString]
        let request = UNNotificationRequest(identifier: threadID.uuidString, content: content, trigger: nil)
        Task { try? await UNUserNotificationCenter.current().add(request) }
    }

    func updateDockBadge() {
        let unread = threads.count { $0.hasUnread && !$0.isArchived && !$0.isInPanel }
        NSApp.dockTile.badgeLabel = unread > 0 ? String(unread) : nil
    }

    // MARK: - Text generation

    func textEngine(preferring provider: ProviderKind?) -> TextGeneration.Engine? {
        func claude() -> TextGeneration.Engine? {
            guard providers.status(.claude).auth != .signedOut, let executable = providers.executable(for: .claude) else { return nil }
            return .claude(executable: executable, environment: providers.environment(for: .claude))
        }
        func codex() -> TextGeneration.Engine? {
            guard providers.status(.codex).auth != .signedOut,
                  let executable = providers.executable(for: .codex),
                  let model = providers.defaultModel(for: .codex)?.id else { return nil }
            return .codex(executable: executable, environment: providers.environment(for: .codex), model: model)
        }
        switch settings.textGeneration {
        case .off: return nil
        case .claude: return claude()
        case .codex: return codex()
        case .automatic: return provider == .codex ? (codex() ?? claude()) : (claude() ?? codex())
        }
    }

    // MARK: - Persistence

    /// The library holds every thread and every head's report, runs to megabytes, and
    /// nearly every thread update lands here. A save waits 400 ms, never goes out within
    /// four seconds of the last one, and takes along every change made while it waits: a
    /// busy team rewrote the file on every status change, over two gigabytes in an hour
    /// and a quarter (September 22). Restarting the wait on each change also meant a steady
    /// stream of changes never saved at all.
    func scheduleSave() {
        guard persistenceEnabled, isLibraryLoaded, saveTask == nil else { return }
        let sinceLast = lastLibrarySave.map { ContinuousClock.now - $0 } ?? .seconds(60)
        let wait = max(.milliseconds(400), .seconds(4) - sinceLast)
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled, let self else { return }
            self.saveTask = nil
            self.saveLibrary()
        }
    }

    private func saveLibrary() {
        guard isLibraryLoaded, persistenceEnabled else { return }
        lastLibrarySave = .now
        var library = Library()
        library.projects = projects
        library.threads = threads
        let url = Storage.libraryURL
        DiskWriter.shared.encodeAndWrite(library, to: url)
    }

    /// Flush recovery metadata before an opt-in provider archive. A capture or a disk
    /// write failure cannot authorize a provider-side change.
    func saveProviderHistoryIntent() async throws {
        guard isLibraryLoaded, persistenceEnabled, !CaptureRun.isEnabled else {
            throw ProviderError.failed(Chrome.localized("Provider history changes require a persistent library."))
        }
        var library = Library()
        library.projects = projects
        library.threads = threads
        try await DiskWriter.shared.writeOrThrow(library, to: Storage.libraryURL)
        lastLibrarySave = .now
    }

    /// Writes everything synchronously, for use while the app terminates.
    func saveBeforeQuit() {
        guard isLibraryLoaded, persistenceEnabled else { return }
        persistenceEnabled = false
        saveTask?.cancel()
        saveTask = nil
        var library = Library()
        library.projects = projects
        library.threads = threads
        DiskWriter.shared.writeSynchronously(library, to: Storage.libraryURL)
        for runtime in runtimes.values {
            runtime.cancelPersistence()
            runtime.stopSession()
            // A thread only read since its last save is already on disk as it is.
            guard let snapshot = runtime.unsavedSnapshot() else { continue }
            DiskWriter.shared.writeThreadSynchronously(snapshot)
        }
        DiskWriter.shared.waitForQueuedWrites()
        terminals.terminateAll()
    }
}

/// Reads project scripts from `tivano.json` at the project root.
enum ProjectFile {
    static func scripts(at url: URL) -> [ProjectScript] {
        guard let data = try? Data(contentsOf: url.appendingPathComponent("tivano.json")),
              let json = JSONValue.parse(data) else { return [] }
        return (json["scripts"]?.array ?? []).compactMap { script in
            guard let name = script["name"]?.string, let command = script["command"]?.string else { return nil }
            return ProjectScript(
                name: name,
                command: command,
                symbol: symbol(for: script["icon"]?.string),
                runOnWorktreeCreate: script["runOnWorktreeCreate"]?.bool ?? false
            )
        }
    }

    static func symbol(for icon: String?) -> String {
        switch icon {
        case "test": "checkmark.seal"
        case "lint": "wand.and.stars"
        case "configure": "gearshape"
        case "build": "hammer"
        case "debug": "ant"
        default: "play"
        }
    }
}
