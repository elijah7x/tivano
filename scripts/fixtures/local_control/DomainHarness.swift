import Foundation
import Observation

// Only surrounding framework/provider/storage dependencies are synthetic. Selected
// production declarations are injected verbatim by local_control_domain_checks.py.
// No App entry point, real Store, account, process, UI or user defaults is initialized.
enum RuntimeMode: String, Codable, Sendable { case supervised, fullAccess, autoAcceptEdits }
enum ProviderKind: String, Codable, CaseIterable, Sendable {
    case codex, claude, cursor, opencode, grok, deepseek, meta, zai, devin, antigravity, copilot, commandcode, pi, kimi, omp, dsh
    var isAPIKeyBased: Bool { [.deepseek, .meta, .zai].contains(self) }
    func supports(_ mode: RuntimeMode) -> Bool { self != .dsh || mode != .supervised }
    func supported(_ mode: RuntimeMode) -> RuntimeMode { supports(mode) ? mode : .autoAcceptEdits }
}
enum DshAgentMode: String, Codable, Sendable { case standard }
enum InteractionMode: String, Codable, Sendable { case build, plan }
enum TurnStatus: String, Codable, Sendable { case running, completed, interrupted, failed }
struct HydraPair: Codable, Hashable, Sendable { var id = UUID() }
struct HydraHeadInfo: Codable, Hashable, Sendable { var targetCheckout: String? }
enum PermissionLowering { static func note(provider: ProviderKind, from: RuntimeMode, to: RuntimeMode) {} }
struct EmptyDefaults: Sendable {
    static let standard = EmptyDefaults()
    func object(forKey: String) -> Any? { nil }
}
enum CaptureRun {
    static let isEnabled = false
    static let defaults: EmptyDefaults? = .standard
    static let storageRoot: URL? = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
}
enum AppInfo { static let libraryName = "Synthetic Local Control" }
enum Chrome { static func localized(_ key: String) -> String { key } }
enum ProviderError: LocalizedError { case failed(String), notRunning
    var errorDescription: String? { if case .failed(let value) = self { return value }; return "synthetic_not_running" }
}

/* TEXT_GENERATION_PRODUCTION */

@MainActor final class MemoryDefaults {
    var values: [String: Any] = [:]
    func set(_ value: Any?, forKey key: String) { values[key] = value }
}

@MainActor final class Settings {
    enum Key {
        static let alphaEnabled = "alphaEnabled", externalControlEnabled = "externalControlEnabled"
        static let performanceMode = "performanceMode", clearerBackdrop = "clearerBackdrop"
        static let showsSkylight = "showsSkylight", antiSlopEnabled = "antiSlopEnabled", textGeneration = "textGeneration"
        static let cliInstallationTarget = "cliInstallationTarget"
    }
    let defaults = MemoryDefaults()
    var onExternalControlChanged: (() -> Void)?
    var disabled: Set<ProviderKind> = []
    func isEnabled(_ provider: ProviderKind) -> Bool { !disabled.contains(provider) }
    /* SETTINGS_PRODUCTION */
    init() {
        alphaEnabled = false; externalControlEnabled = false; performanceMode = false
        clearerBackdrop = true; showsSkylight = true; antiSlopEnabled = true; textGeneration = .automatic
        cliInstallationTarget = nil
    }
}

struct ProviderStatus: Sendable {
    enum Auth: Sendable { case unknown, signedOut, signedIn(String?) }
    var auth: Auth = .signedIn(nil)
    var isInstalled = true
}
struct ModelOption: Sendable { var id: String; var defaultEffort: String? }
@MainActor final class Registry {
    var statuses: [ProviderKind: ProviderStatus] = [:]
    var catalog = [ModelOption(id: "synthetic-model", defaultEffort: nil)]
    func status(_ provider: ProviderKind) -> ProviderStatus { statuses[provider] ?? ProviderStatus() }
    func models(for provider: ProviderKind) -> [ModelOption] { catalog }
}

