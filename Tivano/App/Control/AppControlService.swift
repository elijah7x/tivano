import Foundation
import Observation

enum ControlSource { case local, remote }

struct ControlTurnUpdate {
    var state: ControlOperationState
    var turnStatus: String? = nil
    var failure: ControlFailure? = nil
    var stopEvidence: String? = nil
}

/// The only bridge from external requests to the existing AppModel/runtime. Transport
/// owns no App objects; query paths never ask AppModel for a new runtime or provider.
@MainActor
@Observable
final class AppControlService {
    @ObservationIgnored private weak var app: AppModel?
    let instance = UUID()
    let edition: ControlEdition = AppInfo.isDevelopment ? .dev : .release
    private(set) var listening = false
    private(set) var listenFailure: ControlFailure?
    private(set) var isShuttingDown = false
    @ObservationIgnored private var server: ControlSocketServer?
    @ObservationIgnored private var ledger: ControlLedger
    @ObservationIgnored private var activeRequests = 0
    @ObservationIgnored private var cachedThreadIDs: (instance: UUID, membershipRevision: UInt64, projectsRevision: UInt64, scopeDigest: String, ids: [UUID])?
    @ObservationIgnored private var cachedProjectIDs: (revision: UInt64, ids: [UUID])?

    init(app: AppModel) {
        self.app = app
        ledger = ControlLedger(instance: instance)
    }

    deinit { server?.stop() }

    var welcome: ControlWelcome { ControlWelcome(edition: edition, instance: instance) }
    var hasPendingMutations: Bool { ledger.hasPending }

    func refreshListening() {
        guard let app, app.isLibraryLoaded, app.settings.isExternalControlEnabled,
              !CaptureRun.isEnabled, !isShuttingDown else {
            server?.stop()
            server = nil
            listening = false
            cachedThreadIDs = nil
            cachedProjectIDs = nil
            return
        }
        guard server == nil else { return }
        let socket = ControlSocketServer(directory: ControlSocket.directory(edition: edition), welcome: welcome) { [weak self] request in
            guard let self else { return ControlResponse(id: request.id, error: ControlFailure(code: .unavailable)) }
            return await self.handle(request)
        }
        do {
            try socket.start()
            server = socket
            listening = true
            listenFailure = nil
        } catch {
            socket.stop()
            listening = false
            listenFailure = error as? ControlFailure ?? ControlFailure(code: .unavailable)
        }
    }

    func suspendForShutdown() {
        isShuttingDown = true
        refreshListening()
    }

    func restoreAfterFailedShutdown() {
        isShuttingDown = false
        refreshListening()
    }

    func handle(_ request: ControlRequest, source: ControlSource = .local) async -> ControlResponse {
        do {
            guard let app else { throw ControlFailure(code: .disabled) }
            switch source {
            case .local:
                guard app.settings.isExternalControlEnabled, listening else { throw ControlFailure(code: .disabled) }
            case .remote:
                guard app.settings.isRemoteMCPEnabled, app.remoteMCP.listening else { throw ControlFailure(code: .disabled) }
                if case .settingsSet = request.command { throw ControlFailure(code: .permission) }
            }
            guard !isShuttingDown else { throw ControlFailure(code: .shutdown) }
            guard request.instance == instance else { throw ControlFailure(code: .instanceMismatch) }
            guard activeRequests < LocalControl.maxConnections else { throw ControlFailure(code: .busy) }
            activeRequests += 1
            defer { activeRequests -= 1 }
            let result: ControlResult
            switch request.command {
            case .info: result = .info(welcome)
            case .providers: result = .providers(providerSummaries(app))
            case .projects(let page): result = .projects(try listProjects(page, app: app))
            case .threads(let query): result = .threads(try listThreads(query, app: app))
            case .thread(let id):
                guard let thread = app.thread(id) else { throw ControlFailure(code: .notFound) }
                result = .thread(threadSummary(thread, app: app))
            case .history(let query):
                guard let thread = app.thread(query.threadID) else { throw ControlFailure(code: .notFound) }
                result = .history(try await Storage.controlHistory(query, scope: instance.uuidString, allowsMissing: !thread.hasStartedTurn))
            case .operation(let ticket): result = .operation(ledger.outcome(ticket))
            case .settingsGet: result = .settings(settingsSnapshot(app))
            case .create, .submit, .interrupt, .settingsSet:
                result = .operation(try performWrite(request.command, app: app, source: source))
            }
            return ControlResponse(id: request.id, result: result)
        } catch {
            return ControlResponse(id: request.id, error: error as? ControlFailure ?? ControlFailure(code: .internalError))
        }
    }

