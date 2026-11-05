import Foundation
import os

/// One-shot generation of thread titles and commit messages through a provider CLI with no tools.
enum TextGeneration {
    private static let log = Logger(subsystem: "dev.tivano.Tivano", category: "prediction")
    enum Engine: Sendable {
        case claude(executable: URL, environment: [String: String], model: String? = nil, effort: String? = nil)
        case codex(executable: URL, environment: [String: String], model: String, effort: String? = nil)
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

    static func review(_ prompt: String, engine: Engine, directory: URL) async -> Result<String, ReviewFailure> {
        do {
            switch engine {
            case .claude(let executable, let environment, let model, let effort):
                var arguments = [
                    "-p", "--output-format", "text", "--tools", "",
                    "--disable-slash-commands", "--strict-mcp-config", "--permission-mode", "dontAsk",
                    "--no-session-persistence",
                ]
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
                arguments += ["--output-last-message", output.path, "-"]
                let result = try await Shell.run(executable, arguments, in: directory, environment: environment, input: Data(prompt.utf8), timeout: 900)
                if result.timedOut { return .failure(.timedOut) }
                guard result.succeeded else { return .failure(.exit(result.status)) }
                guard let text = (try? String(contentsOf: output, encoding: .utf8))?.trimmed.nilIfEmpty else {
                    return .failure(.emptyOutput)
                }
                return .success(text)
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
                guard result.succeeded else { return (nil, failure(result)) }
                guard let text = result.trimmedOutput.nilIfEmpty else { return (nil, "empty output") }
                return (text, nil)
            case .codex(let executable, let environment, let model, let effort):
                let output = FileManager.default.temporaryDirectory.appendingPathComponent("tivano-\(UUID().uuidString).txt")
                defer { try? FileManager.default.removeItem(at: output) }
                var arguments = ["exec", "--ephemeral", "--skip-git-repo-check", "-s", "read-only", "--model", model]
                if let effort, !effort.isEmpty { arguments += ["--config", "model_reasoning_effort=\"\(effort)\""] }
                arguments += ["--output-last-message", output.path, "-"]
                let result = try await Shell.run(executable, arguments, in: directory, environment: environment, input: Data(prompt.utf8), timeout: 180)
                guard result.succeeded else { return (nil, failure(result)) }
                guard let text = (try? String(contentsOf: output, encoding: .utf8))?.trimmed.nilIfEmpty else {
                    return (nil, "empty output")
                }
                return (text, nil)
            }
        } catch {
            return (nil, "launch failed: \(error.localizedDescription)")
        }
    }
}
