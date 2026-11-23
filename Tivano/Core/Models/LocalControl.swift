import Foundation

/// Local control v1 is an opt-in, same-account capability, not a sandbox against the
/// owner's other processes. Wire identifiers and enum raw values are never localized.
enum LocalControl {
    static let version = 1
    static let maxFrame = 1_048_576
    static let maxRequest = 131_072
    static let maxText = 65_536
    static let maxConnections = 8
    static let maxOperations = 256
    static let maxPendingOperations = 16
    static let retention: TimeInterval = 3_600
    static let methods = ["info", "providers", "projects", "threads", "thread", "history", "create", "submit", "interrupt", "operation", "settingsGet", "settingsSet", "agentModels", "agentRun"]
    /// An agent run's prompt (BeRead block context included) may exceed `maxText`;
    /// its request frame is bounded by `maxFrame` instead of `maxRequest`.
    static let maxAgentPrompt = 900_000

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

enum ControlEdition: String, Codable, Sendable { case release, dev, preview }

struct ControlHello: Codable, Sendable {
    var version = LocalControl.version
    var edition: ControlEdition
    var expectedInstance: UUID? = nil
}

struct ControlWelcome: Codable, Sendable {
    var version = LocalControl.version
    var edition: ControlEdition
    var instance: UUID
    var methods = LocalControl.methods
    var maxFrame = LocalControl.maxFrame
    var maxRequest = LocalControl.maxRequest
    var maxText = LocalControl.maxText
    var maxConnections = LocalControl.maxConnections
    var maxPendingOperations = LocalControl.maxPendingOperations
    var maxListPage = 100
    var maxHistoryPage = 50
    var firstDeliverySeconds = 30
    var settings = ControlSettingKey.allCases
    var operationRetentionSeconds = Int(LocalControl.retention)
    var maxOperations = LocalControl.maxOperations
    /// No write receipt survives an App restart. An old ticket is never replayed.
    var restartSemantics = "unknown_after_restart_no_replay"
}

/// A write ticket is scoped to one App instance, including when copied between clients.
struct ControlTicket: Codable, Hashable, Sendable {
    var instance: UUID
    var id: UUID
    var issuedAtMilliseconds: Int64

    var string: String { "\(instance.uuidString)/\(id.uuidString)/\(issuedAtMilliseconds)" }
    var issuedAt: Date { Date(timeIntervalSince1970: Double(issuedAtMilliseconds) / 1_000) }
    init(instance: UUID, id: UUID = UUID(), issuedAt: Date = .now) {
        self.instance = instance
        self.id = id
        issuedAtMilliseconds = Int64(issuedAt.timeIntervalSince1970 * 1_000)
    }
    init?(_ string: String) {
        let parts = string.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 3, let instance = UUID(uuidString: String(parts[0])), let id = UUID(uuidString: String(parts[1])),
              let milliseconds = Int64(parts[2]), milliseconds > 0 else { return nil }
        self.instance = instance
        self.id = id
        issuedAtMilliseconds = milliseconds
    }
}

struct ControlRequest: Codable, Sendable {
    var id = UUID()
    var instance: UUID
    var command: ControlCommand
}

enum ControlCommand: Codable, Sendable {
    case info
    case providers
    case projects(ControlPage)
    case threads(ControlThreadQuery)
    case thread(UUID)
    case history(ControlHistoryQuery)
    case create(ControlCreate)
    case submit(ControlSubmit)
    case interrupt(ControlInterrupt)
    case operation(ControlTicket)
    case settingsGet
    case settingsSet(ControlSettingsWrite)
    /// Agent commands are answered without the Local control switch. agentRun is the
    /// only streaming command: its connection carries agentEvent frames until a done or
    /// error event, and a client disconnect cancels the run.
    case agentModels
    case agentRun(ControlAgentRun)

    var isAgent: Bool {
        switch self {
        case .agentModels, .agentRun: true
        default: false
        }
    }

