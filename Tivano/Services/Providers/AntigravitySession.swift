import Foundation
import OSLog

/// Drives Google's Antigravity CLI (`agy`) in headless streaming mode.
///
/// The CLI speaks newline-delimited JSON on stdio, much like Claude's
/// stream-json: Tivano holds one persistent process per thread with
/// `--input-format stream-json --output-format stream-json`, writes one
/// `{"event":"user","message":{"content":"…"}}` object per turn on stdin,
/// and reads `init` / `step_update` / `result` events on stdout.
///
/// Protocol reference: https://antigravity.google/docs/cli/headless/
/// Verified live against `agy 1.2.2` (models TSV, `/usage` and `/credits`
/// headless envelopes, tool step shapes, `denied_actions`).
@MainActor
final class AntigravitySession: ProviderSession {
    private static let log = Logger(subsystem: "dev.tivano.Tivano", category: "antigravity")

    var onEvent: ((ProviderEvent) -> Void)?

    private let configuration: SessionConfiguration
    private var process: StdioProcess?
    private var readTask: Task<Void, Never>?
    private var initContinuation: CheckedContinuation<String, Error>?
    private var launchError: String?
    private var conversationID: String?
    private var runtimeMode: RuntimeMode
    private var interactionMode: InteractionMode
    private var model: String?
    private var effort: String?
    private var turnActive = false
    private var interruptRequested = false
    private var isStopping = false
    /// Resolves the cumulative session token total into per-turn spend.
    private var spendTracker = TokenSpendTracker()
    /// Whether the cumulative total's baseline is known. A launch with
    /// `--conversation` resumes a conversation whose token total carries its
    /// history, and the protocol does not say how much that is, so the first
    /// total is used as the baseline and nothing is charged for it.
    private var spendBaselineKnown: Bool
    /// Namespaces step ids per launch. `step_index` counts up within one
    /// process but a resumed conversation starts over, and a repeated id
    /// would stream a new turn's text into an old entry of the thread.
    private let launchID = String(UUID().uuidString.prefix(8))
    /// Whether any reply text streamed this turn; without it, the result's
    /// `response` is the reply.
    private var streamedText = false
    private var latestCascadeError: (index: Int, message: String)?
    private var cascadeErrorMessages: Set<String> = []
    private var completedAgentResponseIndex: Int?
    /// Reply text streamed after the latest cascade error: recovery needs a new reply,
    /// not text the failed attempt had already produced.
    private var replyAfterCascadeError = false
    /// Errors each conversation has reported, kept across launches (heads relaunch per turn).
    /// agy repeats a conversation's earlier error on every later result, so only a result
    /// error already seen here may be treated as stale; a new one still fails the turn.
    private static var knownConversationErrors: [String: Set<String>] = [:]
    /// Files an edit step is about to change, captured when the step went
    /// active. The stream never carries the edit itself, so the row's diff
    /// is the file before against the file after.
    private var editSnapshots = EditSnapshots()
    /// Tool steps whose start was announced, so a step that surfaces only as
    /// finished still gets its proper row rather than a bare "Tool".
    private var startedTools: Set<String> = []
    /// Error steps already surfaced this turn, so a step reported again as its state
    /// changes does not repeat its notice.
    private var reportedErrors: Set<String> = []

    /// Reasoning efforts `agy --effort` accepts.
    static let efforts = ["low", "medium", "high"]

    init(configuration: SessionConfiguration) {
        self.configuration = configuration
        runtimeMode = configuration.runtimeMode
        interactionMode = configuration.interactionMode
        model = configuration.model
        effort = configuration.effort
        spendBaselineKnown = configuration.resumeID?.isEmpty != false
    }

    var isRunning: Bool { !isStopping && (process?.isRunning ?? false) }
    var lastOutputAt: Date? { process?.lastOutputAt }

    private var workingDirectory: String { configuration.workingDirectory.path }

    // MARK: - Lifecycle

