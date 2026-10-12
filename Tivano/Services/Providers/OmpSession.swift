import Foundation

/// Runs omp over JSONL RPC; only the matching prompt_result completes an agent turn.
@MainActor
final class OmpSession: ProviderSession {
    var onEvent: ((ProviderEvent) -> Void)?

    private let configuration: SessionConfiguration
    private var process: StdioProcess?
    private var readTask: Task<Void, Never>?
    /// The omp session file path, taken from `configuration.resumeID`.
    private var sessionID: String?
    private var started = false
    private var stopped = false
    private let runtimeMode: RuntimeMode
    private let interactionMode: InteractionMode
    private var model: String?
    /// Resolved from OMP's settings-backed @default role, never the resumed session model.
    private var defaultModel: String?
    private var activeModel: String?
    private var effort: String?
    /// This session's settings overlay (see `OmpCLI.writeLaunchSettings`) and gate file (see
    /// `writeGate`), removed on stop.
    private var settingsFile: URL?
    private var gateURL: URL?

    private var turnActive = false
    private var interruptRequested = false
    /// The prompt whose `prompt_result` ends the turn.
    private var promptID: String?
    private var isFinalReport = false
    /// Namespaces ids per launch, so a resumed thread never streams into an old entry.
    private let launchID: String
    private var stream: StreamedTextTracker
    private var toolNames: [String: String] = [:]
    private var toolInputs: [String: JSONValue] = [:]
    private var editSnapshots = EditSnapshots()
    /// The model's context ceiling, from the session state's model.
    private var contextWindow: Int?
    private var pendingApprovals: [String: ApprovalRequest] = [:]
    /// `extension_ui_request` ids by method, for the app's questions.
    private var pendingQuestions: [String: String] = [:]
    /// Approval kinds allowed for the rest of the session ("Approve for session").
    private var sessionGrants: Set<String> = []
    /// Calls that have started and not ended, oldest first: the approval prompt names its
    /// tool but not the call, so it is matched to the oldest call of that name without one.
    private var runningTools: [String] = []
    private var toolsAwaitingAnswer: [String: String] = [:]
    /// Calls shown as something other than a row (the todo list).
    private var hiddenCalls: Set<String> = []
    private var turnError: String?
    /// What the turn's failed model requests said, for telling a spent usage limit from any
    /// other error.
    private var failure = Failure()
    /// The turn's last reply, which plan mode hands over as the plan.
    private var lastReplyText = ""
    private var turnCounter = 0
    private var pendingResponses = PendingReplies<JSONValue>()
    private var requestCounter = 0

    /// A title asked for with `/rename` is on its way; omp's one line about how it went (it
    /// follows the title, or stands in for it) is not shown.
    private var isRenaming = false

    private struct Failure {
        var errorID: Int?
        var status: Int?
        var texts: [String] = []
    }

    private static let planPrompt = "You are in plan mode: read-only. Do not edit files or run commands that change anything; investigate, then end with the plan as markdown."
    private static let finalReportPrompt = "Reply with your final report now: no tools, one message."
    private static let approvalPrefix = "Allow tool: "
    private static let gatePrefix = "tivano-gate "
    /// omp's `Flag.UsageLimit`, set on an error id when the provider's refusal is a spent limit.
    private static let usageLimitFlag = 0x0008_0000

    init(configuration: SessionConfiguration) {
        let launchID = String(UUID().uuidString.prefix(8))
        self.launchID = launchID
        stream = StreamedTextTracker(
            messageID: { "\(launchID)-m-\($0)" },
            thinkingID: { "\(launchID)-t-\($0)" }
        )
        self.configuration = configuration
        runtimeMode = configuration.runtimeMode
        interactionMode = configuration.interactionMode
        model = configuration.model
        effort = configuration.effort
        sessionID = configuration.resumeID.flatMap { $0.isEmpty ? nil : $0 }
    }

    var isRunning: Bool { started && !stopped && process?.isRunning == true }

    private var workingDirectory: String { configuration.workingDirectory.path }

    /// What the gate extension reads before every tool call: the app's word on this session's
    /// mode, whether this turn is a final report, and whether ordinary `task` calls may run.
    /// Hydra always disables `task`; without Hydra only Full access permits it. The mode is
    /// the session's own, fixed for its life.
    private func writeGate(finalReport: Bool) throws {
        guard let gateURL else { throw ProviderError.notRunning }
        let gate: JSONValue = [
            "runtimeMode": .string(runtimeMode.rawValue),
            "interactionMode": .string(interactionMode.rawValue),
            "finalReport": .bool(finalReport),
            "allowTask": .bool(configuration.hydra == nil && runtimeMode == .fullAccess && interactionMode != .plan && !finalReport),
        ]
        try gate.data().write(to: gateURL, options: .atomic)
    }

