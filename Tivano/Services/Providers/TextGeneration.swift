import Foundation
import os

/// One-shot generation of thread titles and commit messages through a provider CLI with no tools.
enum TextGeneration {
    private static let log = Logger(subsystem: "dev.tivano.Tivano", category: "prediction")
    enum Engine: Sendable {
        case claude(executable: URL, environment: [String: String], model: String? = nil, effort: String? = nil)
        case codex(executable: URL, environment: [String: String], model: String, effort: String? = nil)
        case grok(executable: URL, environment: [String: String], model: String?, effort: String? = nil)
        case pi(executable: URL, environment: [String: String], model: String?, effort: String? = nil)
        case antigravity(executable: URL, environment: [String: String], model: String?, effort: String? = nil)
    }

    static func threadTitle(for message: String, engine: Engine) async -> String? {
        let prompt = """
        Write a title for this coding task so the user can recognize it weeks later.
        Rules: 3 to 7 words, under 40 characters, sentence case, no quotes, no trailing punctuation.
        Name the subject and the outcome. Do not copy the request word for word.
        The request may be a word or two, or come with attachments; even then, reply with
        your single best title and nothing else. Never ask a question, never explain,
        never mention the request or the word title.
        Reply with the title only.

        Request:
        \(message.prefix(4_000))
        """
        guard let text = await run(prompt, engine: engine, directory: FileManager.default.temporaryDirectory) else {
            return nil
        }
        return cleanedTitle(text)
    }

    static func refreshedThreadTitle(current: String, context: String, engine: Engine) async -> String? {
        let prompt = """
        Decide whether the current title still describes this coding conversation.
        If it still summarizes the work the conversation is doing now, reply with KEEP only.
        If the work has substantially changed direction, write a new title.
        Rules for a new title: 3 to 7 words, under 40 characters, sentence case, no quotes, no trailing punctuation.
        Name the subject and the outcome. Do not copy the request word for word.
        Never ask a question, never explain, never mention the request or the word title.
        Reply with KEEP or the new title only.

        Current title:
        \(current)

        Conversation:
        \(context.prefix(3_000))
        """
        guard let text = await run(prompt, engine: engine, directory: FileManager.default.temporaryDirectory) else {
            return nil
        }
        let marker = text.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'")))
        guard marker.caseInsensitiveCompare("KEEP") != .orderedSame else { return nil }
        guard let title = cleanedTitle(text), title != current else { return nil }
        return title
    }

    static func nextPrompt(context: String, engine: Engine) async -> String? {
        let prompt = """
        Predict this user's next message from the whole conversation below. Write it as the user would, in the user's language and voice, as one short single-line message, ideally under 120 characters and never over 240. Say only the next request itself; do not add process steps the user has not asked for, such as reviewing or confirming first. First consider whether the user would want to adjust, verify or reuse what was just produced; do not invent unrelated tasks. If no next message is reasonably likely, the suggestion is null. Reply with JSON only: {"suggestion": string or null}.

        Conversation:
        \(context.prefix(8_000))
        """
        let engineDescription: String
        switch engine {
        case .claude(_, _, let model, _): engineDescription = "claude \(model ?? "haiku")"
        case .codex(_, _, let model, let effort): engineDescription = "codex \(model) \(effort ?? "default")"
        case .grok(_, _, let model, let effort): engineDescription = "grok \(model ?? "default") \(effort ?? "default")"
        case .pi(_, _, let model, let effort): engineDescription = "pi \(model ?? "default") \(effort ?? "default")"
        case .antigravity(_, _, let model, let effort): engineDescription = "antigravity \(model ?? "default") \(effort ?? "default")"
        }
        let clock = ContinuousClock()
        let started = clock.now
        let result = await runDetailed(prompt, engine: engine, directory: FileManager.default.temporaryDirectory)
        let elapsed = started.duration(to: clock.now).components
        let milliseconds = Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15
        guard let output = result.text else {
            log.error("prediction failed engine=\(engineDescription, privacy: .public) ms=\(milliseconds, privacy: .public) reason=\(result.failure ?? "empty output", privacy: .public)")
            return nil
        }
        func rejected(_ reason: String) {
            log.notice("prediction rejected engine=\(engineDescription, privacy: .public) ms=\(milliseconds, privacy: .public) reason=\(reason, privacy: .public)")
        }
        let text = output.replacingOccurrences(of: "```json", with: "").replacingOccurrences(of: "```", with: "")
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start <= end,
              let object = try? JSONSerialization.jsonObject(with: Data(text[start...end].utf8)),
              let dictionary = object as? [String: Any] else {
            rejected("no JSON object")
            return nil
        }
        guard let suggestion = dictionary["suggestion"] as? String else {
            rejected("suggestion null or missing")
            return nil
        }
        guard !suggestion.contains(where: \.isNewline) else {
            rejected("contains newline")
            return nil
        }
        let cleaned = String(suggestion.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            rejected("empty after cleanup")
            return nil
        }
        guard cleaned.count <= 240 else {
            rejected("over 240 chars (\(cleaned.count))")
            return nil
        }
        log.notice("prediction ok engine=\(engineDescription, privacy: .public) ms=\(milliseconds, privacy: .public) chars=\(cleaned.count, privacy: .public)")
        return cleaned
    }