@MainActor enum Setup {
    static var isRepository = true
    static var failAdd = false
    static var scriptStarted = false
    static var scriptContinuation: CheckedContinuation<ShellResult, Never>?
}
struct ShellResult: Sendable { var status: Int32; var succeeded: Bool { status == 0 } }
struct Git: Sendable {
    var path: String
    init(_ path: String) { self.path = path }
    @MainActor func isRepository() async -> Bool { Setup.isRepository }
    func hasCommits() async -> Bool { true }
    @MainActor func addWorktree(at path: String, branch: String, base: String?) async throws {
        if Setup.failAdd { throw ProviderError.failed("synthetic_git_failure") }
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }
}
@MainActor enum Shell {
    static func run(_ executable: URL, _ args: [String], in directory: URL, timeout: TimeInterval, outputLimit: Int?) async throws -> ShellResult {
        Setup.scriptStarted = true
        return await withCheckedContinuation { Setup.scriptContinuation = $0 }
    }
}
enum Storage {
    static let worktreesDirectory = CaptureRun.storageRoot!.appendingPathComponent("worktrees", isDirectory: true)
}
@MainActor final class DiskWriter {
    static let shared = DiskWriter()
    var succeeds = true
    func writeThreadSynchronously(_ snapshot: Int) -> Bool { succeeds }
}

/* TURN_UPDATE_PRODUCTION */

@MainActor final class AppModel {
    var projectsRevision: UInt64 = 0
    var threadsRevision: UInt64 = 0
    var controlThreadMembershipRevision: UInt64 = 0
    var projects: [Project] = [] { didSet { projectsRevision &+= 1 } }
    var threads: [ChatThread] = [] { didSet { threadsRevision &+= 1; controlThreadMembershipRevision &+= 1 } }
    var creatingWorktrees: Set<UUID> = []
    var isLibraryLoaded = true
    var persistenceEnabled = true
    var libraryWritesBlocked = false
    var commitSucceeds = true
    var committed: Library?
    var selectedThreadID: UUID?
    var uiDraft = "untouched UI draft"
    let settings = Settings()
    let providers = Registry()
    var localControl = AppControlService()
    var runtimes: [UUID: ThreadRuntime] = [:]
    func project(_ id: UUID?) -> Project? { projects.first { $0.id == id } }
    func thread(_ id: UUID) -> ChatThread? { threads.first { $0.id == id } }
    var existingRuntimeReads = 0
    func existingRuntime(for id: UUID) -> ThreadRuntime? { existingRuntimeReads += 1; return runtimes[id] }
    func children(of id: UUID) -> [ChatThread] { threads.filter { $0.parentThreadID == id } }
    func hydraIsOn(_ thread: ChatThread) -> Bool { thread.hydraEnabled }
    func updateThread(_ id: UUID, _ change: (inout ChatThread) -> Void) { if let index = threads.firstIndex(where: { $0.id == id }) { change(&threads[index]) } }
    func currentLibrary() -> Library { var library = Library(); library.projects = projects; library.threads = threads; return library }
    func commitLibrary(_ library: Library) -> Bool { if commitSucceeds { committed = library }; return commitSucceeds }
    enum Engine { case claude, codex }
    func textEngine(preferring: ProviderKind?) -> Engine? { switch settings.textGeneration { case .off: nil; case .codex: .codex; default: .claude } }
    /* APPMODEL_PRODUCTION */
}

@MainActor final class AppControlService {
    let instance = UUID()
    var isShuttingDown = false
    /* THREAD_CACHE_PRODUCTION */
    /* SERVICE_PRODUCTION */
    func continuation(_ mode: ControlContinuation, _ thread: ChatThread) throws -> ControlContinuation { try resolveContinuation(mode, thread: thread) }
    func settings(_ app: AppModel) -> [ControlSetting] { settingsSnapshot(app) }
    func set(_ write: ControlSettingsWrite, _ app: AppModel) throws { try applySetting(write, app: app) }
    func summaries(_ app: AppModel) -> [ControlProvider] { providerSummaries(app) }
    func query(_ query: ControlThreadQuery, _ app: AppModel) throws -> ControlListPage<ControlThread> { try listThreads(query, app: app) }
}

