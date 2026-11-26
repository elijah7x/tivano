import Foundation

/// Drives the Pi coding harness (`pi`) in RPC mode, its long-lived JSON protocol.
///
/// One `pi --mode rpc` process per thread, strict JSONL over stdin/stdout
/// (LF-delimited, one JSON object per line). Prompts arrive as `prompt` requests
/// and stream back as `message_start` / `message_update` / `message_end` events;
/// tool approvals come as `extension_ui_request` server requests and are answered
/// with `extension_ui_response`. The session file pi reports in `get_state` is the
/// resume id, so a thread's conversation survives relaunches in `~/.pi/agent`.
///
/// Pi has no tool approval of its own (`--approve`/`--no-approve` only decide whether
/// project-local `.pi` files are trusted, so Tivano leaves that to the user's own trust
/// settings), so Tivano gates the tools itself through a pi extension (`PiCLI`) loaded
/// with `-e`: every tool that could change something lands as a `tivano-gate`
/// select request, which the app answers or asks the user. Supervised asks for all
/// of them, Auto-accept edits waves file changes through, Auto also passes shell
/// commands that only read, and Full access returns before asking. Plan mode is
/// read-only from the extension's own prompt, with nothing extra loaded.
@MainActor
final class PiSession: PiRPCSession {
    private static let config = Config(
        displayName: "Pi",
        approveValue: "Allow",
        approveAlwaysValue: "Allow for session",
        confirmYesLabel: { "Yes" },
        confirmNoLabel: { "No" },
        missingSessionError: { String(localized: "Pi no longer has this conversation; starting a new one.") },
        startFailureError: { String(format: String(localized: "Pi could not start: %@"), $0) },
        busyTurnError: { String(localized: "Pi is still on the last turn.") },
        extensionErrorFallback: { String(localized: "Pi reported an extension error.") },
        notificationFallback: { String(localized: "Pi sent a notification.") },
        exitedError: { String(format: String(localized: "Pi exited with status %d%@"), $0, $1) }
    )

    init(configuration: SessionConfiguration) {
        super.init(config: Self.config, configuration: configuration)
    }

    // MARK: - Lifecycle Hooks

    override func prepareLaunch() throws -> (arguments: [String], environment: [String: String]) {
        let extensionURL = try PiCLI.installExtension()
        let gateDirectory = try PiCLISupport.subdirectory("gates", in: PiCLI.supportDirectory)
        let gateURL = gateDirectory.appendingPathComponent("\(UUID().uuidString).json")
        self.gateURL = gateURL
        try writeGate(finalReport: false)

        var arguments = ["--mode", "rpc", "-e", extensionURL.path]
        if let model, !model.isEmpty, model != "default", let slash = model.firstIndex(of: "/") {
            arguments += ["--provider", String(model[..<slash]), "--model", String(model[model.index(after: slash)...])]
        }
        if let effort, !effort.isEmpty, PiCLI.thinkingLevels.contains(effort) {
            arguments += ["--thinking", effort]
        }
        if let sessionID { arguments += ["--session", sessionID] }

        var environment = configuration.environment
        environment["TIVANO_PI_GATE"] = gateURL.path
        environment["PI_SKIP_VERSION_CHECK"] = "1"
        if let bridge = try? MCPBridge.installBridge() {
            environment["TIVANO_MCP_BRIDGE"] = bridge.path
        }
        if FileManager.default.fileExists(atPath: MCPPaths.claudeConfigURL.path) {
            environment["TIVANO_MCP_CONFIG"] = MCPPaths.claudeConfigURL.path
        }
        return (arguments, environment)
    }

    override func completeStartup(process: StdioProcess) async throws {
        let state = await request(["type": .string("get_state")])
        applySessionState(state["data"] ?? state)
        onEvent?(.sessionReady(sessionID: self.sessionID ?? ""))

        let commandsResponse = await request(["type": .string("get_commands")])
        emitCommands(commandsResponse["data"] ?? commandsResponse)
    }

