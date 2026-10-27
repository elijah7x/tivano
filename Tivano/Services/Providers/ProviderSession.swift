import Foundation
import UniformTypeIdentifiers

/// What a thread asks a provider to do for one turn.
struct TurnInput: Sendable {
    var text: String
    var images: [Attachment]
    var model: String?
    var effort: String?
    /// A Codex service tier for this turn: the fast tier, "default", or nil when the model has none.
    var serviceTier: String? = nil
    /// Cursor ACP's Fast variant (`model_config` / `fast`); other providers ignore it.
    var fastMode = false
    var runtimeMode: RuntimeMode
    var interactionMode: InteractionMode
    /// A Hydra head past its budget answering for the last time: the turn is one reply
    /// with no tools, where the session can arrange that.
    var isFinalReport = false
    var command: SlashCommand?
}

/// Everything a provider session needs to launch.
struct SessionConfiguration: Sendable {
    var provider: ProviderKind
    var executable: URL?
    var workingDirectory: URL
    var environment: [String: String]
    var resumeID: String?
    var resumeAt: String?
    var model: String?
    var effort: String?
    var fastMode = false
    var runtimeMode: RuntimeMode
    var interactionMode: InteractionMode
    /// Native API providers (DeepSeek, Meta, Z.ai) authenticate with this instead of a CLI.
    var apiKey: String?
    /// Set while Hydra is on for the thread: the session puts the lead's Hydra policy in
    /// its system prompt and switches its own sub-agent tool off, so every head goes out
    /// through the delegation block as a thread of Tivano's.
    var hydra: HydraLaunch?
    /// The conversation so far, for a provider that keeps nothing between launches (the
    /// API providers hold their history in memory only): the exchanges go back in as
    /// context, so a session that starts over still knows what was said.
    var transcript: [TranscriptMessage] = []
    /// The thread is a Hydra head that Tivano runs: the session paces it, so a head
    /// that keeps reading without ever changing anything is told to act.
    var isHydraHead = false
    /// Only a new Tivano-owned head, or the exact persisted session it created.
    var managesCodexHeadHistory = false
    var codexHistoryArchived = false
    var codexHistoryDirectory: String? = nil
    var antiSlopEnabled = true
    var voiceContext: VoiceOrchestratorContext? = nil
    /// The provider's catalogue as the app holds it, for a provider that names its
    /// variants: its rows map the model the thread chose to an id the agent takes before
    /// the agent's own list arrives (Devin sends it only after the session opens).
    var modelCatalog: [ModelOption] = []
    var dshMode: DshAgentMode = .standard
    var dshFinalReport = false
}

/// One exchange of a conversation, for replaying it into a session that starts over.
struct TranscriptMessage: Sendable {
    enum Role: Sendable {
        case user
        case assistant
    }

    var role: Role
    var text: String
}

/// A head a provider started inside the lead's session.
struct AgentSpawn: Equatable, Sendable {
    /// The provider's id for the head, which its later events carry.
    var id: String
    /// Claude's task id, which is what stops the head; nil where the id above does.
    var taskID: String?
    /// The tool call in the lead's transcript that spawned the head.
    var toolUseID: String?
    var description: String
    /// The head's brief, when the provider says.
    var prompt: String?
    var model: String?
    /// Whether the spawning tool call returns before the head is done. A foreground head
    /// is finished by its tool result; a background one only by the provider saying so.
    var isBackground = true
}

/// Normalized events every provider adapter emits into a thread.
enum ProviderEvent: Sendable {
    case sessionReady(sessionID: String)
    case turnStarted(providerTurnID: String?)
    /// Descriptions of background commands or monitors still running during or after a turn; empty when none remain.
    case backgroundTasks([String])
    case messageDelta(id: String, text: String)
    case messageCompleted(id: String, text: String)
    case reasoningDelta(id: String, text: String)
    case reasoningCompleted(id: String, text: String)
    case toolStarted(id: String, call: ToolCall)
    case toolOutput(id: String, text: String)
    case toolUpdated(id: String, update: ToolUpdate)
    case planDelta(id: String, text: String)
    case planCompleted(id: String, markdown: String)
    case todos([TodoStep])
    case approval(ApprovalRequest)
    case question(QuestionRequest)
    case requestResolved(id: String)
    case usage(ContextUsage)
    /// Previously reported occupancy is no longer current; wait for a new provider report.
    case contextUsageCleared
    /// Tokens newly consumed by one request or turn, with the identity behind
    /// them. Distinct from `usage`, which is context occupancy: an event here
    /// is spend, and a head's spend carries its `agentID`; the turn keeps each
    /// report for run metrics.

