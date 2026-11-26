import Foundation

/// Runs single-turn or multi-turn ephemeral agent sessions on behalf of external CLI
/// callers (such as BeRead) without creating, inserting or persisting any `ChatThread`.
@MainActor final class EphemeralAgentRunner {
    private static let idleTTL: TimeInterval = 30 * 60
    private static let sweepInterval: Duration = .seconds(5 * 60)
    private static let maxErrorLength = 300
    private static let providerStatusWaitTimeout: TimeInterval = 10
    private static let providerStatusPollInterval: TimeInterval = 0.1
    private static let providerStatusIdleKickDelay: TimeInterval = 0.5

    private final class Entry {
        let id: String
        let provider: ProviderKind
        let modelID: String
        let cwd: String
        let session: any ProviderSession
        var lastUsed: Date
        var isBusy: Bool

        init(
            id: String,
            provider: ProviderKind,
            modelID: String,
            cwd: String,
            session: any ProviderSession,
            lastUsed: Date = .now,
            isBusy: Bool = true
        ) {
            self.id = id
            self.provider = provider
            self.modelID = modelID
            self.cwd = cwd
            self.session = session
            self.lastUsed = lastUsed
            self.isBusy = isBusy
        }
    }

    @MainActor
    private final class TurnState {
        struct ToolRecord {
            var kind: ToolCall.Kind
            var title: String
            var editPaths: [String]
            var ended: Bool
            var succeeded: Bool
        }

        let id = UUID()
        let entry: Entry
        let cwdURL: URL
        private let emitEvent: @MainActor (ControlAgentEvent) -> Void
        private let sanitize: @MainActor (String) -> String

        private var continuation: CheckedContinuation<Void, Never>?
        private var streamedMessageIDs: Set<String> = []
        private var streamedReasoningIDs: Set<String> = []
        private var tools: [String: ToolRecord] = [:]
        private var emittedFiles: Set<String> = []
        private(set) var isFinished = false
        private(set) var isCancelled = false
        /// False until the provider reports anything for this turn; a cancel before that
        /// may race the turn's start (Codex has no turn ID to interrupt yet).
        private(set) var sawProviderEvent = false

        init(
            entry: Entry,
            cwdURL: URL,
            emit: @escaping @MainActor (ControlAgentEvent) -> Void,
            sanitize: @escaping @MainActor (String) -> String
        ) {
            self.entry = entry
            self.cwdURL = cwdURL
            self.emitEvent = emit
            self.sanitize = sanitize
        }

        func waitUntilFinished() async {
            guard !isFinished else { return }
            await withCheckedContinuation { continuation in
                if isFinished {
                    continuation.resume()
                } else {
                    self.continuation = continuation
                }
            }
        }

        func cancel() {
            guard !isFinished else { return }
            isCancelled = true
            isFinished = true
            resumeWaiter()
        }

        func fail(_ error: Error) {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            finish(with: .error(.`internal`, sanitize(message)))
        }

        func handle(_ event: ProviderEvent, onSessionExited: @MainActor () -> Void) {
            sawProviderEvent = true
            guard !isFinished, !isCancelled else { return }
            switch event {
            case .messageDelta(let id, let text):
                guard !text.isEmpty else { return }
                streamedMessageIDs.insert(id)
                emitEvent(.text(text))

            case .messageCompleted(let id, let text):
                guard !text.isEmpty, !streamedMessageIDs.contains(id) else { return }
                streamedMessageIDs.insert(id)
                emitEvent(.text(text))

            case .reasoningDelta(let id, let text):
                guard !text.isEmpty else { return }
                streamedReasoningIDs.insert(id)
                emitEvent(.thinking(text))

            case .reasoningCompleted(let id, let text):
                guard !text.isEmpty, !streamedReasoningIDs.contains(id) else { return }
                streamedReasoningIDs.insert(id)
                emitEvent(.thinking(text))

            case .toolStarted(let id, let call):
                handleToolStarted(id: id, call: call)

            case .toolUpdated(let id, let update):
                handleToolUpdated(id: id, update: update)

            case .diff(let diff):
                for path in EphemeralAgentRunner.paths(inDiff: diff) {
                    emitFileIfNeeded(path)
                }

            case .approval(let request):
                let session = entry.session
                let optionID = EphemeralAgentRunner.approvalOptionID(for: request)
                // Defer to the next MainActor turn so providers that register their continuation
                // right after emitting `.approval` (such as OpenAICompatibleSession) see the reply.
                Task { @MainActor in
                    session.resolveApproval(request.id, optionID: optionID)
                }

            case .question(let request):
                let session = entry.session
                let provider = entry.provider
                Task { @MainActor in
                    if provider == .claude {
                        session.resolveApproval(request.id, optionID: "deny")
                    } else {
                        session.answerQuestion(request.id, answers: [:])
                    }
                }

            case .turnCompleted(let status, let error):
                switch status {
                case .completed:
                    if let error, !error.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        finishOpenTools(succeeded: false)
                        finish(with: .error(.`internal`, sanitize(error)))
                    } else {
                        finishOpenTools(succeeded: true)
                        finish(with: .done)
                    }
                case .failed:
                    finishOpenTools(succeeded: false)
                    finish(with: .error(.`internal`, sanitize(error ?? "The provider failed to complete the turn.")))
                case .interrupted:
                    finishOpenTools(succeeded: false)
                    finish(with: .error(.`internal`, sanitize(error ?? "The turn was interrupted.")))
                case .running:
                    break
                }

            case .exited(let error):
                onSessionExited()
                finishOpenTools(succeeded: false)
                finish(with: .error(.`internal`, sanitize(error ?? "\(entry.provider.displayName) stopped unexpectedly.")))

            case .sessionReady, .turnStarted, .backgroundTasks, .toolOutput,
                 .planDelta, .planCompleted, .todos, .requestResolved,
                 .usage, .contextUsageCleared, .tokenSpend, .notice,
                 .usageLimit, .modeChanged, .models, .commands, .title,
                 .assistantMessageID, .agentStarted, .agentEvent,
                 .agentProgress, .agentFinished:
                break
            }
        }