    /// Appended to omp's system prompt: the lead's Hydra policy with a team, the anti-slop
    /// guidance, and plan mode's rule. omp keeps no copy of it in the conversation, so a
    /// resumed thread gets the current one.
    private var systemPrompt: String {
        var parts: [String] = []
        if let hydra = configuration.hydra {
            parts.append(HydraPrompts.fallbackPolicy(hydra))
        }
        parts.append(AntiSlopPolicy.instructions(enabled: configuration.antiSlopEnabled))
        if interactionMode == .plan { parts.append(Self.planPrompt) }
        return parts.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    // MARK: - Lifecycle

    func start() async throws -> String {
        guard let executable = configuration.executable else { throw ProviderError.notInstalled(configuration.provider) }
        guard configuration.provider.supports(runtimeMode) else {
            throw ProviderError.failed(String(localized: "omp does not support Auto permissions."))
        }
        try validateSelection(model: model, effort: effort)
        // omp writes the session file with the first reply, so a conversation that was never
        // answered has none; that thread never recorded an id either.
        if let sessionID, !FileManager.default.fileExists(atPath: sessionID) {
            throw ProviderError.failed(String(localized: "omp no longer has this conversation; starting a new one."))
        }

        let extensionURL = try OmpCLI.installExtension()
        let settings: URL
        do {
            settings = try OmpCLI.writeLaunchSettings(id: launchID, hydra: configuration.hydra, leadModel: model)
            settingsFile = settings
            gateURL = try OmpCLI.gateFile(id: launchID)
            try writeGate(finalReport: false)
        } catch {
            removeLaunchFiles()
            throw error
        }
        stopped = false
        // omp runs as `yolo` in every mode: the decision is the gate extension's, which asks
        // the app about what the mode does not let through. omp's own approval is no gate
        // (`OmpCLI.extensionSource`).
        var arguments = ["--mode", "rpc-ui", "--approval-mode", "yolo", "--config", settings.path, "-e", extensionURL.path]
        var environment = configuration.environment
        environment["TIVANO_OMP_GATE"] = gateURL?.path
        if FileManager.default.fileExists(atPath: MCPPaths.claudeConfigURL.path), let bridge = try? MCPBridge.installBridge() {
            environment["TIVANO_MCP_BRIDGE"] = bridge.path
            environment["TIVANO_MCP_CONFIG"] = MCPPaths.claudeConfigURL.path
        }
        if let model, !model.isEmpty, model != "default", model.contains("/") {
            arguments += ["--model", model]
        }
        if let effort, !effort.isEmpty, OmpCLI.thinkingLevels.contains(effort) {
            arguments += ["--thinking", effort]
        }
        if !systemPrompt.isEmpty { arguments += ["--append-system-prompt", systemPrompt] }
        if let sessionID { arguments += ["--resume", sessionID] }

        let process = StdioProcess(
            executable: executable,
            arguments: arguments,
            directory: configuration.workingDirectory,
            environment: environment,
            framing: .lines
        )
        do {
            try process.start()
        } catch {
            removeLaunchFiles()
            throw ProviderError.failed(String(format: String(localized: "omp could not start: %@"), error.localizedDescription))
        }
        self.process = process
        let messages = process.messages
        readTask = Task { [weak self] in
            for await message in messages {
                guard let self else { return }
                self.handle(message)
            }
            let status = await process.waitForExit()
            self?.didClose(status: status)
        }

        // The gate is what keeps omp's tools in check: omp runs without it only if it did not
        // load the extension, and then nothing is let through, so the session does not start.
        let commandsResponse = await request(["type": .string("get_available_commands")])
        let commands = (commandsResponse["data"] ?? commandsResponse)["commands"]?.array ?? []
        guard commandsResponse["success"]?.bool != false,
              commands.contains(where: { $0["name"]?.string == OmpCLI.gateCommand }) else {
            stop()
            throw ProviderError.failed(String(localized: "omp did not load Tivano's tool gate, so it was not started. Update omp (omp update) and try again."))
        }

        let state = await request(["type": .string("get_state")])
        guard !state.isNull, state["success"]?.bool != false, process.isRunning, !stopped else {
            stop()
            throw ProviderError.failed(String(localized: "omp could not read the session state."))
        }
        let data = state["data"] ?? state
        if let file = data["sessionFile"]?.string, !file.isEmpty {
            self.sessionID = file
        } else if let id = data["sessionId"]?.string, !id.isEmpty {
            self.sessionID = id
        }
        contextWindow = data["model"]?["contextWindow"]?.int
        if let provider = data["model"]?["provider"]?.string, let id = data["model"]?["id"]?.string {
            activeModel = "\(provider)/\(id)"
        }
        do {
            try await selectModel(model)
        } catch {
            stop()
            throw error
        }
        onEvent?(.sessionReady(sessionID: self.sessionID ?? ""))

        emitCommands(commandsResponse["data"] ?? commandsResponse)
        started = true
        stopped = false
        return self.sessionID ?? ""
    }

    /// Invalid UI/stored selections must not silently run the previous model or effort.
    private func validateSelection(model: String?, effort: String?) throws {
        if let model, !model.isEmpty, model != "default" {
            let parts = model.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else {
                throw ProviderError.failed(String(format: String(localized: "omp could not switch to %@. %@"), model, "").trimmed)
            }
        }
        if let effort, !effort.isEmpty, !OmpCLI.thinkingLevels.contains(effort) {
            throw ProviderError.failed(String(localized: "omp could not change its thinking level."))
        }
    }

    private func selectModel(_ selection: String?) async throws {
        let wanted = selection.flatMap { $0.isEmpty ? nil : $0 } ?? "default"
        let selector: String
        if wanted == "default" {
            guard let defaultModel else {
                throw ProviderError.failed(String(localized: "omp could not resolve its configured default model. Select a specific model and try again."))
            }
            selector = defaultModel
        } else {
            selector = wanted
        }
        guard selector != activeModel else { model = wanted; return }
        guard let slash = selector.firstIndex(of: "/") else {
            throw ProviderError.failed(String(format: String(localized: "omp could not switch to %@. %@"), wanted, "").trimmed)
        }
        let response = await request([
            "type": .string("set_model"),
            "provider": .string(String(selector[..<slash])),
            "modelId": .string(String(selector[selector.index(after: slash)...])),
        ])
        guard !response.isNull, response["success"]?.bool != false else {
            throw ProviderError.failed(String(format: String(localized: "omp could not switch to %@. %@"), wanted, response["error"]?.string ?? "").trimmed)
        }
        activeModel = selector
        model = wanted
        contextWindow = (response["data"] ?? response)["contextWindow"]?.int
    }

    func send(_ input: TurnInput) async throws {
        guard isRunning, let process else { throw ProviderError.notRunning }
        try validateSelection(model: input.model, effort: input.effort)
        guard !turnActive else { throw ProviderError.failed(String(localized: "omp is still on the last turn.")) }
        guard input.runtimeMode == runtimeMode, input.interactionMode == interactionMode else {
            throw ProviderError.failed(String(localized: "Restart the omp session to change its permission or interaction mode."))
        }
        try await selectModel(input.model)
        if let wanted = input.effort, !wanted.isEmpty, wanted != effort, OmpCLI.thinkingLevels.contains(wanted) {
            let response = await request(["type": .string("set_thinking_level"), "level": .string(wanted)])
            guard !response.isNull, response["success"]?.bool != false else {
                throw ProviderError.failed(response["error"]?.string ?? String(localized: "omp could not change its thinking level."))
            }
            effort = wanted
        }
        guard isRunning, !Task.isCancelled else { throw ProviderError.notRunning }
        try writeGate(finalReport: input.isFinalReport)
        turnActive = true
        interruptRequested = false
        isFinalReport = input.isFinalReport
        turnError = nil
        failure = Failure()
        turnCounter += 1
        lastReplyText = ""
        toolNames.removeAll()
        toolInputs.removeAll()
        editSnapshots.removeAll()
        runningTools.removeAll()
        toolsAwaitingAnswer.removeAll()
        hiddenCalls.removeAll()
        let id = "tivano-turn-\(turnCounter)"
        promptID = id
        let text = input.isFinalReport ? Self.finalReportPrompt + "\n\n" + input.text : input.text
        var fields: [String: JSONValue] = ["type": .string("prompt"), "id": .string(id), "message": .string(text)]
        let images: [JSONValue] = input.images.compactMap { image in
            guard image.isImage, let data = try? Data(contentsOf: image.url) else { return nil }
            return ["type": "image", "data": .string(data.base64EncodedString()), "mimeType": .string(image.mimeType)]
        }
        if !images.isEmpty { fields["images"] = .array(images) }
        process.send(.object(fields))
        onEvent?(.turnStarted(providerTurnID: nil))
    }

    func interrupt() async {
        interruptRequested = true
        process?.send(["type": .string("abort")])
    }

    func compact() async throws {
        guard isRunning else { throw ProviderError.notRunning }
        onEvent?(.notice(Notice(level: .info, message: String(localized: "Compacting the conversation…"))))
        // Compaction summarises the whole conversation with the model, which takes a while.
        Task { [weak self] in
            guard let self else { return }
            let response = await self.request(["type": .string("compact")], timeout: .seconds(600))
            if response["success"]?.bool == false {
                // omp refuses a conversation too short to compact ("Nothing to compact"): not a failure.
                self.onEvent?(.notice(Notice(level: .warning, message: response["error"]?.string ?? String(localized: "omp could not compact the conversation."))))
            } else if !response.isNull {
                self.onEvent?(.contextUsageCleared)
                self.onEvent?(.notice(Notice(level: .info, message: String(localized: "Conversation compacted"))))
            }
        }
    }

    /// Drops the conversation from the first of the removed prompts on: omp forks a new
    /// session file holding everything before that message, and the session carries on in
    /// it. Returns the new file, which is the id the thread resumes from. The prompts are
    /// the removed turns' own words, in order; omp's user messages are matched to them by
    /// text (they can carry more, a team's note say) and by how far from the end they sit.
    func rollback(removing prompts: [String]) async throws -> String {
        guard isRunning else { throw ProviderError.notRunning }
        guard !turnActive, !isRenaming, !prompts.isEmpty else {
            throw ProviderError.failed(String(localized: "omp cannot rewind while busy or without a removed prompt."))
        }
        let listing = await request(["type": .string("get_branch_messages")])
        let messages = ((listing["data"] ?? listing)["messages"]?.array ?? []).compactMap { entry -> (id: String, text: String)? in
            guard let id = entry["entryId"]?.string else { return nil }
            return (id, entry["text"]?.string ?? "")
        }
        let expected = messages.count - prompts.count
        guard expected >= 0 else { throw ProviderError.failed(String(localized: "omp holds fewer messages than the conversation shows, so the point to rewind to is unclear. The conversation was kept.")) }
        let probe = String((prompts.first ?? "").trimmed.prefix(40))
        // The message at the expected place, or the nearest one that carries the first removed
        // prompt's words.
        let target: Int? = probe.isEmpty
            ? expected
            : messages.indices.filter { messages[$0].text.contains(probe) }.min { abs($0 - expected) < abs($1 - expected) }
        guard let target, messages.indices.contains(target), abs(target - expected) <= 3 else {
            throw ProviderError.failed(String(localized: "omp has no message matching the one to rewind to. The conversation was kept."))
        }
        let branch = await request(["type": .string("branch"), "entryId": .string(messages[target].id)])
        guard branch["success"]?.bool == true, branch["data"]?["cancelled"]?.bool != true else {
            throw ProviderError.failed(branch["error"]?.string ?? String(localized: "omp could not rewind the conversation. It was kept."))
        }
        let state = await request(["type": .string("get_state")])
        guard let file = (state["data"] ?? state)["sessionFile"]?.string, !file.isEmpty else {
            throw ProviderError.failed(String(localized: "omp rewound the conversation but did not say where it went on."))
        }
        sessionID = file
        onEvent?(.sessionReady(sessionID: file))
        onEvent?(.contextUsageCleared)
        return file
    }

    /// Asks omp to name the conversation. omp never does by itself over RPC; `/rename` with
    /// no title writes one from the recent messages in the background and reports it with a
    /// `session_info_update`, which reaches the thread as its title. omp's own words about it
    /// stay out of the chat.
    func requestTitle() async {
        guard isRunning, !turnActive, !isRenaming else { return }
        isRenaming = true
        _ = await request(["type": .string("prompt"), "message": "/rename"])
        // A title that cannot be written (too little to go on, no model for it) ends in omp's
        // sentence rather than a frame; stop holding omp's words back after a while.
        try? await Task.sleep(for: .seconds(45))
        isRenaming = false
    }

    func stop() {
        stopped = true
        started = false
        pendingResponses.resolveAll(.null)
        clearRequests()
        process?.terminate()
        process = nil
        readTask?.cancel()
        readTask = nil
        removeLaunchFiles()
    }

    private func removeLaunchFiles() {
        for file in [settingsFile, gateURL] {
            if let file { try? FileManager.default.removeItem(at: file) }
        }
        settingsFile = nil
        gateURL = nil
    }

    func resolveApproval(_ requestID: String, optionID: String) {
        guard let request = pendingApprovals.removeValue(forKey: requestID) else { return }
        let value: String
        switch request.options.first(where: { $0.id == optionID })?.role {
        case .approveAlways:
            value = "Approve"
            sessionGrants.insert(request.kind.grantKey)
        case .decline, .cancel, nil:
            value = "Deny"
        case .approve:
            value = "Approve"
        }
        if let toolID = request.toolItemID { toolsAwaitingAnswer.removeValue(forKey: toolID) }
        process?.send(["type": .string("extension_ui_response"), "id": .string(requestID), "value": .string(value)])
        onEvent?(.requestResolved(id: requestID))
    }

    func answerQuestion(_ requestID: String, answers: [String: [String]]) {
        guard let method = pendingQuestions.removeValue(forKey: requestID) else { return }
        let texts = answers.values.flatMap { $0 }
        if texts.isEmpty {
            process?.send(["type": .string("extension_ui_response"), "id": .string(requestID), "cancelled": true])
        } else if method == "confirm" {
            process?.send(["type": .string("extension_ui_response"), "id": .string(requestID), "confirmed": .bool(texts.first == String(localized: "Yes"))])
        } else {
            process?.send(["type": .string("extension_ui_response"), "id": .string(requestID), "value": .string(texts.first ?? "")])
        }
        onEvent?(.requestResolved(id: requestID))
    }

    // MARK: - Requests

    /// Writes a request line with a fresh id and resumes with the `response` that
    /// carries it, or `.null` after the timeout.
    private func request(_ fields: [String: JSONValue], timeout: Duration = .seconds(30)) async -> JSONValue {
        guard let process else { return .null }
        requestCounter += 1
        let id = "tivano-\(requestCounter)"
        var line = fields
        line["id"] = .string(id)
        let value = try? await pendingResponses.register(id, timeout: timeout, timeoutValue: .null) {
            process.send(.object(line))
        }
        return value ?? .null
    }

    private func emitCommands(_ data: JSONValue) {
        guard let entries = data["commands"]?.array else { return }
        let commands = entries.compactMap { entry -> SlashCommand? in
            guard let name = entry["name"]?.string, name != OmpCLI.gateCommand else { return nil }
            return SlashCommand(name: name, detail: entry["description"]?.string ?? "")
        }
        if !commands.isEmpty { onEvent?(.commands(commands)) }
    }

    // MARK: - Stream

    private func handle(_ message: JSONValue) {
        switch message["type"]?.string {
        case "response":
            guard let id = message["id"]?.string else { return }
            if pendingResponses.resolve(id, message) { return }
            guard id == promptID else { return }
            if message["success"]?.bool == false {
                turnError = message["error"]?.string ?? String(localized: "omp reported an error.")
                finishTurn()
            } else if message["data"]?["agentInvoked"]?.bool == false {
                // A slash command omp ran itself: no turn follows.
                finishTurn()
            }
        case "prompt_result":
            guard message["id"]?.string == promptID else { return }
            switch message["status"]?.string {
            case "error":
                let error = message["error"] ?? .null
                turnError = error["message"]?.string ?? String(localized: "omp reported an error.")
                failure.status = error["httpStatus"]?.int ?? failure.status
                failure.texts.append(turnError ?? "")
            case "aborted":
                interruptRequested = true
            default:
                break
            }
            finishTurn()
        case "message_start", "message_update", "message_end", "tool_execution_start", "tool_execution_update", "tool_execution_end":
            handleStream(message)
        case "command_output":
            guard let text = message["text"]?.string, !text.trimmed.isEmpty else { return }
            if isRenaming {
                isRenaming = false
                return
            }
            let id = "\(launchID)-c-\(turnCounter)"
            onEvent?(.messageDelta(id: id, text: text))
            onEvent?(.messageCompleted(id: id, text: text))
        case "session_info_update":
            guard let title = message["title"]?.string, !title.isEmpty else { return }
            onEvent?(.title(title))
        case "available_commands_update":
            emitCommands(message)
        case "auto_compaction_start":
            onEvent?(.notice(Notice(level: .info, message: String(localized: "Compacting the conversation…"))))
        case "auto_compaction_end":
            if let failure = message["errorMessage"]?.string {
                onEvent?(.notice(Notice(level: .warning, message: String(format: String(localized: "omp could not compact the conversation. %@"), failure))))
            } else if message["aborted"]?.bool != true {
                onEvent?(.contextUsageCleared)
                onEvent?(.notice(Notice(level: .info, message: String(localized: "Conversation compacted"))))
            }
        case "auto_retry_start":
            failure.errorID = message["errorId"]?.int ?? failure.errorID
            onEvent?(.notice(Notice(level: .warning, message: message["errorMessage"]?.string ?? String(localized: "omp is retrying."))))
        case "auto_retry_end":
            if message["success"]?.bool == false {
                let text = message["finalError"]?.string ?? String(localized: "omp gave up retrying.")
                failure.texts.append(text)
                onEvent?(.notice(Notice(level: .error, message: text)))
            }
        case "notice":
            guard let text = message["message"]?.string, !text.isEmpty else { return }
            let level: Notice.Level = switch message["level"]?.string {
            case "warning", "warn": .warning
            case "error": .error
            default: .info
            }
            onEvent?(.notice(Notice(level: level, message: text)))
        case "extension_error":
            onEvent?(.notice(Notice(level: .error, message: message["error"]?.string ?? String(localized: "omp reported an extension error."))))
        case "extension_ui_request":
            handleExtensionUI(message)
        default:
            break
        }
    }

    private func handleStream(_ message: JSONValue) {
        switch message["type"]?.string {
        case "message_start":
            guard message["message"]?["role"]?.string == "assistant" else { return }
            stream.startMessage()
            stream.resetThinking()
        case "message_update":
            handleUpdate(message)
        case "message_end":
            handleMessageEnd(message["message"] ?? message)
        case "tool_execution_start":
            handleToolStart(message)
        case "tool_execution_update":
            guard let id = message["toolCallId"]?.string, !hiddenCalls.contains(id) else { return }
            let text = ToolText.blocks(message["partialResult"]?["content"])
            if !text.isEmpty { onEvent?(.toolOutput(id: id, text: text)) }
        case "tool_execution_end":
            handleToolEnd(message)
        default:
            break
        }
    }

    private func handleUpdate(_ message: JSONValue) {
        let event = message["assistantMessageEvent"] ?? .null
        switch event["type"]?.string {
        case "text_delta":
            guard let delta = event["delta"]?.string, !delta.isEmpty else { return }
            onEvent?(.messageDelta(id: stream.appendMessage(delta), text: delta))
        case "thinking_delta":
            guard let delta = event["delta"]?.string, !delta.isEmpty else { return }
            onEvent?(.reasoningDelta(id: stream.appendThinking(delta), text: delta))
        default:
            break
        }
        reportContext(message["message"]?["usage"])
    }

    /// The context meter: what the model was just given and said, against its window.
    private func reportContext(_ usage: JSONValue?) {
        guard let used = usage?["contextTokens"]?.int ?? usage?["totalTokens"]?.int, used > 0 else { return }
        onEvent?(.usage(ContextUsage(usedTokens: used, windowTokens: contextWindow)))
    }

    private func handleMessageEnd(_ message: JSONValue) {
        guard message["role"]?.string == "assistant" else { return }
        var finalText = stream.messageText
        if let blocks = message["content"]?.array {
            let joined = blocks.compactMap { block -> String? in
                guard block["type"]?.string == "text" else { return nil }
                return block["text"]?.string
            }.joined()
            if !joined.isEmpty { finalText = joined }
        }
        if let id = stream.currentThinkingID, !stream.thinkingText.trimmed.isEmpty {
            onEvent?(.reasoningCompleted(id: id, text: stream.thinkingText))
        }
        stream.endThinking()
        if let id = stream.currentMessageID {
            onEvent?(.messageCompleted(id: id, text: finalText))
            lastReplyText = finalText
        }
        stream.endMessage()
        // A failed request ends with an error message that omp may still retry, so the turn's
        // verdict is the `prompt_result`, not this message's stop reason; what it said is kept
        // for telling a spent usage limit from any other error.
        if message["stopReason"]?.string == "error" {
            failure.errorID = message["errorId"]?.int ?? failure.errorID
            failure.status = message["errorStatus"]?.int ?? failure.status
            if let text = message["errorMessage"]?.string { failure.texts.append(text) }
        }
        let usage = message["usage"] ?? .null
        reportContext(usage)
        if let spent = usage["totalTokens"]?.int, spent > 0 {
            TokenLedger.shared.record(spend: spent)
            // subagent_event wrappers are ignored; ordinary message usage is recorded per message.
            onEvent?(.tokenSpend(TokenSpend(
                provider: .omp,
                totalTokens: spent,
                inputTokens: usage["input"]?.int,
                outputTokens: usage["output"]?.int,
                cachedInputTokens: usage["cacheRead"]?.int,
                model: message["model"]?.string,
                agentID: nil
            )))
        }
    }

    // MARK: - Tools

    private func handleToolStart(_ message: JSONValue) {
        guard let id = message["toolCallId"]?.string, let name = message["toolName"]?.string else { return }
        let args = message["args"] ?? .null
        toolNames[id] = name
        toolInputs[id] = args
        let device = name == "write" ? args["path"]?.string.flatMap(Self.toolDevice) : nil
        // The lead's todo list is the thread's checklist card, not a row.
        if (device ?? name) == "todo" {
            hiddenCalls.insert(id)
            return
        }
        runningTools.append(id)
        if name == "write", device == nil, let path = args["path"]?.string {
            editSnapshots.capture(id, path: absolute(path))
        }
        let call = describe(name: name, args: args)
        onEvent?(.toolStarted(id: id, call: ToolCall(kind: call.kind, title: call.title, detail: call.detail)))
    }

    private func handleToolEnd(_ message: JSONValue) {
        guard let id = message["toolCallId"]?.string else { return }
        runningTools.removeAll { $0 == id }
        toolsAwaitingAnswer.removeValue(forKey: id)
        let result = message["result"] ?? .null
        let details = result["details"] ?? .null
        let isError = message["isError"]?.bool == true || result["isError"]?.bool == true
        if hiddenCalls.remove(id) != nil {
            // The call's own answer is the whole list as it stands, and a refused call leaves it as it was.
            if !isError, let steps = Self.todoSteps(details) { onEvent?(.todos(steps)) }
            return
        }
        let output = ToolText.blocks(result["content"])
        // A call the gate (or omp) refused comes back as an error that says so, opening with
        // "Declined:" for the gate's own reasons; the row reads as declined rather than failed.
        let status: ToolCall.Status = !isError ? .completed
            : output.hasPrefix("Declined:") || output.hasPrefix("Error: Declined:") || output.hasPrefix("Tool call denied by user") ? .declined : .failed
        let exitCode = details["exitCode"]?.int
        var edits: [FileEdit]? = nil
        if let name = toolNames[id], let args = toolInputs[id] {
            edits = isError ? nil : editDiff(name: name, args: args, details: details, id: id)
        }
        editSnapshots.discard(id)
        let displayOutput: String
        if output.hasPrefix("Declined:") || (isError && output.hasPrefix("Error: Declined:")) {
            let refusal = output.hasPrefix("Error: ") ? String(output.dropFirst("Error: ".count)) : output
            let end = refusal.firstIndex(of: "\n") ?? refusal.endIndex
            displayOutput = AppText.localized(String(refusal[..<end])) + String(refusal[end...])
        } else {
            displayOutput = output
        }
        onEvent?(.toolUpdated(id: id, update: ToolUpdate(output: displayOutput.isEmpty ? nil : displayOutput, status: status, exitCode: exitCode, edits: edits)))
    }

    /// The row a tool call gets. omp's tools: `bash`, `read`, `write`, `edit` (one string of
    /// hashline operations headed by `[path#tag]`), `grep`, `glob`, `find`, `ast_grep`,
    /// `ast_edit`, `web_search`, `task` (its subagents), and MCP tools named
    /// `mcp__<server>_<tool>` (omp's own) or `mcp__<server>__<tool>` (the ones Tivano
    /// registers).
    private func describe(name: String, args: JSONValue) -> (kind: ToolCall.Kind, title: String, detail: String?) {
        let pretty = args.isNull || args.compactString == "{}" ? nil : args.prettyString
        switch name {
        case "bash":
            return (.command, ToolTitles.unwrapShell(args["command"]?.string ?? "bash"), nil)
        case "eval":
            return (.command, "eval", pretty)
        case "read":
            return (.read, ToolTitles.relativePath(args["path"]?.string ?? name, to: workingDirectory), nil)
        case "write":
            // A write to `xd://<tool>` is how omp calls a tool an extension registered (an MCP
            // server's, here): the content is that tool's arguments, and nothing is written.
            if let device = args["path"]?.string.flatMap(Self.toolDevice) {
                return describe(name: device, args: JSONValue.parse(args["content"]?.string ?? "") ?? .null)
            }
            return (.edit, ToolTitles.relativePath(args["path"]?.string ?? name, to: workingDirectory), nil)
        case "edit", "ast_edit":
            let path = args["path"]?.string ?? Self.editedPath(args["input"]?.string)
            return (.edit, path.map { ToolTitles.relativePath($0, to: workingDirectory) } ?? name, nil)
        case "grep", "ast_grep":
            return (.search, args["pattern"]?.string ?? args["pat"]?.string ?? name, nil)
        case "glob", "find":
            return (.search, args["pattern"]?.string ?? args["path"]?.string ?? name, nil)
        case "web_search":
            return (.web, args["query"]?.string ?? name, nil)
        case "task":
            let names = (args["tasks"]?.array ?? []).compactMap { $0["name"]?.string }
            return (.other, names.isEmpty ? "task" : names.joined(separator: ", "), nil)
        case _ where name.hasPrefix("mcp__"):
            let rest = String(name.dropFirst("mcp__".count))
            let parts = rest.contains("__") ? rest.components(separatedBy: "__") : rest.split(separator: "_", maxSplits: 1).map(String.init)
            let title = parts.count > 1 ? "\(parts[0]) · \(parts[1...].joined(separator: "__"))" : rest
            return (.mcp, title, pretty)
        default:
            return (.other, name, pretty)
        }
    }

    /// The file named in the `[path#tag]` header of an edit's hashline input.
    private static func editedPath(_ input: String?) -> String? {
        input?.firstMatch(of: #/\[([^\]#]+)#[0-9A-Za-z]+\]/#).map { String($0.1) }
    }

    /// Conservative canonical subset of v18.8.0 parseXdUrl; topics/query/fragment are not devices.
    private static func toolDevice(_ path: String) -> String? {
        guard path.wholeMatch(of: #/xd:\/\/([A-Za-z0-9_-]+)/#) != nil else { return nil }
        return String(path.dropFirst("xd://".count))
    }

    private static func approvalKind(toolName: String, args: JSONValue, path: String? = nil) -> ApprovalRequest.Kind {
        let devicePath = path ?? args["path"]?.string
        let device = toolName == "write" ? devicePath.flatMap(toolDevice) : nil
        let name = device ?? toolName
        if name == "bash" || name == "eval" { return .command }
        // Even malformed device writes cannot inherit file-change auto acceptance.
        if device != nil { return ["write", "edit", "ast_edit", "notebook"].contains(name) ? .fileChange : .tool }
        if toolName == "write", devicePath?.trimmed.lowercased().hasPrefix("xd://") == true { return .tool }
        return ["write", "edit", "ast_edit", "notebook"].contains(name) ? .fileChange : .tool
    }

    private func absolute(_ path: String) -> String {
        path.hasPrefix("/") ? path : workingDirectory + "/" + path
    }

    /// The finished edit as the file before against after. A `write` is the snapshot taken
    /// as it started against the content written; an `edit` carries both texts in its result.
    private func editDiff(name: String, args: JSONValue, details: JSONValue, id: String) -> [FileEdit]? {
        switch name {
        case "write":
            guard let path = args["path"]?.string, Self.toolDevice(path) == nil, let content = args["content"]?.string else { return nil }
            return [Self.unifiedDiff(path: ToolTitles.relativePath(absolute(path), to: workingDirectory), old: editSnapshots.text(id), new: content)]
        case "edit", "ast_edit":
            guard let old = details["oldText"]?.string, let new = details["newText"]?.string,
                  let path = details["path"]?.string ?? args["path"]?.string ?? Self.editedPath(args["input"]?.string) else { return nil }
            return [Self.unifiedDiff(path: ToolTitles.relativePath(absolute(path), to: workingDirectory), old: old, new: new)]
        default:
            return nil
        }
    }

    private static func unifiedDiff(path: String, old: String, new: String) -> FileEdit {
        let body = old.components(separatedBy: "\n").map { "-\($0)" }
            + new.components(separatedBy: "\n").map { "+\($0)" }
        let diff = (["--- a/\(path)", "+++ b/\(path)"] + body).joined(separator: "\n")
        let stats = ToolTitles.diffStats(diff)
        return FileEdit(path: path, diff: diff, additions: stats.additions, deletions: stats.deletions)
    }

    /// The checklist the `todo` tool left, whole: omp answers each call with every phase and
    /// task as they stand (a call through `xd://todo` nests it one level down). Tivano's
    /// card has three states: omp's blocked task waits as pending, and an abandoned one is
    /// settled, as omp itself counts it.
    static func todoSteps(_ details: JSONValue) -> [TodoStep]? {
        guard let phases = (details["phases"] ?? details["xdev"]?["inner"]?["phases"])?.array else { return nil }
        var steps: [TodoStep] = []
        for phase in phases {
            // One phase is the whole list; several name where each task belongs.
            let prefix = phases.count > 1 ? (phase["name"]?.string).map { "\($0): " } ?? "" : ""
            for task in phase["tasks"]?.array ?? [] {
                guard let content = task["content"]?.string else { continue }
                let status = task["status"]?.string
                let blocked = status == "blocked"
                    ? " " + (task["blocker"]?.string.map { String(format: String(localized: "(blocked: %@)"), $0) } ?? String(localized: "(blocked)"))
                    : ""
                let state: TodoStep.Status = switch status {
                case "in_progress": .active
                case "completed", "abandoned": .done
                default: .pending
                }
                steps.append(TodoStep(text: prefix + content + blocked, status: state))
            }
        }
        return steps
    }

    // MARK: - Turn end

    private func finishTurn() {
        guard turnActive else { return }
        turnActive = false
        promptID = nil
        clearRequests()
        let error = turnError
        turnError = nil
        // Plan mode refuses every tool that is not a read: its final reply is the plan.
        if interactionMode == .plan, error == nil, !interruptRequested,
           !lastReplyText.trimmed.isEmpty {
            onEvent?(.planCompleted(id: "\(launchID)-plan-\(turnCounter)", markdown: lastReplyText))
        }
        if interruptRequested {
            onEvent?(.turnCompleted(status: .interrupted, error: nil))
        } else if let error {
            // A spent usage limit says so first, with the time it comes back when the provider gave one.
            let limit = spentLimit(error)
            if limit.isSpent { onEvent?(.usageLimit(resetsAt: limit.resetsAt)) }
            onEvent?(.turnCompleted(status: .failed, error: error))
        } else {
            onEvent?(.turnCompleted(status: .completed, error: nil))
        }
        interruptRequested = false
    }

    /// Whether the turn failed on a spent usage limit, and when it resets if anything said.
    /// omp marks such an error itself (its error id carries a usage-limit flag); the wording
    /// and the status catch what it leaves unmarked. omp retries short limits on its own,
    /// so an error that gets here ran out of retries. The time comes from
    /// the provider's words, or the app reads the plan's windows when there is none.
    private func spentLimit(_ error: String) -> (isSpent: Bool, resetsAt: Date?) {
        let text = ([error] + failure.texts).joined(separator: "\n")
        let flagged = (failure.errorID ?? 0) & Self.usageLimitFlag != 0
        guard flagged || UsageLimitSignal.matches(text) || failure.status == 429 || failure.status == 402 else { return (false, nil) }
        return (true, UsageLimitSignal.resetTime(in: text))
    }

    // MARK: - Extension UI

    private func handleExtensionUI(_ message: JSONValue) {
        guard let id = message["id"]?.string ?? message["requestId"]?.string,
              let method = message["method"]?.string else { return }
        let params = message["params"] ?? message
        switch method {
        case "select":
            handleSelect(id: id, params: params)
        case "confirm":
            let title = params["title"]?.string ?? "omp"
            let prompt = [title, params["message"]?.string].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
            pendingQuestions[id] = "confirm"
            onEvent?(.question(QuestionRequest(id: id, questions: [
                QuestionRequest.Question(
                    id: id,
                    header: "omp",
                    prompt: prompt,
                    choices: [QuestionRequest.Choice(label: String(localized: "Yes"), detail: nil), QuestionRequest.Choice(label: String(localized: "No"), detail: nil)],
                    allowsMultiple: false,
                    allowsOther: false,
                    isSecret: false
                ),
            ])))
        case "input", "editor":
            pendingQuestions[id] = method
            onEvent?(.question(QuestionRequest(id: id, questions: [
                QuestionRequest.Question(
                    id: id,
                    header: "omp",
                    prompt: params["title"]?.string ?? "omp",
                    choices: [],
                    allowsMultiple: false,
                    allowsOther: true,
                    isSecret: false
                ),
            ])))
        case "cancel":
            // omp withdrew a dialog (a timeout, an abort): the question or approval is moot.
            guard let target = params["targetId"]?.string ?? message["id"]?.string else { return }
            let hadApproval = pendingApprovals.removeValue(forKey: target) != nil
            let hadQuestion = pendingQuestions.removeValue(forKey: target) != nil
            toolsAwaitingAnswer = toolsAwaitingAnswer.filter { $0.value != target }
            if hadApproval || hadQuestion { onEvent?(.requestResolved(id: target)) }
        case "notify":
            let text = params["message"]?.string ?? ""
            let prefix = "tivano-default-model "
            if !started, text.hasPrefix(prefix) {
                if let value = JSONValue.parse(String(text.dropFirst(prefix.count))),
                   let provider = value["provider"]?.string, !provider.isEmpty,
                   let id = value["id"]?.string, !id.isEmpty {
                    defaultModel = "\(provider)/\(id)"
                }
                return
            }
            let level: Notice.Level = switch params["notifyType"]?.string {
            case "warning": .warning
            case "error": .error
            default: .info
            }
            onEvent?(.notice(Notice(level: level, message: params["message"]?.string ?? String(localized: "omp sent a notification."))))
        default:
            // setStatus, setWidget, setTitle, set_editor_text, open_url and the like draw omp's
            // own interface, which this app has no use for.
            break
        }
    }

    private func handleSelect(id: String, params: JSONValue) {
        let title = params["title"]?.string ?? ""
        // The gate extension names the call it asks about exactly: its tool, arguments and id.
        if title.hasPrefix(Self.gatePrefix) {
            guard let payload = JSONValue.parse(String(title.dropFirst(Self.gatePrefix.count))),
                  let name = payload["toolName"]?.string, !name.isEmpty,
                  let args = payload["input"], args.object != nil,
                  let toolID = payload["toolCallId"]?.string, !toolID.isEmpty,
                  payload["kind"]?.string == Self.approvalKind(toolName: name, args: args).grantKey else {
                answer(id, "Deny")
                return
            }
            // The payload's kind must agree with the actual tool/device; it cannot widen a grant.
            if let actualName = toolNames[toolID], let actualArgs = toolInputs[toolID] {
                let device = actualName == "write" ? actualArgs["path"]?.string.flatMap(Self.toolDevice) : nil
                guard (actualName == name || device == name),
                      Self.approvalKind(toolName: actualName, args: actualArgs) == Self.approvalKind(toolName: name, args: args) else {
                    answer(id, "Deny")
                    return
                }
            }
            toolsAwaitingAnswer[toolID] = id
            decide(
                id: id, toolName: name, args: args, toolID: toolID,
                promptDetail: args["path"]?.string.map { String(format: String(localized: "Path: %@"), $0) },
                promptCommand: args["command"]?.string
            )
            return
        }
        guard title.hasPrefix(Self.approvalPrefix) else {
            pendingQuestions[id] = "select"
            onEvent?(.question(QuestionRequest(id: id, questions: [
                QuestionRequest.Question(
                    id: id,
                    header: "omp",
                    prompt: title,
                    choices: (params["options"]?.array ?? []).compactMap(\.string).map { QuestionRequest.Choice(label: $0, detail: nil) },
                    allowsMultiple: false,
                    allowsOther: false,
                    isSecret: false
                ),
            ])))
            return
        }
        // omp's own prompt, for a tool that declares it must be asked about (the gate asks for
        // the rest): "Allow tool: bash\nCommand: rm -rf build", the tool's name, then what it was asked.
        let lines = title.dropFirst(Self.approvalPrefix.count).split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        let toolName = lines.first.map(String.init) ?? "tool"
        let promptDetail = lines.count > 1 ? String(lines[1]) : nil
        // What the prompt says is asked is what will run, so a decision rests on it and not on
        // the call it is matched to below.
        let promptCommand = Self.promptCommand(promptDetail)

        // The tool was announced a moment before it asked, with its arguments. Several calls of
        // one tool can ask in a row, so a call that has been answered is never matched again.
        let candidates = runningTools.filter { toolNames[$0] == toolName && toolsAwaitingAnswer[$0] == nil }
        let toolID = candidates.first { toolInputs[$0]?["command"]?.string?.trimmed == promptCommand?.trimmed && promptCommand != nil } ?? candidates.first
        if let toolID { toolsAwaitingAnswer[toolID] = id }
        decide(id: id, toolName: toolName, args: toolID.flatMap { toolInputs[$0] } ?? .null, toolID: toolID, promptDetail: promptDetail, promptCommand: promptCommand)
    }

    /// Answers a call the gate or omp asked about, or puts it to the user: nothing that asks
    /// runs in a read-only turn, a kind the user approved for the session or (for file
    /// changes) Auto-accept edits goes ahead, and the rest is the user's to decide.
    private func decide(id: String, toolName: String, args: JSONValue, toolID: String?, promptDetail: String?, promptCommand: String?) {
        let path = args["path"]?.string ?? Self.promptPath(promptDetail)
        let device = toolName == "write" ? path.flatMap(Self.toolDevice) : nil
        let kind = Self.approvalKind(toolName: toolName, args: args, path: path)

        // task subagents never ask about their own tools, so only unrestricted sessions allow them.
        if toolName == "task" || device == "task" {
            answer(id, configuration.hydra == nil && runtimeMode == .fullAccess && interactionMode != .plan && !isFinalReport ? "Approve" : "Deny")
            return
        }
        // Plan mode and a final report are read-only turns: nothing that asks may run.
        if interactionMode == .plan || isFinalReport {
            answer(id, "Deny")
            return
        }
        if runtimeMode == .fullAccess || sessionGrants.contains(kind.grantKey) {
            answer(id, "Approve")
            return
        }
        if runtimeMode == .autoAcceptEdits, kind == .fileChange {
            answer(id, "Approve")
            return
        }

        let effectiveArgs = device.flatMap { _ in JSONValue.parse(args["content"]?.string ?? "") } ?? args
        let described = describe(name: device ?? toolName, args: effectiveArgs)
        let effectiveCommand = effectiveArgs["command"]?.string ?? promptCommand
        let callTitle: String
        let callDetail: String?
        switch kind {
        case .command:
            callTitle = ToolTitles.unwrapShell(effectiveCommand ?? described.title)
            callDetail = effectiveCommand ?? described.detail
        case .fileChange:
            callTitle = described.title
            callDetail = promptDetail
        case .tool, .permissions, .plan:
            callTitle = described.title
            callDetail = described.detail ?? promptDetail
        }
        pendingApprovals[id] = ApprovalRequest(
            id: id,
            kind: kind,
            title: callTitle,
            detail: callDetail,
            options: [
                .init(id: "allow", title: String(localized: "Approve"), role: .approve),
                .init(id: "always", title: String(localized: "Approve for session"), role: .approveAlways),
                .init(id: "deny", title: String(localized: "Decline"), role: .decline),
            ],
            toolItemID: toolID
        )
        onEvent?(.approval(pendingApprovals[id]!))
    }

    private func answer(_ id: String, _ value: String) {
        process?.send(["type": .string("extension_ui_response"), "id": .string(id), "value": .string(value)])
    }

    /// The command an approval prompt asks about: its "Command:" line and any lines after it,
    /// since a command can run over several.
    private static func promptCommand(_ detail: String?) -> String? {
        guard let lines = detail?.components(separatedBy: "\n"),
              let index = lines.firstIndex(where: { $0.hasPrefix("Command: ") }) else { return nil }
        return ([String(lines[index].dropFirst("Command: ".count))] + lines[(index + 1)...]).joined(separator: "\n")
    }

    /// The path an approval prompt asks about, from its "Path:" line.
    private static func promptPath(_ detail: String?) -> String? {
        detail?.components(separatedBy: "\n").first { $0.hasPrefix("Path: ") }.map { String($0.dropFirst("Path: ".count)) }
    }

    private func clearRequests() {
        let ids = Set(pendingApprovals.keys).union(pendingQuestions.keys)
        pendingApprovals.removeAll()
        pendingQuestions.removeAll()
        toolsAwaitingAnswer.removeAll()
        for id in ids { onEvent?(.requestResolved(id: id)) }
    }

    private func didClose(status: Int32) {
        pendingResponses.resolveAll(.null)
        clearRequests()
        let tail = TextCleanup.lastLines(process?.errorTail ?? "")
        process = nil
        removeLaunchFiles()
        if turnActive {
            turnActive = false
            onEvent?(.turnCompleted(status: interruptRequested ? .interrupted : .failed, error: tail.flatMap { $0.isEmpty ? nil : $0 }))
        }
        guard !stopped else { return }
        started = false
        if status == 0 {
            onEvent?(.exited(error: nil))
        } else {
            let suffix = (tail ?? "").isEmpty ? "" : "\n" + (tail ?? "")
            onEvent?(.exited(error: String(format: String(localized: "omp exited with status %d%@"), status, suffix)))
        }
    }
}
