import Foundation

/// Drives the bundled ZCode Protocol without starting the desktop UI.
@MainActor
final class ZCodeSession: ProviderSession {
    var onEvent: ((ProviderEvent) -> Void)?

    private enum PendingRequest {
        case permission(RPCID, [String: JSONValue])
        case question(RPCID, [QuestionRequest.Question])
    }

    private let configuration: SessionConfiguration
    private let providerID: String
    private var connection: JSONRPCConnection?
    private var sessionID: String?
    private var turnID: String?
    private var completedTurns: Set<String> = []
    private var activeModel: String?
    private var appliedMode: String?
    private var message: (id: String, text: String)?
    private var reasoning: (id: String, text: String)?
    /// Spend of the running turn, summed per model request, so a failed or stopped turn still reports it.
    private var turnUsage = (input: 0, output: 0, cached: 0)
    private var pendingRequests: [String: PendingRequest] = [:]
    /// Tool calls this session's own model made, so a subagent's forwarded calls can be told apart.
    private var startedTools: Set<String> = []
    private var isStopping = false
    private var closeTask: Task<Void, Never>?

    init(configuration: SessionConfiguration) {
        self.configuration = configuration
        providerID = ZCodeCLI.accountProviderID(ZaiRegion.current)
    }

    var isRunning: Bool { connection.map { !$0.isClosed } ?? false }
    private var workingDirectory: String { configuration.workingDirectory.path }

    func start() async throws -> String {
        guard let entry = configuration.executable,
              FileManager.default.fileExists(atPath: entry.path),
              let runtime = ZCodeCLI.runtime(entry: entry) else { throw ProviderError.notInstalled(.zcode) }
        guard let revision = ZCodeCLI.builtinRevision(entry: entry) else {
            throw ProviderError.failed(AppText.localized("ZCode's bundled provider configuration could not be read."))
        }
        let process = StdioProcess(
            executable: runtime, arguments: [entry.path, "app-server", "--stdio"],
            directory: configuration.workingDirectory,
            environment: ZCodeCLI.launchEnvironment(entry: entry, base: configuration.environment)
        )
        let connection = JSONRPCConnection(process: process, sendsVersion: false)
        self.connection = connection
        // Requests must be answered while create/resume/send are suspended awaiting a reply.
        connection.onRequest = { [weak self] id, method, params in self?.handleRequest(id, method, params) }
        connection.onNotification = { [weak self] method, params in self?.handleNotification(method, params) }
        connection.onClose = { [weak self] tail in self?.handleClose(tail) }
        var started = false
        defer {
            if !started {
                connection.onClose = nil
                connection.close()
                self.connection = nil
            }
        }
        try connection.start()
        let account = try await request("provider/updateAccountConfig", [
            "revision": "tivano-1", "basedOnZCodeBuiltinRevision": .string(revision),
            "providers": .object([providerID: ["access": ["type": "zhipu-account", "entitled": true]]]),
            "states": .object([providerID: ["availability": "available", "entitled": true, "current": true]]),
        ])
        guard account["status"]?.string == "received" else {
            throw ProviderError.failed(AppText.localized("ZCode did not accept the account configuration."))
        }
        let mode = Self.mode(configuration.runtimeMode, configuration.interactionMode)
        let result: JSONValue
        if let resumeID = configuration.resumeID {
            result = try await request("session/resume", ["sessionId": .string(resumeID)])
        } else {
            result = try await request("session/create", [
                "workspace": ["workspacePath": .string(workingDirectory), "workspaceKey": .string(workingDirectory)],
                "model": selection(model: configuration.model, effort: configuration.effort),
                "mode": .string(mode), "persistence": "deferred",
            ])
        }
        guard let id = result["session"]?["sessionId"]?.string,
              configuration.resumeID == nil || configuration.resumeID == id else {
            throw ProviderError.failed(AppText.localized("ZCode did not return the requested session."))
        }
        sessionID = id
        try await setMode(mode)
        _ = try await request("session/subscribe", ["sessionId": .string(id), "deliveryKind": "desktop-continuous"])
        started = true
        onEvent?(.sessionReady(sessionID: id))
        return id
    }

    func send(_ input: TurnInput) async throws {
        guard !isStopping, let sessionID else { throw ProviderError.notRunning }
        let mode = Self.mode(input.runtimeMode, input.interactionMode)
        if appliedMode != mode { try await setMode(mode) }
        let result = try await request("session/send", [
            "sessionId": .string(sessionID), "content": .string(input.text),
            "modelSelection": selection(model: input.model, effort: input.effort),
        ])
        guard result["accepted"]?.bool == true else {
            throw ProviderError.failed(AppText.localized("ZCode did not accept the message."))
        }
    }