        private func handleToolStarted(id: String, call: ToolCall) {
            let newPaths = call.edits.map(\.path).filter { !$0.isEmpty }
            if var existing = tools[id] {
                existing.kind = call.kind
                if !call.title.isEmpty { existing.title = call.title }
                existing.editPaths.append(contentsOf: newPaths)
                tools[id] = existing
                if call.status != .running {
                    settleTool(id: id, status: call.status)
                }
                return
            }

            let record = ToolRecord(
                kind: call.kind,
                title: call.title,
                editPaths: newPaths,
                ended: false,
                succeeded: false
            )
            tools[id] = record
            let name = EphemeralAgentRunner.toolName(for: call)
            let input = EphemeralAgentRunner.toolInput(for: call)
            emitEvent(.toolStart(id: id, name: name, input: input))

            if call.status != .running {
                settleTool(id: id, status: call.status)
            }
        }

        private func handleToolUpdated(id: String, update: ToolUpdate) {
            let updatePaths = (update.edits ?? []).map(\.path).filter { !$0.isEmpty }
            if var record = tools[id] {
                if let kind = update.kind { record.kind = kind }
                if let title = update.title, !title.isEmpty { record.title = title }
                record.editPaths.append(contentsOf: updatePaths)
                tools[id] = record

                if let status = update.status, status != .running {
                    settleTool(id: id, status: status)
                } else if record.ended && record.succeeded {
                    for path in updatePaths { emitFileIfNeeded(path) }
                }
            } else if update.status == .completed || update.status == nil {
                for path in updatePaths { emitFileIfNeeded(path) }
            }
        }

        private func settleTool(id: String, status: ToolCall.Status) {
            guard var record = tools[id] else { return }
            let ok = status == .completed
            if ok {
                emitFiles(for: record)
            }
            guard !record.ended else {
                tools[id] = record
                return
            }
            record.ended = true
            record.succeeded = ok
            tools[id] = record
            emitEvent(.toolEnd(id: id, ok: ok))
        }

        private func finishOpenTools(succeeded: Bool) {
            for (id, var record) in tools where !record.ended {
                if succeeded {
                    emitFiles(for: record)
                }
                record.ended = true
                record.succeeded = succeeded
                tools[id] = record
                emitEvent(.toolEnd(id: id, ok: succeeded))
            }
        }

        private func emitFiles(for record: ToolRecord) {
            if !record.editPaths.isEmpty {
                for path in record.editPaths {
                    emitFileIfNeeded(path)
                }
            } else if record.kind == .edit, let fallback = EphemeralAgentRunner.fallbackEditPath(record.title, cwd: cwdURL) {
                emitFileIfNeeded(fallback)
            }
        }

        private func emitFileIfNeeded(_ rawPath: String) {
            guard let resolved = EphemeralAgentRunner.resolveFilePath(rawPath, cwd: cwdURL),
                  emittedFiles.insert(resolved).inserted else { return }
            emitEvent(.file(resolved))
        }

        private func finish(with event: ControlAgentEvent) {
            guard !isFinished else { return }
            isFinished = true
            if !isCancelled {
                emitEvent(event)
            }
            resumeWaiter()
        }