    func start() async throws -> String {
        guard let executable = configuration.executable else { throw ProviderError.notInstalled(configuration.provider) }
        // `--add-dir` is what makes the thread's folder the workspace. The
        // CLI does not adopt its cwd (verified live, git repo or not): without
        // the flag the agent works in `~/.gemini/antigravity-cli/scratch` and
        // spends its first steps hunting the home directory for the project.
        var arguments = [
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            // agy's cap covers the whole turn and can end one still producing output.
            // Tivano's watchdogs stop quiet turns: normal chats in ThreadRuntime, heads in HydraWatchdog.
            "--print-timeout", "0",
            "--add-dir", workingDirectory,
        ]
        // Scoping to the connected servers happens through the generated settings
        // file `ProviderRegistry` hands the CLI in `GEMINI_CLI_SYSTEM_SETTINGS_PATH`:
        // it lists those servers and no others, so the user's own stay untouched.
        // `agy` has no `--allowed-mcp-server-names` flag (that one is Claude's) and
        // its flag parser exits 2 with usage text on an unknown flag, which killed
        // every Antigravity session as soon as one MCP server was connected.
        let (resolvedModel, resolvedEffort) = Self.normalize(model: model, effort: effort, catalog: Self.addingSeedRows(configuration.modelCatalog, seed: ProviderRegistry.antigravitySeed))
        if let resolvedModel, !resolvedModel.isEmpty { arguments += ["--model", resolvedModel] }
        if let resolvedEffort, !resolvedEffort.isEmpty { arguments += ["--effort", resolvedEffort] }
        arguments += modeArguments(runtimeMode: configuration.runtimeMode, interaction: configuration.interactionMode)
        if let resumeID = configuration.resumeID, !resumeID.isEmpty {
            arguments += ["--conversation", resumeID]
        }

        let process = StdioProcess(
            executable: executable,
            arguments: arguments,
            directory: configuration.workingDirectory,
            environment: configuration.environment
        )
        self.process = process
        isStopping = false
        try process.start()
        let messages = process.messages
        readTask = Task { [weak self] in
            for await message in messages {
                guard let self else { return }
                self.handle(message)
            }
            self?.didClose()
        }
        return try await withCheckedThrowingContinuation { continuation in
            initContinuation = continuation
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(30))
                self?.failStartAfterTimeout()
            }
        }
    }

    /// `agy --mode` only knows `accept-edits` and `plan`: the default review
    /// mode is the absence of the flag. Full access additionally approves
    /// every tool, since headless runs soft-deny unapproved actions instead
    /// of prompting.
    private func modeArguments(runtimeMode: RuntimeMode, interaction: InteractionMode) -> [String] {
        var arguments: [String] = []
        if interaction == .plan {
            arguments += ["--mode", "plan"]
        } else {
            switch runtimeMode {
            case .supervised:
                break
            case .autoAcceptEdits, .auto, .fullAccess:
                arguments += ["--mode", "accept-edits"]
            }
        }
        if runtimeMode == .fullAccess {
            arguments += ["--dangerously-skip-permissions"]
        }
        return arguments
    }

    private func failStartAfterTimeout() {
        guard let continuation = initContinuation else { return }
        initContinuation = nil
        process?.terminate()
        let reason = launchError ?? AppText.localized("Antigravity did not answer. Is `agy` signed in? Run `agy` once in Terminal.")
        continuation.resume(throwing: ProviderError.failed(authHint(in: reason) ?? reason))
    }

    func send(_ input: TurnInput) async throws {
        guard !isStopping, let process, process.isRunning else { throw ProviderError.notRunning }
        runtimeMode = input.runtimeMode
        interactionMode = input.interactionMode
        if let model = input.model, !model.isEmpty { self.model = model }
        if let effort = input.effort, !effort.isEmpty { self.effort = effort }
        // Stream-json only takes text blocks; anything else ends the session
        // with an error, so images never go on the wire (see supportsImages).
        turnActive = true
        interruptRequested = false
        streamedText = false
        latestCascadeError = nil
        cascadeErrorMessages.removeAll()
        completedAgentResponseIndex = nil
        replyAfterCascadeError = false
        reportedErrors.removeAll()
        onEvent?(.turnStarted(providerTurnID: nil))
        process.send(["event": "user", "message": ["content": .string(input.text)]])
    }

    func interrupt() async {
        guard turnActive else { return }
        interruptRequested = true
        // The process going is the stop, not a crash: without this `didClose`
        // would follow the interrupted turn with `.exited` and the chat would
        // read "Antigravity stopped unexpectedly" every time the user stops one.
        // `start` clears the flag again for the next launch.
        isStopping = true
        // The stream has no interrupt request: stopping the process ends the
        // turn, and the conversation persists server-side for the next turn's
        // `--conversation` resume.
        process?.terminate()
    }

    func compact() async throws {
        throw ProviderError.failed(AppText.localized("Antigravity manages its own context."))
    }

    func resolveApproval(_ requestID: String, optionID: String) {}
    func answerQuestion(_ requestID: String, answers: [String: [String]]) {}

    func stopAndWait(timeout: TimeInterval) async {
        let process = process
        stop()
        await process?.terminateAndWait(timeout: timeout)
    }

    func stop() {
        isStopping = true
        process?.terminate()
    }

    // MARK: - Stream

    private func handle(_ message: JSONValue) {
        switch message["event"]?.string {
        case "init":
            guard let id = message["conversation_id"]?.string, !id.isEmpty else { return }
            conversationID = id
            if let continuation = initContinuation {
                initContinuation = nil
                continuation.resume(returning: id)
            }
            onEvent?(.sessionReady(sessionID: id))
        case "step_update":
            handleStep(message["step_update"] ?? .null)
        case "result":
            handleResult(message["result"] ?? .null)
        default:
            break
        }
    }

    private func handleStep(_ step: JSONValue) {
        let index = step["step_index"]?.int ?? 0
        switch step["step_type"]?.string {
        case "agent_response":
            if let usage = Self.contextUsage(step["usage"]) { onEvent?(.usage(usage)) }
            // A reply step in the `ERROR` state carries the failure, not a reply.
            if step["state"]?.string == "ERROR", noticeError(in: step, index: index) { return }
            if step["state"]?.string == "DONE" { completedAgentResponseIndex = index }
            guard let text = step["text_delta"]?.string, !text.isEmpty else { return }
            streamedText = true
            if !text.trimmed.isEmpty { replyAfterCascadeError = true }
            onEvent?(.messageDelta(id: "agy-\(launchID)-message-\(index)", text: text))
        case "tool":
            // A tool step after a reply means that reply was not the turn's last word.
            completedAgentResponseIndex = nil
            guard let name = step["tool_name"]?.string ?? step["tool_info"]?["name"]?.string else { return }
            let id = "agy-\(launchID)-tool-\(index)"
            let info = step["tool_info"] ?? .null
            let parameters = info["parameters"] ?? .null
            let error = info["error"]?["message"]?.string
            let state = step["state"]?.string
            if !startedTools.contains(id) {
                startedTools.insert(id)
                let call = makeToolCall(name: name, parameters: parameters)
                if call.kind == .edit, state == "ACTIVE", let path = Self.path(in: parameters) {
                    editSnapshots.capture(id, path: path)
                }
                onEvent?(.toolStarted(id: id, call: call))
                if state == "ACTIVE" { return }
            }
            // Errors ride on the `error` field (the documented shape) as well
            // as an `ERROR` state, so either ends the call as a failure.
            if state == "ERROR" || (state == "DONE" && error != nil) {
                let message = error ?? AppText.localized("The tool failed.")
                let status: ToolCall.Status = Self.isDenied(message) ? .declined : .failed
                onEvent?(.toolUpdated(id: id, update: ToolUpdate(output: message, status: status, edits: finishEdit(id, parameters: parameters))))
            } else if state == "DONE" {
                var update = ToolUpdate(status: .completed)
                if let output = info["output"]?.string, !output.isEmpty { update.output = output }
                update.edits = finishEdit(id, parameters: parameters)
                onEvent?(.toolUpdated(id: id, update: update))
            }
        case "user_input", "checkpoint":
            // Acknowledgements and markers carry nothing Tivano renders.
            break
        default:
            // Any other step is an error step when it says so: a model call that failed
            // (`API error (attempt 1): ...`) is retried by the CLI on its own and otherwise
            // leaves a stalled turn with nothing to read.
            _ = noticeError(in: step, index: index)
        }
    }

    /// Says an error step's message in the thread, as a warning because the CLI may
    /// retry. False when the step carries none.
    private func noticeError(in step: JSONValue, index: Int) -> Bool {
        guard let message = Self.errorMessage(in: step) else { return false }
        latestCascadeError = (index, message)
        cascadeErrorMessages.insert(message.trimmingCharacters(in: .whitespacesAndNewlines))
        rememberConversationError(message)
        completedAgentResponseIndex = nil
        replyAfterCascadeError = false
        if reportedErrors.insert("\(index)|\(message)").inserted {
            onEvent?(.notice(Notice(level: .warning, message: "Antigravity: " + message)))
        }
        return true
    }

    private func rememberConversationError(_ message: String) {
        let message = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let conversationID, !message.isEmpty else { return }
        Self.knownConversationErrors[conversationID, default: []].insert(message)
    }

    /// The message of an error step. The stream does not document the error shape, so the
    /// fields it plausibly rides on are tried in turn; the free-text fields only count on
    /// a step that is an error itself, because ordinary steps put their reply there.
    private static func errorMessage(in step: JSONValue) -> String? {
        var candidates: [String?] = [step["error"]?["message"]?.string, step["error"]?.string, step["error_message"]?.string]
        if step["step_type"]?.string?.localizedCaseInsensitiveContains("error") == true || step["state"]?.string == "ERROR" {
            candidates += [step["text"]?.string, step["message"]?.string, step["text_delta"]?.string]
        }
        guard let message = candidates.lazy.compactMap({ $0?.trimmed }).first(where: { !$0.isEmpty }) else { return nil }
        return message.count > 500 ? String(message.prefix(499)) + "…" : message
    }

    /// The finished edit as a diff of the file before against after, for the
    /// row's inline diff and the turn's changed-files attribution. Nil for
    /// non-edit steps, so the update leaves the call's edits alone.
    private func finishEdit(_ id: String, parameters: JSONValue) -> [FileEdit]? {
        guard let path = Self.path(in: parameters) else { return nil }
        return editSnapshots.finish(id, path: path, relativeTo: workingDirectory)
    }

    /// The soft-deny wording headless runs use when a permission rule blocks
    /// a tool: the agent asked, the user (or a rule) said no.
    private static func isDenied(_ message: String) -> Bool {
        let lowered = message.lowercased()
        return lowered.contains("permission check failed") || lowered.contains("denied permission")
            || lowered.contains("permission denied")
    }

    /// The context in use after a model call: the step's fresh input plus
    /// what was served from cache, plus the reply. Result totals are the
    /// session's cumulative spend and say nothing about the window.
    private static func contextUsage(_ usage: JSONValue?) -> ContextUsage? {
        guard let usage, !usage.isNull else { return nil }
        let used = (usage["input_tokens"]?.int ?? 0) + (usage["cache_read_tokens"]?.int ?? 0) + (usage["output_tokens"]?.int ?? 0)
        guard used > 0 else { return nil }
        return ContextUsage(usedTokens: used, windowTokens: nil)
    }

    // MARK: - Turn outcome

    struct TurnOutcome: Equatable {
        enum Status: Equatable {
            case completed
            case interrupted
            case failed
        }

        let status: Status
        let recovered: Bool
    }

    /// agy's result status and error are conversation-sticky: an earlier error step is repeated
    /// on later results with finished_reason "error". The turn's own stream decides instead:
    /// a completed agent_response must be the last model/tool step, with reply text, no denied
    /// actions, and no cascade error after it. Without an error step this turn, the result error
    /// must be one the conversation already reported; a new result-only error still fails.
    static func turnOutcome(
        interruptRequested: Bool,
        status: String?,
        finishedReason: String?,
        hasDeniedActions: Bool,
        hasReply: Bool,
        completedResponseIndex: Int?,
        latestCascadeErrorIndex: Int?,
        cascadeErrorMessages: Set<String>,
        knownConversationErrors: Set<String>,
        resultError: String?
    ) -> TurnOutcome {
        if interruptRequested {
            return TurnOutcome(status: .interrupted, recovered: false)
        }
        // An empty or blank reason is the same as an absent one: agy omits it on normal completion.
        let trimmedReason = finishedReason?.trimmingCharacters(in: .whitespacesAndNewlines)
        let finishedReason = trimmedReason?.isEmpty == true ? nil : trimmedReason
        if finishedReason == "interrupted" {
            return TurnOutcome(status: .interrupted, recovered: false)
        }
        if let finishedReason, !(finishedReason == "error" && status == "ERROR") {
            return TurnOutcome(status: .failed, recovered: false)
        }
        switch status {
        case "SUCCESS":
            return TurnOutcome(status: .completed, recovered: false)
        case "CANCELED", "INTERRUPTED":
            return TurnOutcome(status: .interrupted, recovered: false)
        case "WAITING":
            return TurnOutcome(status: hasDeniedActions ? .failed : .completed, recovered: false)
        default:
            guard hasReply, !hasDeniedActions, let completedResponseIndex else {
                return TurnOutcome(status: .failed, recovered: false)
            }
            let resultError = resultError?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if let latestCascadeErrorIndex {
                guard completedResponseIndex > latestCascadeErrorIndex,
                      resultError.isEmpty || cascadeErrorMessages.contains(resultError) else {
                    return TurnOutcome(status: .failed, recovered: false)
                }
            } else {
                // No error step this turn: only an error the conversation already reported is stale.
                guard resultError.isEmpty || knownConversationErrors.contains(resultError) else {
                    return TurnOutcome(status: .failed, recovered: false)
                }
            }
            return TurnOutcome(status: .completed, recovered: true)
        }
    }

    /// Whether agy gave up on a failure that automatic continuation can safely retry.
    /// Keep this conservative: quota, configuration, authentication and permission failures
    /// need user action, and print timeouts describe Tivano's own output limit, not transport.
    nonisolated static func isTransientFailure(_ message: String) -> Bool {
        let lowered = message.lowercased()
        if lowered.contains("print_timeout") || lowered.contains("print timeout") {
            return false
        }
        let permanent = [
            "quota", "resource_exhausted", "credits", "billing",
            "sign in", "sign-in", "log in", "log-in", "not logged into",
            "auth", "permission", "denied",
            "invalid model selection", "unknown flag", "not supported for model",
        ]
        if permanent.contains(where: { lowered.contains($0) })
            || (lowered.contains("has no \"") && lowered.contains("effort")) {
            return false
        }
        let transient = [
            "unexpected eof", "tls handshake timeout", "no such host", "i/o timeout",
            "connection reset", "broken pipe", "network issue", "network is down",
            "stream idle timeout", "http2:", "timeout awaiting response headers",
            "503", "502", "500 ", "unavailable", "internal", "deadline_exceeded",
            "the stream was interrupted",
        ]
        return transient.contains(where: { lowered.contains($0) })
    }

    // MARK: - Result handling

    private func handleResult(_ result: JSONValue) {
        // Before the initialize is answered, a result is the launch's failure, not a turn's:
        // start() throws it from didClose; nothing was sent that could end here.
        guard initContinuation == nil else {
            if let error = result["error"]?.string?.trimmed, !error.isEmpty {
                launchError = error
            }
            return
        }
        // Terminating `agy` after a finished turn (a head's process stops after each turn)
        // makes it emit a second result for the same turn: status ERROR, finished_reason
        // "interrupted", error "stream input cancelled: context canceled" (seen live with
        // agy 1.5.5). Only a result for a turn still running ends one.
        guard turnActive else {
            Self.log.info("Ignored agy result with no active turn: status=\(result["status"]?.string ?? "none", privacy: .public), finished_reason=\(result["finished_reason"]?.string ?? "none", privacy: .public)")
            return
        }
        turnActive = false
        editSnapshots.removeAll()
        startedTools.removeAll()
        if let usage = result["usage"], !usage.isNull {
            // Totals are cumulative over the session (per the headless docs), so the
            // spend tracker resolves them into per-turn deltas — but only once its
            // baseline is known. A conversation resumed with `--conversation` reports a
            // total that already holds the history it resumed with, and the protocol
            // does not say how much that is: the first total seeds the baseline and is
            // left uncounted, rather than charged as new spend or reported as zero.
            // The context meter is fed per step instead (see handleStep).
            let used = usage["total_tokens"]?.int ?? ((usage["input_tokens"]?.int ?? 0) + (usage["output_tokens"]?.int ?? 0))
            if used > 0 {
                if spendBaselineKnown {
                    let spend = spendTracker.spend(total: used)
                    if spend > 0 {
                        TokenLedger.shared.record(spend: spend)
                        onEvent?(.tokenSpend(TokenSpend(
                            provider: .antigravity,
                            totalTokens: spend,
                            model: model
                        )))
                    }
                } else {
                    spendTracker.seedBaseline(total: used)
                    spendBaselineKnown = true
                }
            }
        }
        let response = result["response"]?.string
        let hasReply = streamedText || response?.trimmed.isEmpty == false
        // A turn whose reply never streamed (resumed conversations can answer
        // in the result alone) still shows its text.
        if !streamedText, let response, !response.trimmed.isEmpty {
            onEvent?(.messageCompleted(id: "agy-\(launchID)-result-\(UUID().uuidString.prefix(8))", text: response))
        }
        streamedText = false
        let denied = (result["denied_actions"]?.array ?? []).compactMap { $0["display_name"]?.string ?? $0["action"]?.string }
        if !denied.isEmpty {
            let names = denied.joined(separator: ", ")
            onEvent?(.notice(Notice(
                level: .warning,
                message: String(format: AppText.localized("Antigravity held back %@ without prompting. Use Full access or add an allow rule in the CLI's settings."), names)
            )))
        }
        if let id = result["conversation_id"]?.string, !id.isEmpty {
            conversationID = id
            onEvent?(.sessionReady(sessionID: id))
        }
        let status = result["status"]?.string
        let finishedReason = result["finished_reason"]?.string
        let resultError = result["error"]?.string
        let trimmedResultError = resultError?.trimmed ?? ""
        let outcome = Self.turnOutcome(
            interruptRequested: interruptRequested,
            status: status,
            finishedReason: finishedReason,
            hasDeniedActions: !denied.isEmpty,
            // After a cascade error only a reply streamed since then proves recovery.
            hasReply: latestCascadeError == nil ? hasReply : replyAfterCascadeError,
            completedResponseIndex: completedAgentResponseIndex,
            latestCascadeErrorIndex: latestCascadeError?.index,
            cascadeErrorMessages: cascadeErrorMessages,
            knownConversationErrors: conversationID.flatMap { Self.knownConversationErrors[$0] } ?? [],
            resultError: resultError
        )
        rememberConversationError(trimmedResultError)
        switch outcome.status {
        case .interrupted:
            onEvent?(.turnCompleted(status: .interrupted, error: nil))
        case .completed:
            if outcome.recovered {
                if latestCascadeError != nil, !trimmedResultError.isEmpty,
                   reportedErrors.insert("result|\(trimmedResultError)").inserted {
                    onEvent?(.notice(Notice(level: .warning, message: "Antigravity: " + trimmedResultError)))
                }
                Self.log.warning("Recovered agy result: status=\(status ?? "none", privacy: .public), finished_reason=\(finishedReason ?? "none", privacy: .public), cascade_error_step=\(self.latestCascadeError?.index ?? -1), completed_response_step=\(self.completedAgentResponseIndex ?? -1), stale=\(self.latestCascadeError == nil)")
            }
            onEvent?(.turnCompleted(status: .completed, error: nil))
        case .failed:
            if status == "WAITING", !denied.isEmpty {
                // Stopped for a permission nobody could grant headless, with actions held
                // back: reported as a failure so a head's lead hears it was starved of
                // permissions rather than reading a clean completion.
                onEvent?(.turnCompleted(status: .failed, error: String(format: AppText.localized("Antigravity held back %@ waiting for a permission it could not ask for. Use Full access for this chat."), denied.joined(separator: ", "))))
            } else {
                let fallback = AppText.localized("Antigravity stopped before finishing.")
                let error = trimmedResultError.isEmpty ? fallback : (authHint(in: trimmedResultError) ?? trimmedResultError)
                onEvent?(.turnCompleted(status: .failed, error: error))
            }
        }
        interruptRequested = false
    }

    private func didClose() {
        if let continuation = initContinuation {
            initContinuation = nil
            // The result's own error names the failure better than the stderr tail can.
            let reason: String
            if let launchError {
                reason = authHint(in: launchError) ?? launchError
            } else {
                reason = closeFailure()
            }
            self.launchError = reason
            continuation.resume(throwing: ProviderError.failed(reason))
        }
        if isStopping {
            if turnActive {
                turnActive = false
                onEvent?(.turnCompleted(status: .interrupted, error: nil))
            }
            interruptRequested = false
            return
        }
        if turnActive {
            turnActive = false
            if interruptRequested {
                onEvent?(.turnCompleted(status: .interrupted, error: nil))
            } else {
                onEvent?(.turnCompleted(status: .failed, error: closeFailure()))
            }
            interruptRequested = false
        }
        onEvent?(.exited(error: TextCleanup.lastLines(process?.errorTail ?? "")))
    }

    private func closeFailure() -> String {
        let tail = process?.errorTail ?? ""
        if let hint = authHint(in: tail) { return hint }
        var lines = [Self.agyError(in: tail) ?? TextCleanup.lastLines(tail)].compactMap { $0 }
        if let failure = process?.failureReason?.trimmed, !failure.isEmpty,
           lines.first?.contains(failure) != true {
            lines.append(failure)
        }
        if let status = process?.exitStatus {
            lines.append(String(format: AppText.localized("The agent exited with status %d."), status))
        }
        let message = lines.joined(separator: "\n")
        guard !message.isEmpty else { return AppText.localized("Antigravity exited.") }
        return authHint(in: message) ?? message
    }

    private static func agyError(in tail: String) -> String? {
        let prefix = "AGY_ERROR:"
        for line in tail.components(separatedBy: .newlines).reversed() {
            let line = line.trimmed
            guard line.hasPrefix(prefix) else { continue }
            let payload = line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
            guard let error = JSONValue.parse(payload),
                  let shortError = error["short_error"]?.string?.trimmed, !shortError.isEmpty else { continue }
            var details: [String] = []
            if let status = error["status"]?.string?.trimmed, !status.isEmpty {
                details.append("status: \(status)")
            }
            if let reason = error["reason"]?.string?.trimmed, !reason.isEmpty {
                details.append("reason: \(reason)")
            }
            return details.isEmpty ? shortError : shortError + " (" + details.joined(separator: ", ") + ")"
        }
        return nil
    }

    private func authHint(in text: String) -> String? {
        let lowered = text.lowercased()
        guard lowered.contains("authentication required") || lowered.contains("not signed in")
            || lowered.contains("unauthenticated") || (lowered.contains("login") && lowered.contains("agy")) else { return nil }
        return AppText.localized("Antigravity is not signed in. Run `agy` once in Terminal to sign in.")
    }

    // MARK: - Model and Effort Normalization

    struct ParsedModelRow {
        let baseSlug: String
        let baseName: String
        let effort: String?
    }

    static func parseModelRow(slug: String, name: String) -> ParsedModelRow {
        for effort in ["high", "medium", "low"] {
            if slug.hasSuffix("-\(effort)") {
                let baseSlug = String(slug.dropLast(effort.count + 1))
                var baseName = name
                let suffix = " (\(effort.capitalized))"
                if baseName.hasSuffix(suffix) {
                    baseName = String(baseName.dropLast(suffix.count))
                }
                return ParsedModelRow(baseSlug: baseSlug, baseName: baseName, effort: effort)
            }
        }
        return ParsedModelRow(baseSlug: slug, baseName: name, effort: nil)
    }

    /// A catalog restored from before a seed row existed lacks that model, which would
    /// send it as unknown with whatever effort the thread carries; the seed fills the gap.
    static func addingSeedRows(_ catalog: [ModelOption], seed: [ModelOption]) -> [ModelOption] {
        catalog + seed.filter { row in !catalog.contains { $0.id == row.id } }
    }

    /// Normalizes model and effort flags for `agy`.
    /// Strips any legacy effort suffixes from model slugs and resolves the effort
    /// level against the model's catalog row: `--effort` only carries an effort the
    /// model declares (the CLI exits on one it does not), and an unknown model gets
    /// only an explicitly requested effort, never an invented default.
    static func normalize(model: String?, effort: String?, catalog: [ModelOption]) -> (model: String?, effort: String?) {
        guard let model, !model.isEmpty else { return (nil, nil) }
        let parsed = parseModelRow(slug: model, name: "")
        let baseSlug = parsed.baseSlug

        // Models that do not take --effort (such as Claude models hosted on Antigravity)
        if baseSlug.contains("claude") {
            return (baseSlug, nil)
        }

        var requested = effort
        if requested == nil || requested?.isEmpty == true {
            requested = parsed.effort
        }

        // The catalog keys rows by base slug: `listModels` groups every effort
        // variant of a model under the one row its `id` names.
        guard let row = catalog.first(where: { $0.id == baseSlug }) else {
            // Unknown model: pass only what was asked for. The two slugs known to
            // accept effort keep their adjustments, and their old default when
            // nothing was requested.
            var resolvedEffort = requested
            if resolvedEffort == nil || resolvedEffort?.isEmpty == true {
                if baseSlug == "gpt-oss-120b" {
                    resolvedEffort = "medium"
                } else if baseSlug == "gemini-3.1-pro" {
                    resolvedEffort = "high"
                }
            }
            if baseSlug == "gemini-3.1-pro" && resolvedEffort == "medium" {
                resolvedEffort = "high"
            } else if baseSlug == "gpt-oss-120b" {
                resolvedEffort = "medium"
            }
            return (baseSlug, resolvedEffort)
        }

        guard !row.efforts.isEmpty else { return (baseSlug, nil) }
        var resolvedEffort: String?
        if let requested, row.efforts.contains(requested) {
            resolvedEffort = requested
        } else if let fallback = row.defaultEffort, row.efforts.contains(fallback) {
            resolvedEffort = fallback
        } else {
            // `listModels` orders efforts low to high, so the last one is the highest it takes.
            resolvedEffort = row.efforts.last
        }

        // Validate effort against model constraints, without leaving the row's efforts.
        if baseSlug == "gemini-3.1-pro" && resolvedEffort == "medium" && row.efforts.contains("high") {
            resolvedEffort = "high"
        } else if baseSlug == "gpt-oss-120b" && row.efforts.contains("medium") {
            resolvedEffort = "medium"
        }

        return (baseSlug, resolvedEffort)
    }

    // MARK: - Catalog

    /// `agy models` prints `slug<TAB>Name` rows on stdout (progress goes to
    /// stderr). Rows with effort variants (-high, -medium, -low) are collapsed
    /// into a single base model entry whose supported efforts are toggled via
    /// the reasoning effort slider.
    static func listModels(executable: URL, environment: [String: String]) async throws -> [ModelOption] {
        async let modelsFetch: ShellResult = try Shell.run(executable, ["models"], environment: environment, timeout: 30)
        // The default model is a print-mode read too, so it is skipped offline like the limits.
        async let defaultFetch: ShellResult? = NetworkPath.isUsable() ? try? Shell.run(executable, ["-p", "/model", "--output-format", "json"], environment: environment, timeout: 30) : nil
        let models = try? await modelsFetch
        let current = await defaultFetch
        var currentID: String?
        if let stdout = current?.stdout, let json = JSONValue.parse(stdout) {
            currentID = json["command"]?["data"]?["id"]?.string
        }
        guard let output = models?.stdout, let text = String(data: output, encoding: .utf8) else {
            throw ShellError(AppText.localized("`agy models` produced no output."))
        }

        var grouped: [String: (name: String, efforts: [String], isDefault: Bool)] = [:]
        var order: [String] = []

        for line in TextCleanup.stripANSI(text).components(separatedBy: .newlines) {
            let trimmed = line.trimmed
            guard !trimmed.isEmpty else { continue }
            let parts = trimmed.split(separator: "\t", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard let slug = parts.first, Self.isSlug(slug) else { continue }
            let name = parts.count > 1 && !parts[1].isEmpty ? parts[1] : slug
            let parsed = parseModelRow(slug: slug, name: name)

            let isCurrent = slug == currentID || parsed.baseSlug == currentID || (currentID?.hasPrefix(parsed.baseSlug) == true)

            if grouped[parsed.baseSlug] == nil {
                order.append(parsed.baseSlug)
                grouped[parsed.baseSlug] = (
                    name: parsed.baseName,
                    efforts: parsed.effort.map { [$0] } ?? [],
                    isDefault: isCurrent
                )
            } else {
                if let eff = parsed.effort, !grouped[parsed.baseSlug]!.efforts.contains(eff) {
                    grouped[parsed.baseSlug]!.efforts.append(eff)
                }
                if isCurrent {
                    grouped[parsed.baseSlug]!.isDefault = true
                }
            }
        }

        var list: [ModelOption] = []
        for baseSlug in order {
            guard let data = grouped[baseSlug] else { continue }
            let sortedEfforts = ["low", "medium", "high"].filter { data.efforts.contains($0) }
            let defaultEffort = sortedEfforts.contains("high") ? "high" : sortedEfforts.last
            list.append(ModelOption(
                id: baseSlug,
                name: data.name,
                efforts: sortedEfforts,
                defaultEffort: defaultEffort,
                isDefault: data.isDefault
            ))
        }

        guard !list.isEmpty else { throw ShellError(AppText.localized("`agy models` listed no models.")) }
        if !list.contains(where: \.isDefault), let first = list.first {
            list[list.startIndex] = ModelOption(
                id: first.id, name: first.name, detail: first.detail,
                efforts: first.efforts, defaultEffort: first.defaultEffort, isDefault: true
            )
        }
        return list
    }

    private static func isSlug(_ text: String) -> Bool {
        guard let first = text.first, first.isLetter || first.isNumber else { return false }
        return text.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." }
            && !text.contains(" ")
    }

    /// Sign-in state without spending tokens: `agy models` needs the cached
    /// Google session (or `GEMINI_API_KEY`) and fails loudly without one.
    static func authStatus(executable: URL, environment: [String: String]) async -> ProviderStatus.Auth {
        guard let result = try? await Shell.run(executable, ["models"], environment: environment, timeout: 20) else {
            return .unknown
        }
        let text = TextCleanup.stripANSI(result.output + result.errorOutput)
        let rows = text.components(separatedBy: .newlines).filter { isSlug($0.split(separator: "\t").first.map(String.init) ?? "") }
        if result.succeeded, !rows.isEmpty { return .signedIn(nil) }
        let lowered = text.lowercased()
        if lowered.contains("authentication required") || lowered.contains("not signed in")
            || lowered.contains("unauthenticated") || lowered.contains("sign in") || lowered.contains("login") {
            return .signedOut
        }
        return result.succeeded ? .signedIn(nil) : .unknown
    }

    // MARK: - Plan limits

    /// Model quotas (`/usage`: weekly + 5-hour buckets per model group) and
    /// the AI credit balance (`/credits`). Both are zero-token headless
    /// calls, so reading limits never spends quota itself.
    ///
    /// Neither runs without a network path. Print mode refreshes the Google token first,
    /// and when that fails it starts the interactive sign-in, which opens the browser:
    /// offline, each of the two processes opened a sign-in page of its own.
    static func readPlanLimits(executable: URL, environment: [String: String]) async throws -> PlanLimits? {
        guard await NetworkPath.isUsable() else { return nil }
        async let usageFetch: ShellResult = try Shell.run(executable, ["-p", "/usage", "--output-format", "json"], environment: environment, timeout: 30)
        async let creditsFetch: ShellResult = try Shell.run(executable, ["-p", "/credits", "--output-format", "json"], environment: environment, timeout: 30)
        let usage = try? await usageFetch
        let credits = try? await creditsFetch
        var windows: [PlanLimits.Window] = []
        if let usage, let data = String(data: usage.stdout, encoding: .utf8), let json = JSONValue.parse(data) {
            windows += parseUsage(json["command"]?["data"], fallback: json["response"]?.string)
        }
        if let credits, let data = String(data: credits.stdout, encoding: .utf8), let json = JSONValue.parse(data),
           let window = parseCredits(json["command"]?["data"], fallback: json["response"]?.string) {
            windows.append(window)
        }
        guard !windows.isEmpty else { return nil }
        return PlanLimits(planName: nil, windows: windows)
    }

    /// The structured envelope: groups of models sharing a weekly and a
    /// 5-hour bucket. `remaining_fraction` is what is left, so the usage
    /// panel's percent is the complement.
    private static func parseUsage(_ data: JSONValue?, fallback response: String?) -> [PlanLimits.Window] {
        var windows: [PlanLimits.Window] = []
        for group in data?["groups"]?.array ?? [] {
            let groupName = group["name"]?.string ?? "Models"
            for bucket in group["buckets"]?.array ?? [] {
                guard let remaining = bucket["remaining_fraction"]?.double else { continue }
                windows.append(PlanLimits.Window(
                    id: bucket["id"]?.string ?? "\(groupName)-\(windows.count)",
                    title: "\(groupName) · \(bucket["name"]?.string ?? "Limit")",
                    percent: max(0, min(100, (1 - remaining) * 100)),
                    resetsAt: bucket["reset_time"]?.string.flatMap(ISO8601.date(from:))
                ))
            }
        }
        if windows.isEmpty, let response { windows += parseUsageText(response) }
        return windows
    }

    /// Older CLIs without the structured envelope: `Group<TAB>Bucket<TAB>95%<TAB><ISO date>`
    /// rows, where the percent is what remains.
    private static func parseUsageText(_ response: String) -> [PlanLimits.Window] {
        var windows: [PlanLimits.Window] = []
        for line in response.components(separatedBy: .newlines) {
            let parts = line.split(separator: "\t").map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count >= 3 else { continue }
            let percentText = parts[2].replacingOccurrences(of: "%", with: "")
            guard let remaining = Double(percentText) else { continue }
            let reset = parts.count >= 4 ? ISO8601.date(from: parts[3]) : nil
            windows.append(PlanLimits.Window(
                id: "usage-\(windows.count)",
                title: "\(parts[0]) · \(parts[1])",
                percent: max(0, min(100, 100 - remaining)),
                resetsAt: reset
            ))
        }
        return windows
    }

    private static func parseCredits(_ data: JSONValue?, fallback response: String?) -> PlanLimits.Window? {
        if let remaining = data?["remaining_credits"]?.int {
            return PlanLimits.Window(
                id: "ai-credits",
                title: String(format: AppText.localized("AI credits · %d remaining"), remaining),
                percent: remaining > 0 ? 0 : 100,
                resetsAt: nil
            )
        }
        guard let response else { return nil }
        for line in response.components(separatedBy: .newlines) {
            let parts = line.split(separator: "\t").map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count >= 2, parts[0].localizedCaseInsensitiveContains("credit"),
                  let remaining = Int(parts[1]) else { continue }
            return PlanLimits.Window(
                id: "ai-credits",
                title: String(format: AppText.localized("AI credits · %d remaining"), remaining),
                percent: remaining > 0 ? 0 : 100,
                resetsAt: nil
            )
        }
        return nil
    }

    // MARK: - Tool mapping

    /// Same row shapes as Claude's: the subject is the command, the path, the
    /// pattern or the URL, and the detail is only what qualifies it (a search
    /// folder, an MCP tool's input). The stream sends a display subset of the
    /// parameters (`AbsolutePath`, `TargetFile`, `SearchDirectory`, ...), never
    /// the edit content.
    private func makeToolCall(name: String, parameters: JSONValue) -> ToolCall {
        let kind = Self.kind(of: name)
        let path = Self.path(in: parameters).map { ToolTitles.relativePath($0, to: workingDirectory) }
        switch kind {
        case .command:
            let command = Self.string(in: parameters, keys: ["CommandLine", "command", "Command"]).map(ToolTitles.unwrapShell)
            return ToolCall(kind: .command, title: command ?? Self.humanize(name))
        case .read:
            var call = ToolCall(kind: .read, title: path ?? Self.string(in: parameters, keys: ["Url", "URL", "url"]) ?? Self.humanize(name))
            if path != nil, let range = Self.lineRange(in: parameters) { call.detail = range }
            return call
        case .edit:
            var call = ToolCall(kind: .edit, title: path ?? Self.humanize(name))
            if let path { call.edits = [FileEdit(path: path)] }
            return call
        case .search:
            let pattern = Self.string(in: parameters, keys: ["Query", "query", "Pattern", "pattern"])
            let folder = Self.string(in: parameters, keys: ["SearchPath", "SearchDirectory", "DirectoryPath", "Path", "path"])
                .map { ToolTitles.relativePath($0, to: workingDirectory) }
            if let pattern {
                return ToolCall(kind: .search, title: pattern, detail: folder)
            }
            return ToolCall(kind: .search, title: folder ?? Self.humanize(name))
        case .web:
            let subject = Self.string(in: parameters, keys: ["Url", "URL", "url", "query", "Query"])
            return ToolCall(kind: .web, title: subject ?? Self.humanize(name))
        case .agent:
            let task = Self.string(in: parameters, keys: ["Task", "task", "Prompt", "prompt", "Description", "description"])
            return ToolCall(kind: .agent, title: task.map { TextCleanup.singleLine($0, limit: 96) } ?? Self.humanize(name))
        case .mcp:
            let server = Self.string(in: parameters, keys: ["ServerName", "server_name", "Server", "server"]) ?? "MCP"
            let tool = Self.string(in: parameters, keys: ["ToolName", "tool_name", "Tool", "tool"]) ?? "tool"
            let input = parameters["Arguments"] ?? parameters["arguments"] ?? parameters["Input"] ?? .null
            return ToolCall(kind: .mcp, title: "\(server) · \(tool)", detail: input.isNull ? nil : input.compactString)
        case .other:
            var call = ToolCall(kind: .other, title: Self.humanize(name))
            let detail = parameters.isNull ? nil : parameters.compactString
            if let detail, !detail.isEmpty, detail != "{}", detail.count <= 300 { call.detail = detail }
            return call
        }
    }

    private static func kind(of name: String) -> ToolCall.Kind {
        switch name {
        case "run_command", "send_command_input", "command_status", "wait", "wait_5_seconds", "schedule":
            .command
        case "view_file", "view_file_outline", "view_code_item", "view_content_chunk", "read_resource",
             "read_browser_page", "capture_browser_screenshot", "capture_browser_console_logs":
            .read
        case "write_to_file", "replace_file_content", "multi_replace_file_content", "sed_file", "notebook_edit", "notebook_execution":
            .edit
        case "list_dir", "grep_search", "find_by_name", "list_resources", "list_browser_pages":
            .search
        case "search_web", "read_url_content", "open_browser_url", "browser_click_element", "browser_drag_pixel_to_pixel",
             "browser_get_dom", "browser_get_network_request", "browser_input", "browser_list_network_requests",
             "browser_mouse_down", "browser_mouse_up", "browser_move_mouse", "browser_press_key", "browser_refresh_page",
             "browser_resize_window", "browser_scroll", "browser_scroll_dom", "browser_select_option", "click_browser_pixel",
             "execute_browser_javascript":
            .web
        case "invoke_subagent", "browser_subagent", "define_subagent", "manage_subagents":
            .agent
        case "call_mcp_tool":
            .mcp
        default:
            .other
        }
    }

    private static func path(in parameters: JSONValue) -> String? {
        string(in: parameters, keys: [
            "AbsolutePath", "TargetFile", "NotebookPath", "FilePath", "File", "file", "path", "Path",
            "DirectoryPath", "directory", "dir",
        ])
    }

    private static func string(in parameters: JSONValue, keys: [String]) -> String? {
        for key in keys {
            if let value = parameters[key]?.string, !value.isEmpty { return value }
        }
        return nil
    }

    /// "L12–40" when a read names a line window, so partial reads read as such.
    private static func lineRange(in parameters: JSONValue) -> String? {
        guard let start = parameters["StartLine"]?.int else { return nil }
        if let end = parameters["EndLine"]?.int, end > start { return "L\(start)–\(end)" }
        return "L\(start)"
    }

    private static func humanize(_ name: String) -> String {
        let words = name.split(separator: "_").map(String.init)
        guard let first = words.first else { return name }
        return ([first.capitalized] + words.dropFirst()).joined(separator: " ")
    }
}
