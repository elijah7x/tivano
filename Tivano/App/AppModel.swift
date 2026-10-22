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
    private(set) var keepsakes: [Keepsake] = []
    private var keepsakesSeen = false

    var hasUnseenKeepsakes: Bool { !keepsakes.isEmpty && !keepsakesSeen }

    func markKeepsakesSeen() {
        guard !keepsakes.isEmpty, !keepsakesSeen else { return }
        keepsakesSeen = true
        KeepsakeStore.save(.init(keepsakes: keepsakes, seen: keepsakesSeen))
    }

    func lightKeepsake(_ id: String) {
        guard let index = keepsakes.firstIndex(where: { $0.id == id }), keepsakes[index].litAt == nil else { return }
        keepsakes[index].litAt = Date()
        KeepsakeStore.save(.init(keepsakes: keepsakes, seen: keepsakesSeen))
    }

    #if DEBUG
    func prepareKeepsakePreview() {
        guard CaptureRun.isEnabled else { return }
        let id = "early-supporter"
        if let index = keepsakes.firstIndex(where: { $0.id == id }) {
            keepsakes[index].litAt = nil
        } else {
            keepsakes.append(Keepsake(id: id, earnedAt: Date(), litAt: nil))
        }
        KeepsakeStore.save(.init(keepsakes: keepsakes, seen: keepsakesSeen))
    }
    #endif

    let settings: AppSettings
    let providers: ProviderRegistry
    /// The user's MCP connections, handed to every provider session at launch.
    let mcp: MCPStore
    let terminals: TerminalStore
    let sidebar: SidebarLayout
    /// Picks chats back up once a spent usage limit resets, with the setting on.
    @ObservationIgnored private(set) var autoContinue: AutoContinue!
    @ObservationIgnored private(set) var voice: VoiceController!
    @ObservationIgnored private(set) var localControl: AppControlService!
    /// How often each Tivano-run head has been started again after failing at the door
    /// (see `hydraHeadTurnFinished`); a head gets two more goes.
    @ObservationIgnored var hydraHeadRetries: [UUID: Int] = [:]

    /// The lists are the source of truth for anything that shows several items at once. Single
    /// lookups go through the cells below, so the timeline rows, composer and chat header of one
    /// thread are left alone when another thread's title, status or unread flag changes.
    private(set) var projectsRevision: UInt64 = 0
    private(set) var projects: [Project] = [] {
        didSet {
            Self.write(Self.sync(&projectCells, with: projects))
            projectsRevision &+= 1
        }
    }
    @ObservationIgnored private var threadStorage: [ChatThread] = []
    private(set) var threadsRevision: UInt64 = 0
    /// Only fields used by control-list membership/search/order, not streamed status
    /// or timestamps. Cursor snapshots still use the full threadsRevision.
    private(set) var controlThreadMembershipRevision: UInt64 = 0
    private(set) var threads: [ChatThread] {
        get {
            _ = threadsRevision
            return threadStorage
        }
        set {
            threadStorage = newValue
            controlThreadMembershipRevision &+= 1
            synchronizeThreads()
            if isLibraryLoaded { announceLoweredPermissions() }
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
        var projects: [UUID?: [Int]] = [:]

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
            if oldValue != selectedThreadID {
                scheduleIdleSessionStop(leaving: oldValue)
                if let id = selectedThreadID {
                    Task { @MainActor [weak self] in self?.warmNeighbors(of: id) }
                }
            }
            if let selectedThreadID, let thread = thread(selectedThreadID) {
                rememberAffiliation(thread.affiliation)
            }
        }
    }

    /// The thread the sidebar should bring into view on its next pass, set when a thread
    /// lands somewhere new (moved to another project from the new-thread prompt, say): the
    /// list scrolls to that row and clears this. Never persisted, and nil at rest.
    var sidebarRevealThreadID: UUID?

    var isCommandPalettePresented = false
    var alert: AppAlert?

    /// True while any chat still has work in flight — a running turn, voice, a merge,
    /// helpers or queued work — or local control holds an accepted mutation. The
    /// runtimes dictionary and the control ledger are unobserved, so this flag is
    /// maintained in `updateTaskSleepPrevention`, which every runtime change funnels
    /// through. The updater's install button dims on it; `flushForQuit` stays the
    /// authority.
    private(set) var hasActiveTurns = false

    @ObservationIgnored private let taskSleepPrevention = TaskSleepPrevention()
    @ObservationIgnored private var runtimes: [UUID: ThreadRuntime] = [:]
    private var creatingWorktrees: Set<UUID> = []
    @ObservationIgnored private var runtimeLastAccess: [UUID: ContinuousClock.Instant] = [:]
    @ObservationIgnored private var runtimeCapacityScheduled = false
    @ObservationIgnored private var runtimeCapacityRetry: Task<Void, Never>?
    @ObservationIgnored private var runtimeReleasesAwaitingSave: Set<UUID> = []
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
    @ObservationIgnored private var libraryLoad: Task<LibraryLoad, Never>?
    @ObservationIgnored private var restoreSelectionAfterLoad = false
    @ObservationIgnored private(set) var persistenceEnabled = true
    @ObservationIgnored var libraryWritesBlocked = false
    @ObservationIgnored private var libraryRecoveryURL: URL?
    @ObservationIgnored private var librarySaveFailureShown = false
    @ObservationIgnored private var didRequestNotifications = false

    init() {
        settings = AppSettings()
        providers = ProviderRegistry(settings: settings)
        mcp = MCPStore()
        terminals = TerminalStore()
        sidebar = SidebarLayout()
        autoContinue = AutoContinue(app: self)
        voice = VoiceController(app: self)
        localControl = AppControlService(app: self)
        settings.onExternalControlChanged = { [weak self] in self?.localControl.refreshListening() }
        settings.onSleepPreventionChanged = { [weak self] in
            self?.updateTaskSleepPrevention()
        }
    }

    func updateTaskSleepPrevention() {
        let busy = runtimes.values.contains(where: Self.hasActiveTasks)
        let active = busy || localControl.hasPendingMutations
        if active != hasActiveTurns { hasActiveTurns = active }
        taskSleepPrevention.update(
            mode: CaptureRun.isEnabled ? .off : settings.taskSleepMode,
            hasRunningTasks: busy
        )
    }

    private static func hasActiveTasks(_ runtime: ThreadRuntime) -> Bool {
        runtime.isRunning || runtime.isVoiceOrchestrator || runtime.isHydraMerging || runtime.isCLIStarting
            || !runtime.backgroundTasks.isEmpty || runtime.isWaitingForLimit || runtime.hasWorkingHelpers
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
        let load = Task.detached(priority: .userInitiated) { Storage.loadLibraryRecovering() }
        libraryLoad = load
        var library: Library
        var didRecoverLibrary = false
        switch await load.value {
        case .loaded(let loaded): library = loaded
        case .recovered(let recovered, let skipped, let quarantine, let backup, let fromPrevious):
            library = recovered
            didRecoverLibrary = true
            let message: String
            if fromPrevious {
                message = String(format: Chrome.localized("Tivano's library file was damaged, so it loaded the copy saved at the last launch. Chats created since then may be missing from the sidebar; their documents are still on disk. The damaged file is kept at %@."), backup.path)
            } else if skipped == 0, quarantine != nil {
                message = String(format: Chrome.localized("Tivano repaired damaged workspace records and kept all chats. Affected workspaces cannot run. The original file is kept at %@ and the damaged records at %@."), backup.path, quarantine?.path ?? backup.path)
            } else {
                message = String(format: Chrome.localized("Tivano couldn't read %lld items in its library and loaded the rest. The original file is kept at %@ and the unreadable items at %@."), Int64(skipped), backup.path, quarantine?.path ?? backup.path)
            }
            alert = AppAlert(title: "Some of your library was repaired", message: message)
        case .failed(let error):
            library = Library()
            libraryWritesBlocked = true
            let recovery = Storage.root.appendingPathComponent("library-recovery-\(UUID().uuidString).json")
            libraryRecoveryURL = recovery
            alert = AppAlert(
                title: "Library could not be loaded",
                message: String(format: Chrome.localized("Tivano couldn't read its library (%@). The original file and chat documents are preserved. Repair the library and restart Tivano. Any new chats will be saved separately to %@ when you quit."), error.localizedDescription, recovery.path)
            )
        }
        let keepsakeSnapshot = await Task.detached(priority: .utility) {
            KeepsakeStore.load(granting: KeepsakeCatalog.grantedByThisBuild)
        }.value
        keepsakes = keepsakeSnapshot.keepsakes
        keepsakesSeen = keepsakeSnapshot.seen
        let originalThreads = library.threads
        for index in library.threads.indices where library.threads[index].controlWorkspace?.phase == .preparing {
            library.threads[index].controlWorkspace?.phase = .failed
            library.threads[index].controlWorkspace?.failure = ControlFailure(code: .workspaceFailed, detail: "restart_during_preparation")
        }
        for index in library.threads.indices where !CaptureRun.isEnabled && (library.threads[index].lastStatus == .running || library.threads[index].pendingResultTurnID != nil || library.threads[index].hydra?.status == .running) {
            if library.threads[index].lastStatus == .running || library.threads[index].pendingResultTurnID != nil {
                library.threads[index].lastStatus = .interrupted
                library.threads[index].unreadStatus = .interrupted
                library.threads[index].hasUnread = !library.threads[index].isHydraHead
                library.threads[index].unreadRevision = UUID()
                library.threads[index].pendingResultTurnID = nil
                library.threads[index].lastAttentionTurnID = nil
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
        localControl.refreshListening()
        updateDockBadge()
        libraryLoad = nil
        let permissionsLowered = announceLoweredPermissions()
        // A recovered index goes back out once, so the next launch reads a clean file
        // instead of recovering, alerting and quarantining the same damage again.
        if didRecoverLibrary || permissionsLowered || threads != originalThreads || projects != library.projects { scheduleSave() }
        // Capture seeds retain their staged statuses and never start account or merge services.
        if CaptureRun.isEnabled { return }
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
        if !libraryWritesBlocked { sweepHydraCopies() }
        // A merge the last run did not finish (the app was quit under it) goes out now.
        if !libraryWritesBlocked { await resumeHydraMerges() }
        // The launch sweep alone is not enough: a merge can also be missed while the app
        // stays up, and then nothing asks again until the next launch. This task asks every
        // five minutes for as long as the app runs; the sweep itself skips chats with a turn
        // or a head still running, so it is safe to repeat.
        hydraMergeSweepTask?.cancel()
        hydraMergeSweepTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(300))
                guard !Task.isCancelled, let self, !self.libraryWritesBlocked else { return }
                await self.resumeHydraMerges()
            }
        }
        await providers.refreshAll()
        // Load the live catalogs behind the launch seeds, overlapped. Claude's brings its
        // slash commands too, so the picker and the composer are complete before any turn.
        await withTaskGroup(of: Void.self) { group in
            for provider in [ProviderKind.claude, .codex, .deepseek, .meta, .dsh] where providers.status(provider).isInstalled && (provider != .dsh || settings.isEnabled(provider)) {
                group.addTask { await self.providers.loadCatalog(provider) }
            }
        }
        if providers.status(.zai).isInstalled {
            await providers.loadCatalog(.zai)
        }
        // Read-only version checks from here on. A model that needs a newer CLI still
        // updates when that reply arrives; nothing in this loop installs on a timer.
        providers.isProviderBusy = { [weak self] provider in
            guard let self else { return false }
            for runtime in self.runtimes.values where Self.hasActiveTasks(runtime) && runtime.thread?.provider == provider {
                return true
            }
            return false
        }
        providers.startCLIUpdateChecks()
        // Last, once nothing the first click needs is waiting on the disk: the attachment
        // files no thread refers to any more go, a day after they were written.
        if !libraryWritesBlocked { await Storage.sweepOrphanedAttachments() }
    }

    // MARK: - Lookup

    /// One project, observed on its own: only a change to this project re-renders the caller.
    func project(_ id: UUID?) -> Project? {
        guard let id else { return nil }
        return projectCells[id]?.value ?? nil
    }

    /// One thread, observed on its own: only a change to this thread re-renders the caller.
    func thread(_ id: UUID) -> ChatThread? {
        threadCells[id]?.value ?? nil
    }

    var selectedThread: ChatThread? {
        selectedThreadID.flatMap(thread)
    }

    var currentAffiliation: ThreadAffiliation {
        if let selectedThread { return selectedThread.affiliation }
        if let saved = settings.lastThreadAffiliation { return saved }
        if let recent = threads.filter({ !$0.isHelper && !$0.isArchived }).max(by: { $0.updatedAt < $1.updatedAt }) {
            return recent.affiliation
        }
        return .standalone
    }

    var currentProject: Project? { project(currentAffiliation.projectID) }

    private func rememberAffiliation(_ affiliation: ThreadAffiliation) {
        settings.lastThreadAffiliation = affiliation
        settings.lastProjectID = affiliation.projectID
    }

    private func rememberLastProject(_ id: UUID) {
        guard project(id) != nil else { return }
        rememberAffiliation(.project(id))
    }

    /// Resolves without touching disk. A missing project is an error, never a task.
    func executionDirectory(for thread: ChatThread) throws -> String {
        var current = thread
        var visited = Set<UUID>()
        while visited.insert(current.id).inserted {
            if let workspace = current.controlWorkspace, workspace.enforcesExecutionReadiness, workspace.phase != .ready {
                throw ControlFailure(code: workspace.phase == .preparing ? .workspacePreparing : .workspaceFailed)
            }
            // A ready worktree without its checkout must not run in the project's default directory.
            if let workspace = current.controlWorkspace, workspace.enforcesExecutionReadiness,
               workspace.mode == .worktree, workspace.phase == .ready,
               current.worktreePath?.isEmpty != false {
                throw ControlFailure(code: .workspaceFailed)
            }
            if let id = current.projectID {
                guard let project = project(id) else {
                    throw ProviderError.failed(Chrome.localized("This thread's project is unavailable."))
                }
                return current.executionDirectory(projectPath: project.path)
            }
            if let target = current.hydra?.targetCheckout, !target.isEmpty {
                return current.executionDirectory(projectPath: target)
            }
            guard let parentID = current.parentThreadID else {
                return StoragePaths.taskWorkspace(current.id).path
            }
            guard let parent = self.thread(parentID) else {
                throw ProviderError.failed(Chrome.localized("This task's parent is unavailable."))
            }
            current = parent
        }
        throw ProviderError.failed(Chrome.localized("This task's parent is unavailable."))
    }

    @discardableResult
    func ensureExecutionDirectory(for thread: ChatThread) throws -> String {
        let directory = try executionDirectory(for: thread)
        if thread.projectID == nil {
            var owner = thread
            var visited: Set<UUID> = [owner.id]
            while let parentID = owner.parentThreadID, let parent = self.thread(parentID), parent.projectID == nil {
                guard visited.insert(parentID).inserted else { throw ProviderError.notRunning }
                owner = parent
            }
            if directory == StoragePaths.taskWorkspace(owner.id).path {
                try StoragePaths.ensureTaskWorkspace(owner.id)
            }
        }
        return directory
    }

    /// The project's top-level threads, in sidebar order. A helper whose parent is among
    /// them sits under that parent instead (see `helpers(of:)`); an ordinary helper whose
    /// parent is gone or archived stands
    /// on its own. Hydra heads only appear under their lead, even across projects.
    func threads(in project: Project) -> [ChatThread] { threads(in: .project(project.id)) }

    var standaloneTasks: [ChatThread] { threads(in: .standalone) }

    func threads(in affiliation: ThreadAffiliation) -> [ChatThread] {
        let shown = (threadIndex.projects[affiliation.projectID] ?? []).map { threads[$0] }
            .filter { $0.isStandaloneListCandidate && (affiliation != .standalone || !$0.isHelper) }
        let shownIDs = Set(shown.map(\.id))
        return shown
            .filter { $0.parentThreadID.map { !shownIDs.contains($0) } ?? true }
            .sorted { lhs, rhs in
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
              moving.projectID == target.projectID else { return false }
        let before = threads(in: moving.affiliation).map(\.id)
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

    @discardableResult
    func moveProject(_ id: UUID, to targetID: UUID, placeAfter: Bool) -> Bool {
        guard id != targetID, let moving = projects.first(where: { $0.id == id }),
              projects.contains(where: { $0.id == targetID }) else { return false }
        var reordered = projects
        reordered.removeAll { $0.id == id }
        guard let index = reordered.firstIndex(where: { $0.id == targetID }) else { return false }
        reordered.insert(moving, at: placeAfter ? index + 1 : index)
        guard reordered.map(\.id) != projects.map(\.id) else { return false }
        projects = reordered
        scheduleSave()
        return true
    }

    var archivedThreads: [ChatThread] {
        threads.filter(\.isArchived).sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Threads in the order the sidebar shows them, for keyboard navigation: each thread
    /// followed by the helpers under it, unless they are folded away.
    var sidebarThreads: [ChatThread] {
        let projectThreads = projects.filter(\.isExpanded).flatMap { project in
            threads(in: project).flatMap { thread in
                thread.foldsHelpers ? [thread] : [thread] + helpers(of: thread.id)
            }
        }
        let tasks = standaloneTasks
        let attention = Set(tasks.filter { task in
            guard let runtime = existingRuntime(for: task.id) else { return false }
            return !runtime.approvals.isEmpty || !runtime.questions.isEmpty
        }.map(\.id))
        let rest = tasks.filter { !attention.contains($0.id) }
        let days = Dictionary(grouping: rest.filter { !$0.isPinned }) {
            Calendar.current.startOfDay(for: $0.updatedAt)
        }
        let orderedTasks = ChatThread.orderedByActivity(tasks.filter { attention.contains($0.id) })
            + ChatThread.orderedByActivity(rest.filter(\.isPinned))
            + days.keys.sorted(by: >).flatMap { ChatThread.orderedByActivity(days[$0] ?? []) }
        return projectThreads + orderedTasks.flatMap { $0.foldsHelpers ? [$0] : [$0] + helpers(of: $0.id) }
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
        updateTaskSleepPrevention()
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

    private func releaseExcessIdleRuntimes(isRetry: Bool = false) {
        guard runtimes.count > 12 else { return }
        let fallback = ContinuousClock.now
        let candidates = runtimes.keys.sorted {
            (runtimeLastAccess[$0] ?? fallback) < (runtimeLastAccess[$1] ?? fallback)
        }
        var awaitingSave: Set<UUID> = []
        for id in candidates {
            guard runtimes.count > 12 else { break }
            releaseIdleRuntime(id)
            if runtimeReleasesAwaitingSave.contains(id) { awaitingSave.insert(id) }
        }
        // A save still under way just keeps the runtime for now; a failed one already
        // says so in its own timeline and retries there.
        guard !awaitingSave.isEmpty, !isRetry else { return }
        if runtimeCapacityRetry == nil {
            runtimeCapacityRetry = Task { [weak self] in
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled, let self else { return }
                self.releaseExcessIdleRuntimes(isRetry: true)
                self.runtimeCapacityRetry = nil
            }
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
        guard let id, let thread = thread(id) else { return [] }
        let order = threads(in: thread.affiliation)
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
                guard !runtime.isRunning, self.voice.threadID != id else { continue }
                runtime.stopSession()
                if self.releaseIdleRuntime(id) { return }
                for _ in 0..<3 {
                    guard self.runtimeReleasesAwaitingSave.contains(id) else { break }
                    try? await Task.sleep(for: .seconds(2))
                    guard !Task.isCancelled else { return }
                    if self.releaseIdleRuntime(id) { return }
                }
                self.idleSessionStops[id] = nil
                return
            }
        }
    }

    /// Drops an idle thread's runtime once its document is on disk. Returns
    /// whether it did; a runtime holding anything the document does not stays.
    @discardableResult
    func releaseIdleRuntime(_ id: UUID) -> Bool {
        runtimeReleasesAwaitingSave.remove(id)
        guard let runtime = runtimes[id], selectedThreadID != id, voice.threadID != id, let thread = thread(id),
              // A thread shown beside the selection, in its panel, is on screen.
              thread.parentThreadID == nil || thread.parentThreadID != selectedThreadID,
              !thread.isInPanel, thread.hydra?.status != .running,
              !runtime.isRunning, runtime.draft.isEmpty, runtime.followUps.isEmpty,
              runtime.holdsOnlyPersistedState, !sessionsToRelease.contains(id),
              autoContinue.resumesAt[id] == nil, terminals.sessions(for: id).isEmpty,
              !children(of: id).contains(where: {
                  $0.hydra?.status == .running || existingRuntime(for: $0.id)?.isRunning == true
              }) else { return false }
        if runtime.unsavedSnapshot() != nil {
            runtime.saveNow()
            runtimeReleasesAwaitingSave.insert(id)
            return false
        }
        runtime.cancelPersistence()
        runtimes[id] = nil
        updateTaskSleepPrevention()
        runtimeLastAccess[id] = nil
        idleSessionStops.removeValue(forKey: id)?.cancel()
        return true
    }

    var workingDirectory: String? {
        guard let thread = selectedThread else { return nil }
        return try? executionDirectory(for: thread)
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

    var projectDeletionRequest: UUID?

    func requestProjectDeletion(_ project: Project) {
        projectDeletionRequest = project.id
    }

    func threadsRemovedWithProject(_ project: Project) -> [ChatThread] {
        descendantsIncluding(threads.filter { $0.projectID == project.id }.map(\.id))
    }

    func removeProject(_ project: Project) {
        guard !isAnyHydraMergeRunning else {
            alert = AppAlert(title: "Project is busy", message: Chrome.localized("Wait for Hydra to finish merging before removing this project."))
            return
        }
        let removed = threadsRemovedWithProject(project)
        let ids = Set(removed.map(\.id))
        let cleanup = deletionCleanup(for: removed)
        var library = currentLibrary()
        library.threads.removeAll { ids.contains($0.id) }
        library.projects.removeAll { $0.id == project.id }
        guard commitLibrary(library) else { return }
        completeThreadDeletion(removed, cleanup: cleanup)
        projects.removeAll { $0.id == project.id }
        updateDockBadge()
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
        let affiliation = currentAffiliation
        let restored = threads
            .filter {
                $0.affiliation == affiliation && !$0.isArchived && !$0.isInPanel && !$0.isHelper && !$0.isHydraHead
            }
            .max { lhs, rhs in
                let lhsInterrupted = lhs.lastStatus == .interrupted
                let rhsInterrupted = rhs.lastStatus == .interrupted
                if lhsInterrupted != rhsInterrupted { return !lhsInterrupted }
                return lhs.updatedAt < rhs.updatedAt
            }
        selectedThreadID = restored?.id
    }

    func insertVoiceHomeThread(_ thread: ChatThread) {
        threads.append(thread)
        if let projectID = thread.projectID { updateProject(projectID) { $0.isExpanded = true } }
        scheduleSave()
    }

    @discardableResult
    func newThread(in project: Project? = nil, workspace: WorkspaceMode? = nil) -> ChatThread? {
        newThread(affiliation: project.map { .project($0.id) } ?? .current, workspace: workspace)
    }

    @discardableResult
    func newThread(affiliation choice: NewThreadAffiliation, workspace: WorkspaceMode? = nil) -> ChatThread? {
        let affiliation: ThreadAffiliation
        switch choice {
        case .current:
            // An explicit worktree request still belongs to the current project.
            affiliation = !CaptureRun.isEnabled && workspace != .worktree && settings.newThreadLocation == .standalone
                ? .standalone : currentAffiliation
        case .standalone: affiliation = .standalone
        case .project(let id): affiliation = .project(id)
        }
        if let id = affiliation.projectID, project(id) == nil {
            alert = AppAlert(title: "Could not create thread", message: "This thread's project is unavailable.")
            return nil
        }
        let project = project(affiliation.projectID)
        if workspace == .worktree, project == nil {
            alert = AppAlert(title: "Worktree unavailable", message: "New worktrees need a git repository with at least one commit.")
            return nil
        }
        var thread = makeThread(
            in: project,
            carrying: selectedThread,
            modelSelection: CaptureRun.isEnabled ? nil : settings.newThreadModelSelection
        )
        if project != nil, (workspace ?? settings.defaultWorkspaceMode) == .worktree {
            thread.controlWorkspace = ControlWorkspace(mode: .worktree, phase: .preparing, enforcesExecutionReadiness: false)
        }
        threads.append(thread)
        if let project { updateProject(project.id) { $0.isExpanded = true } }
        rememberAffiliation(affiliation)
        selectedThreadID = thread.id
        scheduleSave()
        if project != nil, (workspace ?? settings.defaultWorkspaceMode) == .worktree {
            Task { await createWorktree(for: thread.id) }
        }
        return thread
    }

    /// Copies conversation context into an unsent thread with independent provider state.
    @discardableResult
    func forwardThread(_ sourceID: UUID) async -> ChatThread? {
        guard thread(sourceID) != nil else { return nil }
        let sourceRuntime = runtime(for: sourceID)
        await sourceRuntime.ensureLoaded()
        // The source can be renamed or removed while its history loads.
        guard let resolved = thread(sourceID), (try? executionDirectory(for: resolved)) != nil else { return nil }
        let project = project(resolved.projectID)
        let continuation = ThreadContinuation.capture(
            sourceID: sourceID,
            title: resolved.title,
            document: sourceRuntime.snapshotForPersistence()
        )
        var thread = makeThread(in: project, carrying: resolved)
        thread.title = "Continued: " + resolved.title
        thread.hasCustomTitle = true
        threads.append(thread)
        if let project { updateProject(project.id) { $0.isExpanded = true } }
        rememberAffiliation(thread.affiliation)
        let newRuntime = runtime(for: thread.id)
        guard await newRuntime.installContinuation(continuation), self.thread(thread.id) != nil else { return nil }
        selectedThreadID = thread.id
        scheduleSave()
        return thread
    }

    /// A chat as it would start in `project`, not yet in `threads`. Only ordinary new
    /// chats pass a fixed selection; continuations retain the existing inheritance chain.
    private func makeThread(in project: Project?, carrying current: ChatThread?, modelSelection: NewThreadModelSelection? = nil) -> ChatThread {
        let installed = ProviderKind.allCases.filter { providers.status($0).isInstalled && settings.isEnabled($0) }
        // The project's own pair, when it has one, sets the provider before anything else.
        let projectPair = HydraPair.projectPair(project?.hydraPairID, hydraOn: settings.hydraEnabled, in: hydraPickerPairs)
        if projectPair == nil, let selection = modelSelection,
           providers.availableProviders.contains(selection.provider),
           let option = providers.model(selection.modelID, for: selection.provider) {
            let preference = settings.preference(for: selection.provider, model: option.id)
            let effort = selection.effort.flatMap { option.efforts.contains($0) ? $0 : nil }
                ?? preference.effort.flatMap { option.efforts.contains($0) ? $0 : nil }
            return ChatThread(
                projectID: project?.id,
                provider: selection.provider,
                model: option.id,
                effort: effort,
                runtimeMode: settings.defaultRuntimeMode,
                fastMode: option.supportsFast && preference.fastMode
            )
        }
        // With no chat to carry from (a fresh launch), the pair last entered from the
        // picker is where the new chat starts. Before any pair has been entered since
        // this was remembered, the chat last worked in stands in: its pair if it led one,
        // and none if it had left its pair for a model of its own.
        let lastPairID = settings.lastHydraPairID
            ?? threads.filter { !$0.isHelper && (project != nil || $0.projectID == nil) }.max { $0.updatedAt < $1.updatedAt }?.hydraPairID
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
            projectID: project?.id,
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
            thread.hydraPairID = inheritableHydraPair(from: current, into: project)
            thread.temporaryHydraPair = thread.hydraPairID == nil ? nil : current?.temporaryHydraPair
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
        defer { if isLibraryLoaded { announceLoweredPermissions() } }
        guard thread != previous else { return }
        if Self.controlListMembershipChanged(previous, thread) { controlThreadMembershipRevision &+= 1 }
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

    private static func controlListMembershipChanged(_ previous: ChatThread, _ thread: ChatThread) -> Bool {
        previous.id != thread.id || previous.projectID != thread.projectID
            || previous.title != thread.title || previous.isArchived != thread.isArchived
            || previous.parentThreadID != thread.parentThreadID || previous.isHydraHead != thread.isHydraHead
    }

    private static func structureChanged(_ previous: ChatThread, _ thread: ChatThread) -> Bool {
        previous.id != thread.id || previous.projectID != thread.projectID
            || previous.parentThreadID != thread.parentThreadID
            || previous.isArchived != thread.isArchived
            || previous.isInPanel != thread.isInPanel || previous.isHydraHead != thread.isHydraHead
            || previous.hydra?.index != thread.hydra?.index
            || previous.isPinned != thread.isPinned || previous.sortOrder != thread.sortOrder
            || previous.createdAt != thread.createdAt || previous.updatedAt != thread.updatedAt
            || previous.activityOrder != thread.activityOrder
            || previous.activityOrderDay != thread.activityOrderDay
            || previous.foldsHelpers != thread.foldsHelpers
    }

    /// Moves a thread to another project's folder: what the old folder's session and
    /// worktree left on it goes, the destination project opens so the row has a place to
    /// land, the last-worked-in project follows, and the sidebar is asked to bring the
    /// moved row into view. The runtime stops first, so no turn carries on against a
    /// folder the chat has left. Wrap the call in `withAnimation` to make the move glide
    /// in the sidebar; the model itself never animates.
    /// Commit the irreversible "has sent" boundary before handing work to a provider.
    func beginThreadTurn(_ id: UUID) -> Bool {
        guard let thread = thread(id) else { return false }
        if thread.hasStartedTurn { return true }
        updateThread(id) { $0.hasStartedTurn = true }
        guard persistenceEnabled else { return true }
        guard commitLibrary(currentLibrary()) else {
            updateThread(id) { $0.hasStartedTurn = false }
            return false
        }
        return true
    }

    func canChangeThreadAffiliation(_ id: UUID) -> Bool {
        guard let thread = thread(id), !thread.isHelper, !thread.isArchived, !thread.hasStartedTurn,
              thread.lastStatus == nil, !creatingWorktrees.contains(id), children(of: id).isEmpty else { return false }
        guard let runtime = existingRuntime(for: id) else { return true }
        return !runtime.isRunning && !runtime.isLoadingHistory && runtime.turns.isEmpty && !runtime.hasSentPrompts
    }

    func moveThread(_ id: UUID, toProject project: Project) {
        guard let thread = thread(id), self.project(project.id) != nil else { return }
        if thread.projectID == nil {
            _ = moveThread(id, to: .project(project.id))
        } else {
            applyThreadAffiliation(id, .project(project.id))
        }
    }

    @discardableResult
    func moveThread(_ id: UUID, to affiliation: ThreadAffiliation) -> Bool {
        guard let thread = thread(id) else { return false }
        if thread.affiliation == affiliation { return true }
        guard canChangeThreadAffiliation(id) else { return false }
        do {
            guard try !Storage.hasStoredTurns(id) else { return false }
            if let projectID = affiliation.projectID, project(projectID) == nil {
                throw ProviderError.failed(Chrome.localized("This thread's project is unavailable."))
            }
            applyThreadAffiliation(id, affiliation)
            return true
        } catch {
            alert = AppAlert(title: "Could not change thread location", message: error.localizedDescription)
            return false
        }
    }

    private func applyThreadAffiliation(_ id: UUID, _ affiliation: ThreadAffiliation) {
        existingRuntime(for: id)?.stopSession()
        terminals.closeAll(for: id)
        updateThread(id) { thread in
            thread.projectID = affiliation.projectID
            thread.worktreePath = nil
            thread.branch = nil
            thread.controlWorkspace = nil
            thread.providerSessionID = nil
            thread.providerResumeAt = nil
            if affiliation == .standalone {
                thread.hydraPairID = nil
                thread.temporaryHydraPair = nil
            }
        }
        if let projectID = affiliation.projectID { updateProject(projectID) { $0.isExpanded = true } }
        rememberAffiliation(affiliation)
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

    @ObservationIgnored private var announcedPermissionLowerings: Set<String> = []

    @discardableResult
    private func announceLoweredPermissions() -> Bool {
        let lowerings = PermissionLowering.drain()
        guard !lowerings.isEmpty else { return false }
        for lowered in lowerings {
            let key = "\(lowered.provider.rawValue)|\(lowered.from.rawValue)|\(lowered.to.rawValue)"
            guard announcedPermissionLowerings.insert(key).inserted else { continue }
            alert = AppAlert(
                title: "Permissions changed",
                message: String(format: Chrome.localized("Switched to %@: %@ does not support %@ permissions."),
                                Chrome.localized(lowered.to.title), lowered.provider.displayName, Chrome.localized(lowered.from.title))
            )
        }
        return true
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

    /// An archive asked for with the shortcut, which the thread's row takes up as a
    /// question on itself.
    struct ArchiveRequest: Equatable {
        let id = UUID()
        let threadID: UUID
    }

    var archiveRequest: ArchiveRequest?

    func delete(_ id: UUID, removeWorktree: Bool = false) {
        guard thread(id) != nil else { return }
        deleteThreads(descendantsIncluding([id]), removeWorktree: removeWorktree ? id : nil)
    }

    /// Deletes archived chats and their helpers after their removal is safely on disk.
    func deleteArchivedThreads() {
        deleteThreads(descendantsIncluding(threads.filter(\.isArchived).map(\.id)))
    }

    /// Deletes the selected archived chats and their helpers, as a single delete does.
    func deleteArchivedThreads(ids: Set<UUID>) {
        deleteThreads(descendantsIncluding(threads.filter { $0.isArchived && ids.contains($0.id) }.map(\.id)))
    }

    private func descendantsIncluding(_ roots: [UUID]) -> [ChatThread] {
        var ids = Set(roots)
        var pending = roots
        while let id = pending.popLast() {
            for child in children(of: id) where ids.insert(child.id).inserted { pending.append(child.id) }
        }
        return threads.filter { ids.contains($0.id) }
    }

    private struct ThreadDeletionCleanup {
        let directory: String
        let id: UUID
        let copy: String?
        let patchBase: String?
        let headName: String?
    }

    private func deletionCleanup(for removed: [ChatThread], removeWorktree: UUID? = nil) -> [ThreadDeletionCleanup] {
        removed.compactMap { thread in
            guard let directory = try? executionDirectory(for: thread) else { return nil }
            let ownsCopy = thread.hydra?.hasOwnCopy == true
                || (!thread.isHelper && thread.id == removeWorktree)
            let copy = ownsCopy ? thread.worktreePath : nil
            let safeCopy = copy.flatMap { path -> String? in
                let url = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
                let managed = Storage.worktreesDirectory.resolvingSymlinksInPath().standardizedFileURL.path + "/"
                guard url.path.hasPrefix(managed),
                      !projects.contains(where: {
                          let path = URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().standardizedFileURL.path
                          return path == url.path || path.hasPrefix(url.path + "/")
                      }),
                      thread.hydra?.targetCheckout.map({ URL(fileURLWithPath: $0).resolvingSymlinksInPath().standardizedFileURL == url }) != true,
                      !threads.contains(where: { $0.id == thread.parentThreadID && $0.worktreePath == path }) else { return nil }
                return path
            }
            // Unfinished or unlanded work in a head's own copy is kept as a patch before
            // the copy goes, so the base it diffs against and the head's name are
            // captured here too (see completeThreadDeletion).
            let keepsPatch = safeCopy != nil && thread.hydra.map { info in
                info.hasOwnCopy && (!info.isFinished || !(info.landing?.landed == true || info.landing?.isEmpty == true))
            } == true
            // Capture the actual checkout before its project and runtime disappear.
            return ThreadDeletionCleanup(directory: directory, id: thread.id, copy: safeCopy,
                                         patchBase: keepsPatch ? thread.hydra?.baseTree : nil,
                                         headName: keepsPatch ? thread.hydra?.persona.name : nil)
        }
    }

    private func deleteThreads(_ removed: [ChatThread], removeWorktree: UUID? = nil) {
        guard !removed.isEmpty else { return }
        let ids = Set(removed.map(\.id))
        let cleanup = deletionCleanup(for: removed, removeWorktree: removeWorktree)
        var library = currentLibrary()
        library.threads.removeAll { ids.contains($0.id) }
        guard commitLibrary(library) else { return }
        completeThreadDeletion(removed, cleanup: cleanup)
        updateDockBadge()
        scheduleSave()
    }

    private func completeThreadDeletion(_ removed: [ChatThread], cleanup: [ThreadDeletionCleanup]) {
        let ids = Set(removed.map(\.id))
        if let voiceThreadID = voice.threadID, ids.contains(voiceThreadID) { voice.end() }
        for thread in removed where thread.isHydraHead && thread.hydra?.isFinished == false {
            finishHydraHead(thread.id, status: .interrupted, summary: nil)
        }
        if let selectedThreadID, ids.contains(selectedThreadID) { selectNeighbor(of: selectedThreadID) }
        threads.removeAll { ids.contains($0.id) }
        if let selectedThreadID, ids.contains(selectedThreadID) { self.selectedThreadID = nil }
        for thread in removed { discardThreadState(thread, deletingDocument: false) }
        Storage.deleteDocuments(removed.map(\.id))
        Task {
            // Helpers can share a parent's checkout, so clear every checkpoint before
            // removing any of the owned worktrees those refs are reached through.
            for item in cleanup { await Git(item.directory).deleteCheckpoints(thread: item.id) }
            for item in cleanup {
                guard let copy = item.copy else { continue }
                do {
                    if let base = item.patchBase {
                        // The work survives in the patch, so the copy goes even with changes.
                        guard await keepHydraCopyAsPatch(item.id, name: item.headName ?? "head", copy: copy, base: base) else {
                            alert = AppAlert(title: "Could not remove worktree", message: Chrome.localized("The head's unfinished work could not be preserved. Its copy was kept so you can retry."))
                            continue
                        }
                    } else {
                        guard let status = await Git(copy).status(), status.changedFiles == 0 else {
                            alert = AppAlert(title: "Could not remove worktree", message: Chrome.localized("The worktree has changes or could not be inspected. Its files were kept."))
                            continue
                        }
                    }
                    let root = try await Git(item.directory).repositoryRoot()
                    try await Git(root.path).removeWorktree(at: copy)
                } catch {
                    alert = AppAlert(title: "Could not remove worktree", message: error.localizedDescription)
                }
            }
        }
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
        hydraHeadRetries[thread.id] = nil
        runtimeLastAccess[thread.id] = nil
        idleSessionStops.removeValue(forKey: thread.id)?.cancel()
        runtimes[thread.id]?.cancelPersistence()
        runtimes[thread.id]?.failExternalControl(ControlFailure(code: .notFound))
        runtimes[thread.id]?.stopSession()
        runtimes[thread.id] = nil
        updateTaskSleepPrevention()
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
        terminals.run(script, threadID: threadID, directory: thread.executionDirectory(projectPath: project.path))
        runtime(for: threadID).isTerminalVisible = true
    }

    /// An explicit user navigation acknowledges only the result currently on this thread.
    func openThread(_ id: UUID) {
        guard let thread = thread(id) else { return }
        markRead(id, revision: thread.unreadRevision)
        selectedThreadID = id
    }

    func selectThread(offset: Int) {
        let order = sidebarThreads
        guard !order.isEmpty else { return }
        guard let current = selectedThreadID, let index = order.firstIndex(where: { $0.id == current }) else {
            if let first = order.first { openThread(first.id) }
            return
        }
        openThread(order[(index + offset + order.count) % order.count].id)
    }

    func selectThread(number: Int) {
        let order = sidebarThreads
        guard order.indices.contains(number - 1) else { return }
        openThread(order[number - 1].id)
    }

    /// The longest branch name Tivano accepts, in characters; git's own limit is a
    /// 255-byte file name per path component, and a CJK character takes three.
    static let branchNameLimit = 60

    /// Letters of any script (Chinese included), digits and `-_./`. Git accepts more, but
    /// quotes, `$`, backticks, `@` and emoji break the unquoted shell commands agents
    /// write and many CI tools that reuse branch names.
    private static let branchNameCharacters = CharacterSet.letters.union(.decimalDigits)
        .union(CharacterSet(charactersIn: "-_./"))

    /// What the user typed, with its spaces turned into dashes.
    static func normalizedBranchName(_ raw: String) -> String {
        raw.trimmed.replacingOccurrences(of: #"\s+"#, with: "-", options: .regularExpression)
    }

    static func suggestedBranchName(title: String, threadID: UUID) -> String {
        let fallback = "tivano/\(threadID.uuidString.lowercased().prefix(8))"
        let title = title.trimmed
        guard title != ChatThread.untitled else { return fallback }
        // The slug keeps letters, digits, `-` and `_`; everything else, `.` and `/` included, becomes a dash.
        let kept = CharacterSet.letters.union(.decimalDigits).union(CharacterSet(charactersIn: "-_"))
        let replaced = title.unicodeScalars.map { kept.contains($0) ? String($0) : "-" }.joined()
        let slug = String(replaced.replacingOccurrences(of: "-+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-")).prefix(40))
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return slug.isEmpty ? fallback : "tivano/\(slug)"
    }

    enum BranchNameCheck {
        case accepted(String)
        case rejected(String)
        /// The branch has an upstream: renaming it locally leaves the remote branch and any
        /// pull request under the old name, so the user confirms first.
        case pushed(name: String, upstream: String)
    }

    /// Checks a new name for a worktree's branch, or for the branch of a worktree about to
    /// be created when `renaming` is nil. `directory` is any checkout of the repository.
    func checkBranchName(_ raw: String, in directory: String, renaming old: String?) async -> BranchNameCheck {
        let name = Self.normalizedBranchName(raw)
        guard !name.isEmpty, name != old else { return .rejected("") }
        guard name.count <= Self.branchNameLimit else {
            return .rejected(String(format: AppText.localized("Branch names can be up to %lld characters."), Self.branchNameLimit))
        }
        guard name.unicodeScalars.allSatisfy(Self.branchNameCharacters.contains) else {
            return .rejected(AppText.localized("Branch names can use letters, numbers and - _ . / only."))
        }
        let git = Git(directory)
        guard await git.isValidBranchName(name) else {
            return .rejected(AppText.localized("That is not a valid branch name."))
        }
        let branches = await git.branches()
        // macOS folds case in ref files, so a name differing only in case collides too.
        guard !branches.contains(where: { $0.name != old && $0.name.lowercased() == name.lowercased() }) else {
            return .rejected(AppText.localized("A branch with that name already exists."))
        }
        guard let old else { return .accepted(name) }
        guard await !git.hasOperationInProgress() else {
            return .rejected(AppText.localized("Finish or abort the merge, rebase or cherry-pick in progress, then rename the branch."))
        }
        if let upstream = branches.first(where: { $0.name == old })?.upstream {
            return .pushed(name: name, upstream: upstream)
        }
        return .accepted(name)
    }

    /// Renames a worktree's branch to a name `checkBranchName` accepted.
    func renameWorktreeBranch(_ threadID: UUID, to name: String) async {
        guard let thread = thread(threadID), let path = thread.worktreePath, let old = thread.branch, name != old else { return }
        let git = Git(path)
        do {
            try await git.renameBranch(old, to: name)
            let ids = threads.filter { $0.projectID == thread.projectID && $0.branch == old }.map(\.id)
            updateThreads(ids) { _, thread in thread.branch = name }
        } catch {
            alert = AppAlert(title: "Could not rename branch", message: error.localizedDescription)
        }
    }

    func createWorktree(for threadID: UUID, branch: String? = nil) async {
        guard let thread = thread(threadID), thread.worktreePath == nil, let project = project(thread.projectID),
              creatingWorktrees.insert(threadID).inserted else { return }
        defer { creatingWorktrees.remove(threadID) }
        updateThread(threadID) { $0.controlWorkspace = ControlWorkspace(mode: .worktree, phase: .preparing, enforcesExecutionReadiness: false) }
        let git = Git(project.path)
        guard await git.isRepository(), await git.hasCommits() else {
            updateThread(threadID) { $0.controlWorkspace?.phase = .failed; $0.controlWorkspace?.failure = ControlFailure(code: .workspaceFailed) }
            alert = AppAlert(title: "Worktree unavailable", message: "New worktrees need a git repository with at least one commit.")
            return
        }
        let suffix = String(threadID.uuidString.lowercased().prefix(8))
        let folder = project.name.replacingOccurrences(of: " ", with: "-").lowercased()
        let path = Storage.worktreesDirectory.appendingPathComponent("\(folder)-\(suffix)").path
        let branch = branch ?? "tivano/\(suffix)"
        let base = await git.status()?.branch
        guard self.thread(threadID)?.affiliation == thread.affiliation else { return }
        do {
            try await git.addWorktree(at: path, branch: branch, base: base)
            updateThread(threadID) {
                $0.worktreePath = path
                $0.branch = branch
                let unobservedSetup = project.scripts.contains(where: \.runOnWorktreeCreate)
                $0.controlWorkspace = ControlWorkspace(mode: .worktree, phase: unobservedSetup ? .failed : .ready,
                                                       failure: unobservedSetup ? ControlFailure(code: .unsupported, detail: "ui_setup_completion_unobserved") : nil,
                                                       enforcesExecutionReadiness: false)
            }
            for script in project.scripts where script.runOnWorktreeCreate {
                terminals.run(script, threadID: threadID, directory: path)
                runtime(for: threadID).isTerminalVisible = true
            }
        } catch {
            updateThread(threadID) { $0.controlWorkspace?.phase = .failed; $0.controlWorkspace?.failure = ControlFailure(code: .workspaceFailed) }
            alert = AppAlert(title: "Could not create a worktree", message: error.localizedDescription)
        }
    }

    // MARK: - Attention

    @ObservationIgnored private var deferredResults: [UUID: (status: TurnStatus, turnID: UUID)] = [:]

    func publishDeferredResult(_ id: UUID, status: TurnStatus? = nil) {
        guard let result = deferredResults[id] else { return }
        turnFinished(id, status: status ?? result.status, continues: false, turnID: result.turnID, userStopped: false)
    }

    func clearDeferredResult(_ id: UUID) { deferredResults[id] = nil }

    @ObservationIgnored var threadViewVisibility: [UUID: (threadID: UUID, visible: () -> Bool)] = [:]

    func isOnScreen(_ thread: ChatThread) -> Bool {
        NSApp?.isActive == true && threadViewVisibility.values.contains {
            $0.threadID == thread.id && $0.visible()
        }
    }

    func markRead(_ id: UUID, revision: UUID?) {
        guard let thread = thread(id), thread.hasUnread,
              thread.unreadRevision == revision else { return }
        updateThread(id) { $0.hasUnread = false }
        updateDockBadge()
    }

    func threadNeedsAttention(_ id: UUID) {
        guard !CaptureRun.isEnabled, let thread = thread(id) else { return }
        // Visible requests need no banner; opening them does not resolve the request.
        if NSApp?.isActive == true && isOnScreen(thread) {
            return
        }
        notify(threadID: id, title: thread.title, body: "Waiting for your decision.")
        NSApp?.requestUserAttention(.informationalRequest)
    }

    /// A turn ended. `continues` means a queued message picks up right away, so the agent is
    /// still at work and neither the chime nor a notification claims otherwise.
    func turnFinished(_ id: UUID, status: TurnStatus, continues: Bool, turnID: UUID, userStopped: Bool) {
        defer {
            if let parentID = thread(id)?.parentThreadID { publishDeferredResult(parentID) }
        }
        guard thread(id)?.lastAttentionTurnID != turnID else { return }
        let isVisible = thread(id).map(isOnScreen) ?? false
        let isHead = thread(id)?.isHydraHead == true
        let waitingForLimit = autoContinue.turnFinished(id, status: status, continues: continues)
        let runtime = existingRuntime(for: id)
        let stillWorking = continues || waitingForLimit || runtime?.isWaitingForLimit == true || runtime?.isRunning == true
            || runtime?.isHydraMerging == true || runtime?.hasWorkingHelpers == true
            || !(runtime?.backgroundTasks.isEmpty ?? true)
        if !isHead && !userStopped && !continues && stillWorking {
            deferredResults[id] = (status, turnID)
        } else if !stillWorking || continues || userStopped {
            deferredResults[id] = nil
        }
        updateThread(id) {
            // A queued successor may already have started: do not replace its running status.
            if runtime?.isRunning != true { $0.lastStatus = status }
            $0.updatedAt = .now
            $0.pendingResultTurnID = stillWorking && !userStopped ? turnID : nil
            if !stillWorking { $0.lastAttentionTurnID = turnID }
            $0.unreadRevision = UUID()
            $0.hasUnread = !isHead && !stillWorking && !userStopped && status != .running
            $0.unreadStatus = $0.hasUnread ? status : nil
        }
        updateDockBadge()
        if sessionsToRelease.remove(id) != nil { runtime?.stopSession() }
        if isHead, let head = thread(id) {
            if !continues { hydraHeadTurnFinished(head, status: status) }
            return
        }
        guard !stillWorking, !userStopped else { return }
        let chimed = settings.chimeWhenFinished && status != .interrupted
        if chimed { FinishChime.play() }
        guard !isVisible, settings.notifyWhenFinished, let thread = thread(id) else { return }
        let body = switch status {
        case .completed: "Finished."
        case .interrupted: "Stopped."
        case .failed: "Stopped with an error."
        case .running: ""
        }
        notify(threadID: id, title: thread.title, body: body, sound: chimed ? nil : .default)
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
        if NSApp?.isActive == true, let thread = thread(threadID), isOnScreen(thread) { return }
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
        NSApp?.dockTile.badgeLabel = unread > 0 ? String(unread) : nil
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

    // MARK: - Parameterized external creation (no selection, draft or pair inheritance)

    func controlWorkspace(for thread: ChatThread) -> ControlWorkspace {
        if creatingWorktrees.contains(thread.id) {
            var workspace = thread.controlWorkspace ?? ControlWorkspace(mode: .worktree, phase: .preparing, enforcesExecutionReadiness: false)
            workspace.phase = .preparing
            return workspace
        }
        if let workspace = thread.controlWorkspace { return workspace }
        if thread.worktreePath != nil, project(thread.projectID)?.scripts.contains(where: \.runOnWorktreeCreate) == true {
            return ControlWorkspace(mode: .worktree, phase: .failed,
                                    failure: ControlFailure(code: .unsupported, detail: "ui_setup_completion_unobserved"), enforcesExecutionReadiness: false)
        }
        return ControlWorkspace(mode: thread.worktreePath == nil ? .local : .worktree, phase: .ready)
    }

    func requireExternalPersistence() throws {
        guard isLibraryLoaded, persistenceEnabled, !libraryWritesBlocked, !CaptureRun.isEnabled else {
            throw ControlFailure(code: .persistence)
        }
        guard !localControl.isShuttingDown else { throw ControlFailure(code: .shutdown) }
    }

    func commitExternalLibrary() throws {
        try requireExternalPersistence()
        guard commitLibrary(currentLibrary()) else { throw ControlFailure(code: .persistence) }
    }

    func createExternalThread(_ request: ControlCreate, provider: ProviderKind) throws -> ChatThread {
        try requireExternalPersistence()
        if let projectID = request.projectID, project(projectID) == nil { throw ControlFailure(code: .missingProject) }
        guard request.workspace != .worktree || request.projectID != nil else { throw ControlFailure(code: .unsupported) }
        // Never grant permissions implicitly to a provider that cannot ask first.
        guard provider.supports(.supervised) else { throw ControlFailure(code: .unsupported) }
        if let project = project(request.projectID) { try Self.requireControlDirectory(project.path) }
        var thread = ChatThread(projectID: request.projectID, provider: provider, model: request.model,
                                effort: nil, runtimeMode: .supervised)
        thread.hydraEnabled = false
        thread.hydraPairID = nil
        thread.temporaryHydraPair = nil
        thread.controlWorkspace = ControlWorkspace(mode: request.workspace, phase: request.workspace == .worktree ? .preparing : .ready)
        var library = currentLibrary()
        library.threads.append(thread)
        guard commitLibrary(library) else { throw ControlFailure(code: .persistence) }
        threads.append(thread)
        return thread
    }

    static func requireControlDirectory(_ path: String) throws {
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &directory), directory.boolValue,
              FileManager.default.isReadableFile(atPath: path), FileManager.default.isWritableFile(atPath: path) else {
            throw ControlFailure(code: .directoryUnavailable)
        }
    }

    /// Unlike the UI terminal path, setup is complete only after every configured script
    /// exits successfully. Failed worktrees are retained, explicitly unusable, for review.
    func prepareExternalWorktree(_ id: UUID) async throws {
        guard let original = thread(id), original.controlWorkspace?.phase == .preparing,
              let project = project(original.projectID), creatingWorktrees.insert(id).inserted else {
            throw ControlFailure(code: .workspaceFailed)
        }
        defer { creatingWorktrees.remove(id) }
        do {
            let git = Git(project.path)
            guard await git.isRepository(), await git.hasCommits() else { throw ControlFailure(code: .workspaceFailed, detail: "repository_requires_commit") }
            try requireExternalWorkspaceOwner(id, original: original, projectPath: project.path)
            let suffix = id.uuidString.lowercased()
            let path = Storage.worktreesDirectory.appendingPathComponent("control-\(suffix)").path
            let branch = "tivano/control-\(suffix)"
            // Git resolves HEAD at creation; never silently substitute another checkout.
            try await git.addWorktree(at: path, branch: branch, base: "HEAD")
            try requireExternalWorkspaceOwner(id, original: original, projectPath: project.path)
            updateThread(id) { $0.worktreePath = path; $0.branch = branch }
            try commitExternalLibrary()
            let scripts = project.scripts.filter(\.runOnWorktreeCreate)
            guard scripts.count <= 16 else { throw ControlFailure(code: .bounds) }
            for script in scripts {
                try requireExternalWorkspaceOwner(id, original: original, projectPath: project.path)
                let result = try await Shell.run(URL(fileURLWithPath: "/bin/zsh"), ["-lc", script.command],
                                                in: URL(fileURLWithPath: path), timeout: 120, outputLimit: 8_192)
                guard result.succeeded else { throw ControlFailure(code: .workspaceFailed, detail: "setup_exit_\(result.status)") }
            }
            try requireExternalWorkspaceOwner(id, original: original, projectPath: project.path)
            try Self.requireControlDirectory(path)
            updateThread(id) { $0.controlWorkspace?.phase = .ready }
            try commitExternalLibrary()
        } catch {
            let failure = error as? ControlFailure ?? ControlFailure(code: .workspaceFailed)
            updateThread(id) { $0.controlWorkspace?.phase = .failed; $0.controlWorkspace?.failure = failure }
            // If even the failed state cannot persist, report persistence, never ready.
            try commitExternalLibrary()
            throw failure
        }
    }

    private func requireExternalWorkspaceOwner(_ id: UUID, original: ChatThread, projectPath: String) throws {
        try requireExternalPersistence()
        guard let current = thread(id), current.affiliation == original.affiliation, !current.isArchived,
              current.controlWorkspace?.phase == .preparing, project(current.projectID)?.path == projectPath else {
            throw ControlFailure(code: .workspaceFailed)
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
        guard persistenceEnabled, isLibraryLoaded, !libraryWritesBlocked, saveTask == nil else { return }
        let sinceLast = lastLibrarySave.map { ContinuousClock.now - $0 } ?? .seconds(60)
        let wait = max(.milliseconds(400), .seconds(4) - sinceLast)
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled, let self else { return }
            self.saveTask = nil
            self.saveLibrary()
        }
    }

    private func currentLibrary() -> Library {
        var library = Library()
        library.projects = projects
        library.threads = threads
        return library
    }

    private func showLibrarySaveFailure() {
        guard !librarySaveFailureShown else { return }
        librarySaveFailureShown = true
        alert = AppAlert(title: "Could not save the library", message: "Tivano couldn't save your changes to disk. Your chats are kept in memory and saving will be retried. Free up disk space or check folder permissions before quitting.")
    }

    private func saveLibrary() {
        guard isLibraryLoaded, persistenceEnabled, !libraryWritesBlocked else { return }
        lastLibrarySave = .now
        DiskWriter.shared.encodeAndWrite(currentLibrary(), to: Storage.libraryURL) { [weak self] success in
            Task { @MainActor [weak self] in
                guard let self, self.persistenceEnabled else { return }
                if success { self.librarySaveFailureShown = false }
                else {
                    self.showLibrarySaveFailure()
                    self.scheduleSave()
                }
            }
        }
    }

    /// Destructive actions cannot run until the index that forgets their files is durable.
    /// `duringShutdown` lets the quit flush write after `persistenceEnabled` was switched
    /// off: quit flushes twice — once before sessions stop, once after the MCP shutdown —
    /// and the second pass still persists what that window changed.
    private func commitLibrary(_ library: Library, duringShutdown: Bool = false) -> Bool {
        guard isLibraryLoaded, duringShutdown || persistenceEnabled, !libraryWritesBlocked else { return false }
        saveTask?.cancel()
        saveTask = nil
        guard DiskWriter.shared.writeSynchronously(library, to: Storage.libraryURL) else {
            showLibrarySaveFailure()
            scheduleSave()
            return false
        }
        lastLibrarySave = .now
        librarySaveFailureShown = false
        return true
    }

    /// Flush recovery metadata before an opt-in provider archive. A capture or a disk
    /// write failure cannot authorize a provider-side change.
    func saveProviderHistoryIntent() async throws {
        guard isLibraryLoaded, persistenceEnabled, !libraryWritesBlocked, !CaptureRun.isEnabled else {
            throw ProviderError.failed(Chrome.localized("Provider history changes require a persistent library."))
        }
        var library = Library()
        library.projects = projects
        library.threads = threads
        try await DiskWriter.shared.writeOrThrow(library, to: Storage.libraryURL)
        lastLibrarySave = .now
    }

    /// The updater also uses this barrier before starting its external installer.
    func flushForQuit() -> Bool {
        // No externally-admitted operation may write beyond the updater's flush barrier.
        // Refuse rather than silently cancel accepted turns or half-created worktrees.
        localControl.suspendForShutdown()
        var flushed = false
        defer { if !flushed { localControl.restoreAfterFailedShutdown() } }
        guard !localControl.hasPendingMutations else {
            alert = AppAlert(title: "Local control is busy", message: "Wait for accepted local-control operations to end before quitting or updating.")
            return false
        }
        guard isLibraryLoaded else { return false }
        for runtime in runtimes.values {
            if let snapshot = runtime.unsavedSnapshot(), !DiskWriter.shared.writeThreadSynchronously(snapshot) {
                showLibrarySaveFailure()
                runtime.saveNow()
                return false
            }
        }
        if libraryWritesBlocked {
            if !projects.isEmpty || !threads.isEmpty {
                guard let libraryRecoveryURL,
                      DiskWriter.shared.writeSynchronously(currentLibrary(), to: libraryRecoveryURL) else {
                    showLibrarySaveFailure()
                    return false
                }
            }
        } else if !commitLibrary(currentLibrary(), duringShutdown: true) {
            return false
        }
        DiskWriter.shared.waitForQueuedWrites()
        flushed = true
        return true
    }

    /// Writes everything before stopping sessions, so a failed quit can still retry.
    @discardableResult
    func saveBeforeQuit() -> Bool {
        guard flushForQuit() else { return false }
        voice.shutdown()
        persistenceEnabled = false
        saveTask?.cancel()
        saveTask = nil
        for runtime in runtimes.values {
            runtime.cancelPersistence()
            runtime.stopSession()
        }
        terminals.terminateAll()
        return true
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
