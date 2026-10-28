import Foundation

/// Drives Claude Code in headless stream-json mode, routing permission prompts to the app.
///
/// With Hydra on, the session appends the lead's delegation-block policy to the system prompt
/// and launches with `--disallowedTools Agent Task`: every head is a thread Tivano
/// runs, never a sub-agent of this session. Messages that still carry a
/// `parent_tool_use_id` keep their own block bookkeeping and go out wrapped in `agentEvent`.
@MainActor
final class ClaudeSession: ProviderSession {
    var onEvent: ((ProviderEvent) -> Void)?

    private struct PendingTool {
        var name: String
        var input: JSONValue
        var suggestions: JSONValue?
    }

    /// The open blocks of one streamed transcript: the lead's, or one head's.
    private struct StreamState {
        var currentMessageID: String?
        var blockIDs: [Int: String] = [:]
        var openText: [String: [String]] = [:]
        var openThinking: [String: [String]] = [:]
    }

    private let configuration: SessionConfiguration
    private var process: StdioProcess?
    private var readTask: Task<Void, Never>?
    private var sessionID: String?
    private var permissionMode: String
    private var permissionModeIsConfirmed = true
    private var runtimeMode: RuntimeMode
    private var model: String?
    private var controlCounter = 0
    private var pendingControl = PendingReplies<JSONValue>()
    private var pendingTools: [String: PendingTool] = [:]
    private var toolNames: [String: String] = [:]
    private var mainStream = StreamState()
    /// Each head's stream, by the tool call that spawned it.
    private var agentStreams: [String: StreamState] = [:]
    /// Heads by their task id, for progress and completion, and their task ids by head, for stopping.
    private var agentsByTask: [String: String] = [:]
    private var tasksByAgent: [String: String] = [:]
    private var backgroundTasks: [(id: String, description: String)] = []
    private var turnActive = false
    private var preparationID: UUID?
    private var contextRevision = 0
    private var interruptRequested = false
    private var isStopping = false
    /// Set once the CLI has answered the initialize. Before that, a result or an exit is
    /// the launch's failure, reported by `start()` throwing, never a turn's end.
    private var isStarted = false
    private var hasClosed = false
    /// What the CLI said as it failed to launch: the `errors` of a result that came
    /// before the initialize was answered, or the last of its stderr.
    private var launchError: String?
    private static var knownOptions: [String: Set<String>] = [:]

    init(configuration: SessionConfiguration) {
        self.configuration = configuration
        runtimeMode = configuration.runtimeMode
        permissionMode = Self.modeName(configuration.runtimeMode, configuration.interactionMode)
        model = configuration.model
    }

    var isRunning: Bool { !isStopping && (process?.isRunning ?? false) }

    private var workingDirectory: String { configuration.workingDirectory.path }

    /// The newer CLI options are only passed when `--help` lists them, so an older
    /// Claude Code that does not know them yet still launches. Read once per executable;
    /// a probe that fails is not remembered, so the next launch asks again.
    private static func knownOptions(of executable: URL, environment: [String: String]) async -> Set<String> {
        if let cached = knownOptions[executable.path] { return cached }
        guard let result = try? await Shell.run(executable, ["--help"], environment: environment, timeout: 20) else { return [] }
        let help = TextCleanup.stripANSI(result.output + result.errorOutput)
        let found = ["--system-prompt-snapshot"].filter { help.contains($0) }
        let options = Set(found)
        knownOptions[executable.path] = options
        return options
    }