enum RuntimePhase { case idle, starting, running }
enum ProviderEvent { case turnStarted(providerTurnID: String?), turnCompleted(status: TurnStatus, error: String?), approval }
@MainActor final class ThreadRuntime {
    let threadID: UUID
    let app: AppModel?
    var thread: ChatThread? { app?.thread(threadID) }
    var phase = RuntimePhase.idle
    var isReverting = false, isVoiceOrchestrator = false, isHydraMerging = false, hydraStartupPending = false
    var hasWorkingHelpers = false, isWaitingForLimit = false, hydraFlushScheduled = false, isStartingSession = false
    var backgroundTasks: [String] = [], followUps: [Int] = [], hydraPendingReports: [Int] = [], turns: [Int] = []
    var approvals: [String] = [], questions: [String] = []
    var pendingSend: Int?
    var providerHistoryOperation: Task<Void, Never>?, hydraLanding: Task<Void, Never>?
    var finishingTurnID: UUID?, closingTurnID: UUID?, currentTurnID: UUID?
    var hasSentPrompts = false
    var beforeLoaded: (() -> Void)?
    var sent: [(text: String, id: UUID?)] = []
    var draft = "reader's untouched draft"
    var interruptRequested = false
    var persistenceEnabled = true
    /* RUNTIME_STATE_PRODUCTION */
    init(_ app: AppModel, _ threadID: UUID) { self.app = app; self.threadID = threadID }
    func ensureLoaded() async { await Task.yield(); beforeLoaded?() }
    func startTurn(text: String, attachments: [Int], externalTurnID: UUID?) async { sent.append((text, externalTurnID)); currentTurnID = externalTurnID; phase = .starting }
    func interrupt() { interruptRequested = true }
    func flushFollowUpsIfIdle() {}
    func snapshotForSave() -> Int { 1 }
    /* RUNTIME_PRODUCTION */
    func event(_ event: ProviderEvent) { publishControlEvent(event) }
    func finish(_ turnID: UUID, _ status: TurnStatus) { finishControlTurn(turnID, status: status) }
    func holdSubmission(_ turnID: UUID) { controlSendingTurns.insert(turnID) }
    func unwindSubmission(_ turnID: UUID) { completeControlSubmission(turnID) }
}

