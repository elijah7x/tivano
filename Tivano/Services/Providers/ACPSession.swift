import Foundation

/// Spaces out the starts of ACP agent processes. An agent keeps a store of its own on this
/// Mac (OpenCode's is SQLite), and several starting in the same instant, as a team of heads
/// does, trip over its lock: "database is locked", and a head's first turn is over before
/// it began. A lone start never waits; a batch starts one every `spacing` seconds.
private actor ACPLaunchGate {
    private let spacing: TimeInterval
    private var nextSlot = Date.distantPast

    init(spacing: TimeInterval) {
        self.spacing = spacing
    }

    func wait() async {
        let now = Date.now
        let slot = max(now, nextSlot)
        nextSlot = slot.addingTimeInterval(spacing)
        if slot > now { try? await Task.sleep(for: .seconds(slot.timeIntervalSince(now))) }
    }
}

/// Drives Agent Client Protocol agents: Cursor, OpenCode, Grok, Devin and Kimi Code.
@MainActor
final class ACPSession: ProviderSession {
    private static let launchGate = ACPLaunchGate(spacing: 1.5)

    var onEvent: ((ProviderEvent) -> Void)?

    private let configuration: SessionConfiguration
    private var connection: JSONRPCConnection?
    private var sessionID: String?
    private var authMethods: [String] = []
    private var canLoadSessions = false
    private var supportsHTTPMCP = false
    private var isReplaying = false
    private var isStopping = false
    private var runtimeMode: RuntimeMode
    private var messageID: String?
    private var thoughtID: String?
    private var counter = 0
    private var pendingPermissions: [String: RPCID] = [:]
    private struct PendingQuestion {
        var rpcID: RPCID
        var form: ACPQuestionForm?
        var permissionOptions: [String: String] = [:]
    }
    private var pendingQuestions: [String: PendingQuestion] = [:]
    private var toolKinds: [String: ToolCall.Kind] = [:]
    private var promptActive = false
    private var cancelRequested = false
    /// Tool calls already routed to the checklist (opencode `todowrite` arrives as a
    /// generic tool_call, not a plan update). Their later updates keep feeding the
    /// same checklist instead of opening new tool rows.
    private var todoToolCallIDs: Set<String> = []

    private var models: [ModelOption] = []
    private var modelConfigID: String?
    private var modeConfigID: String?
    private var effortConfigID: String?
    /// Cursor's Fast toggle (`model_config` / `fast`), when the parameterized picker is on.
    private var fastConfigID: String?
    private var hasModeAPI = false
    private var planMode: String?
    private var buildMode: String?
    private var currentMode: String?
    private var currentModel: String?
    private var currentEffort: String?
    private var currentFast: String?
    /// Cursor only exposes effort/fast selectors when the client opts into its parameterized picker.
    private var usesParameterizedModels: Bool { configuration.provider == .cursor }

    init(configuration: SessionConfiguration) {
        self.configuration = configuration
        runtimeMode = configuration.runtimeMode
        models = configuration.modelCatalog
    }

    var isRunning: Bool {
        guard let connection else { return false }
        return !connection.isClosed
    }

    private var workingDirectory: String { configuration.workingDirectory.path }

    private var launchArguments: [String] {
        switch configuration.provider {
        case .cursor:
            switch configuration.runtimeMode {
            case .auto: ["--auto-review", "acp"]
            case .fullAccess: ["--force", "acp"]
            default: ["acp"]
            }
        case .grok:
            switch configuration.runtimeMode {
            case .supervised: ["--permission-mode", "default", "agent", "stdio"]
            case .autoAcceptEdits: ["--permission-mode", "acceptEdits", "agent", "stdio"]
            case .auto: ["--permission-mode", "auto", "agent", "stdio"]
            case .fullAccess: ["agent", "--always-approve", "stdio"]
            }
        case .devin:
            // Devin's modes at a glance: auto approves read-only tools, accept-edits
            // adds workspace edits, smart adds model-judged-safe actions, dangerous
            // approves everything. Passed before the subcommand, like its CLI expects.
            switch configuration.runtimeMode {
            case .supervised: ["--permission-mode", "auto", "acp"]
            case .autoAcceptEdits: ["--permission-mode", "accept-edits", "acp"]
            case .auto: ["--permission-mode", "smart", "acp"]
            case .fullAccess: ["--permission-mode", "dangerous", "acp"]
            }
        default:
            ["acp"]
        }
    }

    func start() async throws -> String {
        guard let executable = configuration.executable else { throw ProviderError.notInstalled(configuration.provider) }
        await Self.launchGate.wait()
        let process = StdioProcess(
            executable: executable,
            arguments: launchArguments,
            directory: configuration.workingDirectory,
            environment: configuration.environment
        )
        let connection = JSONRPCConnection(process: process, sendsVersion: true)
        connection.onNotification = { [weak self] method, params in self?.handleNotification(method, params) }
        connection.onRequest = { [weak self] id, method, params in self?.handleRequest(id, method, params) }
        connection.onClose = { [weak self] tail in self?.handleClose(tail) }
        self.connection = connection
        try connection.start()

        let initialized = try await deadlineRequest(connection, "initialize", [
            "protocolVersion": 1,
            "clientCapabilities": clientCapabilities,
            "clientInfo": ["name": "tivano", "title": "Tivano", "version": .string(AppInfo.version)],
        ])
        canLoadSessions = initialized["agentCapabilities"]?["loadSession"]?.bool ?? false
        supportsHTTPMCP = initialized["agentCapabilities"]?["mcpCapabilities"]?["http"]?.bool ?? false
        authMethods = (initialized["authMethods"]?.array ?? []).compactMap { $0["id"]?.string }
        if let state = initialized["_meta"]?["modelState"] { applyModels(state) }

        let session: JSONValue
        do {
            session = try await openSession(connection)
        } catch let error as RPCError where error.message.localizedCaseInsensitiveContains("auth") && !authMethods.isEmpty {
            if configuration.provider == .kimi { throw Self.kimiLoginRequired }
            _ = try await deadlineRequest(connection, "authenticate", ["methodId": .string(authMethods[0])])
            session = try await openSession(connection)
        }
        applySessionState(session)
        try await applySelection(
            model: configuration.model,
            effort: configuration.effort,
            fastMode: configuration.fastMode,
            interaction: configuration.interactionMode
        )
        guard let sessionID else {
            throw ProviderError.failed("\(configuration.provider.displayName) did not start a session.")
        }
        return sessionID
    }