    func start() async throws -> String {
        guard let executable = configuration.executable else { throw ProviderError.notInstalled(configuration.provider) }
        let id = configuration.resumeID ?? UUID().uuidString.lowercased()
        var arguments = [
            "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
            "--include-partial-messages", "--permission-prompt-tool", "stdio",
            "--setting-sources", "user,project,local",
            "--allow-dangerously-skip-permissions", "--permission-mode", permissionMode,
        ]
        if let model = configuration.model, model != "default" { arguments += ["--model", model] }
        if let effort = configuration.effort, !effort.isEmpty { arguments += ["--effort", effort] }
        if configuration.fastMode { arguments += ["--settings", #"{"fastMode":true}"#] }
        // Connected servers from Settings are the only MCP servers the session sees.
        // --strict-mcp-config leaves the user's own Claude config files alone but out of this session; with none connected, the flag is not passed and Claude reads its own config as usual.
        if let mcpConfig = MCPProviderConfig.claudeConfigPath() { arguments += ["--mcp-config", mcpConfig, "--strict-mcp-config"] }
        let environment = configuration.environment
        let options = await Self.knownOptions(of: executable, environment: environment)
        // Resumed chats must use the current setting, even with Hydra off.
        if options.contains("--system-prompt-snapshot") { arguments += ["--system-prompt-snapshot", "off"] }
        var hydraPolicy: String?
        if let hydra = configuration.hydra {
            // The system prompt is rendered fresh rather than replayed from the
            // conversation's first request, so switching Hydra on for an existing chat
            // reaches the model. The heads are threads Tivano starts: the lead asks
            // for them with the delegation block, and its own agent tool goes, since a
            // head it spawned itself would run inside this session instead of the app.
            hydraPolicy = HydraPrompts.fallbackPolicy(hydra)
            arguments += ["--disallowedTools", "Agent", "Task"]
        }
        // Exactly one combined system prompt segment for every session, Hydra or not. The
        // off notice goes out too, so a resumed thread cannot keep earlier guidance alive.
        arguments += [
            "--append-system-prompt",
            [hydraPolicy, AntiSlopPolicy.instructions(enabled: configuration.antiSlopEnabled)]
                .compactMap { $0 }
                .joined(separator: "\n\n"),
        ]
        if let resumeID = configuration.resumeID {
            arguments += ["--resume", resumeID]
            if let anchor = configuration.resumeAt { arguments += ["--resume-session-at", anchor] }
        } else {
            arguments += ["--session-id", id]
        }

        let process = StdioProcess(
            executable: executable,
            arguments: arguments,
            directory: configuration.workingDirectory,
            environment: environment
        )
        self.process = process
        try process.start()
        let messages = process.messages
        readTask = Task { [weak self] in
            for await message in messages {
                guard let self else { return }
                await self.handle(message)
            }
            self?.didClose()
        }

        sessionID = id
        let initialize: [String: JSONValue] = ["subtype": "initialize", "hooks": .null]
        let initialization = try await control(.object(initialize))
        isStarted = true
        let models = Self.models(in: initialization)
        if !models.isEmpty { onEvent?(.models(models, current: configuration.model)) }
        let commands = SlashCommand.claudeCommands(initialization["commands"]?.array ?? [])
        if !commands.isEmpty { onEvent?(.commands(commands)) }
        invalidateContextUsage()
        refreshContextUsage()
        return id
    }

    private static func models(in initialization: JSONValue) -> [ModelOption] {
        (initialization["models"]?.array ?? []).compactMap { entry -> ModelOption? in
            guard let value = entry["value"]?.string else { return nil }
            return ModelOption(
                id: value,
                name: entry["displayName"]?.string ?? value,
                detail: entry["description"]?.string,
                efforts: (entry["supportedEffortLevels"]?.array ?? []).compactMap(\.string),
                isDefault: value == "default",
                fastTier: entry["supportsFastMode"]?.bool == true ? "fast" : nil
            )
        }
    }

    /// What the CLI reports in its handshake: its models, and the slash commands it finds
    /// for `directory`. A bare process, not a session: it gets the initialize and nothing else.
    static func handshake(executable: URL, directory: URL, environment: [String: String]) async throws -> (models: [ModelOption], commands: [SlashCommand]) {
        let process = StdioProcess(
            executable: executable,
            arguments: ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose", "--no-session-persistence", "--setting-sources", "user,project,local"],
            directory: directory,
            environment: environment
        )
        try process.start()
        let watchdog = Task {
            try? await Task.sleep(for: .seconds(20))
            if !Task.isCancelled { process.terminate() }
        }
        defer { watchdog.cancel(); process.terminate() }
        process.send(["type": "control_request", "request_id": "handshake", "request": ["subtype": "initialize", "hooks": .null]])
        return try await withTaskCancellationHandler {
            for await message in process.messages {
                guard message["type"]?.string == "control_response",
                      message["response"]?["request_id"]?.string == "handshake" else { continue }
                guard let response = message["response"]?["response"], let commands = response["commands"]?.array else {
                    throw ProviderError.failed("Claude could not load its commands.")
                }
                return (models(in: response), SlashCommand.claudeCommands(commands))
            }
            throw ProviderError.failed("Claude's command discovery did not finish. Try again.")
        } onCancel: {
            process.terminate()
        }
    }

    func send(_ input: TurnInput) async throws {
        guard isRunning, !turnActive, preparationID == nil else { throw ProviderError.notRunning }
        let preparation = UUID()
        preparationID = preparation
        defer { if preparationID == preparation { preparationID = nil } }
        do {
            guard continuePreparation(preparation) else { return }
            let mode = Self.modeName(input.runtimeMode, input.interactionMode)
            if mode != permissionMode || !permissionModeIsConfirmed {
                permissionModeIsConfirmed = false
                _ = try await control(["subtype": "set_permission_mode", "mode": .string(mode)])
                guard continuePreparation(preparation) else { return }
                permissionMode = mode
                permissionModeIsConfirmed = true
            }
            runtimeMode = input.runtimeMode
            if input.model != model {
                let wire = input.model == "default" ? nil : input.model
                _ = try? await control(["subtype": "set_model", "model": .optional(wire)])
                guard continuePreparation(preparation) else { return }
                model = input.model
            }
            let images = await Attachment.base64Images(input.images)
            guard continuePreparation(preparation) else { return }
            var content: [JSONValue] = images.map { image, base64 in
                ["type": "image", "source": ["type": "base64", "media_type": .string(image.mimeType), "data": .string(base64)]]
            }
            content.append(["type": "text", "text": .string(input.text)])
            preparationID = nil
            writeUserMessage(.array(content))
        } catch {
            guard continuePreparation(preparation) else { return }
            throw error
        }
    }

    private func continuePreparation(_ id: UUID) -> Bool {
        guard preparationID == id, !isStopping else { return false }
        if Task.isCancelled {
            stop()
            onEvent?(.turnCompleted(status: .interrupted, error: nil))
            return false
        }
        return isRunning
    }

    func interrupt() async {
        if preparationID != nil {
            stop()
            onEvent?(.turnCompleted(status: .interrupted, error: nil))
            return
        }
        guard turnActive else { return }
        interruptRequested = true
        for requestID in pendingTools.keys {
            sendToolResponse(requestID, ["behavior": "deny", "message": "The user stopped the turn.", "interrupt": true])
            onEvent?(.requestResolved(id: requestID))
        }
        pendingTools.removeAll()
        _ = try? await control(["subtype": "interrupt"])
    }

    func compact() async throws {
        guard let process, process.isRunning else { throw ProviderError.notRunning }
        writeUserMessage("/compact")
    }

    func resolveApproval(_ requestID: String, optionID: String) {
        resolveApproval(requestID, optionID: optionID, delivered: { _ in })
    }

    func resolveApproval(_ requestID: String, optionID: String, delivered: @escaping @MainActor (Bool) -> Void) {
        guard !hasClosed, !isStopping, let pending = pendingTools[requestID] else { delivered(false); return }
        let allowed = optionID == "allow" || optionID == "always"
        let response: JSONValue
        if allowed {
            var payload: [String: JSONValue] = ["behavior": "allow", "updatedInput": pending.input]
            if optionID == "always", let suggestions = pending.suggestions?.array {
                payload["updatedPermissions"] = .array(suggestions.map(Self.sessionScoped))
            }
            response = .object(payload)
        } else {
            let message = pending.name == "ExitPlanMode"
                ? "The user wants to keep planning. Wait for their feedback before changing anything."
                : "The user declined this action."
            response = ["behavior": "deny", "message": .string(message)]
        }
        sendToolResponse(requestID, response) { [weak self] succeeded in
            if succeeded, let self {
                if self.pendingTools.removeValue(forKey: requestID) != nil {
                    self.onEvent?(.requestResolved(id: requestID))
                }
                if allowed, pending.name == "ExitPlanMode", !self.hasClosed, !self.isStopping {
                    let mode = Self.modeName(self.runtimeMode, .build)
                    Task {
                        guard !self.hasClosed, !self.isStopping else { return }
                        do {
                            self.permissionModeIsConfirmed = false
                            _ = try await self.control(["subtype": "set_permission_mode", "mode": .string(mode)])
                            guard !self.hasClosed, !self.isStopping else { return }
                            self.permissionMode = mode
                            self.permissionModeIsConfirmed = true
                            self.onEvent?(.modeChanged(.build))
                        } catch {
                            guard !self.hasClosed, !self.isStopping else { return }
                            self.stop()
                            self.onEvent?(.exited(error: error.localizedDescription))
                        }
                    }
                }
            }
            delivered(succeeded)
        }
    }

    func answerQuestion(_ requestID: String, answers: [String: [String]]) {
        answerQuestion(requestID, answers: answers, delivered: { _ in })
    }

    func answerQuestion(_ requestID: String, answers: [String: [String]], delivered: @escaping @MainActor (Bool) -> Void) {
        guard !hasClosed, !isStopping, let pending = pendingTools[requestID] else { delivered(false); return }
        var input = pending.input.object ?? [:]
        var mapped: [String: JSONValue] = [:]
        for (question, values) in answers {
            mapped[question] = .string(values.joined(separator: ", "))
        }
        input["answers"] = .object(mapped)
        sendToolResponse(requestID, ["behavior": "allow", "updatedInput": .object(input)]) { [weak self] succeeded in
            if succeeded, let self, self.pendingTools.removeValue(forKey: requestID) != nil {
                self.onEvent?(.requestResolved(id: requestID))
            }
            delivered(succeeded)
        }
    }

    func stopAndWait(timeout: TimeInterval) async {
        let process = process
        stop()
        await process?.terminateAndWait(timeout: timeout)
    }

    func stop() {
        preparationID = nil
        isStopping = true
        clearBackgroundTasks()
        process?.terminate()
    }

    func stopAgent(_ id: String) async -> Bool {
        guard let taskID = tasksByAgent[id] else { return false }
        return (try? await control(["subtype": "stop_task", "task_id": .string(taskID)])) != nil
    }

    // MARK: - Wire

    private func control(_ request: JSONValue) async throws -> JSONValue {
        guard let process else { throw ProviderError.notRunning }
        if hasClosed { throw ProviderError.failed(launchError ?? "Claude exited.") }
        controlCounter += 1
        let requestID = "tivano-\(controlCounter)"
        return try await pendingControl.register(requestID, timeout: .seconds(request["subtype"]?.string == "interrupt" ? 10 : 30)) {
            process.send(["type": "control_request", "request_id": .string(requestID), "request": request])
        }
    }

    private func invalidateContextUsage() {
        contextRevision += 1
        onEvent?(.contextUsageCleared)
    }

    /// Official Agent SDK get_context_usage control request, not result.usage (turn spend).
    /// https://github.com/anthropics/claude-agent-sdk-python/blob/main/src/claude_agent_sdk/_internal/query.py
    private func refreshContextUsage() {
        let revision = contextRevision
        Task { [weak self] in
            guard let self, self.isRunning, !self.isStopping, !self.turnActive,
                  self.contextRevision == revision else { return }
            guard let report = try? await self.control(["subtype": "get_context_usage"]),
                  self.contextRevision == revision, !self.turnActive,
                  !self.hasClosed, !self.isStopping,
                  let usage = Self.contextUsage(report) else { return }
            self.onEvent?(.usage(usage))
        }
    }

    private func writeUserMessage(_ content: JSONValue) {
        guard isRunning else { return }
        invalidateContextUsage()
        turnActive = true
        interruptRequested = false
        onEvent?(.turnStarted(providerTurnID: nil))
        process?.send([
            "type": "user",
            "session_id": "",
            "message": ["role": "user", "content": content],
            "parent_tool_use_id": .null,
        ])
    }

    private func sendToolResponse(_ requestID: String, _ response: JSONValue, completion: (@MainActor (Bool) -> Void)? = nil) {
        guard !hasClosed, !isStopping, let process else { completion?(false); return }
        process.send([
            "type": "control_response",
            "response": ["subtype": "success", "request_id": .string(requestID), "response": response],
        ]) { [weak self] succeeded in
            Task { @MainActor [weak self] in
                if !succeeded { self?.didClose() }
                completion?(succeeded)
            }
        }
    }

    private func handle(_ message: JSONValue) async {
        // A head's message names the tool call that spawned it; the lead's carries null.
        let parent = message["parent_tool_use_id"]?.string
        let type = message["type"]?.string
        if parent == nil, type == "stream_event" || type == "assistant", isStarted, !turnActive {
            // Claude Code answers a finished background task's notification with a turn of its own, without a send from the app.
            invalidateContextUsage()
            turnActive = true
            interruptRequested = false
            onEvent?(.turnStarted(providerTurnID: nil))
        }
        switch type {
        case "control_response":
            let response = message["response"] ?? .null
            guard let requestID = response["request_id"]?.string else { return }
            switch response["subtype"]?.string {
            case "success":
                pendingControl.resolve(requestID, response["response"] ?? .null)
            case "error":
                pendingControl.fail(requestID, ProviderError.failed(response["error"]?.string ?? "Claude rejected the request."))
            default:
                pendingControl.fail(requestID, ProviderError.failed("Claude rejected the request."))
            }
        case "control_request":
            handleControlRequest(message)
        case "control_cancel_request":
            if let requestID = message["request_id"]?.string, pendingTools.removeValue(forKey: requestID) != nil {
                onEvent?(.requestResolved(id: requestID))
            }
        case "system":
            handleSystem(message)
        case "stream_event":
            if let parent {
                // The sink hands the event on at once, and what it reaches can come back
                // into this session and read the same heads. The state is taken out,
                // worked on and put back, so nothing is held open across the callbacks.
                var stream = agentStreams[parent] ?? StreamState()
                handleStreamEvent(message["event"] ?? .null, stream: &stream, sink: agentSink(parent))
                agentStreams[parent] = stream
            } else {
                handleStreamEvent(message["event"] ?? .null, stream: &mainStream, sink: leadSink)
            }
        case "assistant":
            if let parent {
                var stream = agentStreams[parent] ?? StreamState()
                handleAssistant(message, stream: &stream, sink: agentSink(parent))
                agentStreams[parent] = stream
            } else {
                handleAssistant(message, stream: &mainStream, sink: leadSink)
            }
        case "user":
            await handleToolResults(message, sink: parent.map(agentSink) ?? leadSink)
        case "result":
            handleResult(message)
        case "rate_limit_event":
            let info = message["rate_limit_info"] ?? .null
            if info["status"]?.string == "rejected" {
                let resetsAt = (info["resetsAt"]?.double ?? info["resetsAtSeconds"]?.double).map { Date(timeIntervalSince1970: $0) }
                let when = resetsAt.map { " It resets at \(UsageLimitSignal.format($0))." } ?? ""
                onEvent?(.notice(Notice(level: .warning, message: "Claude hit a usage limit.\(when)")))
                onEvent?(.usageLimit(resetsAt: resetsAt))
            }
        default:
            break
        }
    }

    private func handleSystem(_ message: JSONValue) {
        switch message["subtype"]?.string {
        case "init":
            if let id = message["session_id"]?.string, id != sessionID {
                sessionID = id
                onEvent?(.sessionReady(sessionID: id))
            }
        case "compact_boundary":
            invalidateContextUsage()
            onEvent?(.notice(Notice(level: .info, message: "Context compacted.")))
        case "task_started":
            handleTaskStarted(message)
        case "task_progress":
            guard let taskID = message["task_id"]?.string, let agentID = agentsByTask[taskID] else { return }
            let usage = message["usage"]
            // The head's own running total, for its panel. It is not added to the
            // ledger: this total and the turn result's usage are two accounts of
            // overlapping work, and the CLI does not say how much of the head's
            // work the result already covers, so counting both would charge it twice.
            onEvent?(.agentProgress(
                agentID: agentID,
                summary: message["summary"]?.string,
                lastTool: message["last_tool_name"]?.string,
                tokens: usage?["total_tokens"]?.int,
                toolCalls: usage?["tool_uses"]?.int
            ))
        case "task_notification":
            guard let taskID = message["task_id"]?.string else { return }
            if backgroundTasks.contains(where: { $0.id == taskID }) {
                backgroundTasks.removeAll { $0.id == taskID }
                onEvent?(.backgroundTasks(backgroundTasks.map(\.description)))
                return
            }
            guard let agentID = agentsByTask[taskID] else { return }
            let status: TurnStatus = switch message["status"]?.string {
            case "failed": .failed
            case "stopped": .interrupted
            default: .completed
            }
            agentStreams[agentID] = nil
            onEvent?(.agentFinished(agentID: agentID, status: status, summary: message["summary"]?.string))
        default:
            break
        }
    }

    /// A subagent task: the head it stands for is keyed by the spawning tool call, which
    /// its transcript messages carry. Background shell commands are tasks too and pass.
    private func handleTaskStarted(_ message: JSONValue) {
        guard let taskID = message["task_id"]?.string, message["skip_transcript"]?.bool != true else { return }
        let isAgent = message["subagent_type"]?.string != nil || message["task_type"]?.string == "local_agent"
        guard isAgent else {
            backgroundTasks.append((taskID, message["description"]?.string ?? "a background command"))
            onEvent?(.backgroundTasks(backgroundTasks.map(\.description)))
            return
        }
        let toolUseID = message["tool_use_id"]?.string
        let agentID = toolUseID ?? taskID
        agentsByTask[taskID] = agentID
        tasksByAgent[agentID] = taskID
        onEvent?(.agentStarted(AgentSpawn(
            id: agentID,
            taskID: taskID,
            toolUseID: toolUseID,
            description: message["description"]?.string ?? "Subagent",
            prompt: message["prompt"]?.string,
            model: nil,
            isBackground: message["is_backgrounded"]?.bool ?? false
        )))
    }

    /// Where a stream's events go: straight out for the lead, wrapped for a head. The
    /// lead's is made once, not once per message.
    private lazy var leadSink: (ProviderEvent) -> Void = { [weak self] event in self?.onEvent?(event) }

    private func agentSink(_ agentID: String) -> (ProviderEvent) -> Void {
        { [weak self] event in self?.onEvent?(.agentEvent(agentID: agentID, event)) }
    }

    private func handleStreamEvent(_ event: JSONValue, stream: inout StreamState, sink: (ProviderEvent) -> Void) {
        switch event["type"]?.string {
        case "message_start":
            stream.currentMessageID = event["message"]?["id"]?.string ?? UUID().uuidString
            stream.blockIDs.removeAll()
        case "content_block_start":
            guard let index = event["index"]?.int, let block = event["content_block"] else { return }
            let messageID = stream.currentMessageID ?? "message"
            let id = "\(messageID)-\(index)"
            switch block["type"]?.string {
            case "text":
                stream.blockIDs[index] = id
                stream.openText[messageID, default: []].append(id)
                sink(.messageDelta(id: id, text: block["text"]?.string ?? ""))
            case "thinking":
                stream.blockIDs[index] = id
                stream.openThinking[messageID, default: []].append(id)
                sink(.reasoningDelta(id: id, text: block["thinking"]?.string ?? ""))
            case "tool_use":
                guard let toolID = block["id"]?.string, let name = block["name"]?.string else { return }
                toolNames[toolID] = name
                if let call = toolCall(name: name, input: [:]) {
                    sink(.toolStarted(id: toolID, call: call))
                }
            default:
                break
            }
        case "content_block_delta":
            guard let index = event["index"]?.int, let id = stream.blockIDs[index], let delta = event["delta"] else { return }
            switch delta["type"]?.string {
            case "text_delta":
                if let text = delta["text"]?.string { sink(.messageDelta(id: id, text: text)) }
            case "thinking_delta":
                if let text = delta["thinking"]?.string { sink(.reasoningDelta(id: id, text: text)) }
            default:
                break
            }
        default:
            break
        }
    }

    /// Text Claude Code puts in the transcript itself, under the model name `<synthetic>`,
    /// where the model said nothing: "No response requested." for a turn it found
    /// unanswered when a session was resumed, "(no content)" for an empty reply.
    private static let syntheticModel = "<synthetic>"
    private static let syntheticPlaceholders: Set<String> = ["No response requested.", "(no content)"]

    private func handleAssistant(_ message: JSONValue, stream: inout StreamState, sink: (ProviderEvent) -> Void) {
        guard let body = message["message"], let content = body["content"]?.array else { return }
        // Claude Code's own bookkeeping is never the model's words: a resumed session whose
        // transcript ended on a user message (a turn stopped or rewound here) gets a
        // synthetic "No response requested." after it, and the chat drew that as a reply
        // from the lead. An API error the CLI wraps the same way keeps its text, as a
        // notice rather than a message; the placeholders say nothing and are dropped.
        if body["model"]?.string == Self.syntheticModel {
            let text = content.compactMap { $0["type"]?.string == "text" ? $0["text"]?.string : nil }
                .joined(separator: "\n").trimmed
            if message["isApiErrorMessage"]?.bool == true, !text.isEmpty, !Self.syntheticPlaceholders.contains(text) {
                sink(.notice(Notice(level: .warning, message: text)))
            }
            return
        }
        let messageID = body["id"]?.string ?? UUID().uuidString
        if let uuid = message["uuid"]?.string { sink(.assistantMessageID(uuid)) }
        for block in content {
            switch block["type"]?.string {
            case "text":
                let text = block["text"]?.string ?? ""
                let id = stream.openText[messageID]?.isEmpty == false ? stream.openText[messageID]!.removeFirst() : "\(messageID)-text-\(UUID().uuidString)"
                sink(.messageCompleted(id: id, text: text))
            case "thinking":
                let text = block["thinking"]?.string ?? ""
                let id = stream.openThinking[messageID]?.isEmpty == false ? stream.openThinking[messageID]!.removeFirst() : "\(messageID)-thinking-\(UUID().uuidString)"
                sink(.reasoningCompleted(id: id, text: text))
            case "tool_use":
                guard let toolID = block["id"]?.string, let name = block["name"]?.string else { continue }
                let input = block["input"] ?? [:]
                toolNames[toolID] = name
                if name == "TodoWrite" {
                    sink(.todos(ACPSession.parseTodoItems(input["todos"])))
                } else if let call = toolCall(name: name, input: input) {
                    sink(.toolStarted(id: toolID, call: call))
                    sink(.toolUpdated(id: toolID, update: ToolUpdate(title: call.title, detail: call.detail, edits: call.edits, kind: call.kind)))
                }
            default:
                break
            }
        }
    }

    private func handleToolResults(_ message: JSONValue, sink: (ProviderEvent) -> Void) async {
        for block in message["message"]?["content"]?.array ?? [] where block["type"]?.string == "tool_result" {
            guard let toolID = block["tool_use_id"]?.string else { continue }
            // The result closes the call, so its name is not needed again.
            let name = toolNames.removeValue(forKey: toolID) ?? ""
            if Self.hiddenResultTools.contains(name) { continue }
            let isError = block["is_error"]?.bool ?? false
            let output = ToolText.blocks(block["content"])
            let images: [Attachment]
            if name == "Read" {
                images = []
            } else {
                images = await ToolImages.blocks(block["content"])
            }
            var status: ToolCall.Status = isError ? .failed : .completed
            if isError, output.localizedCaseInsensitiveContains("declined") || output.localizedCaseInsensitiveContains("doesn't want") {
                status = .declined
            }
            sink(.toolUpdated(id: toolID, update: ToolUpdate(output: output, status: status, images: images.isEmpty ? nil : images)))
        }
    }

    private func handleResult(_ message: JSONValue) {
        // Before the initialize is answered, a result is the launch's failure, not a turn's:
        // a `--resume` of a conversation the CLI no longer has answers with one
        // (`error_during_execution`, no turns, its `errors` naming the session) and exits.
        // `start()` throws it from `didClose`; nothing was sent that could end here.
        guard isStarted else {
            let errors = (message["errors"]?.array ?? []).compactMap(\.string).joined(separator: "\n")
            if !errors.isEmpty { launchError = errors }
            return
        }
        turnActive = false
        // Spend and context occupancy have independent sources. A failed context
        // query must neither fabricate occupancy nor drop the turn's spend.
        if let spend = Self.turnSpendEvent(message, model: model) {
            TokenLedger.shared.record(spend: spend.totalTokens)
            onEvent?(.tokenSpend(spend))
        }
        refreshContextUsage()
        for requestID in pendingTools.keys { onEvent?(.requestResolved(id: requestID)) }
        pendingTools.removeAll()
        // Every call of the turn has had its result; an interrupted one never will.
        toolNames.removeAll()
        mainStream = StreamState()
        // The heads' streams stay: a head running in the background outlives the lead's
        // turn, and clearing its stream here made its next delta orphaned and dropped.
        // Each head's stream goes with its own task_notification.
        let isError = message["is_error"]?.bool ?? (message["subtype"]?.string != "success")
        if interruptRequested {
            onEvent?(.turnCompleted(status: .interrupted, error: nil))
        } else if isError {
            let errors = (message["errors"]?.array ?? []).compactMap(\.string).joined(separator: "\n")
            let text = message["result"]?.string ?? errors
            // The limit refusal may arrive as the result alone, without a rate limit event before it.
            if UsageLimitSignal.matches(text) { onEvent?(.usageLimit(resetsAt: UsageLimitSignal.resetTime(in: text))) }
            onEvent?(.turnCompleted(status: .failed, error: text.isEmpty ? "Claude stopped before finishing." : text))
        } else {
            onEvent?(.turnCompleted(status: .completed, error: nil))
        }
        interruptRequested = false
    }

    private func handleControlRequest(_ message: JSONValue) {
        guard let requestID = message["request_id"]?.string, let request = message["request"] else { return }
        guard request["subtype"]?.string == "can_use_tool" else {
            process?.send([
                "type": "control_response",
                "response": ["subtype": "error", "request_id": .string(requestID), "error": "Tivano does not support this request."],
            ])
            return
        }
        let name = request["tool_name"]?.string ?? "Tool"
        let input = request["input"] ?? [:]
        let toolUseID = request["tool_use_id"]?.string
        pendingTools[requestID] = PendingTool(name: name, input: input, suggestions: request["permission_suggestions"])

        switch name {
        case "AskUserQuestion":
            let questions = (input["questions"]?.array ?? []).compactMap { question -> QuestionRequest.Question? in
                guard let prompt = question["question"]?.string else { return nil }
                return QuestionRequest.Question(
                    id: prompt,
                    header: question["header"]?.string ?? "",
                    prompt: prompt,
                    choices: (question["options"]?.array ?? []).compactMap { option in
                        option["label"]?.string.map { QuestionRequest.Choice(label: $0, detail: option["description"]?.string) }
                    },
                    allowsMultiple: question["multiSelect"]?.bool ?? false,
                    allowsOther: true,
                    isSecret: false
                )
            }
            onEvent?(.question(QuestionRequest(id: requestID, questions: questions)))
        case "ExitPlanMode":
            onEvent?(.planCompleted(id: toolUseID ?? requestID, markdown: input["plan"]?.string ?? ""))
            onEvent?(.approval(ApprovalRequest(
                id: requestID,
                kind: .plan,
                title: "Implement this plan",
                options: [
                    .init(id: "allow", title: "Implement plan", role: .approve),
                    .init(id: "deny", title: "Keep planning", role: .decline),
                ],
                toolItemID: toolUseID
            )))
        default:
            // The card shows the kind, title and detail; the edits' diffs are built once,
            // when the assistant message lands.
            let call = toolCall(name: name, input: input, withEdits: false) ?? ToolCall(kind: .other, title: name)
            let kind: ApprovalRequest.Kind = switch call.kind {
            case .command: .command
            case .edit: .fileChange
            default: .tool
            }
            var options: [ApprovalRequest.Option] = [.init(id: "allow", title: "Approve", role: .approve)]
            if let suggestions = request["permission_suggestions"]?.array, !suggestions.isEmpty {
                options.append(.init(id: "always", title: "Approve for session", role: .approveAlways))
            }
            options.append(.init(id: "deny", title: "Decline", role: .decline))
            onEvent?(.approval(ApprovalRequest(
                id: requestID,
                kind: kind,
                title: call.title,
                detail: call.kind == .command ? request["description"]?.string : call.detail,
                reason: request["decision_reason"]?.string,
                options: options,
                toolItemID: toolUseID
            )))
        }
    }

    private func clearBackgroundTasks() {
        guard !backgroundTasks.isEmpty else { return }
        backgroundTasks.removeAll()
        onEvent?(.backgroundTasks([]))
    }

    private func didClose() {
        guard !hasClosed else { return }
        clearBackgroundTasks()
        hasClosed = true
        let tail = process?.errorTail ?? ""
        // The result's own error names the failure better than the stderr tail can.
        let reason = launchError ?? TextCleanup.lastLines(tail)
        launchError = reason
        pendingControl.failAll(ProviderError.failed(reason ?? "Claude exited."))
        turnActive = false
        // A launch that failed is reported by `start()` throwing; only a session that
        // ran says it exited.
        guard !isStopping, isStarted else { return }
        onEvent?(.exited(error: TextCleanup.lastLines(tail)))
    }

    // MARK: - Mapping

    /// Tools whose results are shown by the app itself, never as a tool row.
    private static let hiddenResultTools: Set<String> = ["AskUserQuestion", "ExitPlanMode", "EnterPlanMode", "TodoWrite", "ToolSearch"]

    private func toolCall(name: String, input: JSONValue, withEdits: Bool = true) -> ToolCall? {
        func path(_ key: String) -> String? {
            input[key]?.string.map { ToolTitles.relativePath($0, to: workingDirectory) }
        }
        switch name {
        case "TodoWrite", "AskUserQuestion", "ExitPlanMode", "EnterPlanMode", "ToolSearch":
            return nil
        case "Bash":
            return ToolCall(kind: .command, title: input["command"]?.string ?? "Shell command", detail: input["description"]?.string)
        case "BashOutput", "KillShell", "KillBash", "Monitor", "TaskOutput", "TaskStop":
            return ToolCall(kind: .command, title: name)
        case "Read":
            return ToolCall(kind: .read, title: path("file_path") ?? "Read file")
        case "Write":
            var call = ToolCall(kind: .edit, title: path("file_path") ?? "Write file")
            if withEdits, let file = path("file_path"), let content = input["content"]?.string {
                call.edits = [FileEdit(path: file, old: "", new: content)]
            }
            return call
        case "Edit":
            var call = ToolCall(kind: .edit, title: path("file_path") ?? "Edit file")
            if withEdits, let file = path("file_path") {
                call.edits = [FileEdit(path: file, old: input["old_string"]?.string ?? "", new: input["new_string"]?.string ?? "")]
            }
            return call
        case "MultiEdit":
            var call = ToolCall(kind: .edit, title: path("file_path") ?? "Edit file")
            if withEdits, let file = path("file_path") {
                call.edits = (input["edits"]?.array ?? []).map {
                    FileEdit(path: file, old: $0["old_string"]?.string ?? "", new: $0["new_string"]?.string ?? "")
                }
            }
            return call
        case "NotebookEdit":
            return ToolCall(kind: .edit, title: path("notebook_path") ?? "Edit notebook")
        case "Glob":
            return ToolCall(kind: .search, title: input["pattern"]?.string ?? "Find files", detail: path("path"))
        case "Grep":
            return ToolCall(kind: .search, title: input["pattern"]?.string ?? "Search", detail: path("path"))
        case "LS":
            return ToolCall(kind: .search, title: path("path") ?? "List files")
        case "WebFetch":
            return ToolCall(kind: .web, title: input["url"]?.string ?? "Fetch page")
        case "WebSearch":
            return ToolCall(kind: .web, title: input["query"]?.string ?? "Search the web")
        case "Task", "Agent":
            return ToolCall(kind: .agent, title: input["description"]?.string ?? "Subagent", detail: input["subagent_type"]?.string)
        case "Skill":
            return ToolCall(kind: .other, title: "Skill · \(input["skill"]?.string ?? input["command"]?.string ?? "")")
        default:
            if name.hasPrefix("mcp__") {
                let parts = name.split(separator: "__", omittingEmptySubsequences: true)
                let server = parts.count > 1 ? String(parts[1]) : "MCP"
                let tool = parts.count > 2 ? parts[2...].joined(separator: "__") : name
                return ToolCall(kind: .mcp, title: "\(server) · \(tool)", detail: input.isNull ? nil : input.compactString)
            }
            return ToolCall(kind: .other, title: name)
        }
    }

    /// The tokens the turn sent and received across its API calls, cache reads
    /// included, which is what Claude Code itself reports.
    private static func turnSpend(_ message: JSONValue) -> Int {
        guard let usage = message["usage"] else { return 0 }
        func tokens(_ value: JSONValue?) -> Int {
            (value?["input_tokens"]?.int ?? 0)
                + (value?["cache_read_input_tokens"]?.int ?? 0)
                + (value?["cache_creation_input_tokens"]?.int ?? 0)
                + (value?["output_tokens"]?.int ?? 0)
        }
        if let iterations = usage["iterations"]?.array, !iterations.isEmpty {
            return iterations.reduce(0) { $0 + tokens($1) }
        }
        return tokens(usage)
    }

    /// The turn's usage as spend: the total `turnSpend` counts, with the parts
    /// the CLI gives when the usage is a single object. With iterations the
    /// total is their sum and the parts are left out rather than guessed. Cache
    /// reads stay inside `cachedInputTokens`, which is a slice of the total,
    /// never something added to it.
    private static func turnSpendEvent(_ message: JSONValue, model: String?) -> TokenSpend? {
        guard let usage = message["usage"] else { return nil }
        let total = turnSpend(message)
        guard total > 0 else { return nil }
        let iterations = usage["iterations"]?.array ?? []
        guard iterations.isEmpty else {
            return TokenSpend(provider: .claude, totalTokens: total, model: model)
        }
        let cached = usage["cache_read_input_tokens"]?.int
        let input = usage["input_tokens"]?.int.map {
            $0 + (cached ?? 0) + (usage["cache_creation_input_tokens"]?.int ?? 0)
        }
        return TokenSpend(
            provider: .claude,
            totalTokens: total,
            inputTokens: input,
            outputTokens: usage["output_tokens"]?.int,
            cachedInputTokens: cached,
            model: model
        )
    }

    private static func contextUsage(_ report: JSONValue) -> ContextUsage? {
        guard let used = report["totalTokens"]?.int, used >= 0,
              let window = report["maxTokens"]?.int, window > 0 else { return nil }
        return ContextUsage(usedTokens: used, windowTokens: window)
    }

    private static func sessionScoped(_ suggestion: JSONValue) -> JSONValue {
        guard var object = suggestion.object else { return suggestion }
        object["destination"] = "session"
        return .object(object)
    }

    static func modeName(_ runtime: RuntimeMode, _ interaction: InteractionMode) -> String {
        if interaction == .plan { return "plan" }
        switch runtime {
        case .supervised: return "default"
        case .autoAcceptEdits: return "acceptEdits"
        case .auto: return "auto"
        case .fullAccess: return "bypassPermissions"
        }
    }
}