    private func performWrite(_ command: ControlCommand, app: AppModel, source: ControlSource) throws -> ControlOutcome {
        try app.requireExternalPersistence()
        let accepted = try ledger.accept(command)
        guard accepted.isNew, let ticket = command.ticket else { return accepted.outcome }
        do {
            switch command {
            case .create(let request):
                guard let provider = ProviderKind(rawValue: request.provider), app.settings.isEnabled(provider) else { throw ControlFailure(code: .unsupported) }
                var resolved = request
                if let model = request.model {
                    guard model.utf8.count <= 512, let option = app.providers.model(model, for: provider) else { throw ControlFailure(code: .unsupported, detail: "model_unavailable") }
                    resolved.model = option.id
                }
                let mode: RuntimeMode = source == .remote && app.settings.isRemoteMCPFullAccess ? .fullAccess : .supervised
                let thread = try app.createExternalThread(resolved, provider: provider, runtimeMode: mode)
                ledger.update(ticket) { $0.threadID = thread.id; $0.state = request.workspace == .worktree ? .preparing : .ready }
                if request.workspace == .worktree {
                    Task { [weak self, weak app] in
                        guard let self, let app else { return }
                        do {
                            try await app.prepareExternalWorktree(thread.id)
                            self.ledger.update(ticket) { $0.state = .ready }
                            app.updateTaskSleepPrevention()
                        } catch { self.fail(ticket, error) }
                    }
                }
            case .submit(let request):
                guard !request.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      request.text.utf8.count <= LocalControl.maxText else { throw ControlFailure(code: .bounds) }
                // Slash commands can change permissions, load skills or control the session;
                // this API is deliberately text-only rather than a second command surface.
                guard !request.text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("/") else { throw ControlFailure(code: .unsupported) }
                let thread = try requireOrdinaryThread(request.threadID, app: app)
                try requireAvailableProvider(thread, app: app)
                let continuation = try resolveContinuation(request.continuation, thread: thread)
                let runtime = app.runtime(for: thread.id)
                let turnID = UUID()
                try runtime.reserveExternalSubmission(turnID: turnID, continuation: continuation) { [weak self] event in
                    self?.updateTurn(ticket, event)
                }
                ledger.update(ticket) { $0.threadID = thread.id; $0.turnID = turnID; $0.continuation = continuation }
                Task { await runtime.submitExternal(text: request.text, turnID: turnID) }
            case .interrupt(let request):
                _ = try requireOrdinaryThread(request.threadID, app: app, requireReady: false)
                guard let runtime = app.existingRuntime(for: request.threadID) else { throw ControlFailure(code: .notFound) }
                ledger.update(ticket) { $0.threadID = request.threadID; $0.turnID = request.turnID; $0.stopEvidence = "not_yet_confirmed" }
                try runtime.interruptExternal(turnID: request.turnID, operationID: ticket.id) { [weak self] event in
                    self?.updateTurn(ticket, event)
                }
            case .settingsSet(let request):
                try applySetting(request, app: app)
                let setting = settingsSnapshot(app).first { $0.key == request.key }
                ledger.update(ticket) { $0.state = .ready; $0.setting = setting }
            default: throw ControlFailure(code: .invalidRequest)
            }
        } catch { fail(ticket, error) }
        app.updateTaskSleepPrevention()
        return ledger.outcome(ticket)
    }

    private func fail(_ ticket: ControlTicket, _ error: Error) {
        ledger.update(ticket) { $0.state = .failed; $0.error = error as? ControlFailure ?? ControlFailure(code: .internalError) }
        app?.updateTaskSleepPrevention()
    }

    private func updateTurn(_ ticket: ControlTicket, _ event: ControlTurnUpdate) {
        ledger.update(ticket) {
            $0.state = event.state
            $0.turnStatus = event.turnStatus
            $0.error = event.failure
            if let evidence = event.stopEvidence { $0.stopEvidence = evidence }
        }
        // A pending mutation counts as work in progress (`AppModel.hasActiveTurns`).
        app?.updateTaskSleepPrevention()
    }

    func requireOrdinaryThread(_ id: UUID, app: AppModel, requireReady: Bool = true) throws -> ChatThread {
        guard let thread = app.thread(id) else { throw ControlFailure(code: .notFound) }
        guard !thread.isArchived else { throw ControlFailure(code: .archived) }
        guard !thread.isHelper, !thread.isHydraHead, !thread.isVoiceSession, !app.hydraIsOn(thread),
              app.children(of: id).isEmpty else { throw ControlFailure(code: .unsupported) }
        if let projectID = thread.projectID, app.project(projectID) == nil { throw ControlFailure(code: .missingProject) }
        if requireReady {
            let workspace = app.controlWorkspace(for: thread)
            guard workspace.phase == .ready else {
                if workspace.phase == .failed, let failure = workspace.failure { throw failure }
                throw ControlFailure(code: workspace.phase == .preparing ? .workspacePreparing : .workspaceFailed)
            }
        }
        return thread
    }