    /// Cursor hides effort and Fast behind an undocumented `_meta` flag; without it the
    /// agent only returns one baked-in variant per model and rejects any other effort.
    private var clientCapabilities: JSONValue {
        var capabilities: [String: JSONValue] = [
            "fs": ["readTextFile": false, "writeTextFile": false],
            "terminal": false,
        ]
        if usesParameterizedModels {
            capabilities["_meta"] = ["parameterizedModelPicker": true]
        }
        if configuration.provider == .kimi {
            capabilities["elicitation"] = ["form": [:]]
        }
        return .object(capabilities)
    }

    func send(_ input: TurnInput) async throws {
        guard let connection, !connection.isClosed, let sessionID else { throw ProviderError.notRunning }
        runtimeMode = input.runtimeMode
        try await applySelection(
            model: input.model,
            effort: input.effort,
            fastMode: input.fastMode,
            interaction: input.interactionMode
        )
        var prompt: [JSONValue] = [["type": "text", "text": .string(input.text)]]
        for (image, base64) in await Attachment.base64Images(input.images) {
            prompt.append(["type": "image", "mimeType": .string(image.mimeType), "data": .string(base64)])
        }
        messageID = nil
        thoughtID = nil
        promptActive = true
        cancelRequested = false
        onEvent?(.turnStarted(providerTurnID: nil))
        Task { [weak self] in
            do {
                let result = try await connection.request("session/prompt", [
                    "sessionId": .string(sessionID),
                    "prompt": .array(prompt),
                ])
                self?.finishPrompt(result["stopReason"]?.string, error: nil)
            } catch {
                self?.finishPrompt(nil, error: error)
            }
        }
    }

    func interrupt() async {
        guard promptActive, let connection, let sessionID else { return }
        cancelRequested = true
        for (key, id) in pendingPermissions {
            connection.respond(to: id, result: ["outcome": ["outcome": "cancelled"]])
            onEvent?(.requestResolved(id: key))
        }
        pendingPermissions.removeAll()
        cancelQuestions(connection)
        connection.notify("session/cancel", ["sessionId": .string(sessionID)])
    }

    func compact() async throws {
        throw ProviderError.failed("\(configuration.provider.displayName) compacts its own context.")
    }

    func resolveApproval(_ requestID: String, optionID: String) {
        resolveApproval(requestID, optionID: optionID, delivered: { _ in })
    }

    func resolveApproval(_ requestID: String, optionID: String, delivered: @escaping @MainActor (Bool) -> Void) {
        guard !isStopping, let connection, !connection.isClosed, let id = pendingPermissions[requestID] else {
            delivered(false)
            return
        }
        connection.respond(to: id, result: ["outcome": ["outcome": "selected", "optionId": .string(optionID)]]) { [weak self] succeeded in
            if succeeded, let self, self.pendingPermissions.removeValue(forKey: requestID) != nil {
                self.onEvent?(.requestResolved(id: requestID))
            }
            delivered(succeeded)
        }
    }

    func answerQuestion(_ requestID: String, answers: [String: [String]]) {
        answerQuestion(requestID, answers: answers, delivered: { _ in })
    }

    func answerQuestion(_ requestID: String, answers: [String: [String]], delivered: @escaping @MainActor (Bool) -> Void) {
        guard !isStopping, let connection, !connection.isClosed, let pending = pendingQuestions[requestID] else {
            delivered(false)
            return
        }
        let response: JSONValue
        if answers.values.allSatisfy({ $0.isEmpty }) {
            response = pending.form == nil ? ["outcome": ["outcome": "cancelled"]] : ["action": "cancel"]
        } else if let form = pending.form {
            guard let accepted = form.response(answers: answers) else { delivered(false); return }
            response = accepted
        } else {
            guard let selected = answers["q0"]?.first, let optionID = pending.permissionOptions[selected] else {
                delivered(false)
                return
            }
            response = ["outcome": ["outcome": "selected", "optionId": .string(optionID)]]
        }
        connection.respond(to: pending.rpcID, result: response) { [weak self] succeeded in
            if succeeded, self?.pendingQuestions.removeValue(forKey: requestID) != nil {
                self?.onEvent?(.requestResolved(id: requestID))
            }
            delivered(succeeded)
        }
    }

    private func cancelQuestions(_ connection: JSONRPCConnection) {
        for (key, pending) in pendingQuestions {
            let response: JSONValue = pending.form == nil
                ? ["outcome": ["outcome": "cancelled"]] : ["action": "cancel"]
            connection.respond(to: pending.rpcID, result: response)
            onEvent?(.requestResolved(id: key))
        }
        pendingQuestions.removeAll()
    }