    case tokenSpend(TokenSpend)
    case diff(String)
    case notice(Notice)
    /// The account's usage limit is spent; the turn stops until it resets, at the time given when known.
    case usageLimit(resetsAt: Date?)
    case modeChanged(InteractionMode)
    case models([ModelOption], current: String?)
    case commands([SlashCommand])
    case title(String)
    case assistantMessageID(String)
    case turnCompleted(status: TurnStatus, error: String?)
    case exited(error: String?)
    /// A head started inside the session, or an existing one was described further.
    case agentStarted(AgentSpawn)
    /// An event from inside a head's own transcript.
    indirect case agentEvent(agentID: String, ProviderEvent)
    /// The provider's word on a running head: a progress note, its last tool, its spend.
    case agentProgress(agentID: String, summary: String?, lastTool: String?, tokens: Int?, toolCalls: Int?)
    /// A head finished, with the provider's summary of its result when it has one.
    case agentFinished(agentID: String, status: TurnStatus, summary: String?)
}

struct ToolUpdate: Sendable {
    var title: String?
    var detail: String?
    var output: String?
    var status: ToolCall.Status?
    var exitCode: Int?
    var edits: [FileEdit]?
    /// The pictures the call made or returned; the latest non-empty set replaces the row's.
    var images: [Attachment]?
    var kind: ToolCall.Kind?
}

@MainActor
protocol ProviderSession: AnyObject {
    var onEvent: ((ProviderEvent) -> Void)? { get set }
    var isRunning: Bool { get }

    /// Launches the provider and returns its session id.
    func start() async throws -> String
    func send(_ input: TurnInput) async throws
    func interrupt() async
    func resolveApproval(_ requestID: String, optionID: String)
    func answerQuestion(_ requestID: String, answers: [String: [String]])
    func resolveApproval(_ requestID: String, optionID: String, delivered: @escaping @MainActor (Bool) -> Void)
    func answerQuestion(_ requestID: String, answers: [String: [String]], delivered: @escaping @MainActor (Bool) -> Void)
    func compact() async throws
    func stopAndWait(timeout: TimeInterval) async
    func stop()
    /// Stops a head running inside the session. Returns whether the provider could.
    func stopAgent(_ id: String) async -> Bool
}

extension ProviderSession {
    func resolveApproval(_ requestID: String, optionID: String, delivered: @escaping @MainActor (Bool) -> Void) {
        resolveApproval(requestID, optionID: optionID)
        delivered(true)
    }

    func answerQuestion(_ requestID: String, answers: [String: [String]], delivered: @escaping @MainActor (Bool) -> Void) {
        answerQuestion(requestID, answers: answers)
        delivered(true)
    }

    func stopAndWait(timeout: TimeInterval) async { stop() }

    func stopAgent(_ id: String) async -> Bool { false }
}

enum ProviderError: LocalizedError {
    case notInstalled(ProviderKind)
    case notRunning
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .notInstalled(let provider):
            if provider == .minimaxCode {
                AppText.localized("MiniMax Code is not installed. Install the official mcode CLI, then refresh Providers. Authentication is configured separately in MiniMax Code.")
            } else if provider == .zcode {
                AppText.localized("ZCode is not installed. Install the ZCode app, then refresh Providers.")
            } else if provider.isAPIKeyBased {
                "\(provider.displayName) needs an API key. Add one in Settings → Providers → \(provider.displayName)."
            } else {
                "\(provider.displayName) is not installed. Install it and sign in with `\(provider.loginCommand)`."
            }
        case .notRunning:
            "The agent session is not running."
        case .failed(let message):
            message
        }
    }
}

enum ToolTitles {
    /// Removes the `/bin/zsh -lc '…'` wrapper providers put around shell commands.
    static func unwrapShell(_ command: String) -> String {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["/bin/zsh -lc ", "/bin/bash -lc ", "bash -lc ", "zsh -lc ", "/bin/sh -c ", "sh -c "] {
            guard trimmed.hasPrefix(prefix) else { continue }
            var rest = String(trimmed.dropFirst(prefix.count))
            if rest.count >= 2, let first = rest.first, first == "'" || first == "\"", rest.last == first {
                rest = String(rest.dropFirst().dropLast())
                if first == "'" { rest = rest.replacingOccurrences(of: "'\\''", with: "'") }
            }
            return rest
        }
        return trimmed
    }