        private func resumeWaiter() {
            let waiter = continuation
            continuation = nil
            waiter?.resume()
        }
    }

    private weak var app: AppModel?
    private var entries: [String: Entry] = [:]
    private var activeTurns: [UUID: TurnState] = [:]
    private var sweepTask: Task<Void, Never>?
    private var initialRefreshTask: Task<Void, Never>?
    private var shutdownGeneration: UInt64 = 0

    init(app: AppModel) {
        self.app = app
    }

    func models() async -> ControlAgentModels {
        guard let app else { return ControlAgentModels(models: []) }
        await waitForProviderStatuses(for: enabledSupportedProviders(app: app), app: app)

        var candidates: [(provider: ProviderKind, option: ModelOption, isDefault: Bool)] = []
        var seenIDs: Set<String> = []

        if let defaultChoice = resolveDefaultModel(app: app) {
            let id = ControlAgentModel.encode(provider: defaultChoice.provider.rawValue, model: defaultChoice.option.id)
            seenIDs.insert(id)
            candidates.append((defaultChoice.provider, defaultChoice.option, true))
        }

        for pin in app.settings.modelList {
            guard isProviderAvailable(pin.provider, app: app),
                  let option = app.providers.model(pin.modelID, for: pin.provider) else { continue }
            let id = ControlAgentModel.encode(provider: pin.provider.rawValue, model: option.id)
            guard seenIDs.insert(id).inserted else { continue }
            candidates.append((pin.provider, option, false))
        }

        // Guarantee exactly one isDefault when any model is available.
        if !candidates.isEmpty, !candidates.contains(where: \.isDefault) {
            candidates[0].isDefault = true
        }

        let peersByProvider = Dictionary(grouping: candidates, by: \.provider).mapValues { $0.map(\.option) }
        let models = candidates.map { item in
            let peers = peersByProvider[item.provider] ?? []
            return ControlAgentModel(
                id: ControlAgentModel.encode(provider: item.provider.rawValue, model: item.option.id),
                label: item.option.label(among: peers),
                providerName: item.provider.displayName,
                isDefault: item.isDefault
            )
        }
        return ControlAgentModels(models: models)
    }

    func run(_ request: ControlAgentRun, emit: @escaping @MainActor (ControlAgentEvent) -> Void) async {
        sweepExpiredSessions()

        guard let app else {
            emit(.error(.app_unavailable, "Tivano is unavailable."))
            return
        }

        let trimmedPrompt = request.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else {
            emit(.error(.bad_request, "Prompt must not be empty."))
            return
        }
        guard request.prompt.utf8.count <= LocalControl.maxAgentPrompt else {
            emit(.error(.bad_request, "Prompt exceeds maximum size."))
            return
        }

        guard request.cwd.hasPrefix("/") else {
            emit(.error(.bad_request, "Working directory must be an absolute path."))
            return
        }
        let cwdURL = URL(fileURLWithPath: request.cwd).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: cwdURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            emit(.error(.bad_request, "Working directory does not exist or is not a directory."))
            return
        }

        let statusTargets: [ProviderKind]
        if let requestedID = request.model,
           let provider = ProviderKind(rawValue: ControlAgentModel.decode(requestedID).provider),
           app.settings.isEnabled(provider),
           provider.supports(.autoAcceptEdits) {
            statusTargets = [provider]
        } else {
            statusTargets = enabledSupportedProviders(app: app)
        }
        await waitForProviderStatuses(for: statusTargets, app: app)
        guard !Task.isCancelled else { return }

        let resolved: (provider: ProviderKind, option: ModelOption)
        // A follow-up that names its session but no model keeps that session's model.
        var requestedModel = request.model
        if requestedModel == nil, let sessionID = request.session, let hit = entries[sessionID] {
            requestedModel = ControlAgentModel.encode(provider: hit.provider.rawValue, model: hit.modelID)
        }
        switch resolveRequestedModel(requestedModel, app: app) {
        case .success(let pair):
            resolved = pair
        case .failure(let failure):
            emit(.error(failure.code, failure.message))
            return
        }

        let provider = resolved.provider
        let option = resolved.option
        let preference = app.settings.preference(for: provider, model: option.id)
        let effort = preference.effort.flatMap { option.efforts.contains($0) ? $0 : nil } ?? option.defaultEffort
        let fastMode = option.supportsFast && preference.fastMode
        let serviceTier: String? = (provider == .codex && option.fastTier != nil) ? (fastMode ? option.fastTier : "default") : nil

        var reusedEntry: Entry?
        if let requestedID = request.session,
           let existing = entries[requestedID],
           existing.provider == provider,
           existing.modelID == option.id,
           existing.cwd == cwdURL.path {
            if existing.isBusy {
                emit(.error(.bad_request, "session_busy"))
                return
            }
            if existing.session.isRunning {
                reusedEntry = existing
            } else {
                existing.session.onEvent = nil
                existing.session.stop()
                entries.removeValue(forKey: requestedID)
            }
        }

        guard !Task.isCancelled else { return }

        let sessionID: String
        if let existing = reusedEntry {
            existing.isBusy = true
            existing.lastUsed = .now
            sessionID = existing.id
        } else {
            sessionID = UUID().uuidString
        }

        emit(.session(sessionID))

        let entry: Entry
        if let existing = reusedEntry {
            entry = existing
        } else {
            guard let started = await startEntry(
                id: sessionID,
                provider: provider,
                option: option,
                effort: effort,
                fastMode: fastMode,
                cwdURL: cwdURL,
                app: app,
                emit: emit
            ) else { return }
            entry = started
        }

        guard !Task.isCancelled else {
            finishEntry(entry)
            return
        }

        let turn = TurnState(
            entry: entry,
            cwdURL: cwdURL,
            emit: emit,
            sanitize: { [weak self] message in
                self?.sanitizeError(message) ?? "Provider error."
            }
        )
        let turnID = turn.id
        activeTurns[turnID] = turn

        entry.session.onEvent = { [weak self, weak turn] event in
            guard let turn else { return }
            turn.handle(event) {
                if let self, self.entries[entry.id] === entry {
                    self.entries.removeValue(forKey: entry.id)
                }
            }
        }

        let input = TurnInput(
            text: request.prompt,
            images: [],
            model: option.id,
            effort: effort,
            serviceTier: serviceTier,
            fastMode: fastMode,
            runtimeMode: .autoAcceptEdits,
            interactionMode: .build,
            isFinalReport: false,
            command: nil
        )

        defer {
            activeTurns.removeValue(forKey: turnID)
            finishEntry(entry)
        }

        await withTaskCancellationHandler {
            do {
                try await entry.session.send(input)
            } catch {
                if !Task.isCancelled && !turn.isFinished {
                    turn.fail(error)
                }
            }
            if !Task.isCancelled && !turn.isFinished {
                await turn.waitUntilFinished()
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelTurn(id: turnID)
            }
        }
    }

    func shutdown() {
        shutdownGeneration &+= 1
        sweepTask?.cancel()
        sweepTask = nil
        initialRefreshTask?.cancel()
        initialRefreshTask = nil

        let runningTurns = Array(activeTurns.values)
        activeTurns.removeAll()
        for turn in runningTurns {
            turn.cancel()
        }

        let snapshot = Array(entries.values)
        entries.removeAll()
        for entry in snapshot {
            let session = entry.session
            session.onEvent = nil
            Task { @MainActor in
                await session.interrupt()
                session.stop()
            }
        }
    }

    // MARK: - Session lifecycle

    private func startEntry(
        id: String,
        provider: ProviderKind,
        option: ModelOption,
        effort: String?,
        fastMode: Bool,
        cwdURL: URL,
        app: AppModel,
        emit: @escaping @MainActor (ControlAgentEvent) -> Void
    ) async -> Entry? {
        let generation = shutdownGeneration
        func emitStoppedIfNeeded() {
            guard !Task.isCancelled else { return }
            emit(.error(.app_unavailable, "Tivano is unavailable."))
        }

        if !provider.isAPIKeyBased {
            await LoginEnvironment.load()
            guard !Task.isCancelled else { return nil }
            guard shutdownGeneration == generation else {
                emitStoppedIfNeeded()
                return nil
            }
            await app.providers.waitWhileCLIUpdating(provider)
            guard !Task.isCancelled else { return nil }
            guard shutdownGeneration == generation else {
                emitStoppedIfNeeded()
                return nil
            }
        }

        let session: any ProviderSession
        do {
            session = try await makeSession(
                provider: provider,
                modelID: option.id,
                effort: effort,
                fastMode: fastMode,
                cwdURL: cwdURL,
                app: app
            )
        } catch is CancellationError {
            if !Task.isCancelled {
                if shutdownGeneration != generation {
                    emit(.error(.app_unavailable, "Tivano is unavailable."))
                } else {
                    emit(.error(.`internal`, "The session startup was cancelled."))
                }
            }
            return nil
        } catch {
            if !Task.isCancelled {
                if shutdownGeneration != generation {
                    emit(.error(.app_unavailable, "Tivano is unavailable."))
                } else {
                    emit(.error(.`internal`, sanitizeError(error)))
                }
            }
            return nil
        }

        guard !Task.isCancelled else {
            session.onEvent = nil
            session.stop()
            return nil
        }
        guard shutdownGeneration == generation else {
            session.onEvent = nil
            session.stop()
            emitStoppedIfNeeded()
            return nil
        }

        do {
            _ = try await session.start()
        } catch is CancellationError {
            session.onEvent = nil
            session.stop()
            if !Task.isCancelled {
                if shutdownGeneration != generation {
                    emit(.error(.app_unavailable, "Tivano is unavailable."))
                } else {
                    emit(.error(.`internal`, "The session startup was cancelled."))
                }
            }
            return nil
        } catch {
            session.onEvent = nil
            session.stop()
            if !Task.isCancelled {
                if shutdownGeneration != generation {
                    emit(.error(.app_unavailable, "Tivano is unavailable."))
                } else {
                    emit(.error(.`internal`, sanitizeError(error)))
                }
            }
            return nil
        }

        guard !Task.isCancelled else {
            session.onEvent = nil
            session.stop()
            return nil
        }
        guard shutdownGeneration == generation else {
            session.onEvent = nil
            session.stop()
            emitStoppedIfNeeded()
            return nil
        }

        let entry = Entry(
            id: id,
            provider: provider,
            modelID: option.id,
            cwd: cwdURL.path,
            session: session,
            lastUsed: .now,
            isBusy: true
        )
        entries[entry.id] = entry
        ensureSweepTask()
        return entry
    }

    private func makeSession(
        provider: ProviderKind,
        modelID: String,
        effort: String?,
        fastMode: Bool,
        cwdURL: URL,
        app: AppModel
    ) async throws -> any ProviderSession {
        var claudeAccount: ProviderAccount?
        var claudeIdentity: ClaudeAccountIdentity?

        if provider == .claude {
            guard let account = app.providers.accounts.activeAccount(for: .claude), account.provider == .claude else {
                throw ProviderError.failed("Claude account is unavailable.")
            }
            guard !account.requiresClaudeActivation, !account.requiresClaudeCleanup else {
                throw ProviderError.failed("Sign in again to this Claude account before using it.")
            }
            claudeAccount = account
            if !account.isDefault {
                guard let executable = app.providers.executable(for: .claude) else {
                    throw ProviderError.notInstalled(.claude)
                }
                guard ProviderAccounts.canStartProcess(account.id), ProviderAccounts.beginRead(account.id) else {
                    throw ProviderError.failed("This Claude account is busy.")
                }
                defer { ProviderAccounts.endRead(account.id) }
                let actual = try await ProviderRegistry.claudeIdentity(
                    executable: executable,
                    environment: app.providers.environment(for: .claude, account: account),
                    directory: cwdURL,
                    reusingFor: account.id
                )
                guard !Task.isCancelled else { throw CancellationError() }
                try app.providers.accounts.bindClaudeIdentity(actual, to: account.id)
                claudeIdentity = actual
            }
        }

        let executable: URL?
        let apiKey: String?
        if provider.isAPIKeyBased {
            let key = app.settings.apiKey(for: provider)
            guard !key.isEmpty else { throw ProviderError.notInstalled(provider) }
            executable = nil
            apiKey = key
        } else {
            guard let found = app.providers.executable(for: provider) else {
                throw ProviderError.notInstalled(provider)
            }
            executable = found
            apiKey = provider == .zcode ? app.settings.apiKey(for: .zai) : nil
        }

        await app.mcp.ensureReady()
        let launchAccount = provider == .claude ? claudeAccount : app.providers.accounts.activeAccount(for: provider)
        let environment = app.providers.environment(for: provider, account: launchAccount)
        let needsCatalog = provider.namesModelVariants || provider == .dsh || provider == .minimaxCode || provider == .antigravity

        let configuration = SessionConfiguration(
            provider: provider,
            executable: executable,
            workingDirectory: cwdURL,
            environment: environment,
            resumeID: nil,
            resumeAt: nil,
            model: modelID,
            effort: effort,
            fastMode: fastMode,
            runtimeMode: .autoAcceptEdits,
            interactionMode: .build,
            apiKey: apiKey,
            hydra: nil,
            transcript: [],
            isHydraHead: false,
            managesCodexHeadHistory: false,
            codexHistoryArchived: false,
            codexHistoryDirectory: nil,
            voiceContext: nil,
            modelCatalog: needsCatalog ? app.providers.models(for: provider) : [],
            dshMode: .standard,
            dshFinalReport: false,
            claudeAccountID: claudeAccount?.id,
            claudeIdentity: claudeIdentity,
            deniesShell: true,
            isEphemeral: true
        )

        return switch provider {
        case .codex: CodexSession(configuration: configuration)
        case .claude: ClaudeSession(configuration: configuration)
        case .copilot: CopilotSession(configuration: configuration)
        case .commandcode: CommandCodeSession(configuration: configuration)
        case .pi: PiSession(configuration: configuration)
        case .omp: OmpSession(configuration: configuration)
        case .zcode: ZCodeSession(configuration: configuration)
        case .cursor, .opencode, .grok, .devin, .antigravity, .kimi, .dsh, .minimaxCode: ACPSession(configuration: configuration)
        case .deepseek: DeepSeekSession(configuration: configuration)
        case .meta: MetaSession(configuration: configuration)
        case .zai: ZaiSession(configuration: configuration)
        }
    }

    private func cancelTurn(id: UUID) {
        guard let turn = activeTurns[id] else { return }
        turn.cancel()
        let entry = turn.entry
        let session = entry.session
        // Nothing seen yet: the turn may still be starting and outlive an interrupt, so
        // end the whole session instead of keeping it for a follow-up.
        let stopsSession = !turn.sawProviderEvent
        if stopsSession, entries[entry.id] === entry {
            entries.removeValue(forKey: entry.id)
        }
        Task { @MainActor in
            await session.interrupt()
            if stopsSession {
                session.onEvent = nil
                session.stop()
            }
        }
    }

    private func finishEntry(_ entry: Entry) {
        entry.isBusy = false
        entry.lastUsed = .now
        guard entries[entry.id] === entry else {
            entry.session.onEvent = nil
            return
        }
        if !entry.session.isRunning {
            entry.session.onEvent = nil
            entries.removeValue(forKey: entry.id)
        } else {
            let entryID = entry.id
            entry.session.onEvent = { [weak self, weak entry] event in
                guard case .exited = event, let self, let entry, self.entries[entryID] === entry else { return }
                entry.session.onEvent = nil
                self.entries.removeValue(forKey: entryID)
            }
        }
        if entries.isEmpty {
            sweepTask?.cancel()
            sweepTask = nil
        }
    }

    private func sweepExpiredSessions() {
        let now = Date.now
        let expiredIDs = entries.compactMap { id, entry -> String? in
            guard !entry.isBusy else { return nil }
            if !entry.session.isRunning || now.timeIntervalSince(entry.lastUsed) >= Self.idleTTL {
                return id
            }
            return nil
        }
        for id in expiredIDs {
            guard let entry = entries.removeValue(forKey: id) else { continue }
            entry.session.onEvent = nil
            entry.session.stop()
        }
        if entries.isEmpty {
            sweepTask?.cancel()
            sweepTask = nil
        }
    }

    private func ensureSweepTask() {
        guard sweepTask == nil, !entries.isEmpty else { return }
        sweepTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: Self.sweepInterval)
                } catch {
                    return
                }
                guard let self, !Task.isCancelled else { return }
                self.sweepExpiredSessions()
                if self.entries.isEmpty {
                    self.sweepTask = nil
                    return
                }
            }
        }
    }

    // MARK: - Model resolution & availability

    private struct ResolutionFailure: Error {
        var code: ControlAgentErrorCode
        var message: String
    }

    private func enabledSupportedProviders(app: AppModel) -> [ProviderKind] {
        ProviderKind.allCases.filter { app.settings.isEnabled($0) && $0.supports(.autoAcceptEdits) }
    }

    private func hasUnresolvedProviderStatus(in targets: [ProviderKind], app: AppModel) -> Bool {
        targets.contains { provider in
            guard let status = app.providers.statuses[provider] else { return true }
            if status.isChecking { return true }
            if status.isInstalled, status.auth == .unknown, app.providers.isRefreshing { return true }
            return false
        }
    }

    private func waitForProviderStatuses(for targets: [ProviderKind], app: AppModel) async {
        guard !CaptureRun.isEnabled, !targets.isEmpty else { return }
        guard hasUnresolvedProviderStatus(in: targets, app: app) else { return }

        let deadline = Date.now.addingTimeInterval(Self.providerStatusWaitTimeout)
        var idleSince: Date?
        var kicked = false

        while hasUnresolvedProviderStatus(in: targets, app: app), Date.now < deadline, !Task.isCancelled {
            let refreshInFlight = app.providers.isRefreshing
                || app.providers.statuses.values.contains(where: \.isChecking)
                || initialRefreshTask != nil

            if !refreshInFlight, LoginEnvironment.isLoaded {
                let now = Date.now
                if let since = idleSince {
                    if !kicked, now.timeIntervalSince(since) >= Self.providerStatusIdleKickDelay {
                        let unchecked = targets.filter { app.providers.statuses[$0] == nil }
                        if !unchecked.isEmpty {
                            kicked = true
                            initialRefreshTask = Task { @MainActor [weak self, weak app] in
                                defer { self?.initialRefreshTask = nil }
                                guard let app else { return }
                                await withTaskGroup(of: Void.self) { group in
                                    for provider in unchecked {
                                        group.addTask { await app.providers.refresh(provider) }
                                    }
                                }
                            }
                        }
                    }
                } else {
                    idleSince = now
                }
            } else {
                idleSince = nil
            }

            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { break }
            do {
                try await Task.sleep(for: .seconds(min(Self.providerStatusPollInterval, remaining)))
            } catch {
                return
            }
        }
    }

    private func isProviderAvailable(_ provider: ProviderKind, app: AppModel) -> Bool {
        guard app.settings.isEnabled(provider), provider.supports(.autoAcceptEdits) else { return false }
        let status = app.providers.status(provider)
        guard status.isInstalled else { return false }
        guard case .signedIn = status.auth else { return false }
        if provider == .claude,
           let account = app.providers.accounts.activeAccount(for: .claude),
           account.requiresClaudeActivation || account.requiresClaudeCleanup {
            return false
        }
        return true
    }

    private func resolveDefaultModel(app: AppModel) -> (provider: ProviderKind, option: ModelOption)? {
        // 1. Explicit new-thread default (skip Hydra pairs).
        if case .model(let selection) = app.settings.newThreadDefault,
           isProviderAvailable(selection.provider, app: app),
           let option = app.providers.model(selection.modelID, for: selection.provider) {
            return (selection.provider, option)
        }

        // 2. Last non-pair model picked for a new chat.
        if let pin = app.settings.lastNewChatModel,
           isProviderAvailable(pin.provider, app: app),
           let option = app.providers.model(pin.modelID, for: pin.provider) {
            return (pin.provider, option)
        }

        // 3. Default provider's default model.
        let defaultProvider = app.settings.defaultProvider
        if isProviderAvailable(defaultProvider, app: app),
           let option = app.providers.defaultModel(for: defaultProvider) {
            return (defaultProvider, option)
        }

        // 4. First available pinned model.
        for pin in app.settings.modelList {
            if isProviderAvailable(pin.provider, app: app),
               let option = app.providers.model(pin.modelID, for: pin.provider) {
                return (pin.provider, option)
            }
        }

        // 5. Any available provider's default model.
        for provider in ProviderKind.allCases {
            if isProviderAvailable(provider, app: app),
               let option = app.providers.defaultModel(for: provider) {
                return (provider, option)
            }
        }

        return nil
    }

    private func resolveRequestedModel(
        _ requestedID: String?,
        app: AppModel
    ) -> Result<(provider: ProviderKind, option: ModelOption), ResolutionFailure> {
        guard let requestedID else {
            guard let fallback = resolveDefaultModel(app: app) else {
                return .failure(ResolutionFailure(code: .model_unavailable, message: "No available model is configured in Tivano."))
            }
            return .success(fallback)
        }

        let decoded = ControlAgentModel.decode(requestedID)
        guard let provider = ProviderKind(rawValue: decoded.provider) else {
            return .failure(ResolutionFailure(code: .model_unavailable, message: "Unknown provider."))
        }
        guard isProviderAvailable(provider, app: app) else {
            return .failure(ResolutionFailure(code: .model_unavailable, message: "\(provider.displayName) is unavailable."))
        }
        let option: ModelOption? = if let modelID = decoded.model {
            app.providers.model(modelID, for: provider)
        } else {
            app.providers.defaultModel(for: provider)
        }
        guard let option else {
            return .failure(ResolutionFailure(code: .model_unavailable, message: "Requested model is unavailable for \(provider.displayName)."))
        }
        return .success((provider, option))
    }

    // MARK: - Event mapping helpers

    private static func approvalOptionID(for request: ApprovalRequest) -> String {
        switch request.kind {
        case .fileChange:
            return request.options.first(where: { $0.role == .approve })?.id
                ?? request.options.first(where: { $0.role == .approveAlways })?.id
                ?? "allow"
        case .command, .tool, .permissions, .plan:
            return request.options.first(where: { $0.role == .decline })?.id
                ?? request.options.first(where: { $0.role == .cancel })?.id
                ?? "decline"
        }
    }

    private static func toolName(for call: ToolCall) -> String {
        switch call.kind {
        case .mcp, .other:
            return call.title.isEmpty ? call.kind.rawValue : call.title
        case .command, .read, .edit, .search, .web, .agent:
            return call.kind.rawValue
        }
    }

    private static func genericToolTitles(for kind: ToolCall.Kind) -> [String] {
        switch kind {
        case .command:
            ["Shell command", "Run command", "Monitor command", "Shell output", "Shell tasks", "Stop shell"]
        case .read:
            ["Read file", "Image"]
        case .edit:
            ["Write file", "Edit file", "Create file", "Edit notebook", "Apply file changes"]
        case .search:
            ["Find files", "Search", "List files"]
        case .web:
            ["Fetch page", "Search the web", "Web search", "Fetch"]
        case .agent:
            ["Subagent", "Sub-agent", "Agent", "Agent output"]
        case .mcp, .other:
            ["Tool"]
        }
    }

    private static func isGenericToolTitle(_ title: String, kind: ToolCall.Kind) -> Bool {
        let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return true }
        for key in genericToolTitles(for: kind) {
            if normalized == key.lowercased() || normalized == AppText.localized(key).lowercased() {
                return true
            }
        }
        return false
    }

    private static func toolInput(for call: ToolCall) -> Any? {
        var dict: [String: Any] = [:]
        let editPaths = call.edits.map(\.path).filter { !$0.isEmpty }
        if !editPaths.isEmpty {
            if editPaths.count == 1 {
                dict["path"] = editPaths[0]
            } else {
                dict["paths"] = editPaths
            }
        }

        let trimmedTitle = call.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTitle.isEmpty, !isGenericToolTitle(trimmedTitle, kind: call.kind) {
            switch call.kind {
            case .read:
                dict["path"] = trimmedTitle
            case .edit:
                if dict["path"] == nil && dict["paths"] == nil {
                    dict["path"] = trimmedTitle
                }
            case .command:
                dict["command"] = trimmedTitle
            case .search:
                dict["query"] = trimmedTitle
            case .web:
                dict["target"] = trimmedTitle
            case .mcp, .agent, .other:
                dict["title"] = trimmedTitle
            }
        }

        if let detail = call.detail?.trimmingCharacters(in: .whitespacesAndNewlines), !detail.isEmpty {
            if let parsed = JSONValue.parse(detail) {
                switch parsed {
                case .object(let map):
                    if !map.isEmpty {
                        if dict.isEmpty {
                            return parsed.foundationObject
                        }
                        dict["detail"] = parsed.foundationObject
                    }
                case .array(let list):
                    if !list.isEmpty {
                        dict["detail"] = parsed.foundationObject
                    }
                default:
                    dict["detail"] = detail
                }
            } else {
                dict["detail"] = detail
            }
        }

        return dict.isEmpty ? nil : dict
    }

    private static func resolveFilePath(_ raw: String, cwd: URL) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "/dev/null" else { return nil }
        let url: URL
        if trimmed.hasPrefix("/") {
            url = URL(fileURLWithPath: trimmed).standardizedFileURL
        } else if trimmed.hasPrefix("~/") {
            let expanded = (trimmed as NSString).expandingTildeInPath
            url = URL(fileURLWithPath: expanded).standardizedFileURL
        } else {
            url = cwd.appendingPathComponent(trimmed).standardizedFileURL
        }
        return url.path
    }

    private static func fallbackEditPath(_ title: String, cwd: URL) -> String? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isGenericToolTitle(trimmed, kind: .edit) else { return nil }
        guard let resolved = resolveFilePath(trimmed, cwd: cwd) else { return nil }
        if FileManager.default.fileExists(atPath: resolved) || trimmed.contains("/") || trimmed.contains(".") {
            return resolved
        }
        return nil
    }

    private static func paths(inDiff diff: String) -> [String] {
        var result: [String] = []
        var pendingOldPath: String?

        func cleanHeaderPath(_ raw: Substring) -> String? {
            let beforeTab = raw.split(separator: "\t", maxSplits: 1).first ?? raw
            var path = String(beforeTab).trimmingCharacters(in: .whitespacesAndNewlines)
            if path.hasPrefix("\"") && path.hasSuffix("\"") && path.count >= 2 {
                path = String(path.dropFirst().dropLast())
            }
            if path == "/dev/null" || path.isEmpty { return nil }
            if path.hasPrefix("a/") || path.hasPrefix("b/") {
                path = String(path.dropFirst(2))
            }
            return path.isEmpty ? nil : path
        }

        for line in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("--- ") {
                pendingOldPath = cleanHeaderPath(line.dropFirst(4))
            } else if line.hasPrefix("+++ ") {
                if let path = cleanHeaderPath(line.dropFirst(4)) {
                    result.append(path)
                } else if let deleted = pendingOldPath {
                    result.append(deleted)
                }
                pendingOldPath = nil
            }
        }
        return result
    }

    // MARK: - Error sanitization

    private func sanitizeError(_ error: Error) -> String {
        let raw = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        return sanitizeError(raw)
    }

    private func sanitizeError(_ raw: String) -> String {
        var cleaned = TextCleanup.stripANSI(raw)
        if let settings = app?.settings {
            for provider in ProviderKind.allCases where provider.acceptsAPIKey {
                let key = settings.apiKey(for: provider).trimmingCharacters(in: .whitespacesAndNewlines)
                if key.count >= 6 {
                    cleaned = cleaned.replacingOccurrences(of: key, with: "[redacted]")
                }
            }
        }
        let secretPatterns = [
            #"(?i)\bBearer\s+[A-Za-z0-9._\-+/=]{8,}"#,
            #"(?i)\b(api[_-]?key|access[_-]?token|auth[_-]?token|secret|password|authorization)\s*[:=]\s*['"]?[^\s'",;}{]{6,}['"]?"#,
            #"\b(sk-[A-Za-z0-9_\-]{8,}|ghp_[A-Za-z0-9]{10,}|gho_[A-Za-z0-9]{10,}|xox[baprs]-[A-Za-z0-9\-]{10,}|AIza[A-Za-z0-9_\-]{20,}|AKIA[0-9A-Z]{16})\b"#,
        ]
        for pattern in secretPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                let range = NSRange(cleaned.startIndex..., in: cleaned)
                cleaned = regex.stringByReplacingMatches(in: cleaned, range: range, withTemplate: "[redacted]")
            }
        }
        let collapsed = cleaned
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return "Provider error." }
        if collapsed.count > Self.maxErrorLength {
            return String(collapsed.prefix(Self.maxErrorLength - 1)) + "…"
        }
        return collapsed
    }
}