    override func prepareTurn(_ input: TurnInput, preparation: UUID, process: StdioProcess) async throws -> Bool {
        runtimeMode = input.runtimeMode
        interactionMode = input.interactionMode
        try writeGate(finalReport: input.isFinalReport)
        if let wanted = input.model, !wanted.isEmpty, wanted != model, let slash = wanted.firstIndex(of: "/") {
            process.send(["type": .string("set_model"), "provider": .string(String(wanted[..<slash])), "modelId": .string(String(wanted[wanted.index(after: slash)...]))])
            model = wanted
            // The context window was read with the model Pi started on; the usage panel's
            // fraction wants the one it runs on now.
            let state = await request(["type": .string("get_state")])
            guard continuePreparation(preparation) else { return false }
            if let window = (state["data"] ?? state)["model"]?["contextWindow"]?.int {
                contextWindow = window
            }
        }
        if let wanted = input.effort, !wanted.isEmpty, wanted != effort, PiCLI.thinkingLevels.contains(wanted) {
            process.send(["type": .string("set_thinking_level"), "level": .string(wanted)])
            effort = wanted
        }
        return true
    }

    override func extraGateFields(finalReport: Bool) -> [String: JSONValue] {
        ["systemPrompt": ""]
    }

    // MARK: - Stream Hooks

    override func handleUnmatchedResponse(id: String, message: JSONValue) {
        if message["command"]?.string == "prompt", message["success"]?.bool == false {
            turnError = message["error"]?.string ?? message["message"]?.string ?? String(localized: "Pi reported an error.")
            finishTurn()
        }
    }

    override func handleProviderEvent(type: String, message: JSONValue) {
        switch type {
        case "agent_start":
            // Pi resumes on its own after a failed run (its own retry, or an extension's):
            // no `send` opened this turn, so the thread would stay idle while it works.
            guard !turnActive else { return }
            turnActive = true
            turnError = nil
            lastReplyText = ""
            onEvent?(.turnStarted(providerTurnID: nil))
        case "agent_end":
            // `willRetry`: Pi's own retry follows this run, so the turn is not over.
            if message["willRetry"]?.bool == true {
                turnError = nil
            } else {
                finishTurn()
            }
        case "compaction_start":
            onEvent?(.notice(Notice(level: .info, message: String(localized: "Compacting the conversation…"))))
        case "compaction_end":
            onEvent?(.notice(Notice(level: .info, message: String(localized: "Conversation compacted"))))
        case "auto_retry_start":
            onEvent?(.notice(Notice(level: .warning, message: message["errorMessage"]?.string ?? message["error"]?.string ?? String(localized: "Pi is retrying."))))
        case "auto_retry_end":
            // A retry cancelled while it waited ends no run, so nothing else closes the turn.
            guard message["success"]?.bool == false else { return }
            turnError = message["finalError"]?.string ?? String(localized: "Pi reported an error.")
            finishTurn()
        default:
            break
        }
    }

    override func reportUpdateUsage(message: JSONValue, event: JSONValue) {
        let usage = message["usage"] ?? event["usage"] ?? .null
        let total = usage["totalTokens"]?.int
        // One sum of four fallback pairs is more than the expression type checker will take:
        // `swiftc -typecheck` gives up on it with "unable to type-check this expression in
        // reasonable time". Naming each part is the fix the diagnostic asks for, and the
        // arithmetic is unchanged.
        let input = usage["input"]?.int ?? usage["inputTokens"]?.int ?? 0
        let output = usage["output"]?.int ?? usage["outputTokens"]?.int ?? 0
        let cacheRead = usage["cacheRead"]?.int ?? usage["cacheReadTokens"]?.int ?? 0
        let cacheWrite = usage["cacheWrite"]?.int ?? usage["cacheWriteTokens"]?.int ?? 0
        let used = total ?? (input + output + cacheRead + cacheWrite)
        if used > 0 { onEvent?(.usage(ContextUsage(usedTokens: used, windowTokens: contextWindow))) }
    }

    override func didFinishAssistantMessage(_ message: JSONValue) {
        if message["stopReason"]?.string == "error" {
            turnError = message["errorMessage"]?.string ?? String(localized: "Pi reported an error.")
        }
    }

    // MARK: - Tool & Approval Hooks