    static func relativePath(_ path: String, to root: String) -> String {
        let normalizedRoot = root.hasSuffix("/") ? root : root + "/"
        return path.hasPrefix(normalizedRoot) ? String(path.dropFirst(normalizedRoot.count)) : path
    }

    /// Counts additions and deletions in a unified diff.
    static func diffStats(_ diff: String) -> (additions: Int, deletions: Int) {
        var additions = 0
        var deletions = 0
        for line in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("+++") || line.hasPrefix("---") { continue }
            if line.hasPrefix("+") { additions += 1 } else if line.hasPrefix("-") { deletions += 1 }
        }
        return (additions, deletions)
    }
}

enum ToolText {
    /// The text of a content-block array, as tool results and messages carry it.
    static func blocks(_ value: JSONValue?) -> String {
        guard let value, !value.isNull else { return "" }
        if let text = value.string { return text }
        guard let blocks = value.array else { return "" }
        return blocks.compactMap { $0["text"]?.string }.joined(separator: "\n")
    }
}

/// Pictures a tool made or returned, turned into attachments the timeline can show.
enum ToolImages {
    /// The images among a content-block array (or a single block). Reads Anthropic's
    /// `source.data` + `source.media_type`, MCP's `data` + `mimeType`, and ACP's
    /// `{"type": "content", "content": <block>}` wrapper.
    nonisolated static func blocks(_ value: JSONValue?) async -> [Attachment] {
        guard let value, !value.isNull else { return [] }
        let items = value.array ?? [value]
        // Most results hold no image: they skip the hop to a background task.
        guard items.contains(where: { item in
            item["type"]?.string == "image" || (item["type"]?.string == "content" && item["content"]?["type"]?.string == "image")
        }) else { return [] }
        // Multi-megabyte agent images must not decode or write to disk on the main actor.
        return await Task.detached(priority: .userInitiated) {
            items.compactMap(importAttachment(block:))
        }.value
    }

    nonisolated static func attachment(block: JSONValue) async -> Attachment? {
        await Task.detached(priority: .userInitiated) {
            importAttachment(block: block)
        }.value
    }

    /// An image file the agent saved, copied into app storage so the row keeps it after the
    /// original moves. Nil when it is missing or not an image.
    nonisolated static func file(at path: String) async -> Attachment? {
        await Task.detached(priority: .userInitiated) {
            importFile(at: path)
        }.value
    }

    private static func importAttachment(block: JSONValue) -> Attachment? {
        var block = block
        if block["type"]?.string == "content", let inner = block["content"] { block = inner }
        guard block["type"]?.string == "image" else { return nil }
        let source = block["source"] ?? block
        if let encoded = source["data"]?.string,
           let mimeType = source["media_type"]?.string ?? source["mimeType"]?.string, mimeType.hasPrefix("image/"),
           let data = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters), !data.isEmpty {
            return stored(data, mimeType: mimeType)
        }
        if let uri = block["uri"]?.string, uri.hasPrefix("file://"), let path = URL(string: uri)?.path {
            return importFile(at: path)
        }
        return nil
    }

    private static func importFile(at path: String) -> Attachment? {
        let url = URL(fileURLWithPath: path)
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()), type.conforms(to: .image),
              FileManager.default.fileExists(atPath: path),
              var attachment = try? Storage.importAttachment(from: url) else { return nil }
        attachment.mimeType = type.preferredMIMEType ?? "image/png"
        return attachment
    }

    private static func stored(_ data: Data, mimeType: String) -> Attachment? {
        let ext = UTType(mimeType: mimeType)?.preferredFilenameExtension ?? "png"
        guard var attachment = try? Storage.importAttachment(data: data, name: "Image.\(ext)", fileExtension: ext) else { return nil }
        attachment.mimeType = mimeType
        return attachment
    }
}

extension ApprovalRequest.Kind {
    /// The key an "approve for session" grant is remembered under.
    var grantKey: String {
        switch self {
        case .command: "command"
        case .fileChange: "fileChange"
        case .tool, .permissions, .plan: "tool"
        }
    }
}