    private static func cleanedTitle(_ text: String) -> String? {
        let cleaned = TextCleanup.singleLine(text, limit: 60)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'`*#. "))
        if let title = usable(cleaned) { return title }
        // A model that answers with a sentence usually puts the title on its first
        // non-empty line; that line is worth keeping on its own.
        let firstLine = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
        return firstLine.flatMap { usable($0.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`*#. "))) }
    }

    /// A reply that reads as a title, or nil when the model answered with a sentence or a
    /// question instead - 'I need more context to create a meaningful title. What spec…'
    /// is one such reply that reached a chat's name.
    private static func usable(_ candidate: String) -> String? {
        let title = candidate.trimmed
        guard !title.isEmpty, title.count <= 64 else { return nil }
        guard title.split(whereSeparator: \.isWhitespace).count <= 9 else { return nil }
        guard !title.contains("\n"), !title.contains("?") else { return nil }
        guard let last = title.last, !":;,!…".contains(last) else { return nil }
        let lower = title.lowercased()
        let openers = ["i ", "i'", "sorry", "sure", "here", "please", "could you", "can you",
                       "what ", "it seems", "it looks", "unfortunately", "there is no",
                       "not enough", "need more", "maybe ", "the request", "this request"]
        guard !openers.contains(where: { lower.hasPrefix($0) }) else { return nil }
        let phrases = ["more context", "meaningful title", "as an ai", "cannot", "can't", "unable to"]
        guard !phrases.contains(where: { lower.contains($0) }) else { return nil }
        return title
    }

    static func commitMessage(summary: String, patch: String, instructions: String, engine: Engine, directory: URL) async -> String? {
        let extra = instructions.isEmpty ? "" : "\nFollow these instructions too: \(instructions)\n"
        let prompt = """
        Write a git commit message for the changes below.
        Rules: an imperative subject line of at most 72 characters with no trailing period. \
        Optionally add a blank line and a few short bullet points. Reply with the message only, without code fences.
        \(extra)
        Changed files:
        \(summary.prefix(6_000))

        Patch:
        \(patch.prefix(40_000))
        """
        guard let text = await run(prompt, engine: engine, directory: directory) else { return nil }
        let message = text
            .replacingOccurrences(of: "```", with: "")
            .trimmed
        return message.isEmpty ? nil : message
    }

    enum ReviewFailure: Error, CustomStringConvertible {
        case timedOut
        case exit(Int32)
        case launchFailed
        case cancelled
        case emptyOutput

        var description: String {
            switch self {
            case .timedOut: "timed out after 900s"
            // CLI output can echo the prompt or patch; retain only the exit code.
            case .exit(let code): "exit \(code)"
            case .launchFailed: "launch failed"
            case .cancelled: "cancelled"
            case .emptyOutput: "empty output"
            }
        }
    }

    static func review(
        _ prompt: String,
        engine: Engine,
        directory: URL,
        readableDirectories: [URL] = []
    ) async -> Result<String, ReviewFailure> {
        do {
            switch engine {
            case .claude(let executable, let environment, let model, let effort):
                var arguments = [
                    "-p", "--output-format", "text",
                    "--tools", "Read,Grep,Glob", "--allowedTools", "Read,Grep,Glob",
                    "--disable-slash-commands", "--strict-mcp-config", "--permission-mode", "dontAsk",
                    "--no-session-persistence",
                ]
                let basePath = directory.standardizedFileURL.path
                var seenPaths: Set<String> = [basePath]
                for url in readableDirectories {
                    let standardizedPath = url.standardizedFileURL.path
                    guard seenPaths.insert(standardizedPath).inserted else { continue }
                    arguments += ["--add-dir", url.path]
                }
                if let model, !model.isEmpty, model != "default" { arguments += ["--model", model] }
                if let effort, !effort.isEmpty { arguments += ["--effort", effort] }
                let result = try await Shell.run(executable, arguments, in: directory, environment: environment, input: Data(prompt.utf8), timeout: 900)
                if result.timedOut { return .failure(.timedOut) }
                guard result.succeeded else { return .failure(.exit(result.status)) }
                guard let text = result.trimmedOutput.nilIfEmpty else { return .failure(.emptyOutput) }
                return .success(text)
            case .codex(let executable, let environment, let model, let effort):
                let output = FileManager.default.temporaryDirectory.appendingPathComponent("tivano-\(UUID().uuidString).txt")
                defer { try? FileManager.default.removeItem(at: output) }
                var arguments = [
                    "exec", "--ephemeral", "--skip-git-repo-check", "-s", "read-only", "--model", model,
                ]
                if let effort, !effort.isEmpty { arguments += ["--config", "model_reasoning_effort=\"\(effort)\""] }
                arguments += CodexSession.oneShotConfigArguments
                arguments += ["--output-last-message", output.path, "-"]
                let result = try await Shell.run(executable, arguments, in: directory, environment: environment, input: Data(prompt.utf8), timeout: 900)
                if result.timedOut { return .failure(.timedOut) }
                guard result.succeeded else { return .failure(.exit(result.status)) }
                guard let text = (try? String(contentsOf: output, encoding: .utf8))?.trimmed.nilIfEmpty else {
                    return .failure(.emptyOutput)
                }
                return .success(text)
            case .grok(let executable, let environment, let model, let effort):
                let promptFile = try writePromptFile(prompt)
                defer { try? FileManager.default.removeItem(at: promptFile) }
                var arguments = [
                    "--prompt-file", promptFile.path, "--output-format", "plain",
                    "--permission-mode", "dontAsk", "--disable-web-search",
                    "--cwd", directory.path,
                ]
                for path in uniqueReadableDirectoryPaths(base: directory, readableDirectories: readableDirectories) {
                    arguments += ["--add-dir", path]
                }
                if let model, !model.isEmpty, model != "default" { arguments += ["-m", model] }
                if let effort, !effort.isEmpty { arguments += ["--effort", effort] }
                let result = try await Shell.run(executable, arguments, in: directory, environment: environment, timeout: 900)
                if result.timedOut { return .failure(.timedOut) }
                guard result.succeeded else { return .failure(.exit(result.status)) }
                guard let text = result.trimmedOutput.nilIfEmpty else { return .failure(.emptyOutput) }
                return .success(text)
            case .pi(let executable, let environment, let model, let effort):
                var arguments = [
                    "-p", "--no-session", "--tools", "read,grep,find,ls", "--no-skills",
                    "--no-context-files", "--no-prompt-templates", "--no-themes",
                ]
                appendPiModelAndEffort(to: &arguments, model: model, effort: effort)
                var launchEnvironment = environment
                launchEnvironment["PI_SKIP_VERSION_CHECK"] = "1"
                let extraDirectories = uniqueReadableDirectoryPaths(base: directory, readableDirectories: readableDirectories)
                let effectivePrompt: String
                if extraDirectories.isEmpty {
                    effectivePrompt = prompt
                } else {
                    let directoryList = extraDirectories.map { "- \($0)" }.joined(separator: "\n")
                    effectivePrompt = """
                    \(prompt)

                    Additional readable directories you may inspect by absolute path:
                    \(directoryList)
                    """
                }
                let result = try await Shell.run(executable, arguments, in: directory, environment: launchEnvironment, input: Data(effectivePrompt.utf8), timeout: 900)
                if result.timedOut { return .failure(.timedOut) }
                guard result.succeeded else { return .failure(.exit(result.status)) }
                guard let text = result.trimmedOutput.nilIfEmpty else { return .failure(.emptyOutput) }
                return .success(text)
            case .antigravity(let executable, let environment, let model, let effort):
                guard await NetworkPath.isUsable() else { return .failure(.launchFailed) }
                // The request goes over stdin as one stream-json turn, never in the
                // arguments, so a large patch stays off the command line; agy exits at EOF.
                var arguments = [
                    "--input-format", "stream-json", "--output-format", "stream-json", "--mode", "plan",
                    "--add-dir", directory.path,
                ]
                let turn: [String: Any] = ["event": "user", "message": ["content": prompt]]
                var input = try JSONSerialization.data(withJSONObject: turn)
                input.append(0x0A)
                for path in uniqueReadableDirectoryPaths(base: directory, readableDirectories: readableDirectories) {
                    arguments += ["--add-dir", path]
                }
                if let model, !model.isEmpty, model != "default" { arguments += ["--model", model] }
                if let effort, !effort.isEmpty { arguments += ["--effort", effort] }

                let deadline = ContinuousClock.now.advanced(by: .seconds(900))
                for attempt in 0..<2 {
                    try Task.checkCancellation()
                    let remaining = ContinuousClock.now.duration(to: deadline).components
                    let remainingSeconds = Double(remaining.seconds) + Double(remaining.attoseconds) / 1e18
                    guard remainingSeconds > 1 else { return .failure(.timedOut) }

                    let result = try await Shell.run(executable, arguments, in: directory, environment: environment, input: input, timeout: remainingSeconds)
                    if result.timedOut { return .failure(.timedOut) }

                    // Judged like a chat turn, so a review agy recovered inside the turn
                    // (after an earlier model-call error) is kept rather than rerun.
                    let turn = AntigravitySession.oneShotReply(streamJSON: result.output)
                    let json = turn.result
                    let status = json?["status"]?.string
                    let finishedReason = json?["finished_reason"]?.string?.trimmed.nilIfEmpty
                    let jsonError = json?["error"]?.string?.trimmed.nilIfEmpty

                    if result.succeeded, let reply = turn.reply {
                        return .success(reply)
                    }

                    let stderrFirstLine = result.errorOutput.trimmed.split(whereSeparator: \.isNewline).first.map(String.init)
                    let isTransient = (stderrFirstLine.map { AntigravitySession.isTransientFailure($0) } == true)
                        || (jsonError.map { AntigravitySession.isTransientFailure($0) } == true)
                    if attempt == 0, isTransient {
                        let beforeSleep = ContinuousClock.now.duration(to: deadline).components
                        let secondsLeft = Double(beforeSleep.seconds) + Double(beforeSleep.attoseconds) / 1e18
                        if secondsLeft > 4 {
                            try Task.checkCancellation()
                            try await Task.sleep(for: .seconds(3))
                            try Task.checkCancellation()
                            guard await NetworkPath.isUsable() else { return .failure(.launchFailed) }
                            continue
                        }
                    }

                    if Task.isCancelled { return .failure(.cancelled) }
                    if finishedReason == "interrupted" || status == "CANCELED" || status == "INTERRUPTED" {
                        return .failure(.cancelled)
                    }
                    guard result.succeeded else { return .failure(.exit(result.status)) }
                    if status == "SUCCESS" { return .failure(.emptyOutput) }
                    if status != nil || jsonError != nil { return .failure(.exit(1)) }
                    return .failure(.emptyOutput)
                }
                return .failure(.emptyOutput)
            }
        } catch is CancellationError {
            return .failure(.cancelled)
        } catch {
            return .failure(.launchFailed)
        }
    }

    private static func run(_ prompt: String, engine: Engine, directory: URL) async -> String? {
        await runDetailed(prompt, engine: engine, directory: directory).text
    }

    /// A failed run's reason with the first line of the CLI's error, such as "Not logged in".
    private static func failure(_ result: ShellResult) -> String {
        if result.timedOut { return "timed out" }
        let firstLine = result.errorOutput.trimmed.split(whereSeparator: \.isNewline).first.map { String($0.prefix(200)) } ?? ""
        return firstLine.isEmpty ? "exit \(result.status)" : "exit \(result.status): \(firstLine)"
    }

    private static func runDetailed(_ prompt: String, engine: Engine, directory: URL) async -> (text: String?, failure: String?) {
        do {
            switch engine {
            case .claude(let executable, let environment, let model, let effort):
                var arguments = [
                    "-p", "--output-format", "text", "--model", model ?? "haiku", "--tools", "",
                    "--disable-slash-commands", "--strict-mcp-config", "--permission-mode", "dontAsk",
                    "--no-session-persistence",
                ]
                if let effort, !effort.isEmpty { arguments += ["--effort", effort] }
                let result = try await Shell.run(executable, arguments, in: directory, environment: environment, input: Data(prompt.utf8), timeout: 120)
                guard !result.timedOut, result.succeeded else { return (nil, failure(result)) }
                guard let text = result.trimmedOutput.nilIfEmpty else { return (nil, "empty output") }
                return (text, nil)
            case .codex(let executable, let environment, let model, let effort):
                let output = FileManager.default.temporaryDirectory.appendingPathComponent("tivano-\(UUID().uuidString).txt")
                defer { try? FileManager.default.removeItem(at: output) }
                var arguments = ["exec", "--ephemeral", "--skip-git-repo-check", "-s", "read-only", "--model", model]
                if let effort, !effort.isEmpty { arguments += ["--config", "model_reasoning_effort=\"\(effort)\""] }
                arguments += CodexSession.oneShotConfigArguments
                arguments += ["--output-last-message", output.path, "-"]
                let result = try await Shell.run(executable, arguments, in: directory, environment: environment, input: Data(prompt.utf8), timeout: 180)
                guard !result.timedOut, result.succeeded else { return (nil, failure(result)) }
                guard let text = (try? String(contentsOf: output, encoding: .utf8))?.trimmed.nilIfEmpty else {
                    return (nil, "empty output")
                }
                return (text, nil)
            case .grok(let executable, let environment, let model, let effort):
                let promptFile = try writePromptFile(prompt)
                defer { try? FileManager.default.removeItem(at: promptFile) }
                var arguments = [
                    "--prompt-file", promptFile.path, "--output-format", "plain",
                    "--tools", "", "--permission-mode", "dontAsk", "--disable-web-search",
                    "--cwd", directory.path,
                ]
                if let model, !model.isEmpty, model != "default" { arguments += ["-m", model] }
                if let effort, !effort.isEmpty { arguments += ["--effort", effort] }
                let result = try await Shell.run(executable, arguments, in: directory, environment: environment, timeout: 120)
                guard !result.timedOut, result.succeeded else { return (nil, failure(result)) }
                guard let text = result.trimmedOutput.nilIfEmpty else { return (nil, "empty output") }
                return (text, nil)
            case .pi(let executable, let environment, let model, let effort):
                var arguments = [
                    "-p", "--no-session", "--no-tools", "--no-skills",
                    "--no-context-files", "--no-prompt-templates", "--no-themes",
                ]
                appendPiModelAndEffort(to: &arguments, model: model, effort: effort)
                var launchEnvironment = environment
                launchEnvironment["PI_SKIP_VERSION_CHECK"] = "1"
                let result = try await Shell.run(executable, arguments, in: directory, environment: launchEnvironment, input: Data(prompt.utf8), timeout: 120)
                guard !result.timedOut, result.succeeded else { return (nil, failure(result)) }
                guard let text = result.trimmedOutput.nilIfEmpty else { return (nil, "empty output") }
                return (text, nil)
            case .antigravity:
                return (nil, "Antigravity is not offered for background text")
            }
        } catch {
            return (nil, "launch failed: \(error.localizedDescription)")
        }
    }

    private static func writePromptFile(_ prompt: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tivano-prompt-\(UUID().uuidString).txt")
        guard FileManager.default.createFile(
            atPath: url.path,
            contents: Data(prompt.utf8),
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return url
    }

    private static func uniqueReadableDirectoryPaths(base directory: URL, readableDirectories: [URL]) -> [String] {
        let basePath = directory.standardizedFileURL.path
        var seenPaths: Set<String> = [basePath]
        var paths: [String] = []
        for url in readableDirectories {
            let standardizedPath = url.standardizedFileURL.path
            guard seenPaths.insert(standardizedPath).inserted else { continue }
            paths.append(url.path)
        }
        return paths
    }

    private static func appendPiModelAndEffort(to arguments: inout [String], model: String?, effort: String?) {
        if let model, !model.isEmpty, model != "default" {
            if let slash = model.firstIndex(of: "/") {
                let provider = String(model[..<slash])
                let modelID = String(model[model.index(after: slash)...])
                if !provider.isEmpty, !modelID.isEmpty {
                    arguments += ["--provider", provider, "--model", modelID]
                } else {
                    arguments += ["--model", model]
                }
            } else {
                arguments += ["--model", model]
            }
        }
        if let effort, !effort.isEmpty, PiCLI.thinkingLevels.contains(effort) {
            arguments += ["--thinking", effort]
        }
    }
}