    var ticket: ControlTicket? {
        switch self {
        case .create(let value): value.ticket
        case .submit(let value): value.ticket
        case .interrupt(let value): value.ticket
        case .settingsSet(let value): value.ticket
        default: nil
        }
    }
}

struct ControlPage: Codable, Sendable {
    var limit = 50
    var cursor: String? = nil
}

enum ControlArchiveFilter: String, Codable, Sendable { case active, archived, all }
enum ControlRoleFilter: String, Codable, Sendable { case normal, helper, head, all }
enum ControlAffiliationFilter: String, Codable, Sendable { case all, standalone, project, missing_project }

struct ControlThreadQuery: Codable, Sendable {
    var page = ControlPage()
    var archive: ControlArchiveFilter = .active
    var role: ControlRoleFilter = .normal
    var affiliation: ControlAffiliationFilter = .all
    var projectID: UUID? = nil
    /// Title only, case-insensitive; never a transcript search.
    var search: String? = nil
}

struct ControlHistoryQuery: Codable, Sendable {
    var threadID: UUID
    var page = ControlPage(limit: 25)
}

enum ControlWorkspaceMode: String, Codable, Sendable { case local, worktree }
enum ControlWorkspacePhase: String, Codable, Sendable { case preparing, ready, failed }

/// Persisted with externally-created threads. A failed/preparing worktree must never
/// inherit ChatThread's historical project-directory fallback, including after restart.
struct ControlWorkspace: Codable, Hashable, Sendable {
    var mode: ControlWorkspaceMode
    var phase: ControlWorkspacePhase
    var failure: ControlFailure? = nil
    /// External workspaces enforce readiness in the runtime too. UI terminal setup
    /// retains its existing UI workflow but cannot be represented as CLI-ready unless
    /// completion was observed; this flag is never writable through the protocol.
    var enforcesExecutionReadiness = true
}

struct ControlCreate: Codable, Sendable {
    var ticket: ControlTicket
    /// Nil explicitly means standalone; an unknown non-nil project is an error.
    var projectID: UUID?
    var workspace: ControlWorkspaceMode
    var provider: String
    var model: String? = nil
    /// Nil or false starts with Hydra off; true enables this chat's Hydra switch (requires app-wide Hydra).
    var hydra: Bool? = nil
}

/// Automatic chooses fresh for an unsent thread, transcript for API providers, and
/// providerSession otherwise. Exact providerSession never falls back to a new session.
enum ControlContinuation: String, Codable, Sendable { case automatic, fresh, providerSession, transcript }

struct ControlSubmit: Codable, Sendable {
    var ticket: ControlTicket
    var threadID: UUID
    var text: String
    var continuation: ControlContinuation = .automatic
}

struct ControlInterrupt: Codable, Sendable {
    var ticket: ControlTicket
    var threadID: UUID
    var turnID: UUID
}

enum ControlSettingKey: String, Codable, CaseIterable, Sendable {
    case textGeneration, weatherWindow
}

enum ControlSettingValue: Codable, Equatable, Sendable {
    case bool(Bool)
    case textGeneration(ControlTextGeneration)
}

enum ControlTextGeneration: String, Codable, Sendable { case automatic, claude, codex, grok, pi, off }

struct ControlSettingsWrite: Codable, Sendable {
    var ticket: ControlTicket
    var key: ControlSettingKey
    var value: ControlSettingValue
}

struct ControlSetting: Codable, Sendable {
    var key: ControlSettingKey
    var preference: ControlSettingValue
    var effective: ControlSettingValue
}

struct ControlProject: Codable, Sendable {
    var id: UUID
    var name: String
    var path: String
}

struct ControlThread: Codable, Sendable {
    var id: UUID
    var title: String
    var projectID: UUID?
    var affiliation: ControlAffiliationFilter
    var role: ControlRoleFilter
    var archived: Bool
    var provider: String
    var model: String?
    var hydra: Bool
    var createdAt: Date
    var updatedAt: Date
    var lastStatus: String?
    var activeTurnID: UUID?
    var waitingForUI: Bool
    var workspace: ControlWorkspace
    var executionDirectory: String?
}

struct ControlProvider: Codable, Sendable {
    var id: String
    var enabled: Bool
    var installed: Bool
    /// unknown is not signedIn. Account names, executable paths and auth messages stay private.
    var authentication: String
    var models: [String]
    var freshSubmission: Bool
    var continuation: [ControlContinuation]
    var interrupt: Bool
    var capabilityScope = "provider_model_session_rechecked_on_submission"
}

struct ControlHistoryEntry: Codable, Sendable {
    var id: String
    var turnID: UUID?
    var turnStatus: String?
    var date: Date
    var kind: String
    /// Excerpts, never attachment bytes or paths. Long content is explicitly marked.
    var text: String
    var truncated: Bool
}

struct ControlHistoryPage: Codable, Sendable {
    var threadID: UUID
    var entries: [ControlHistoryEntry]
    var nextCursor: String?
    var snapshot: String
    var persistedOnly = true
}

struct ControlListPage<Item: Codable & Sendable>: Codable, Sendable {
    var items: [Item]
    var nextCursor: String?
    var snapshot: String
}

enum ControlOperationState: String, Codable, Sendable {
    case accepted, preparing, ready, started, waiting, ended, failed, unknown
}

struct ControlOutcome: Codable, Sendable {
    var ticket: ControlTicket
    var state: ControlOperationState
    var threadID: UUID? = nil
    var turnID: UUID? = nil
    var continuation: ControlContinuation? = nil
    /// completed means the provider reported completion, not proof of task correctness.
    var turnStatus: String? = nil
    var error: ControlFailure? = nil
    var setting: ControlSetting? = nil
    /// An ended runtime is not by itself proof that a provider process stopped.
    var stopEvidence: String? = nil
    var updatedAt = Date.now
    var expiresAt: Date? = nil