    private func selection(model: String?, effort: String?) -> JSONValue {
        let chosen = model ?? configuration.model ?? configuration.modelCatalog.first?.id
            ?? configuration.executable.flatMap { ZCodeCLI.models(entry: $0, region: ZaiRegion.current).first?.id } ?? "GLM-5.3"
        activeModel = chosen
        let level = effort.flatMap { ZCodeCLI.efforts.contains($0) ? $0 : nil } ?? ZCodeCLI.defaultEffort
        return ["providerId": .string(providerID), "modelId": .string(chosen), "options": ["reasoningLevel": .string(level)]]
    }

    private static func mode(_ runtime: RuntimeMode, _ interaction: InteractionMode) -> String {
        if interaction == .plan { return "plan" }
        switch runtime {
        case .supervised: return "build"
        case .autoAcceptEdits: return "edit"
        case .auto: return "guarded"
        case .fullAccess: return "yolo"
        }
    }

    private func setMode(_ mode: String) async throws {
        guard let sessionID else { throw ProviderError.notRunning }
        _ = try await request("session/setMode", ["sessionId": .string(sessionID), "mode": .string(mode)])
        appliedMode = mode
    }

    private func request(_ method: String, _ params: JSONValue, seconds: Int = 90) async throws -> JSONValue {
        guard let connection, !connection.isClosed else { throw ProviderError.notRunning }
        return try await withDeadline(seconds: seconds, provider: "ZCode", operation: method) {
            try await connection.request(method, params)
        }
    }

    func interrupt() async {
        guard let sessionID else { return }
        _ = try? await request("session/stop", ["sessionId": .string(sessionID)], seconds: 10)
    }

    func compact() async throws {
        guard let sessionID else { throw ProviderError.notRunning }
        _ = try await request("session/compact", ["sessionId": .string(sessionID)], seconds: 120)
    }

    func stop() {
        guard !isStopping else { return }
        isStopping = true
        let connection = connection
        let sessionID = sessionID
        closeTask = Task {
            if let connection, !connection.isClosed, let sessionID {
                _ = try? await withDeadline(seconds: 2, provider: "ZCode", operation: "session/close") {
                    try await connection.request("session/close", ["sessionId": .string(sessionID)])
                }
            }
            connection?.close()
        }
    }

    func stopAndWait(timeout: TimeInterval) async {
        stop()
        await closeTask?.value
        await connection?.closeAndWait(timeout: timeout)
    }