    func requireAvailableProvider(_ thread: ChatThread, app: AppModel) throws {
        guard app.settings.isEnabled(thread.provider) else { throw ControlFailure(code: .unavailable, detail: "provider_disabled") }
        let status = app.providers.status(thread.provider)
        guard status.isInstalled else { throw ControlFailure(code: .unavailable, detail: "provider_not_installed") }
        switch status.auth {
        case .unknown: throw ControlFailure(code: .unavailable, detail: "authentication_unknown")
        case .signedOut: throw ControlFailure(code: .permission, detail: "authentication_required_in_ui")
        case .signedIn: break
        }
    }

    private func resolveContinuation(_ requested: ControlContinuation, thread: ChatThread) throws -> ControlContinuation {
        let mode: ControlContinuation = requested == .automatic
            ? (!thread.hasStartedTurn ? .fresh : (thread.provider.isAPIKeyBased ? .transcript : .providerSession)) : requested
        switch mode {
        case .fresh:
            guard !thread.hasStartedTurn, thread.providerSessionID == nil else { throw ControlFailure(code: .continuationUnavailable) }
        case .providerSession:
            guard Self.supportsExactContinuation(thread.provider), thread.providerSessionID != nil else { throw ControlFailure(code: .continuationUnavailable) }
        case .transcript:
            guard thread.provider.isAPIKeyBased else { throw ControlFailure(code: .continuationUnavailable) }
        case .automatic: throw ControlFailure(code: .invalidRequest)
        }
        return mode
    }

    static func supportsExactContinuation(_ provider: ProviderKind) -> Bool {
        // These adapters reconstruct transcripts, or only start a process without an
        // acknowledged resume boundary. Do not advertise that as exact continuation.
        switch provider {
        case .deepseek, .meta, .zai, .antigravity, .commandcode: false
        default: true
        }
    }

    private func providerSummaries(_ app: AppModel) -> [ControlProvider] {
        ProviderKind.allCases.map { provider in
            let status = app.providers.status(provider)
            let auth: String
            switch status.auth { case .unknown: auth = "unknown"; case .signedOut: auth = "signedOut"; case .signedIn: auth = "signedIn" }
            return ControlProvider(id: provider.rawValue, enabled: app.settings.isEnabled(provider), installed: status.isInstalled,
                                   authentication: auth, models: Array(app.providers.models(for: provider).prefix(128)).map { String($0.id.prefix(512)) },
                                   freshSubmission: app.settings.isEnabled(provider) && status.isInstalled && auth == "signedIn" && provider.supports(.supervised),
                                   continuation: provider.isAPIKeyBased ? [.transcript] : (Self.supportsExactContinuation(provider) ? [.providerSession] : []), interrupt: true)
        }
    }

    private func listProjects(_ page: ControlPage, app: AppModel) throws -> ControlListPage<ControlProject> {
        guard (1...100).contains(page.limit), app.projects.count <= 10_000 else { throw ControlFailure(code: .bounds) }
        if cachedProjectIDs?.revision != app.projectsRevision {
            cachedProjectIDs = (app.projectsRevision, app.projects.map { ($0.id, $0.id.uuidString) }.sorted { $0.1 < $1.1 }.map(\.0))
        }
        let ids = cachedProjectIDs?.ids ?? []
        let snapshot = try ControlLedger.digest(instance.uuidString + "/projects/\(app.projectsRevision)")
        return try ControlPagination.boundedPage(count: ids.count, request: page, snapshot: snapshot) { window in
            ids[window].compactMap { app.project($0) }.map { ControlProject(id: $0.id, name: String($0.name.prefix(1_024)), path: $0.path) }
        }
    }