    var terminal: Bool { [.ready, .ended, .failed, .unknown].contains(state) }
}

struct ControlResponse: Codable, Sendable {
    var id: UUID?
    var result: ControlResult? = nil
    var error: ControlFailure? = nil
}

enum ControlResult: Codable, Sendable {
    case welcome(ControlWelcome)
    case info(ControlWelcome)
    case providers([ControlProvider])
    case projects(ControlListPage<ControlProject>)
    case threads(ControlListPage<ControlThread>)
    case thread(ControlThread)
    case history(ControlHistoryPage)
    case operation(ControlOutcome)
    case settings([ControlSetting])
    case agentModels(ControlAgentModels)
    case agentEvent(ControlAgentLine)
}

// MARK: - Agent bridge (external readers such as BeRead)

struct ControlAgentModel: Codable, Sendable {
    /// Opaque to clients: `ControlAgentModel.encode(provider:model:)`.
    var id: String
    var label: String
    var providerName: String
    var isDefault: Bool

    static func encode(provider: String, model: String?) -> String { model.map { provider + "/" + $0 } ?? provider }
    static func decode(_ id: String) -> (provider: String, model: String?) {
        guard let slash = id.firstIndex(of: "/") else { return (id, nil) }
        let model = String(id[id.index(after: slash)...])
        return (String(id[..<slash]), model.isEmpty ? nil : model)
    }
}

struct ControlAgentModels: Codable, Sendable {
    var version = 1
    var models: [ControlAgentModel]
}

struct ControlAgentRun: Codable, Sendable {
    /// Absolute working directory.
    var cwd: String
    /// A `ControlAgentModel.id`; nil uses Tivano's default model.
    var model: String? = nil
    /// An earlier `session` event's value; unknown or expired starts a new session.
    var session: String? = nil
    var prompt: String
}

/// One NDJSON event line, already encoded as a single-line JSON object (no newline),
/// so tool inputs can carry arbitrary JSON. The CLI prints `json` verbatim.
struct ControlAgentLine: Codable, Sendable {
    var type: String
    var json: String
}

enum ControlAgentErrorCode: String, Sendable { case app_unavailable, model_unavailable, bad_request, `internal` }

enum ControlAgentEvent {
    case session(String)
    case text(String)
    case thinking(String)
    /// `input` must be a JSONSerialization-compatible value (dictionary, array, string, number, bool, NSNull).
    case toolStart(id: String, name: String, input: Any?)
    case toolEnd(id: String, ok: Bool)
    case file(String)
    case done
    case error(ControlAgentErrorCode, String)

