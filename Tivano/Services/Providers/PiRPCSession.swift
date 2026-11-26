import Foundation

/// Shared JSONL RPC session runtime for Pi (`pi`) and omp (`omp`).
///
/// Both harnesses speak the same line-framed stdio RPC protocol (`prompt`,
/// `get_state`, `abort`, `compact`, `message_start` / `message_update` /
/// `message_end`, `tool_execution_*`, and `extension_ui_request` /
/// `extension_ui_response`), with a Tivano gate file updated before each turn.
/// Subclasses supply a `Config` and override the real per-harness hooks:
/// launch arguments & startup handshake, turn preparation (model/effort/mode
/// switching), gate fields, tool description/diffing, approval matching, and
/// provider-specific stream/turn-end events.
@MainActor
class PiRPCSession: ProviderSession {
    struct Config {
        let displayName: String
        let approveValue: String
        let approveAlwaysValue: String
        let confirmYesLabel: () -> String
        let confirmNoLabel: () -> String
        let missingSessionError: () -> String
        let startFailureError: (String) -> String
        let busyTurnError: () -> String
        let extensionErrorFallback: () -> String
        let notificationFallback: () -> String
        let exitedError: (Int32, String) -> String
    }

    let config: Config
    var onEvent: ((ProviderEvent) -> Void)?

    let configuration: SessionConfiguration
    var process: StdioProcess?
    var readTask: Task<Void, Never>?
    /// The session file path, taken from `configuration.resumeID`.
    var sessionID: String?
    var started = false
    var stopped = false
    var runtimeMode: RuntimeMode
    var interactionMode: InteractionMode
    var model: String?
    var effort: String?

    var turnActive = false
    var preparationID: UUID?
    var interruptRequested = false
    /// Namespaces ids per launch, so a resumed thread never streams into an old entry.
    let launchID: String
    var stream: StreamedTextTracker
    /// The model's context ceiling, from the session state's model.
    var contextWindow: Int?
    var gateURL: URL?
    var pendingApprovals: [String: ApprovalRequest] = [:]
    /// `extension_ui_request` ids by method, for the app's questions.
    var pendingQuestions: [String: String] = [:]
    /// Approval kinds granted for the rest of the session ("Approve for session").
    var sessionGrants: Set<String> = []
    var toolNames: [String: String] = [:]
    var toolInputs: [String: JSONValue] = [:]
    /// Files a `write` is about to replace, read as the call starts, so the row's
    /// diff is the file before against the content written.
    var editSnapshots = EditSnapshots()
    var turnError: String?
    /// The turn's last reply, which plan mode hands over as the plan.
    var lastReplyText = ""
    var turnCounter = 0
    var pendingResponses = PendingReplies()
    var requestCounter = 0

