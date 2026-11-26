import Foundation

/// Runs omp over JSONL RPC; only the matching prompt_result completes an agent turn.
@MainActor
final class OmpSession: PiRPCSession {
    private static let config = Config(
        displayName: "omp",
        approveValue: "Approve",
        approveAlwaysValue: "Approve",
        confirmYesLabel: { String(localized: "Yes") },
        confirmNoLabel: { String(localized: "No") },
        missingSessionError: { String(localized: "omp no longer has this conversation; starting a new one.") },
        startFailureError: { String(format: String(localized: "omp could not start: %@"), $0) },
        busyTurnError: { String(localized: "omp is still on the last turn.") },
        extensionErrorFallback: { String(localized: "omp reported an extension error.") },
        notificationFallback: { String(localized: "omp sent a notification.") },
        exitedError: { String(format: String(localized: "omp exited with status %d%@"), $0, $1) }
    )

    /// Resolved from OMP's settings-backed @default role, never the resumed session model.
    private var defaultModel: String?
    private var activeModel: String?
    /// This session's settings overlay (see `OmpCLI.writeLaunchSettings`), removed on stop.
    private var settingsFile: URL?
    /// The prompt whose `prompt_result` ends the turn.
    private var promptID: String?
    private var isFinalReport = false
    /// Calls that have started and not ended, oldest first: the approval prompt names its
    /// tool but not the call, so it is matched to the oldest call of that name without one.
    private var runningTools: [String] = []
    private var toolsAwaitingAnswer: [String: String] = [:]
    /// Calls shown as something other than a row (the todo list).
    private var hiddenCalls: Set<String> = []
    /// What the turn's failed model requests said, for telling a spent usage limit from any
    /// other error.
    private var failure = Failure()
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
        super.init(config: Self.config, configuration: configuration)
    }

    /// What the gate extension reads before every tool call: the app's word on this session's
    /// mode, whether this turn is a final report, and whether ordinary `task` calls may run.
    /// Hydra always disables `task`; without Hydra only Full access permits it. The mode is
    /// the session's own, fixed for its life.
    override func extraGateFields(finalReport: Bool) -> [String: JSONValue] {
        [
            "allowTask": .bool(configuration.hydra == nil && runtimeMode == .fullAccess && interactionMode != .plan && !finalReport),
        ]
    }

    /// Appended to omp's system prompt: the lead's Hydra policy with a team and plan
    /// mode's rule. omp keeps no copy of it in the conversation, so a resumed thread
    /// gets the current one.
    private var systemPrompt: String {
        var parts: [String] = []
        if let hydra = configuration.hydra {
            parts.append(HydraPrompts.fallbackPolicy(hydra))
        }
        if interactionMode == .plan { parts.append(Self.planPrompt) }
        return parts.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    // MARK: - Lifecycle Hooks

    override func validateStart() throws {
        guard configuration.provider.supports(runtimeMode) else {
            throw ProviderError.failed(String(localized: "omp does not support Auto permissions."))
        }
        try validateSelection(model: model, effort: effort)
    }

    override func prepareLaunch() throws -> (arguments: [String], environment: [String: String]) {
        let extensionURL = try OmpCLI.installExtension()
        let settings = try OmpCLI.writeLaunchSettings(id: launchID)
        settingsFile = settings
        gateURL = try OmpCLI.gateFile(id: launchID)
        try writeGate(finalReport: false)

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
        return (arguments, environment)
    }

    override func completeStartup(process: StdioProcess) async throws {
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
        applySessionState(data)
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

        emitCommands(commandsResponse["data"] ?? commandsResponse, excluding: OmpCLI.gateCommand)
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

    private func selectModel(_ selection: String?, preparation: UUID? = nil) async throws {
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
        try Task.checkCancellation()
        guard !stopped, preparation == nil || preparationID == preparation else { throw CancellationError() }
        guard !response.isNull, response["success"]?.bool != false else {
            throw ProviderError.failed(String(format: String(localized: "omp could not switch to %@. %@"), wanted, response["error"]?.string ?? "").trimmed)
        }
        activeModel = selector
        model = wanted
        contextWindow = (response["data"] ?? response)["contextWindow"]?.int
    }

    override func validateBeforeBusyCheck(_ input: TurnInput) throws {
        try validateSelection(model: input.model, effort: input.effort)
    }

    override func validateModesForTurn(_ input: TurnInput) throws {
        guard input.runtimeMode == runtimeMode, input.interactionMode == interactionMode else {
            throw ProviderError.failed(String(localized: "Restart the omp session to change its permission or interaction mode."))
        }
    }

    override func prepareTurn(_ input: TurnInput, preparation: UUID, process: StdioProcess) async throws -> Bool {
        do {
            try await selectModel(input.model, preparation: preparation)
        } catch {
            guard continuePreparation(preparation) else { return false }
            throw error
        }
        guard continuePreparation(preparation) else { return false }
        if let wanted = input.effort, !wanted.isEmpty, wanted != effort, OmpCLI.thinkingLevels.contains(wanted) {
            let response = await request(["type": .string("set_thinking_level"), "level": .string(wanted)])
            guard continuePreparation(preparation) else { return false }
            guard !response.isNull, response["success"]?.bool != false else {
                throw ProviderError.failed(response["error"]?.string ?? String(localized: "omp could not change its thinking level."))
            }
            effort = wanted
        }
        try writeGate(finalReport: input.isFinalReport)
        return true
    }

    override func makePromptFields(for input: TurnInput, turnNumber: Int) -> (fields: [String: JSONValue], promptID: String?) {
        let id = "tivano-turn-\(turnNumber)"
        let text = input.isFinalReport ? Self.finalReportPrompt + "\n\n" + input.text : input.text
        return (["type": .string("prompt"), "id": .string(id), "message": .string(text)], id)
    }

    override func willStartTurn(input: TurnInput, promptID: String?) {
        isFinalReport = input.isFinalReport
        failure = Failure()
        runningTools.removeAll()
        toolsAwaitingAnswer.removeAll()
        hiddenCalls.removeAll()
        self.promptID = promptID
    }

    override func compact() async throws {
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

    override func clearRequests() {
        toolsAwaitingAnswer.removeAll()
        super.clearRequests()
    }

    override func removeLaunchFiles() {
        if let settingsFile {
            try? FileManager.default.removeItem(at: settingsFile)
            self.settingsFile = nil
        }
        super.removeLaunchFiles()
    }

    override func didResolveApproval(_ request: ApprovalRequest) {
        if let toolID = request.toolItemID { toolsAwaitingAnswer.removeValue(forKey: toolID) }
    }

    // MARK: - Stream Hooks

    override func handleUnmatchedResponse(id: String, message: JSONValue) {
        guard id == promptID else { return }
        if message["success"]?.bool == false {
            turnError = message["error"]?.string ?? String(localized: "omp reported an error.")
            finishTurn()
        } else if message["data"]?["agentInvoked"]?.bool == false {
            // A slash command omp ran itself: no turn follows.
            finishTurn()
        }
    }

    override func handleProviderEvent(type: String, message: JSONValue) {
        switch type {
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
            emitCommands(message, excluding: OmpCLI.gateCommand)
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
        default:
            break
        }
    }

    override func reportUpdateUsage(message: JSONValue, event: JSONValue) {
        reportContext(message["message"]?["usage"])
    }

    /// The context meter: what the model was just given and said, against its window.
    private func reportContext(_ usage: JSONValue?) {
        guard let used = usage?["contextTokens"]?.int ?? usage?["totalTokens"]?.int, used > 0 else { return }
        onEvent?(.usage(ContextUsage(usedTokens: used, windowTokens: contextWindow)))
    }

    override func didFinishAssistantMessage(_ message: JSONValue) {
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

    override func isHiddenToolCall(_ id: String) -> Bool {
        hiddenCalls.contains(id)
    }

    override func willStartTool(id: String, name: String, args: JSONValue) -> Bool {
        let device = name == "write" ? args["path"]?.string.flatMap(Self.toolDevice) : nil
        // The lead's todo list is the thread's checklist card, not a row.
        if (device ?? name) == "todo" {
            hiddenCalls.insert(id)
            return false
        }
        runningTools.append(id)
        if name == "write", device == nil, let path = args["path"]?.string {
            editSnapshots.capture(id, path: absolute(path))
        }
        return true
    }

    override func describeTool(name: String, args: JSONValue) -> ToolCall {
        let call = describe(name: name, args: args)
        return ToolCall(kind: call.kind, title: call.title, detail: call.detail)
    }

    override func consumeHiddenToolEnd(id: String, details: JSONValue, isError: Bool) -> Bool {
        runningTools.removeAll { $0 == id }
        toolsAwaitingAnswer.removeValue(forKey: id)
        if hiddenCalls.remove(id) != nil {
            // The call's own answer is the whole list as it stands, and a refused call leaves it as it was.
            if !isError, let steps = Self.todoSteps(details) { onEvent?(.todos(steps)) }
            return true
        }
        return false
    }

    override func isDeclinedToolOutput(_ output: String) -> Bool {
        // A call the gate (or omp) refused comes back as an error that says so, opening with
        // "Declined:" for the gate's own reasons; the row reads as declined rather than failed.
        output.hasPrefix("Declined:") || output.hasPrefix("Error: Declined:") || output.hasPrefix("Tool call denied by user")
    }

    override func formatToolOutput(_ output: String, isError: Bool) -> String {
        if output.hasPrefix("Declined:") || (isError && output.hasPrefix("Error: Declined:")) {
            let refusal = output.hasPrefix("Error: ") ? String(output.dropFirst("Error: ".count)) : output
            let end = refusal.firstIndex(of: "\n") ?? refusal.endIndex
            return AppText.localized(String(refusal[..<end])) + String(refusal[end...])
        }
        return output
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
    override func editDiff(name: String, args: JSONValue, details: JSONValue, id: String, isError: Bool) -> [FileEdit]? {
        guard !isError else { return nil }
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

    // MARK: - Turn End Hooks

    override func willFinishTurn() {
        promptID = nil
        clearRequests()
    }

    override func willReportTurnError(_ error: String) {
        // A spent usage limit says so first, with the time it comes back when the provider gave one.
        let limit = spentLimit(error)
        if limit.isSpent { onEvent?(.usageLimit(resetsAt: limit.resetsAt)) }
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

    // MARK: - Extension UI Hooks

    override func didCancelRequest(_ target: String) {
        toolsAwaitingAnswer = toolsAwaitingAnswer.filter { $0.value != target }
    }

    override func handleCustomNotification(_ params: JSONValue) -> Bool {
        let text = params["message"]?.string ?? ""
        let prefix = "tivano-default-model "
        guard !started, text.hasPrefix(prefix) else { return false }
        if let value = JSONValue.parse(String(text.dropFirst(prefix.count))),
           let provider = value["provider"]?.string, !provider.isEmpty,
           let id = value["id"]?.string, !id.isEmpty {
            defaultModel = "\(provider)/\(id)"
        }
        return true
    }

    override func handleSelect(id: String, params: JSONValue) {
        let title = params["title"]?.string ?? ""
        // The gate extension names the call it asks about exactly: its tool, arguments and id.
        if title.hasPrefix(Self.gatePrefix) {
            guard let payload = JSONValue.parse(String(title.dropFirst(Self.gatePrefix.count))),
                  let name = payload["toolName"]?.string, !name.isEmpty,
                  let args = payload["input"], args.object != nil,
                  let toolID = payload["toolCallId"]?.string, !toolID.isEmpty,
                  payload["kind"]?.string == Self.approvalKind(toolName: name, args: args).grantKey else {
                sendUIResponse(id, value: "Deny")
                return
            }
            // The payload's kind must agree with the actual tool/device; it cannot widen a grant.
            if let actualName = toolNames[toolID], let actualArgs = toolInputs[toolID] {
                let device = actualName == "write" ? actualArgs["path"]?.string.flatMap(Self.toolDevice) : nil
                guard (actualName == name || device == name),
                      Self.approvalKind(toolName: actualName, args: actualArgs) == Self.approvalKind(toolName: name, args: args) else {
                    sendUIResponse(id, value: "Deny")
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
            emitSelectQuestion(id: id, title: title, params: params)
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
            sendUIResponse(id, value: configuration.hydra == nil && runtimeMode == .fullAccess && interactionMode != .plan && !isFinalReport ? "Approve" : "Deny")
            return
        }
        // Plan mode and a final report are read-only turns: nothing that asks may run.
        if interactionMode == .plan || isFinalReport {
            sendUIResponse(id, value: "Deny")
            return
        }
        if runtimeMode == .fullAccess || sessionGrants.contains(kind.grantKey) {
            sendUIResponse(id, value: "Approve")
            return
        }
        if runtimeMode == .autoAcceptEdits, kind == .fileChange {
            sendUIResponse(id, value: "Approve")
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
}