    var line: ControlAgentLine {
        var object: [String: Any]
        switch self {
        case .session(let id): object = ["type": "session", "session": id]
        case .text(let delta): object = ["type": "text", "delta": delta]
        case .thinking(let delta): object = ["type": "thinking", "delta": delta]
        case .toolStart(let id, let name, let input):
            object = ["type": "tool_start", "id": id, "name": name]
            if let input, JSONSerialization.isValidJSONObject(["input": input]) { object["input"] = input }
        case .toolEnd(let id, let ok): object = ["type": "tool_end", "id": id, "ok": ok]
        case .file(let path): object = ["type": "file", "path": path]
        case .done: object = ["type": "done"]
        case .error(let code, let message): object = ["type": "error", "code": code.rawValue, "message": message]
        }
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed])) ?? Data(#"{"type":"error","code":"internal","message":"encoding"}"#.utf8)
        return ControlAgentLine(type: object["type"] as? String ?? "error", json: String(decoding: data, as: UTF8.self))
    }

    /// done and error end the stream.
    var isTerminal: Bool {
        switch self {
        case .done, .error: true
        default: false
        }
    }
}

struct ControlFailure: Error, Codable, Hashable, Sendable, LocalizedError {
    enum Code: String, Codable, Sendable {
        case disabled, unavailable, permission, protocolMismatch, editionMismatch, instanceMismatch
        case invalidRequest, bounds, busy, notFound, missingProject, unsupported, archived
        case workspacePreparing, workspaceFailed, directoryUnavailable, persistence, conflict
        case continuationUnavailable, shutdown, corruptHistory, cursorInvalid, providerFailure, internalError

        var message: String {
            switch self {
            case .disabled: "Local control is disabled."
            case .unavailable: "The requested local-control capability is unavailable."
            case .permission: "This local-control request is not permitted."
            case .protocolMismatch: "The local-control protocol versions do not match."
            case .editionMismatch: "The local-control editions do not match."
            case .instanceMismatch: "The Tivano instance changed. Query the old operation outcome before retrying."
            case .invalidRequest: "The local-control request is invalid."
            case .bounds: "The local-control request exceeds a supported limit."
            case .busy: "This thread or local-control service is busy."
            case .notFound: "The requested thread or operation was not found."
            case .missingProject: "This thread's project is unavailable."
            case .unsupported: "This thread or action is not supported by local control."
            case .archived: "Archived threads cannot be controlled externally."
            case .workspacePreparing: "This worktree is still being prepared."
            case .workspaceFailed: "This workspace could not be prepared. It will not fall back to the project directory."
            case .directoryUnavailable: "The thread's execution directory is unavailable."
            case .persistence: "Tivano could not persist the local-control operation."
            case .conflict: "The operation payload or thread configuration changed."
            case .continuationUnavailable: "The requested conversation continuation is unavailable."
            case .shutdown: "Tivano is preparing to quit or update. Local control is suspended."
            case .corruptHistory: "This thread's persisted history is missing or unreadable."
            case .cursorInvalid: "This page changed. Restart pagination without a cursor."
            case .providerFailure: "The provider reported a failure. Check the thread in Tivano."
            case .internalError: "The local-control request could not be completed."
            }
        }
    }
    var code: Code
    /// Diagnostic identifiers only; never a provider credential, environment or settings dump.
    var detail: String? = nil
    var errorDescription: String? {
        let message = Bundle.main.localizedString(forKey: code.message, value: code.message, table: "Localizable")
        return message + (detail.map { " [\(code.rawValue): \($0)]" } ?? "")
    }
}