    private func handleRequest(_ id: RPCID, _ method: String, _ params: JSONValue) {
        switch method {
        case "session/requestRuntimePreferences":
            connection?.respond(to: id, result: ZCodeCLI.runtimePreferences())
        case "interaction/requestProviderRuntimeHeaders":
            if let key = configuration.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
                connection?.respond(to: id, result: ["headersApplied": true, "requestAuth": ["apiKey": .string(key)]])
            } else {
                connection?.respond(to: id, result: ["headersApplied": false, "errorMessage": .string(AppText.localized("ZCode needs your GLM Coding Plan key. Add it in Settings → Providers → Z.ai."))])
            }
        case "interaction/requestPermission":
            let name = params["toolName"]?.string ?? AppText.localized("Tool")
            var payloads: [String: JSONValue] = [:]
            let options = (params["options"]?.array ?? []).compactMap { option -> ApprovalRequest.Option? in
                guard let optionID = option["optionId"]?.string, let response = option["response"] else { return nil }
                payloads[optionID] = response
                let role: ApprovalRequest.Option.Role = option["kind"]?.string == "allow_once" ? .approve : .decline
                return .init(id: optionID, title: option["name"]?.string ?? optionID, role: role)
            }
            pendingRequests[id.key] = .permission(id, payloads)
            let kind: ApprovalRequest.Kind = name == "Bash" ? .command
                : (["Write", "Edit", "MultiEdit", "NotebookEdit"].contains(name) ? .fileChange : .tool)
            let input = params["input"]
            let title = input?["command"]?.string ?? input?["file_path"]?.string.map { ToolTitles.relativePath($0, to: workingDirectory) } ?? name
            onEvent?(.approval(ApprovalRequest(id: id.key, kind: kind, title: title, detail: nil,
                reason: params["reason"]?.string, options: options, toolItemID: params["toolCallId"]?.string)))
        case "interaction/requestUserInput":
            var questions = (params["questions"]?.array ?? []).enumerated().compactMap { index, value -> QuestionRequest.Question? in
                guard let prompt = value["question"]?.string else { return nil }
                return .init(id: String(index), header: value["header"]?.string ?? "", prompt: prompt,
                    choices: (value["options"]?.array ?? []).compactMap { option in
                        guard let label = option["label"]?.string else { return nil }
                        return .init(label: label, detail: option["description"]?.string)
                    }, allowsMultiple: value["multiSelect"]?.bool ?? false, allowsOther: true, isSecret: false)
            }
            if questions.isEmpty, let prompt = params["prompt"]?.string {
                questions = [.init(id: "0", header: "", prompt: prompt, choices: [], allowsMultiple: false, allowsOther: true, isSecret: false)]
            }
            guard !questions.isEmpty else {
                connection?.respond(to: id, result: ["action": "decline"])
                return
            }
            pendingRequests[id.key] = .question(id, questions)
            onEvent?(.question(QuestionRequest(id: id.key, questions: questions)))
        default:
            connection?.respond(to: id, errorCode: -32601, message: "Method not found")
        }
    }

    func resolveApproval(_ requestID: String, optionID: String) {
        resolveApproval(requestID, optionID: optionID, delivered: { _ in })
    }

    func resolveApproval(_ requestID: String, optionID: String, delivered: @escaping @MainActor (Bool) -> Void) {
        guard case .permission(let id, let options)? = pendingRequests[requestID], let result = options[optionID] else {
            delivered(false)
            return
        }
        respond(id, requestID: requestID, result: result, delivered: delivered)
    }

    func answerQuestion(_ requestID: String, answers: [String: [String]]) {
        answerQuestion(requestID, answers: answers, delivered: { _ in })
    }

    func answerQuestion(_ requestID: String, answers: [String: [String]], delivered: @escaping @MainActor (Bool) -> Void) {
        guard case .question(let id, let questions)? = pendingRequests[requestID] else { delivered(false); return }
        var content: [String: JSONValue] = [:]
        for question in questions {
            let values = (answers[question.id] ?? []).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            if !values.isEmpty { content[question.prompt] = .string(values.joined(separator: ", ")) }
        }
        let result: JSONValue = content.isEmpty ? ["action": "decline"] : ["action": "accept", "content": ["answers": .object(content)]]
        respond(id, requestID: requestID, result: result, delivered: delivered)
    }

    private func respond(_ id: RPCID, requestID: String, result: JSONValue, delivered: @escaping @MainActor (Bool) -> Void) {
        guard !isStopping, let connection, !connection.isClosed else { delivered(false); return }
        connection.respond(to: id, result: result) { [weak self] succeeded in
            if succeeded, let self, self.pendingRequests.removeValue(forKey: requestID) != nil {
                self.onEvent?(.requestResolved(id: requestID))
            }
            delivered(succeeded)
        }
    }

    private func handleNotification(_ method: String, _ params: JSONValue) {
        if let id = params["sessionId"]?.string, let sessionID, id != sessionID { return }
        if method == "v4/telemetry/event" {
            guard params["kind"]?.string == "turn.terminal", let id = params["turnId"]?.string,
                  id == turnID, let status = params["status"]?.string, status != "success" else { return }
            finishTurn(id, status: ["cancelled", "interrupted"].contains(status) ? .interrupted : .failed,
                error: params["errorMessage"]?.string)
            return
        }
        guard method == "session/event" else { return }
        let payload = params["payload"] ?? .null
        let type = params["type"]?.string
        let id = params["turnId"]?.string
        if type == "session.titleUpdated" {
            if payload["source"]?.string == "generated", let title = payload["title"]?.string { onEvent?(.title(title)) }
            return
        }
        if type == "turn.started", let id, !completedTurns.contains(id), turnID != id {
            turnID = id
            turnUsage = (0, 0, 0)
            onEvent?(.turnStarted(providerTurnID: id))
        }
        if let id, completedTurns.contains(id) { return }
        if let id, let turnID, id != turnID { return }
        if let error = payload["error"], error.object != nil, let id, id == turnID {
            finishTurn(id, status: .failed, error: error["message"]?.string ?? AppText.localized("ZCode reported an error."))
            return
        }
        switch type {
        case "model.streaming": handleStreaming(payload)
        case "tool.updated": handleToolResult(payload)
        case "session.updated":
            guard payload["hookEventName"] == nil, payload["querySource"]?.string == "main_turn",
                  let usage = payload["usage"], let input = usage["inputTokens"]?.int,
                  let output = usage["outputTokens"]?.int else { return }
            turnUsage.input += input
            turnUsage.output += output
            turnUsage.cached += usage["cacheReadTokens"]?.int ?? 0
            onEvent?(.usage(ContextUsage(usedTokens: input + output, windowTokens: payload["contextWindow"]?.int)))
        case "turn.completed":
            guard let id, id == turnID else { return }
            finishMessage()
            finishReasoning()
            // The turn's own total is authoritative over the per-request sum.
            if let usage = payload["usage"], let input = usage["inputTokens"]?.int, let output = usage["outputTokens"]?.int {
                turnUsage = (input, output, usage["cacheReadTokens"]?.int ?? 0)
            }
            finishTurn(id, status: .completed, error: nil)
        default: break
        }
    }

    private func handleStreaming(_ payload: JSONValue) {
        switch payload["kind"]?.string {
        case "text_delta", "reasoning_delta":
            guard let id = payload["assistantMessageId"]?.string, let delta = payload["delta"]?.string else { return }
            if message?.id != nil && message?.id != id { finishMessage() }
            if reasoning?.id != nil && reasoning?.id != id { finishReasoning() }
            if payload["kind"]?.string == "text_delta" {
                if message == nil { message = (id, "") }
                message?.text += delta
                onEvent?(.messageDelta(id: id, text: delta))
            } else {
                if reasoning == nil { reasoning = (id, "") }
                reasoning?.text += delta
                onEvent?(.reasoningDelta(id: id + ":reasoning", text: delta))
            }
        case "tool_call":
            guard let id = payload["toolCallId"]?.string else { return }
            let name = payload["toolName"]?.string ?? AppText.localized("Tool")
            let input = payload["input"] ?? .null
            let path = input["file_path"]?.string.map { ToolTitles.relativePath($0, to: workingDirectory) }
            let call: ToolCall
            switch name {
            case "Bash": call = ToolCall(kind: .command, title: input["command"]?.string.map(ToolTitles.unwrapShell) ?? name)
            case "Write", "Edit", "MultiEdit", "NotebookEdit": call = ToolCall(kind: .edit, title: path ?? name)
            case "Read": call = ToolCall(kind: .read, title: path ?? name)
            case "Grep", "Glob": call = ToolCall(kind: .search, title: input["pattern"]?.string ?? name, detail: path)
            case "Agent", "Task": call = ToolCall(kind: .agent, title: input["description"]?.string ?? "Subagent", detail: input["subagent_type"]?.string)
            default: call = ToolCall(kind: .other, title: name, detail: input.isNull ? nil : input.compactString)
            }
            startedTools.insert(id)
            onEvent?(.toolStarted(id: id, call: call))
        default: break
        }
    }

    private func handleToolResult(_ payload: JSONValue) {
        guard payload["kind"]?.string == "result", let id = payload["toolCallId"]?.string,
              let result = payload["result"] else { return }
        // ZCode forwards each subagent tool result into the parent session; the subagent's work
        // shows on its Agent row, not as untitled rows between the lead's paragraphs.
        if payload["source"]?.string == "subagent", !startedTools.contains(id) { return }
        var update = ToolUpdate(output: ToolText.blocks(result["content"]), status: result["success"]?.bool == true ? .completed : .failed)
        if let display = result["display"], display["kind"]?.string == "file_diff",
           let path = display["filePath"]?.string, let hunks = display["structuredPatch"]?.array {
            let lines = hunks.flatMap { $0["lines"]?.array?.compactMap(\.string) ?? [] }
            if !lines.isEmpty {
                update.edits = [FileEdit(path: ToolTitles.relativePath(path, to: workingDirectory), diff: lines.joined(separator: "\n"),
                    additions: lines.filter { $0.hasPrefix("+") }.count, deletions: lines.filter { $0.hasPrefix("-") }.count)]
            }
        }
        onEvent?(.toolUpdated(id: id, update: update))
    }

    private func finishMessage() {
        guard let message else { return }
        self.message = nil
        onEvent?(.messageCompleted(id: message.id, text: message.text))
    }

    private func finishReasoning() {
        guard let reasoning else { return }
        self.reasoning = nil
        onEvent?(.reasoningCompleted(id: reasoning.id + ":reasoning", text: reasoning.text))
    }

    private func finishTurn(_ id: String, status: TurnStatus, error: String?) {
        guard completedTurns.insert(id).inserted else { return }
        finishMessage()
        finishReasoning()
        if turnID == id { turnID = nil }
        if turnUsage.input + turnUsage.output > 0 {
            onEvent?(.tokenSpend(TokenSpend(provider: .zcode, totalTokens: turnUsage.input + turnUsage.output, inputTokens: turnUsage.input,
                outputTokens: turnUsage.output, cachedInputTokens: turnUsage.cached, model: activeModel)))
        }
        turnUsage = (0, 0, 0)
        resolvePendingRequests()
        onEvent?(.turnCompleted(status: status, error: error))
    }

    private func resolvePendingRequests() {
        let ids = Array(pendingRequests.keys)
        pendingRequests.removeAll()
        for id in ids { onEvent?(.requestResolved(id: id)) }
    }

    private func handleClose(_ tail: String) {
        if let turnID {
            finishTurn(turnID, status: isStopping ? .interrupted : .failed,
                error: isStopping ? nil : (tail.isEmpty ? AppText.localized("The agent process exited.") : TextCleanup.lastLines(tail)))
        }
        resolvePendingRequests()
        if !isStopping { onEvent?(.exited(error: TextCleanup.lastLines(tail))) }
    }
}