@main @MainActor struct DomainChecks {
    static var passed: [String] = []
    static func check(_ condition: @autoclosure () throws -> Bool, _ name: String) throws {
        guard try condition() else { throw Failure(name: name) }; passed.append(name); print("PASS \(name)")
    }
    struct Failure: Error { var name: String }
    static func rejects(_ code: ControlFailure.Code, _ name: String, _ action: () throws -> Void) throws {
        do { try action() } catch let error as ControlFailure { try check(error.code == code, name); return }
        throw Failure(name: "Expected \(code): \(name)")
    }
    static func main() async throws {
        let root = CaptureRun.storageRoot!
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let app = AppModel()
        let ticket = ControlTicket(instance: app.localControl.instance)
        app.selectedThreadID = UUID()
        let selected = app.selectedThreadID
        var request = ControlCreate(ticket: ticket, projectID: nil, workspace: .local, provider: "codex")
        let standalone = try app.createExternalThread(request, provider: .codex)
        try check(standalone.projectID == nil && !standalone.hydraEnabled && standalone.runtimeMode == .supervised, "external creation is standalone, supervised and Hydra-off")
        try check(app.selectedThreadID == selected && app.uiDraft == "untouched UI draft", "external creation does not select or consume draft")
        try check(app.committed?.threads.contains(where: { $0.id == standalone.id }) == true, "creation crosses persistence boundary before publication")
        let taskPath = try app.executionDirectory(for: standalone)
        try check(taskPath == StoragePaths.taskWorkspace(standalone.id).path && !FileManager.default.fileExists(atPath: taskPath), "standalone execution uses owned workspace but query does not create it")
        request.projectID = UUID()
        try rejects(.missingProject, "missing project never becomes standalone") { _ = try app.createExternalThread(request, provider: .codex) }
        app.commitSucceeds = false
        request.projectID = nil
        let count = app.threads.count
        try rejects(.persistence, "creation persistence failure rejects without publication") { _ = try app.createExternalThread(request, provider: .codex) }
        try check(app.threads.count == count, "failed creation leaves thread index unchanged")
        app.commitSucceeds = true
        let projectPath = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectPath, withIntermediateDirectories: true)
        var project = Project(name: "Synthetic project", path: projectPath.path)
        project.scripts = [ProjectScript(name: "setup", command: "never executed by this harness", runOnWorktreeCreate: true)]
        app.projects.append(project)
        let unavailable = Project(name: "Unavailable", path: root.appendingPathComponent("missing-project-directory").path)
        app.projects.append(unavailable)
        request.projectID = unavailable.id
        try rejects(.directoryUnavailable, "unavailable project directory fails without cwd fallback") { _ = try app.createExternalThread(request, provider: .codex) }
        request.projectID = project.id; request.workspace = .worktree
        let worktree = try app.createExternalThread(request, provider: .codex)
        try rejects(.workspacePreparing, "send/directory resolution rejects preparing worktree") { _ = try app.executionDirectory(for: worktree) }
        let preparation = Task { try await app.prepareExternalWorktree(worktree.id) }
        for _ in 0..<1_000 where !Setup.scriptStarted { await Task.yield() }
        try check(Setup.scriptStarted && app.thread(worktree.id)?.controlWorkspace?.phase == .preparing, "spawned setup script is not ready")
        Setup.scriptContinuation?.resume(returning: ShellResult(status: 0)); Setup.scriptContinuation = nil
        try await preparation.value
        try check(app.thread(worktree.id)?.controlWorkspace?.phase == .ready, "successful script completion marks worktree ready")
        try check(try app.executionDirectory(for: app.thread(worktree.id)!) != project.path, "worktree uses explicit checkout, not project fallback")
        Setup.failAdd = true
        let failed = try app.createExternalThread(request, provider: .codex)
        do { try await app.prepareExternalWorktree(failed.id) } catch {}
        try check(app.thread(failed.id)?.controlWorkspace?.phase == .failed, "worktree creation failure is retained explicitly")
        try rejects(.workspaceFailed, "failed worktree never falls back to project directory") { _ = try app.executionDirectory(for: app.thread(failed.id)!) }
        Setup.failAdd = false
        Setup.scriptStarted = false
        let setupFailure = try app.createExternalThread(request, provider: .codex)
        let unsuccessfulSetup = Task { try await app.prepareExternalWorktree(setupFailure.id) }
        for _ in 0..<1_000 where !Setup.scriptStarted { await Task.yield() }
        Setup.scriptContinuation?.resume(returning: ShellResult(status: 1)); Setup.scriptContinuation = nil
        do { try await unsuccessfulSetup.value } catch {}
        try check(app.thread(setupFailure.id)?.controlWorkspace?.phase == .failed && app.thread(setupFailure.id)?.worktreePath != nil, "failed setup keeps checkout but does not mark ready")
        try rejects(.workspaceFailed, "failed setup cannot send in project or worktree") { _ = try app.executionDirectory(for: app.thread(setupFailure.id)!) }
        Setup.scriptStarted = false
        let changedProject = try app.createExternalThread(request, provider: .codex)
        let changedPreparation = Task { try await app.prepareExternalWorktree(changedProject.id) }
        for _ in 0..<1_000 where !Setup.scriptStarted { await Task.yield() }
        let projectIndex = app.projects.firstIndex { $0.id == project.id }!
        app.projects[projectIndex].path = root.appendingPathComponent("changed-project-path").path
        Setup.scriptContinuation?.resume(returning: ShellResult(status: 0)); Setup.scriptContinuation = nil
        do { try await changedPreparation.value } catch {}
        try check(app.thread(changedProject.id)?.controlWorkspace?.phase == .failed, "project path mutation during setup fails rather than switching directories")
        app.projects[projectIndex].path = project.path
        request.workspace = .local
        let local = try app.createExternalThread(request, provider: .codex)
        try check(try app.executionDirectory(for: local) == project.path, "local project directory is explicit")
        app.creatingWorktrees.insert(local.id)
        try rejects(.workspacePreparing, "UI worktree preparation overrides a previously-ready local workspace for CLI admission") { _ = try app.localControl.requireOrdinaryThread(local.id, app: app) }
        app.creatingWorktrees.remove(local.id)
        var legacyUI = local; legacyUI.id = UUID(); legacyUI.worktreePath = root.appendingPathComponent("legacy-worktree").path; legacyUI.controlWorkspace = nil
        app.threads.append(legacyUI)
        try rejects(.unsupported, "unobserved UI terminal setup cannot be advertised CLI-ready") { _ = try app.localControl.requireOrdinaryThread(legacyUI.id, app: app) }
        var failedUI = local; failedUI.id = UUID()
        failedUI.controlWorkspace = ControlWorkspace(mode: .worktree, phase: .failed, failure: ControlFailure(code: .workspaceFailed), enforcesExecutionReadiness: false)
        app.threads.append(failedUI)
        try rejects(.workspaceFailed, "UI worktree failure never authorizes CLI project-directory fallback") { _ = try app.localControl.requireOrdinaryThread(failedUI.id, app: app) }