    private func listThreads(_ query: ControlThreadQuery, app: AppModel) throws -> ControlListPage<ControlThread> {
        guard (1...100).contains(query.page.limit), app.threads.count <= 100_000 else { throw ControlFailure(code: .bounds) }
        guard (query.search?.utf8.count ?? 0) <= 256,
              query.projectID == nil || query.affiliation == .project else { throw ControlFailure(code: .invalidRequest) }
        var scope = query
        scope.page.cursor = nil
        scope.page.limit = 1
        let scopeDigest = try ControlLedger.digest(scope)
        let snapshot = try ControlLedger.digest(instance.uuidString + "/threads/\(app.threadsRevision)/\(app.projectsRevision)/" + scopeDigest)
        if cachedThreadIDs?.instance != instance
            || cachedThreadIDs?.membershipRevision != app.controlThreadMembershipRevision
            || cachedThreadIDs?.projectsRevision != app.projectsRevision
            || cachedThreadIDs?.scopeDigest != scopeDigest {
            let ids = app.threads.lazy.filter { thread in
                let affiliation: ControlAffiliationFilter = thread.projectID == nil ? .standalone : (app.project(thread.projectID) == nil ? .missing_project : .project)
                let role: ControlRoleFilter = thread.isHydraHead ? .head : (thread.isHelper ? .helper : .normal)
                return (query.archive == .all || (query.archive == .archived) == thread.isArchived)
                    && (query.role == .all || query.role == role)
                    && (query.affiliation == .all || query.affiliation == affiliation)
                    && (query.projectID == nil || query.projectID == thread.projectID)
                    && (query.search == nil || thread.title.localizedCaseInsensitiveContains(query.search!))
            }.map { ($0.id, $0.id.uuidString) }.sorted { $0.1 < $1.1 }.map(\.0)
            cachedThreadIDs = (instance, app.controlThreadMembershipRevision, app.projectsRevision, scopeDigest, ids)
        }
        let ids = cachedThreadIDs?.ids ?? []
        // Runtime status is volatile and sampled only for this window; membership and
        // order are bound to the library revisions. No full-library DTO serialization.
        return try ControlPagination.boundedPage(count: ids.count, request: query.page, snapshot: snapshot) { window in
            ids[window].compactMap { app.thread($0) }.map { threadSummary($0, app: app) }
        }
    }

    private func threadSummary(_ thread: ChatThread, app: AppModel) -> ControlThread {
        let runtime = app.existingRuntime(for: thread.id)
        return ControlThread(id: thread.id, title: String(thread.title.prefix(1_024)), projectID: thread.projectID,
                             affiliation: thread.projectID == nil ? .standalone : (app.project(thread.projectID) == nil ? .missing_project : .project),
                             role: thread.isHydraHead ? .head : (thread.isHelper ? .helper : .normal), archived: thread.isArchived,
                             provider: thread.provider.rawValue, model: thread.model, createdAt: thread.createdAt, updatedAt: thread.updatedAt,
                             lastStatus: thread.lastStatus?.rawValue, activeTurnID: runtime?.controlActiveTurnID,
                             waitingForUI: runtime.map { !$0.approvals.isEmpty || !$0.questions.isEmpty } ?? false,
                             workspace: app.controlWorkspace(for: thread), executionDirectory: try? app.executionDirectory(for: thread))
    }

    private func settingsSnapshot(_ app: AppModel) -> [ControlSetting] {
        let settings = app.settings
        let preference = ControlTextGeneration(rawValue: settings.textGeneration.rawValue) ?? .automatic
        let effective: ControlTextGeneration
        switch app.textEngine(preferring: nil) { case .claude: effective = .claude; case .codex: effective = .codex; case nil: effective = .off }
        return [
            ControlSetting(key: .textGeneration, preference: .textGeneration(preference), effective: .textGeneration(effective)),
            ControlSetting(key: .antiSlopEnabled, preference: .bool(settings.antiSlopEnabled), effective: .bool(settings.antiSlopEnabled)),
            ControlSetting(key: .performanceMode, preference: .bool(settings.performanceMode), effective: .bool(settings.performanceMode)),
            ControlSetting(key: .showsSkylight, preference: .bool(settings.showsSkylight), effective: .bool(settings.showsSkylightNow))
        ]
    }

    private func applySetting(_ request: ControlSettingsWrite, app: AppModel) throws {
        // Validate the complete typed pair before invoking any application-level setter.
        switch (request.key, request.value) {
        case (.textGeneration, .textGeneration(let value)):
            guard let choice = TextGenerationChoice(rawValue: value.rawValue) else { throw ControlFailure(code: .invalidRequest) }
            app.settings.textGeneration = choice
        case (.antiSlopEnabled, .bool(let value)): app.settings.antiSlopEnabled = value
        case (.performanceMode, .bool(let value)): app.settings.performanceMode = value // also clears clearerBackdrop
        case (.showsSkylight, .bool(let value)): app.settings.showsSkylight = value // preference survives performance mode
        default: throw ControlFailure(code: .invalidRequest)
        }
    }
}