    init(config: Config, configuration: SessionConfiguration) {
        self.config = config
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

    var workingDirectory: String { configuration.workingDirectory.path }

    var busyTurnError: String { config.busyTurnError() }

    // MARK: - Lifecycle

    func start() async throws -> String {
        guard let executable = configuration.executable else { throw ProviderError.notInstalled(configuration.provider) }
        try validateStart()
        if let sessionID, !FileManager.default.fileExists(atPath: sessionID) {
            throw ProviderError.failed(config.missingSessionError())
        }

        let launch: (arguments: [String], environment: [String: String])
        do {
            launch = try prepareLaunch()
        } catch {
            removeLaunchFiles()
            throw error
        }
        stopped = false

        let process = StdioProcess(
            executable: executable,
            arguments: launch.arguments,
            directory: configuration.workingDirectory,
            environment: launch.environment,
            framing: .lines
        )
        do {
            try process.start()
        } catch {
            removeLaunchFiles()
            throw ProviderError.failed(config.startFailureError(error.localizedDescription))
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

        try await completeStartup(process: process)
        started = true
        stopped = false
        return self.sessionID ?? ""
    }

    func send(_ input: TurnInput) async throws {
        guard isRunning, let process else { throw ProviderError.notRunning }
        try validateBeforeBusyCheck(input)
        guard !turnActive, preparationID == nil else { throw ProviderError.failed(busyTurnError) }
        try validateModesForTurn(input)
        let preparation = UUID()
        preparationID = preparation
        interruptRequested = false
        defer {
            if preparationID == preparation { preparationID = nil }
        }
        guard continuePreparation(preparation) else { return }
        guard try await prepareTurn(input, preparation: preparation, process: process) else { return }
        let turnNumber = turnCounter + 1
        let promptSpec = makePromptFields(for: input, turnNumber: turnNumber)
        var fields = promptSpec.fields
        let promptID = promptSpec.promptID
        let encodedImages = await Attachment.base64Images(input.images)
        guard continuePreparation(preparation) else { return }
        let images: [JSONValue] = encodedImages.map { image, base64 in
            ["type": "image", "data": .string(base64), "mimeType": .string(image.mimeType)]
        }
        if !images.isEmpty { fields["images"] = .array(images) }
        let payload = await Self.encodePrompt(.object(fields))
        guard continuePreparation(preparation) else { return }
        guard payload.count <= 32 * 1024 * 1024 else {
            throw ProviderError.failed(AppText.localized("The agent input queue exceeded 32 MB or the connection closed."))
        }
        preparationID = nil
        turnActive = true
        turnError = nil
        turnCounter = turnNumber
        lastReplyText = ""
        toolNames.removeAll()
        toolInputs.removeAll()
        editSnapshots.removeAll()
        willStartTurn(input: input, promptID: promptID)
        process.write(payload)
        onEvent?(.turnStarted(providerTurnID: nil))
    }

    @concurrent
    private static func encodePrompt(_ prompt: JSONValue) async -> Data {
        prompt.data() + Data([0x0A])
    }

    func continuePreparation(_ id: UUID) -> Bool {
        guard preparationID == id, !stopped else { return false }
        if Task.isCancelled || interruptRequested {
            stop()
            onEvent?(.turnCompleted(status: .interrupted, error: nil))
            return false
        }
        return isRunning
    }

    func interrupt() async {
        interruptRequested = true
        if preparationID != nil {
            stop()
            onEvent?(.turnCompleted(status: .interrupted, error: nil))
            return
        }
        process?.send(["type": .string("abort")])
    }

    func compact() async throws {
        guard isRunning, let process else { throw ProviderError.notRunning }
        process.send(["type": .string("compact")])
    }

    func stop() {
        stopped = true
        preparationID = nil
        started = false
        pendingResponses.resolveAll(.null)
        clearRequests()
        process?.terminate()
        process = nil
        readTask?.cancel()
        readTask = nil
        removeLaunchFiles()
    }

    func stopAgent(_ id: String) async -> Bool { false }

    func resolveApproval(_ requestID: String, optionID: String) {
        guard let request = pendingApprovals.removeValue(forKey: requestID) else { return }
        let value: String
        switch request.options.first(where: { $0.id == optionID })?.role {
        case .approveAlways:
            value = config.approveAlwaysValue
            sessionGrants.insert(request.kind.grantKey)
        case .decline, .cancel, nil:
            value = "Deny"
        case .approve:
            value = config.approveValue
        }
        didResolveApproval(request)
        sendUIResponse(requestID, value: value)
        onEvent?(.requestResolved(id: requestID))
    }

    func answerQuestion(_ requestID: String, answers: [String: [String]]) {
        guard let method = pendingQuestions.removeValue(forKey: requestID) else { return }
        let texts = answers.values.flatMap { $0 }
        if texts.isEmpty {
            process?.send(["type": .string("extension_ui_response"), "id": .string(requestID), "cancelled": true])
        } else if method == "confirm" {
            process?.send(["type": .string("extension_ui_response"), "id": .string(requestID), "confirmed": .bool(texts.first == config.confirmYesLabel())])
        } else {
            sendUIResponse(requestID, value: texts.first ?? "")
        }
        onEvent?(.requestResolved(id: requestID))
    }

    // MARK: - Requests & Helpers

    /// Writes a request line with a fresh id and resumes with the `response` that
    /// carries it, or `.null` after the timeout.
    func request(_ fields: [String: JSONValue], timeout: Duration = .seconds(30)) async -> JSONValue {
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

    /// The gate the extension reads before every tool call.
    func writeGate(finalReport: Bool) throws {
        guard let gateURL else { throw ProviderError.notRunning }
        var fields: [String: JSONValue] = [
            "runtimeMode": .string(runtimeMode.rawValue),
            "interactionMode": .string(interactionMode.rawValue),
            "finalReport": .bool(finalReport),
        ]
        for (key, value) in extraGateFields(finalReport: finalReport) {
            fields[key] = value
        }
        try JSONValue.object(fields).data().write(to: gateURL, options: .atomic)
    }

    func applySessionState(_ data: JSONValue) {
        if let file = data["sessionFile"]?.string, !file.isEmpty {
            sessionID = file
        } else if let id = data["sessionId"]?.string, !id.isEmpty {
            sessionID = id
        }
        contextWindow = data["model"]?["contextWindow"]?.int
    }

    func emitCommands(_ data: JSONValue, excluding excluded: String? = nil) {
        guard let entries = data["commands"]?.array else { return }
        let commands = entries.compactMap { entry -> SlashCommand? in
            guard let name = entry["name"]?.string, name != excluded else { return nil }
            return SlashCommand(name: name, detail: entry["description"]?.string ?? "")
        }
        if !commands.isEmpty { onEvent?(.commands(commands)) }
    }

    func sendUIResponse(_ id: String, value: String) {
        process?.send(["type": .string("extension_ui_response"), "id": .string(id), "value": .string(value)])
    }

    func emitSelectQuestion(id: String, title: String, params: JSONValue) {
        let options = (params["options"]?.array ?? []).compactMap(\.string)
        pendingQuestions[id] = "select"
        onEvent?(.question(QuestionRequest(id: id, questions: [
            QuestionRequest.Question(
                id: id,
                header: config.displayName,
                prompt: title,
                choices: options.map { QuestionRequest.Choice(label: $0, detail: nil) },
                allowsMultiple: false,
                allowsOther: false,
                isSecret: false
            ),
        ])))
    }

    func clearRequests() {
        let ids = Set(pendingApprovals.keys).union(pendingQuestions.keys)
        pendingApprovals.removeAll()
        pendingQuestions.removeAll()
        for id in ids { onEvent?(.requestResolved(id: id)) }
    }

    func removeLaunchFiles() {
        if let gateURL {
            try? FileManager.default.removeItem(at: gateURL)
            self.gateURL = nil
        }
    }

    /// A minimal unified diff of the old text against the new: a `---`/`+++` header,
    /// then the old lines prefixed with `-` and the new lines prefixed with `+`.
    static func unifiedDiff(path: String, old: String, new: String, omitEmptyLines: Bool = false) -> FileEdit {
        let oldLines = old.components(separatedBy: "\n")
        let newLines = new.components(separatedBy: "\n")
        let body = (omitEmptyLines ? oldLines.filter { !$0.isEmpty } : oldLines).map { "-\($0)" }
            + (omitEmptyLines ? newLines.filter { !$0.isEmpty } : newLines).map { "+\($0)" }
        let diff = (["--- a/\(path)", "+++ b/\(path)"] + body).joined(separator: "\n")
        let stats = ToolTitles.diffStats(diff)
        return FileEdit(path: path, diff: diff, additions: stats.additions, deletions: stats.deletions)
    }

    // MARK: - Stream

    private func handle(_ message: JSONValue) {
        guard let type = message["type"]?.string else { return }
        switch type {
        case "response":
            guard let id = message["id"]?.string else { return }
            if pendingResponses.resolve(id, message) { return }
            handleUnmatchedResponse(id: id, message: message)
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
            guard let id = message["toolCallId"]?.string, !isHiddenToolCall(id) else { return }
            let text = ToolText.blocks(message["partialResult"]?["content"])
            if !text.isEmpty { onEvent?(.toolOutput(id: id, text: text)) }
        case "tool_execution_end":
            handleToolEnd(message)
        case "extension_error":
            onEvent?(.notice(Notice(level: .error, message: message["error"]?.string ?? config.extensionErrorFallback())))
        case "extension_ui_request":
            handleExtensionUI(message)
        default:
            handleProviderEvent(type: type, message: message)
        }
    }

    private func handleUpdate(_ message: JSONValue) {
        let event = message["assistantMessageEvent"] ?? message["event"] ?? .null
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
        reportUpdateUsage(message: message, event: event)
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
        didFinishAssistantMessage(message)
    }

    private func handleToolStart(_ message: JSONValue) {
        guard let id = message["toolCallId"]?.string, let name = message["toolName"]?.string else { return }
        let args = message["args"] ?? message["input"] ?? .null
        toolNames[id] = name
        toolInputs[id] = args
        guard willStartTool(id: id, name: name, args: args) else { return }
        onEvent?(.toolStarted(id: id, call: describeTool(name: name, args: args)))
    }

    private func handleToolEnd(_ message: JSONValue) {
        guard let id = message["toolCallId"]?.string else { return }
        let result = message["result"] ?? .null
        let details = result["details"] ?? .null
        let isError = message["isError"]?.bool == true || result["isError"]?.bool == true
        if consumeHiddenToolEnd(id: id, details: details, isError: isError) { return }
        let output = ToolText.blocks(result["content"])
        let status: ToolCall.Status = !isError ? .completed
            : isDeclinedToolOutput(output) ? .declined : .failed
        let exitCode = details["exitCode"]?.int
        var edits: [FileEdit]? = nil
        if let name = toolNames[id], let args = toolInputs[id] {
            edits = editDiff(name: name, args: args, details: details, id: id, isError: isError)
        }
        editSnapshots.discard(id)
        let displayOutput = formatToolOutput(output, isError: isError)
        onEvent?(.toolUpdated(id: id, update: ToolUpdate(output: displayOutput.isEmpty ? nil : displayOutput, status: status, exitCode: exitCode, edits: edits)))
    }

    func finishTurn() {
        guard turnActive else { return }
        turnActive = false
        willFinishTurn()
        let error = turnError
        turnError = nil
        // Plan mode is the gate's read-only turn: its final reply is the plan.
        if interactionMode == .plan, error == nil, !interruptRequested,
           !lastReplyText.trimmed.isEmpty {
            onEvent?(.planCompleted(id: "\(launchID)-plan-\(turnCounter)", markdown: lastReplyText))
        }
        if interruptRequested {
            onEvent?(.turnCompleted(status: .interrupted, error: nil))
        } else if let error {
            willReportTurnError(error)
            onEvent?(.turnCompleted(status: .failed, error: error))
        } else {
            onEvent?(.turnCompleted(status: .completed, error: nil))
        }
        interruptRequested = false
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
            let title = params["title"]?.string ?? config.displayName
            let prompt = [title, params["message"]?.string].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
            pendingQuestions[id] = "confirm"
            onEvent?(.question(QuestionRequest(id: id, questions: [
                QuestionRequest.Question(
                    id: id,
                    header: config.displayName,
                    prompt: prompt,
                    choices: [
                        QuestionRequest.Choice(label: config.confirmYesLabel(), detail: nil),
                        QuestionRequest.Choice(label: config.confirmNoLabel(), detail: nil),
                    ],
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
                    header: config.displayName,
                    prompt: params["title"]?.string ?? config.displayName,
                    choices: [],
                    allowsMultiple: false,
                    allowsOther: true,
                    isSecret: false
                ),
            ])))
        case "cancel":
            // Withdrawn dialog (timeout or abort): the question or approval is moot.
            guard let target = params["targetId"]?.string ?? message["id"]?.string else { return }
            let hadApproval = pendingApprovals.removeValue(forKey: target) != nil
            let hadQuestion = pendingQuestions.removeValue(forKey: target) != nil
            didCancelRequest(target)
            if hadApproval || hadQuestion { onEvent?(.requestResolved(id: target)) }
        case "notify":
            if handleCustomNotification(params) { return }
            let level: Notice.Level = switch params["notifyType"]?.string {
            case "warning": .warning
            case "error": .error
            default: .info
            }
            onEvent?(.notice(Notice(level: level, message: params["message"]?.string ?? config.notificationFallback())))
        default:
            break
        }
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
            onEvent?(.exited(error: config.exitedError(status, suffix)))
        }
    }

    // MARK: - Subclass Hooks

    func validateStart() throws {}

    func prepareLaunch() throws -> (arguments: [String], environment: [String: String]) {
        ([], configuration.environment)
    }

    func completeStartup(process: StdioProcess) async throws {}

    func validateBeforeBusyCheck(_ input: TurnInput) throws {}

    func validateModesForTurn(_ input: TurnInput) throws {}

    func prepareTurn(_ input: TurnInput, preparation: UUID, process: StdioProcess) async throws -> Bool { true }

    func makePromptFields(for input: TurnInput, turnNumber: Int) -> (fields: [String: JSONValue], promptID: String?) {
        (["type": .string("prompt"), "message": .string(input.text)], nil)
    }

    func willStartTurn(input: TurnInput, promptID: String?) {}

    func extraGateFields(finalReport: Bool) -> [String: JSONValue] { [:] }

    func didResolveApproval(_ request: ApprovalRequest) {}

    func handleUnmatchedResponse(id: String, message: JSONValue) {}

    func handleProviderEvent(type: String, message: JSONValue) {}

    func reportUpdateUsage(message: JSONValue, event: JSONValue) {}

    func didFinishAssistantMessage(_ message: JSONValue) {}

    func isHiddenToolCall(_ id: String) -> Bool { false }

    func willStartTool(id: String, name: String, args: JSONValue) -> Bool {
        if name == "write", let path = args["path"]?.string {
            editSnapshots.capture(id, path: path)
        }
        return true
    }

    func describeTool(name: String, args: JSONValue) -> ToolCall {
        ToolCall(kind: .other, title: name, detail: nil)
    }

    func consumeHiddenToolEnd(id: String, details: JSONValue, isError: Bool) -> Bool { false }

    func isDeclinedToolOutput(_ output: String) -> Bool { false }

    func formatToolOutput(_ output: String, isError: Bool) -> String { output }

    func editDiff(name: String, args: JSONValue, details: JSONValue, id: String, isError: Bool) -> [FileEdit]? { nil }

    func willFinishTurn() {}

    func willReportTurnError(_ error: String) {}

    func didCancelRequest(_ target: String) {}

    func handleCustomNotification(_ params: JSONValue) -> Bool { false }

    func handleSelect(id: String, params: JSONValue) {
        emitSelectQuestion(id: id, title: params["title"]?.string ?? "", params: params)
    }
}