        var callbacks = 0
        app.settings.onExternalControlChanged = { callbacks += 1 }
        try check(!app.settings.externalControlEnabled && !app.settings.isExternalControlEnabled, "dedicated control permission defaults false")
        app.settings.externalControlEnabled = true
        try check(!app.settings.isExternalControlEnabled, "Alpha remains an independent gate")
        app.settings.alphaEnabled = true
        try check(app.settings.isExternalControlEnabled, "both gates are required")
        app.settings.alphaEnabled = false
        try check(!app.settings.isExternalControlEnabled && callbacks == 3, "closing Alpha invokes revocation callback")
        app.settings.alphaEnabled = true
        app.settings.clearerBackdrop = true
        try app.localControl.set(ControlSettingsWrite(ticket: ticket, key: .performanceMode, value: .bool(true)), app)
        try check(app.settings.performanceMode && app.settings.clearerBackdrop, "performance setter keeps the clearer-glass preference")
        let skylight = app.localControl.settings(app).first { $0.key == .showsSkylight }!
        try check(skylight.preference == .bool(true) && skylight.effective == .bool(false), "Skylight preference survives effective suppression")
        try rejects(.invalidRequest, "invalid typed setting pair rejects before changes") { try app.localControl.set(ControlSettingsWrite(ticket: ticket, key: .performanceMode, value: .textGeneration(.off)), app) }
        try check(app.settings.performanceMode && app.settings.showsSkylight, "invalid settings have no partial effects")
        try app.localControl.set(ControlSettingsWrite(ticket: ticket, key: .performanceMode, value: .bool(false)), app)
        try check(app.settings.showsSkylightNow, "performance off restores preferred Skylight visibility")
        app.providers.statuses[.codex] = ProviderStatus(auth: .unknown)
        let codex = app.localControl.summaries(app).first { $0.id == "codex" }!
        try check(codex.authentication == "unknown" && !codex.freshSubmission, "authentication unknown is not advertised authenticated")
        try rejects(.unavailable, "unknown authentication does not authorize submission") { try app.localControl.requireAvailableProvider(standalone, app: app) }
        app.providers.statuses[.codex] = ProviderStatus(auth: .signedOut)
        try rejects(.permission, "signed-out provider requires owner UI authentication") { try app.localControl.requireAvailableProvider(standalone, app: app) }
        app.providers.statuses[.codex] = ProviderStatus()
        try check(try app.localControl.continuation(.automatic, standalone) == .fresh, "unsent automatic continuation is fresh")
        var resumed = standalone; resumed.hasStartedTurn = true
        try rejects(.continuationUnavailable, "exact continuation without session fails") { _ = try app.localControl.continuation(.providerSession, resumed) }
        resumed.provider = .deepseek
        try check(try app.localControl.continuation(.automatic, resumed) == .transcript, "API automatic continuation explicitly reconstructs transcript")
        try rejects(.continuationUnavailable, "API exact provider continuation fails explicitly") { _ = try app.localControl.continuation(.providerSession, resumed) }
        resumed.provider = .antigravity; resumed.providerSessionID = "synthetic"
        try rejects(.continuationUnavailable, "unacknowledged process-only resume is not exact capability") { _ = try app.localControl.continuation(.providerSession, resumed) }