    func stopAndWait(timeout: TimeInterval) async {
        let connection = connection
        stop()
        await connection?.closeAndWait(timeout: timeout)
    }

    func stop() {
        isStopping = true
        connection?.close()
    }

    private static var kimiLoginRequired: ProviderError {
        .failed(AppText.localized("Sign in to Kimi Code with `kimi login`, then try again."))
    }

    static func authStatus(provider: ProviderKind, executable: URL, environment: [String: String]) async -> ProviderStatus.Auth {
        let process = StdioProcess(executable: executable, arguments: ["acp"], directory: FileManager.default.temporaryDirectory, environment: environment)
        let connection = JSONRPCConnection(process: process, sendsVersion: true)
        defer { connection.close() }
        do {
            try connection.start()
            _ = try await withDeadline(seconds: 20, provider: provider.displayName, operation: "authenticate") {
                _ = try await connection.request("initialize", ["protocolVersion": 1, "clientCapabilities": [:]])
                return try await connection.request("authenticate", ["methodId": "login"])
            }
            return .signedIn(nil)
        } catch let error as RPCError where error.code == -32000 && error.message.localizedCaseInsensitiveContains("auth") {
            return .signedOut
        } catch {
            return .unknown
        }
    }

    // MARK: - Catalog

    static func probeModels(provider: ProviderKind, executable: URL, environment: [String: String]) async throws -> [ModelOption] {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tivano-catalog", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let session = ACPSession(configuration: SessionConfiguration(
            provider: provider,
            executable: executable,
            workingDirectory: directory,
            environment: environment,
            runtimeMode: .supervised,
            interactionMode: .build
        ))
        var models: [ModelOption] = []
        session.onEvent = { event in
            if case .models(let list, _) = event { models = list }
        }
        defer { session.stop() }
        _ = try await session.start()
        await session.probeModelEfforts()
        return models
    }

    // MARK: - Session state

    private func deadlineRequest(_ connection: JSONRPCConnection, _ method: String, _ params: JSONValue) async throws -> JSONValue {
        try await withDeadline(seconds: 45, provider: configuration.provider.displayName, operation: method) {
            try await connection.request(method, params)
        }
    }

    private func openSession(_ connection: JSONRPCConnection) async throws -> JSONValue {
        // The connected servers ride into every new session through ACP's own field,
        // HTTP ones directly where the agent says it speaks HTTP MCP, else through `mcp-remote`.
        let base: [String: JSONValue] = ["cwd": .string(workingDirectory), "mcpServers": MCPProviderConfig.acpServers(allowsHTTP: supportsHTTPMCP)]
        if let resumeID = configuration.resumeID {
            guard canLoadSessions else {
                throw ProviderError.failed(AppText.localized("This ACP agent cannot resume the original session."))
            }
            var params = base
            params["sessionId"] = .string(resumeID)
            isReplaying = true
            defer { isReplaying = false }
            let result = try await deadlineRequest(connection, "session/load", .object(params))
            sessionID = resumeID
            return result
        }
        let result = try await deadlineRequest(connection, "session/new", .object(base))
        sessionID = result["sessionId"]?.string
        return result
    }

    private func applySessionState(_ state: JSONValue) {
        if let modes = state["modes"], !modes.isNull {
            hasModeAPI = true
            currentMode = modes["currentModeId"]?.string
            resolveModes((modes["availableModes"]?.array ?? []).compactMap { $0["id"]?.string })
        }
        if let modelState = state["models"], !modelState.isNull { applyModels(modelState) }
        if let options = state["configOptions"]?.array { applyConfigOptions(options) }
    }

    /// Cursor and OpenCode report the effort scale of the current model only (the
    /// `thought_level` config option in each reply), so the catalog probe walks the
    /// list: each model without a scale yet is made current in turn and its scale
    /// read off the reply, and the model the session started on is put back. Models
    /// that arrived with a scale (Grok lists them in `_meta.reasoningEfforts`) are
    /// skipped by the `where` filter. A provider that names its variants (Devin) has its
    /// scale in the names and no effort option to read, so it is not walked at all.
    private func probeModelEfforts() async {
        guard let modelConfigID, !configuration.provider.namesModelVariants else { return }
        let original = currentModel
        for model in models where model.efforts.isEmpty {
            guard (try? await setConfigOption(modelConfigID, value: model.id)) != nil else { continue }
            currentModel = model.id
        }
        if let original, !Self.sameModel(original, currentModel) {
            if (try? await setConfigOption(modelConfigID, value: original)) != nil { currentModel = original }
        }
    }

    private func resolveModes(_ ids: [String]) {
        planMode = ids.first { $0 == "plan" }
        buildMode = ids.first { ["agent", "build", "code", "default"].contains($0) }
            ?? ids.first { $0 != "plan" && $0 != "ask" }
    }

    private func applyModels(_ state: JSONValue) {
        let current = state["currentModelId"]?.string.map(Self.baseModelID)
        currentModel = current ?? currentModel
        let list = (state["availableModels"]?.array ?? []).compactMap { entry -> ModelOption? in
            guard let rawID = entry["modelId"]?.string else { return nil }
            let id = usesParameterizedModels ? Self.baseModelID(rawID) : rawID
            let efforts = entry["_meta"]?["reasoningEfforts"]?.array ?? []
            return ModelOption(
                id: id,
                name: entry["name"]?.string ?? id,
                detail: entry["description"]?.string,
                efforts: ModelOption.orderedEfforts(efforts.compactMap { $0["value"]?.string }),
                defaultEffort: efforts.first { $0["default"]?.bool == true }?["value"]?.string,
                isDefault: id == current
            )
        }
        guard !list.isEmpty else { return }
        models = configuration.provider.namesModelVariants ? ModelFamilies.collapsed(list) : list
        onEvent?(.models(models, current: currentModel))
    }

    private func applyConfigOptions(_ options: [JSONValue]) {
        var efforts: [String] = []
        var hasFast = false
        effortConfigID = nil
        fastConfigID = nil
        for option in options {
            guard let id = option["id"]?.string else { continue }
            let values = Self.flatten(option["options"]?.array ?? [])
            let current = option["currentValue"]?.string
            switch option["category"]?.string ?? id {
            case "model":
                modelConfigID = id
                currentModel = current.map { usesParameterizedModels ? Self.baseModelID($0) : $0 } ?? currentModel
                // One lookup per value: the walk over OpenCode's four hundred models replies
                // four hundred times, and a linear search per value on each reply stalled the
                // main actor.
                let knownByID = Dictionary(models.map { (Self.baseModelID($0.id), $0) }, uniquingKeysWith: { first, _ in first })
                let list = values.compactMap { value -> ModelOption? in
                    guard let rawID = value["value"]?.string else { return nil }
                    let valueID = usesParameterizedModels ? Self.baseModelID(rawID) : rawID
                    // A rebuilt list keeps what earlier passes learned about each model (its
                    // scale, its Fast tier): Cursor reports them for the current model only,
                    // one pass at a time.
                    let known = knownByID[Self.baseModelID(valueID)]
                    var option = ModelOption(
                        id: valueID,
                        name: value["name"]?.string ?? valueID,
                        detail: value["description"]?.string,
                        efforts: known?.efforts ?? [],
                        defaultEffort: known?.defaultEffort,
                        isDefault: valueID == currentModel
                    )
                    option.fastTier = known?.fastTier
                    return option
                }
                if !list.isEmpty { models = configuration.provider.namesModelVariants ? ModelFamilies.collapsed(list) : list }
            case "mode":
                modeConfigID = id
                currentMode = current ?? currentMode
                resolveModes(values.compactMap { $0["value"]?.string })
            case "thought_level", "effort":
                // Cursor also advertises a boolean `thinking` thought_level; only the
                // scale (low/medium/high/…) drives the effort slider.
                let scale = values.compactMap { $0["value"]?.string }
                guard Self.isEffortScale(scale) else { break }
                effortConfigID = id
                currentEffort = current
                efforts = ModelOption.orderedEfforts(scale)
            case "model_config":
                if id == "fast" {
                    fastConfigID = id
                    currentFast = current
                    hasFast = true
                }
            default:
                break
            }
        }
        models = models.map { model in
            var model = model
            let isCurrent = Self.sameModel(model.id, currentModel)
            if isCurrent, !efforts.isEmpty {
                model.efforts = efforts
                model.defaultEffort = currentEffort ?? model.defaultEffort
            }
            // A row of variants takes Fast from its variants, not from an option.
            if isCurrent, model.variants.isEmpty {
                model.fastTier = hasFast ? "true" : nil
            }
            return model
        }
        if !models.isEmpty { onEvent?(.models(models, current: currentModel)) }
    }

    private static func flatten(_ values: [JSONValue]) -> [JSONValue] {
        values.flatMap { value -> [JSONValue] in
            if let nested = value["options"]?.array { return nested }
            return [value]
        }
    }

    /// Values that belong on the effort slider, as opposed to a boolean thinking toggle.
    private static func isEffortScale(_ values: [String]) -> Bool {
        let known: Set<String> = ["none", "low", "medium", "high", "xhigh", "max", "extra-high"]
        return values.contains { known.contains($0.lowercased()) }
    }

    /// Cursor's parameterized IDs are `model[effort=high,…]`; the picker stores the base name.
    private static func baseModelID(_ id: String) -> String {
        guard let bracket = id.firstIndex(of: "[") else { return id }
        return String(id[..<bracket])
    }

    /// The id the agent takes for a model at an effort and speed. A row of variants
    /// (see `ModelFamilies`) resolves to the variant that matches; an id a thread kept
    /// from before its provider's variants were merged runs as it was until the effort
    /// or Fast is changed, and then moves within its family.
    private func providerID(for model: String, effort: String?, fastMode: Bool) -> String {
        if let family = models.first(where: { $0.id == model }) {
            return family.providerID(effort: effort, fastMode: fastMode)
        }
        guard let family = models.first(where: { $0.variant(model) != nil }), let variant = family.variant(model) else { return model }
        if effort == nil, !fastMode { return model }
        return family.providerID(effort: effort ?? variant.effort, fastMode: fastMode)
    }

    private static func sameModel(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhs, let rhs else { return false }
        return baseModelID(lhs) == baseModelID(rhs)
    }

    private func applySelection(model: String?, effort: String?, fastMode: Bool, interaction: InteractionMode) async throws {
        guard let connection, let sessionID else { return }
        if let model, !model.isEmpty {
            let wireID = usesParameterizedModels ? Self.baseModelID(model) : providerID(for: model, effort: effort, fastMode: fastMode)
            if !Self.sameModel(wireID, currentModel) {
                if let modelConfigID {
                    try await setConfigOption(modelConfigID, value: wireID)
                } else {
                    _ = try await connection.request("session/set_model", ["sessionId": .string(sessionID), "modelId": .string(wireID)])
                }
                currentModel = wireID
            }
        }
        if let effort, !effort.isEmpty, let effortConfigID, effort != currentEffort {
            try await setConfigOption(effortConfigID, value: effort)
            currentEffort = effort
        }
        if let fastConfigID {
            let wanted = fastMode ? "true" : "false"
            if wanted != currentFast {
                try await setConfigOption(fastConfigID, value: wanted)
                currentFast = wanted
            }
        }
        let wantedMode: String?
        if configuration.provider == .kimi, interaction != .plan {
            wantedMode = switch runtimeMode {
            case .supervised, .autoAcceptEdits: "default"
            case .auto: "auto"
            case .fullAccess: "yolo"
            }
        } else {
            wantedMode = interaction == .plan ? planMode : buildMode
        }
        if let mode = wantedMode, mode != currentMode {
            if let modeConfigID {
                try await setConfigOption(modeConfigID, value: mode)
            } else if hasModeAPI {
                _ = try await connection.request("session/set_mode", ["sessionId": .string(sessionID), "modeId": .string(mode)])
            }
            currentMode = mode
        }
    }

    private func setConfigOption(_ configID: String, value: String) async throws {
        guard let connection, let sessionID else { throw ProviderError.notRunning }
        let result = try await connection.request("session/set_config_option", [
            "sessionId": .string(sessionID),
            "configId": .string(configID),
            "value": .string(value),
        ])
        if let options = result["configOptions"]?.array { applyConfigOptions(options) }
    }

    // MARK: - Updates

    private func handleNotification(_ method: String, _ params: JSONValue) {
        guard method == "session/update", !isReplaying, let update = params["update"] else { return }
        switch update["sessionUpdate"]?.string {
        case "agent_message_chunk":
            guard let text = update["content"]?["text"]?.string else { return }
            thoughtID = nil
            let id = update["messageId"]?.string.map { "message-\($0)" } ?? messageID ?? nextID("message")
            messageID = id
            onEvent?(.messageDelta(id: id, text: text))
        case "agent_thought_chunk":
            guard let text = update["content"]?["text"]?.string else { return }
            let id = thoughtID ?? nextID("thought")
            thoughtID = id
            onEvent?(.reasoningDelta(id: id, text: text))
        case "tool_call":
            guard let id = update["toolCallId"]?.string else { return }
            messageID = nil
            thoughtID = nil
            if Self.isTodoCall(update) {
                todoToolCallIDs.insert(id)
                let steps = Self.todoSteps(update)
                if !steps.isEmpty { onEvent?(.todos(steps)) }
                return
            }
            let call = makeToolCall(update)
            toolKinds[id] = call.kind
            onEvent?(.toolStarted(id: id, call: call))
            let initial = makeToolUpdate(update)
            if initial.output != nil || initial.status != nil { onEvent?(.toolUpdated(id: id, update: initial)) }
        case "tool_call_update":
            guard let id = update["toolCallId"]?.string else { return }
            if todoToolCallIDs.contains(id) || Self.isTodoCall(update) {
                todoToolCallIDs.insert(id)
                let steps = Self.todoSteps(update)
                if !steps.isEmpty { onEvent?(.todos(steps)) }
                return
            }
            if let kind = update["kind"]?.string { toolKinds[id] = Self.kind(kind) }
            onEvent?(.toolUpdated(id: id, update: makeToolUpdate(update)))
        case "plan":
            let steps = Self.parseTodoItems(update["entries"])
            onEvent?(.todos(steps))
        case "available_commands_update":
            let commands = (update["availableCommands"]?.array ?? []).compactMap { command -> SlashCommand? in
                guard let name = command["name"]?.string else { return nil }
                return SlashCommand(name: name, detail: command["description"]?.string ?? "")
            }
            onEvent?(.commands(commands))
        case "current_mode_update":
            currentMode = update["currentModeId"]?.string
            if let planMode { onEvent?(.modeChanged(currentMode == planMode ? .plan : .build)) }
        case "config_option_update":
            if let options = update["configOptions"]?.array { applyConfigOptions(options) }
        case "session_info_update":
            if let title = update["title"]?.string, !title.isEmpty { onEvent?(.title(title)) }
        case "usage_update":
            if let used = update["used"]?.int {
                // Occupancy, not spend: `used` of `size` is how full the context
                // window is, so it feeds the context meter and nothing else. The
                // deltas a session total would give are the growth of that meter,
                // and a compaction or a new request drops them; charging the
                // ledger here would bill the context, not the tokens.
                onEvent?(.usage(ContextUsage(usedTokens: used, windowTokens: update["size"]?.int)))
            }
        default:
            break
        }
    }

    private func handleRequest(_ id: RPCID, _ method: String, _ params: JSONValue) {
        if method == "elicitation/create", configuration.provider == .kimi {
            guard let form = ACPQuestionForm(params) else {
                connection?.respond(to: id, errorCode: -32602, message: "Unsupported question form")
                return
            }
            pendingQuestions[id.key] = PendingQuestion(rpcID: id, form: form)
            onEvent?(.question(QuestionRequest(id: id.key, questions: form.questions)))
            return
        }
        guard method == "session/request_permission" else {
            connection?.respond(to: id, errorCode: -32601, message: "Method not found")
            return
        }
        let options = params["options"]?.array ?? []
        let toolCall = params["toolCall"] ?? .null
        var call = makeToolCall(toolCall)
        if let toolID = toolCall["toolCallId"]?.string, let knownKind = toolKinds[toolID], toolCall["kind"] == nil {
            call.kind = knownKind
        }
        let isQuestion = configuration.provider == .kimi && (toolCall["title"]?.string == "AskUserQuestion"
            || options.contains { $0["optionId"]?.string?.hasPrefix("q0_") == true })
        let isPlan = configuration.provider == .kimi && options.contains { $0["optionId"]?.string?.hasPrefix("plan_") == true }
        if isQuestion {
            var choices: [QuestionRequest.Choice] = []
            var optionIDs: [String: String] = [:]
            for option in options where option["kind"]?.string == "allow_once" {
                guard let optionID = option["optionId"]?.string, let label = option["name"]?.string else { continue }
                choices.append(.init(label: label, detail: nil))
                optionIDs[label] = optionID
            }
            pendingQuestions[id.key] = PendingQuestion(rpcID: id, form: nil, permissionOptions: optionIDs)
            onEvent?(.question(QuestionRequest(id: id.key, questions: [
                .init(id: "q0", header: call.title, prompt: permissionDetail(toolCall) ?? call.title,
                      choices: choices, allowsMultiple: false, allowsOther: false, isSecret: false)
            ])))
            return
        }
        if !isPlan, let optionID = automaticOption(for: call.kind, options: options) {
            connection?.respond(to: id, result: ["outcome": ["outcome": "selected", "optionId": .string(optionID)]])
            return
        }
        let mapped = options.compactMap { option -> ApprovalRequest.Option? in
            guard let optionID = option["optionId"]?.string else { return nil }
            let role: ApprovalRequest.Option.Role = switch option["kind"]?.string {
            case "allow_always": .approveAlways
            case "reject_once", "reject_always": .decline
            default: .approve
            }
            return .init(id: optionID, title: option["name"]?.string ?? optionID, role: role)
        }
        pendingPermissions[id.key] = id
        let kind: ApprovalRequest.Kind
        if isPlan {
            kind = .plan
        } else {
            kind = switch call.kind {
            case .command: .command
            case .edit: .fileChange
            default: .tool
            }
        }
        onEvent?(.approval(ApprovalRequest(
            id: id.key,
            kind: kind,
            title: call.title,
            detail: call.detail ?? permissionDetail(toolCall),
            options: mapped,
            toolItemID: toolCall["toolCallId"]?.string
        )))
    }

    private func permissionDetail(_ toolCall: JSONValue) -> String? {
        let text = (toolCall["content"]?.array ?? []).compactMap { $0["content"]?["text"]?.string }.joined(separator: "\n")
        return text.isEmpty ? nil : text
    }

    private func automaticOption(for kind: ToolCall.Kind, options: [JSONValue]) -> String? {
        let automatic = switch runtimeMode {
        case .fullAccess: true
        case .autoAcceptEdits: kind == .edit
        default: false
        }
        guard automatic else { return nil }
        let allowOnce = options.first { $0["kind"]?.string == "allow_once" }
        let allowAlways = options.first { $0["kind"]?.string == "allow_always" }
        return (allowOnce ?? allowAlways)?["optionId"]?.string
    }

    private func finishPrompt(_ stopReason: String?, error: Error?) {
        guard promptActive else { return }
        promptActive = false
        todoToolCallIDs.removeAll()
        toolKinds.removeAll()
        if let connection, !connection.isClosed {
            cancelQuestions(connection)
            for (key, id) in pendingPermissions {
                connection.respond(to: id, result: ["outcome": ["outcome": "cancelled"]]) { [weak self] succeeded in
                    if succeeded, let self, self.pendingPermissions.removeValue(forKey: key) != nil {
                        self.onEvent?(.requestResolved(id: key))
                    }
                }
            }
        }
        if cancelRequested || stopReason == "cancelled" {
            onEvent?(.turnCompleted(status: .interrupted, error: nil))
        } else if let error {
            let detail: String
            if configuration.provider == .kimi, let rpc = error as? RPCError,
               rpc.code == -32000, rpc.message.localizedCaseInsensitiveContains("auth") {
                detail = Self.kimiLoginRequired.localizedDescription
            } else {
                detail = error.localizedDescription
            }
            onEvent?(.turnCompleted(status: .failed, error: detail))
        } else if stopReason == "refusal" {
            onEvent?(.turnCompleted(status: .failed, error: "The agent declined this request."))
        } else {
            onEvent?(.turnCompleted(status: .completed, error: nil))
        }
        cancelRequested = false
    }

    private func handleClose(_ tail: String) {
        if promptActive {
            finishPrompt(nil, error: ProviderError.failed(TextCleanup.lastLines(tail) ?? "The agent exited."))
        }
        guard !isStopping else { return }
        onEvent?(.exited(error: TextCleanup.lastLines(tail)))
    }

    // MARK: - Mapping

    /// True when a tool_call update belongs to a todo-list tool. opencode's `todowrite`
    /// reports itself with a count title ("3 todos") and the JSON list as its output,
    /// never as a plan update, so it is detected here instead of in `makeToolCall`.
    private static func isTodoCall(_ update: JSONValue) -> Bool {
        if update["rawInput"]?["todos"] != nil { return true }
        if let title = update["title"]?.string, isTodoTitle(title) { return true }
        return false
    }

    private static func isTodoTitle(_ title: String) -> Bool {
        let text = title.trimmed.lowercased()
        switch text {
        case "todo", "todos", "todowrite", "todo write", "write todos":
            return true
        default:
            break
        }
        // opencode titles the call "<n> todos", e.g. "3 todos".
        for suffix in [" todos", " todo"] {
            guard text.hasSuffix(suffix) else { continue }
            let count = text.dropLast(suffix.count).trimmingCharacters(in: .whitespaces)
            if !count.isEmpty, count.allSatisfy(\.isNumber) { return true }
        }
        return false
    }

    /// The checklist carried by a todo tool call: structured input first, then the
    /// JSON list the tool reports back as its result text.
    private static func todoSteps(_ update: JSONValue) -> [TodoStep] {
        var steps = parseTodoItems(update["rawInput"]?["todos"])
        if !steps.isEmpty { return steps }
        steps = parseTodoItems(update["rawOutput"]?["todos"])
        if !steps.isEmpty { return steps }
        for block in update["content"]?.array ?? [] {
            guard block["type"]?.string == "content",
                  let text = block["content"]?["text"]?.string,
                  let json = JSONValue.parse(text) else { continue }
            steps = parseTodoItems(json["todos"] ?? json)
            if !steps.isEmpty { return steps }
        }
        if let raw = update["rawOutput"], !raw.isNull {
            for key in ["output", "stdout", "text"] {
                guard let text = raw[key]?.string, let json = JSONValue.parse(text) else { continue }
                steps = parseTodoItems(json["todos"] ?? json)
                if !steps.isEmpty { return steps }
            }
        }
        return []
    }

    /// Todo items across provider shapes: ACP plan entries (`content`), Claude's
    /// TodoWrite (`content`) and Codex-style steps (`step`). Unknown statuses stay
    /// pending so a new provider state never drops an item.
    static func parseTodoItems(_ value: JSONValue?) -> [TodoStep] {
        (value?.array ?? []).compactMap { item -> TodoStep? in
            guard let text = item["content"]?.string ?? item["text"]?.string ?? item["step"]?.string ?? item["title"]?.string,
                  !text.trimmed.isEmpty else { return nil }
            let status: TodoStep.Status = switch item["status"]?.string {
            case "completed", "complete", "done": .done
            case "in_progress", "inProgress", "in-progress", "active": .active
            default: .pending
            }
            return TodoStep(text: text, status: status)
        }
    }

    private func nextID(_ prefix: String) -> String {
        counter += 1
        return "\(prefix)-\(counter)-\(UUID().uuidString.prefix(8))"
    }

    /// Same row shapes as Claude's: the subject is the command, the path, the
    /// pattern or the URL, and the detail only qualifies it. ACP agents title
    /// calls freely ("Fetched https://…", "Search for 'x'", a bare "read"), so
    /// the subject comes from `rawInput` and `locations` first and the title
    /// is the fallback, with its leading verb dropped.
    private func makeToolCall(_ update: JSONValue) -> ToolCall {
        let kind = Self.kind(update["kind"]?.string)
        let raw = update["rawInput"] ?? .null
        let location = update["locations"]?.array?.first?["path"]?.string.map { ToolTitles.relativePath($0, to: workingDirectory) }
        let path = Self.string(in: raw, keys: Self.pathKeys).map { ToolTitles.relativePath($0, to: workingDirectory) } ?? location
        let title = Self.subject(from: update["title"]?.string, kind: kind)
        var call = ToolCall(kind: kind, title: "")
        switch kind {
        case .command:
            call.title = raw["command"]?.string.map(ToolTitles.unwrapShell) ?? title
        case .read, .edit:
            call.title = path ?? title
        case .search:
            let pattern = Self.string(in: raw, keys: ["pattern", "query", "glob", "regex", "search"])
            call.title = pattern ?? title.nilIfEmpty ?? path ?? ""
            if pattern != nil || !title.isEmpty, let path, path != workingDirectory, path != call.title { call.detail = path }
        case .web:
            call.title = Self.string(in: raw, keys: ["url", "query", "prompt"]) ?? title
        case .mcp, .agent, .other:
            call.title = title
            if let path, path != workingDirectory, path != call.title { call.detail = path }
        }
        if call.title.isEmpty { call.title = path ?? Self.fallbackTitle(kind) }
        call.edits = diffs(update["content"])
        if let status = update["status"]?.string { call.status = Self.status(status) }
        return call
    }

    private func makeToolUpdate(_ update: JSONValue) -> ToolUpdate {
        var result = ToolUpdate()
        if let kind = update["kind"]?.string { result.kind = Self.kind(kind) }
        let kind = result.kind ?? .other
        let title = Self.subject(from: update["title"]?.string, kind: kind)
        // A bare tool-name title ("Edit file") must not overwrite a real path.
        if !title.isEmpty, !Self.isFallbackTitle(title) { result.title = title }
        if let command = update["rawInput"]?["command"]?.string { result.title = ToolTitles.unwrapShell(command) }
        // A path that only arrives with the update still names the row.
        if kind == .read || kind == .edit, result.title == nil,
           let path = update["locations"]?.array?.first?["path"]?.string {
            let relative = ToolTitles.relativePath(path, to: workingDirectory)
            if relative != workingDirectory { result.title = relative }
        }
        if let status = update["status"]?.string { result.status = Self.status(status) }
        let edits = diffs(update["content"])
        if !edits.isEmpty { result.edits = edits }
        var output = (update["content"]?.array ?? [])
            .compactMap { $0["type"]?.string == "content" ? $0["content"]?["text"]?.string : nil }
            .joined(separator: "\n")
        if let raw = update["rawOutput"], !raw.isNull {
            if output.isEmpty {
                output = [raw["stdout"]?.string, raw["stderr"]?.string, raw["output"]?.string]
                    .compactMap { $0 }
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n")
            }
            result.exitCode = raw["exitCode"]?.int ?? raw["metadata"]?["exit"]?.int
        }
        if !output.isEmpty, output != "(no output)" { result.output = output }
        if let exitCode = result.exitCode, exitCode != 0, result.status == .completed { result.status = .failed }
        return result
    }

    private static let pathKeys = ["filePath", "file_path", "path", "file", "notebook_path", "target_file", "targetFile"]

    private static func string(in value: JSONValue, keys: [String]) -> String? {
        for key in keys {
            if let text = value[key]?.string?.trimmed, !text.isEmpty { return text }
        }
        return nil
    }

    /// The title without the verb an agent prefixed it with, so the row reads
    /// "Browsed https://…" rather than "Browsed Fetched https://…". Verbs are
    /// only dropped when something remains; a bare tool name ("read", "glob")
    /// becomes empty so a path or pattern takes its place.
    /// Longest phrases first, so "searched the web for" wins over "searched for". Each
    /// carries its trailing space, matched as is against the lowercased title.
    private static let subjectPhrases = [
        "searched web for ", "search web for ", "searching web for ", "searched the web for ", "search the web for ",
        "searched for ", "searching for ", "search for ", "reading file ", "read file ", "listed directory ",
        "listing directory ", "list directory ", "listed files in ", "list files in ", "listing files in ",
    ]
    private static let subjectVerbs: Set<String> = [
        "read", "reading", "viewed", "viewing", "view", "fetched", "fetching", "fetch", "browsed", "browsing",
        "searched", "searching", "search", "grep", "glob", "listed", "listing", "list", "wrote", "writing",
        "write", "edited", "editing", "edit", "modified", "modifying", "modify", "updated", "updating", "update",
        "created", "creating", "create", "deleted", "deleting", "delete", "ran", "running", "run", "executed",
        "executing", "execute", "called", "calling", "call", "opened", "opening", "open",
    ]

    private static func subject(from title: String?, kind: ToolCall.Kind) -> String {
        var text = cleanTitle(title)
        guard !text.isEmpty else { return "" }
        if isBareToolName(text) { return "" }
        let phrases = subjectPhrases
        let verbs = subjectVerbs
        let lowered = text.lowercased()
        var stripped = false
        for phrase in phrases where [.read, .edit, .search, .web].contains(kind) && lowered.hasPrefix(phrase) {
            text = String(text.dropFirst(phrase.count))
            stripped = true
            break
        }
        let rowHasVerb = [.read, .edit, .search, .web].contains(kind)
        if !stripped, rowHasVerb, let head = lowered.split(separator: " ", maxSplits: 1).first, verbs.contains(String(head)) {
            let rest = text.dropFirst(head.count).trimmingCharacters(in: .whitespaces)
            if !rest.isEmpty { text = rest }
        }
        text = text.trimmed
        // "'devin'" / "“x”" → x
        for (open, close) in [("'", "'"), ("\"", "\""), ("“", "”"), ("`", "`")]
        where text.count >= 2 && text.hasPrefix(open) && text.hasSuffix(close) {
            text = String(text.dropFirst().dropLast())
        }
        return text
    }

    /// A title that is just the tool's identifier: one lowercase token like
    /// "read", "webfetch" or "todowrite".
    private static func isBareToolName(_ title: String) -> Bool {
        let bare: Set<String> = [
            "read", "write", "edit", "multiedit", "patch", "bash", "shell", "list", "ls", "glob", "grep", "search",
            "webfetch", "websearch", "fetch", "todowrite", "todoread", "task", "tool", "apply_patch", "read_file",
            "write_file", "edit_file", "list_files", "search_files", "run_command", "run_terminal_cmd", "web_search",
            "web_fetch", "codebase_search", "file_search", "grep_search", "list_dir", "view_file", "replace_file_content",
        ]
        return bare.contains(title.lowercased())
    }

    private func diffs(_ content: JSONValue?) -> [FileEdit] {
        (content?.array ?? []).compactMap { block -> FileEdit? in
            guard block["type"]?.string == "diff", let path = block["path"]?.string else { return nil }
            return FileEdit(
                path: ToolTitles.relativePath(path, to: workingDirectory),
                old: block["oldText"]?.string ?? "",
                new: block["newText"]?.string ?? ""
            )
        }
    }

    private static func cleanTitle(_ title: String?) -> String {
        (title ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "` \n"))
    }

    private static func kind(_ raw: String?) -> ToolCall.Kind {
        switch raw {
        case "read": .read
        case "edit", "delete", "move": .edit
        case "search": .search
        case "execute": .command
        case "fetch": .web
        default: .other
        }
    }

    private static func fallbackTitle(_ kind: ToolCall.Kind) -> String {
        switch kind {
        case .command: "Run command"
        case .read: "Read file"
        case .edit: "Edit file"
        case .search: "Search"
        case .web: "Fetch"
        case .mcp: "Tool"
        case .agent: "Agent"
        case .other: "Tool"
        }
    }

    /// True when a call's title is just the tool's display name — no subject.
    private static func isFallbackTitle(_ title: String) -> Bool {
        switch title.lowercased() {
        case "run command", "read file", "edit file", "write file", "search", "fetch", "tool", "agent", "file", "files":
            true
        default:
            isBareToolName(title)
        }
    }

    private static func status(_ raw: String) -> ToolCall.Status {
        switch raw {
        case "completed": .completed
        case "failed": .failed
        default: .running
        }
    }
}

extension SessionConfiguration {
    init(
        provider: ProviderKind,
        executable: URL,
        workingDirectory: URL,
        environment: [String: String],
        runtimeMode: RuntimeMode,
        interactionMode: InteractionMode
    ) {
        self.init(
            provider: provider,
            executable: executable,
            workingDirectory: workingDirectory,
            environment: environment,
            resumeID: nil,
            resumeAt: nil,
            model: nil,
            effort: nil,
            runtimeMode: runtimeMode,
            interactionMode: interactionMode
        )
    }
}