    override func describeTool(name: String, args: JSONValue) -> ToolCall {
        let kind: ToolCall.Kind = switch name {
        case "bash": .command
        case "read": .read
        case "edit", "write": .edit
        case "grep", "find", "ls": .search
        case _ where name.hasPrefix("mcp__"): .mcp
        default: .other
        }
        let title: String
        let detail: String?
        switch name {
        case "bash":
            title = ToolTitles.unwrapShell(args["command"]?.string ?? "bash")
            detail = nil
        case "read", "edit", "write":
            title = ToolTitles.relativePath(args["path"]?.string ?? name, to: workingDirectory)
            detail = nil
        case "grep", "find":
            title = args["pattern"]?.string ?? name
            detail = nil
        case "ls":
            title = args["path"]?.string ?? "."
            detail = nil
        case _ where name.hasPrefix("mcp__"):
            let parts = name.split(separator: "__", omittingEmptySubsequences: true)
            let server = parts.count > 1 ? String(parts[1]) : "MCP"
            let tool = parts.count > 2 ? parts[2...].joined(separator: "__") : name
            title = "\(server) · \(tool)"
            detail = args.isNull || args.compactString == "{}" ? nil : args.prettyString
        default:
            title = name
            detail = args.isNull || args.compactString == "{}" ? nil : args.prettyString
        }
        return ToolCall(kind: kind, title: title, detail: detail)
    }

    override func isDeclinedToolOutput(_ output: String) -> Bool {
        // A call the gate blocked on the user's word comes back as an error whose text is
        // the gate's reason; the row reads as declined rather than failed.
        output.hasPrefix("The user declined this")
    }

    override func editDiff(name: String, args: JSONValue, details: JSONValue, id: String, isError: Bool) -> [FileEdit]? {
        switch name {
        case "edit":
            guard let path = args["path"]?.string else { return nil }
            let old = args["oldText"]?.string ?? ""
            let new = args["newText"]?.string ?? ""
            return [Self.unifiedDiff(path: path, old: old, new: new, omitEmptyLines: true)]
        case "write":
            guard let path = args["path"]?.string, let content = args["content"]?.string else { return nil }
            let before = editSnapshots.text(id)
            editSnapshots.discard(id)
            return [Self.unifiedDiff(path: path, old: before, new: content, omitEmptyLines: true)]
        default:
            return nil
        }
    }

    override func handleSelect(id: String, params: JSONValue) {
        let title = params["title"]?.string ?? ""
        guard title.hasPrefix("tivano-gate "), let payload = JSONValue.parse(String(title.dropFirst("tivano-gate ".count))) else {
            emitSelectQuestion(id: id, title: title, params: params)
            return
        }
        let kindString = payload["kind"]?.string ?? "tool"
        if sessionGrants.contains(kindString) {
            sendUIResponse(id, value: "Allow")
            return
        }
        let toolName = payload["toolName"]?.string ?? "tool"
        let input = payload["input"] ?? .null
        let kind: ApprovalRequest.Kind = kindString == "command" ? .command : kindString == "fileChange" ? .fileChange : .tool
        let callTitle: String
        let callDetail: String?
        switch kind {
        case .command:
            callTitle = ToolTitles.unwrapShell(input["command"]?.string ?? toolName)
            callDetail = input["command"]?.string
        case .fileChange:
            callTitle = ToolTitles.relativePath(input["path"]?.string ?? toolName, to: workingDirectory)
            callDetail = input["path"]?.string
        case .tool, .permissions, .plan:
            callTitle = toolName
            callDetail = input.isNull || input.compactString == "{}" ? nil : input.prettyString
        }
        pendingApprovals[id] = ApprovalRequest(
            id: id,
            kind: kind,
            title: callTitle,
            detail: callDetail,
            options: [
                .init(id: "allow", title: "Approve", role: .approve),
                .init(id: "always", title: "Approve for session", role: .approveAlways),
                .init(id: "deny", title: "Decline", role: .decline),
            ],
            toolItemID: payload["toolCallId"]?.string
        )
        onEvent?(.approval(pendingApprovals[id]!))
    }
}