        var missing = standalone; missing.id = UUID(); missing.projectID = UUID(); missing.title = "Missing project"
        app.threads.append(missing)
        let queried = try app.localControl.query(ControlThreadQuery(affiliation: .missing_project), app)
        try check(queried.items.map(\.id) == [missing.id] && queried.items[0].executionDirectory == nil, "metadata distinguishes missing_project without fallback")
        try check(app.runtimes.isEmpty && !FileManager.default.fileExists(atPath: taskPath), "metadata queries instantiate no runtime and create no task directories")
        for number in 0..<1_000 {
            var value = standalone; value.id = UUID(); value.title = "Page fixture \(number)"; app.threads.append(value)
        }
        app.existingRuntimeReads = 0
        var query = ControlThreadQuery(page: ControlPage(limit: 3), search: "Page fixture")
        let small = try app.localControl.query(query, app)
        try check(small.items.count == 3 && app.existingRuntimeReads == 3, "metadata projects DTOs only for bounded requested window")
        query.page.cursor = small.nextCursor
        let next = try app.localControl.query(query, app)
        try check(Set(small.items.map(\.id)).isDisjoint(with: next.items.map(\.id)), "cached metadata pages do not overlap")
        app.updateThread(standalone.id) { $0.title = "metadata mutation" }
        try rejects(.cursorInvalid, "App index revision invalidates old metadata cursor") { _ = try app.localControl.query(query, app) }
        var helper = standalone; helper.id = UUID(); helper.parentThreadID = UUID(); app.threads.append(helper)
        var head = helper; head.id = UUID(); head.hydra = HydraHeadInfo(); app.threads.append(head)
        var archived = standalone; archived.id = UUID(); archived.isArchived = true; app.threads.append(archived)
        try check(try app.localControl.query(ControlThreadQuery(role: .helper), app).items.map(\.id) == [helper.id], "helper filter excludes heads")
        try check(try app.localControl.query(ControlThreadQuery(role: .head), app).items.map(\.id) == [head.id], "head filter is explicit")
        try check(try app.localControl.query(ControlThreadQuery(archive: .archived), app).items.map(\.id) == [archived.id], "archived filter is explicit")
        let runtime = ThreadRuntime(app, standalone.id)
        var events: [ControlTurnUpdate] = []
        let turnID = UUID()
        try runtime.reserveExternalSubmission(turnID: turnID, continuation: .fresh) { events.append($0) }
        await runtime.submitExternal(text: "external synthetic text", turnID: turnID)
        try check(runtime.sent.count == 1 && runtime.sent[0].text == "external synthetic text", "parameterized external front door delivers explicit text")
        try check(runtime.draft == "reader's untouched draft" && runtime.followUps.isEmpty, "external front door neither consumes draft nor queues")
        runtime.event(.turnStarted(providerTurnID: nil))
        try check(events.last?.state == .started, "adapter turn event is distinct from acceptance")
        runtime.approvals = ["synthetic approval"]
        runtime.event(.approval)
        try check(events.last?.state == .waiting, "pending approval stays in UI with observable waiting state")
        runtime.approvals = []
        var stopped: [ControlTurnUpdate] = []
        try runtime.interruptExternal(turnID: turnID, operationID: UUID()) { stopped.append($0) }
        try check(runtime.interruptRequested && stopped.isEmpty, "interrupt request is not proof of stopped turn")
        runtime.holdSubmission(turnID)
        runtime.finish(turnID, .interrupted)
        try check(stopped.isEmpty, "completion event waits for submission stack to unwind before flush barrier opens")
        runtime.unwindSubmission(turnID)
        try check(stopped.last?.state == .ended && stopped.last?.stopEvidence == "runtime_ended_only", "runtime-only interruption does not claim provider stop proof")
        let race = ThreadRuntime(app, standalone.id)
        var raceFailure: ControlFailure?
        let raceID = UUID()
        try race.reserveExternalSubmission(turnID: raceID, continuation: .fresh) { raceFailure = $0.failure }
        race.beforeLoaded = { race.phase = .running }
        await race.submitExternal(text: "must not queue", turnID: raceID)
        try check(raceFailure?.code == .busy && race.sent.isEmpty && race.followUps.isEmpty, "eligibility is rechecked after history await; busy rejects without queue")
        let archiveRace = ThreadRuntime(app, standalone.id)
        var archiveFailure: ControlFailure?
        let archiveID = UUID()
        try archiveRace.reserveExternalSubmission(turnID: archiveID, continuation: .fresh) { archiveFailure = $0.failure }
        archiveRace.beforeLoaded = { app.updateThread(standalone.id) { $0.isArchived = true } }
        await archiveRace.submitExternal(text: "must not send", turnID: archiveID)
        try check(archiveFailure?.code == .archived && archiveRace.sent.isEmpty, "archive during await rejects submission")
        app.updateThread(standalone.id) { $0.isArchived = false }
        let revoked = ThreadRuntime(app, standalone.id)
        let revokedID = UUID()
        try revoked.reserveExternalSubmission(turnID: revokedID, continuation: .fresh) { _ in }
        revoked.beforeLoaded = { app.settings.alphaEnabled = false; app.settings.externalControlEnabled = false }
        await revoked.submitExternal(text: "already accepted", turnID: revokedID)
        try check(revoked.sent.count == 1, "permission revocation does not silently cancel an accepted turn")
        revoked.finish(revokedID, .completed)
        let persistence = ThreadRuntime(app, standalone.id)
        var final: ControlTurnUpdate?
        let persistenceID = UUID()
        try persistence.reserveExternalSubmission(turnID: persistenceID, continuation: .fresh) { final = $0 }
        await persistence.submitExternal(text: "synthetic", turnID: persistenceID)
        DiskWriter.shared.succeeds = false
        persistence.finish(persistenceID, .completed)
        try check(final?.state == .failed && final?.failure?.code == .persistence, "completion persistence failure cannot report successful receipt")
        DiskWriter.shared.succeeds = true
        let data = try JSONSerialization.data(withJSONObject: ["checks": passed, "count": passed.count, "scope": "extracted production domain declarations with synthetic framework/provider/storage dependencies; no provider execution or App end-to-end proof"], options: [.prettyPrinted, .sortedKeys])
        try data.write(to: root.appendingPathComponent("domain-results.json"))
        print("DOMAIN CHECKS COMPLETE: \(passed.count)")
    }
}
