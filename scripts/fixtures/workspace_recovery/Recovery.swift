import Foundation

// Only unrelated provider/presentation types and environment are synthetic.
enum RuntimeMode: String, Codable { case supervised }
enum ProviderKind: String, Codable {
    case codex
    func supported(_ mode: RuntimeMode) -> RuntimeMode { mode }
}
enum DshAgentMode: String, Codable { case standard }
enum InteractionMode: String, Codable { case build }
enum TurnStatus: String, Codable { case completed }
struct HydraPair: Codable, Hashable { var id = UUID() }
struct HydraHeadInfo: Codable, Hashable { var targetCheckout: String? }
enum PermissionLowering {
    static func note(provider: ProviderKind, from: RuntimeMode, to: RuntimeMode) {}
}
struct FixtureDefaults: Sendable {
    static var standard: FixtureDefaults { fatalError("Real defaults must not be used") }
    func object(forKey key: String) -> Any? { nil }
}
enum CaptureRun {
    static let defaults: FixtureDefaults? = FixtureDefaults()
}
enum Chrome { static func localized(_ key: String) -> String { key } }
enum ProviderError: Error { case failed(String) }
enum StoragePaths {
    static let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    /* TASK_PATH_PRODUCTION */
}

// Fixed filenames allow real filesystem collisions, not mocked write results.
final class ISO8601DateFormatter {
    var formatOptions: Foundation.ISO8601DateFormatter.Options = []
    func string(from date: Date) -> String { "fixture" }
}

/* MODELS_PRODUCTION */

enum Storage {
    static let root = StoragePaths.root
    static let libraryURL = root.appendingPathComponent("library.json")
    static let preStandaloneLibraryURL = root.appendingPathComponent("library-before-standalone.json")
    /* STORAGE_PRODUCTION */
}

final class ModelHarness {
    var projects: [Project] = []
    var threads: [ChatThread] = []
    func project(_ id: UUID?) -> Project? { projects.first { $0.id == id } }
    func thread(_ id: UUID) -> ChatThread? { threads.first { $0.id == id } }
    /* EXECUTION_PRODUCTION */
}

@main struct RecoveryChecks {
    struct Failure: Error { let message: String }

    static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw Failure(message: message) }
    }

    static func rejects(_ code: ControlFailure.Code, _ operation: () throws -> Void) throws {
        do {
            try operation()
        } catch let error as ControlFailure {
            try check(error.code == code, "Unexpected execution failure: \(error.code)")
            return
        }
        throw Failure(message: "executionDirectory did not reject with \(code)")
    }

    static func object<T: Encodable>(_ value: T) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: JSONEncoder.storage.encode(value)) as! [String: Any]
    }

    static func normalized(_ thread: ChatThread) throws -> ChatThread {
        try JSONDecoder.storage.decode(ChatThread.self, from: JSONEncoder.storage.encode(thread))
    }

    static func checkClosed(_ thread: ChatThread, in model: ModelHarness) throws {
        try check(thread.controlWorkspace?.mode == .worktree, "Repaired workspace is not a worktree")
        try check(thread.controlWorkspace?.phase == .failed, "Repaired workspace is not failed")
        try check(thread.controlWorkspace?.failure?.code == .workspaceFailed, "Missing persisted workspace failure")
        try check(thread.controlWorkspace?.enforcesExecutionReadiness == true, "Readiness is not enforced")
        try rejects(.workspaceFailed) { _ = try model.executionDirectory(for: thread) }
    }

    static func main() throws {
        let root = Storage.root
        let name = CommandLine.arguments[2]
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        do {
            let checks = try run(name)
            let report: [String: Any] = ["case": name, "pass": true, "checks": checks]
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: root.appendingPathComponent("results.json"))
            print(String(decoding: data, as: UTF8.self))
        } catch {
            let report: [String: Any] = ["case": name, "pass": false, "error": String(describing: error)]
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: root.appendingPathComponent("results.json"))
            }
            throw error
        }
    }

    static func run(_ name: String) throws -> [String] {
        let root = Storage.root
        let manager = FileManager.default
        let project = Project(name: "Synthetic project", path: root.appendingPathComponent("project").path)
        var projects = [project]
        var normal = try (0..<3).map { index in
            var thread = ChatThread(projectID: project.id, provider: .codex, model: "synthetic", effort: "fixture", runtimeMode: .supervised)
            thread.title = "Preserved normal \(index)"
            thread.providerSessionID = "synthetic-normal-\(index)"
            thread.hydraEnabled = false
            thread.isPinned = index == 0
            thread.hasStartedTurn = true
            return try normalized(thread)
        }
        var subject = normal[0]
        subject.id = UUID()
        subject.title = "Keep every other field"
        subject.providerSessionID = "synthetic-resume-id"
        subject.providerResumeAt = "synthetic-turn-id"
        subject.branch = "fixture-branch"
        subject.hasCustomTitle = true
        subject.hasUnread = true
        subject.unreadRevision = UUID()
        subject.lastAttentionTurnID = UUID()
        subject.pendingResultTurnID = UUID()
        subject.sortOrder = 3
        subject.activityOrder = 2
        subject.activityOrderDay = subject.updatedAt
        subject.expandsHelpers = true
        subject.hydraSpawnCount = 4
        if ["ready", "ready_unenforced"].contains(name) {
            subject.worktreePath = root.appendingPathComponent("checkout").path
        } else if ["ready_empty", "ready_empty_unenforced"].contains(name) {
            subject.worktreePath = ""
        }
        if name == "only_bad" {
            normal = []
            projects = []
            subject.projectID = nil
        }
        if name == "majority_bad" {
            normal = [normal[0]]
            normal[0].projectID = nil
            projects = []
            subject.projectID = nil
        }
        let preservedSubject = try normalized(subject)
        var raw = try object(subject)
        var workspace: [String: Any] = ["mode": "worktree", "phase": "ready", "enforcesExecutionReadiness": true]
        let controls = ["missing", "null", "local", "local_unenforced", "preparing", "preparing_unenforced", "ready", "ready_unenforced"]
        let damaged = !controls.contains(name) && name != "previous_fallback"
        switch name {
        case "missing": break
        case "null": raw["controlWorkspace"] = NSNull()
        case "local", "local_unenforced", "previous_fallback":
            workspace["mode"] = "local"
            workspace["enforcesExecutionReadiness"] = name != "local_unenforced"
            raw["controlWorkspace"] = workspace
        case "preparing", "preparing_unenforced":
            workspace["phase"] = "preparing"
            workspace["enforcesExecutionReadiness"] = name != "preparing_unenforced"
            raw["controlWorkspace"] = workspace
        case "wrong_type", "only_bad", "other_bad_field", "mixed_skipped", "majority_bad", "backup_failure", "quarantine_failure":
            raw["controlWorkspace"] = "invalid synthetic workspace"
        case "number": raw["controlWorkspace"] = 42
        case "array": raw["controlWorkspace"] = ["worktree", "ready"]
        case "unknown_mode":
            workspace["mode"] = "future-mode"
            raw["controlWorkspace"] = workspace
        case "unknown_phase":
            workspace["phase"] = "future-phase"
            raw["controlWorkspace"] = workspace
        case "missing_mode":
            workspace.removeValue(forKey: "mode")
            raw["controlWorkspace"] = workspace
        case "missing_phase":
            workspace.removeValue(forKey: "phase")
            raw["controlWorkspace"] = workspace
        case "missing_enforcement":
            workspace.removeValue(forKey: "enforcesExecutionReadiness")
            raw["controlWorkspace"] = workspace
        case "ready", "ready_nil", "ready_empty": raw["controlWorkspace"] = workspace
        case "ready_unenforced", "ready_nil_unenforced", "ready_empty_unenforced":
            workspace["enforcesExecutionReadiness"] = false
            raw["controlWorkspace"] = workspace
        default: throw Failure(message: "Unknown fixture \(name)")
        }
        if name == "other_bad_field" { raw["hasStartedTurn"] = "not a boolean" }
        // Unknown content must survive in quarantine, not just its ID or rewritten workspace.
        if damaged { raw["futureMetadata"] = ["nested": ["keep", "all", "raw", "values"]] }
        let rawData = try JSONSerialization.data(withJSONObject: raw, options: [.sortedKeys])
        if damaged {
            do {
                _ = try JSONDecoder.storage.decode(ChatThread.self, from: rawData)
                throw Failure(message: "Damaged record bypassed strict decoding")
            } catch is DecodingError {}
        } else {
            _ = try JSONDecoder.storage.decode(ChatThread.self, from: rawData)
        }

        var threadRecords = try normal.map(object) + [raw]
        var projectRecords = try projects.map(object)
        var quarantinedThreads: [[String: Any]] = damaged ? [raw] : []
        var quarantinedProjects: [[String: Any]] = []
        if name == "mixed_skipped" || name == "majority_bad" {
            for _ in 0..<(name == "majority_bad" ? 3 : 1) {
                var unreadable = try object(subject)
                unreadable["id"] = UUID().uuidString
                unreadable["projectID"] = "not-a-uuid"
                threadRecords.append(unreadable)
                quarantinedThreads.append(unreadable)
            }
        }
        if name == "mixed_skipped" {
            let unreadable: [String: Any] = ["id": UUID().uuidString, "path": 42]
            projectRecords.append(unreadable)
            quarantinedProjects.append(unreadable)
        }
        let encoded = try JSONSerialization.data(withJSONObject: ["projects": projectRecords, "threads": threadRecords], options: [.prettyPrinted, .sortedKeys])
        let original = name == "previous_fallback" ? Data("{truncated-library".utf8) : encoded
        try original.write(to: Storage.libraryURL, options: .atomic)
        if name == "previous_fallback" {
            try encoded.write(to: root.appendingPathComponent("library-previous.json"), options: .atomic)
        }
        let backupURL = root.appendingPathComponent("library-before-recovery-fixture.json")
        let quarantineURL = root.appendingPathComponent("library-quarantine-fixture.json")
        if name == "backup_failure" || name == "quarantine_failure" {
            let blocked = name == "backup_failure" ? backupURL : quarantineURL
            try manager.createDirectory(at: blocked, withIntermediateDirectories: false)
            try Data("keep blocker".utf8).write(to: blocked.appendingPathComponent("sentinel"))
        }
        let load = Storage.loadLibraryRecovering()
        try check(try Data(contentsOf: Storage.libraryURL) == original, "Recovery rewrote original bytes before save")
        if ["backup_failure", "quarantine_failure", "majority_bad"].contains(name) {
            guard case .failed = load else { throw Failure(message: "Unsafe recovery was allowed: \(name)") }
            if name == "quarantine_failure" {
                try check(try Data(contentsOf: backupURL) == original, "Quarantine failure did not preserve successful backup")
            }
            if name == "majority_bad" {
                try check(!manager.fileExists(atPath: backupURL.path), "Majority guard ran after recovery writes")
            } else {
                let blocked = name == "backup_failure" ? backupURL : quarantineURL
                try check(try Data(contentsOf: blocked.appendingPathComponent("sentinel")) == Data("keep blocker".utf8), "Recovery changed collision sentinel")
            }
            return ["strict decoding", "failed without publishing recovered library", "original bytes unchanged"]
        }

        let library: Library
        let expectedSkipped = name == "other_bad_field" ? 1 : (name == "mixed_skipped" ? 2 : 0)
        switch load {
        case .loaded(let value):
            try check(!damaged && name != "previous_fallback", "Damaged library silently loaded")
            library = value
        case .recovered(let value, let skipped, let quarantine, let backup, let fromPrevious):
            try check(damaged || name == "previous_fallback", "Valid library needed recovery")
            try check(skipped == expectedSkipped, "Quarantined records were counted as skipped")
            try check(fromPrevious == (name == "previous_fallback"), "Wrong recovery source")
            try check(try Data(contentsOf: backup) == original, "Backup changed original bytes")
            if damaged {
                guard let quarantine else { throw Failure(message: "Missing quarantine") }
                let quarantined = try JSONSerialization.jsonObject(with: Data(contentsOf: quarantine)) as! [String: Any]
                let expected: [String: Any] = ["projects": quarantinedProjects, "threads": quarantinedThreads]
                try check(NSDictionary(dictionary: quarantined).isEqual(to: expected), "Quarantine lost or rewrote original records")
            } else {
                try check(quarantine == nil, "Clean previous library had quarantined records")
            }
            library = value
        case .failed(let error): throw Failure(message: "Unexpected recovery failure: \(error)")
        }
        let subjectKept = name != "other_bad_field"
        try check(library.threads.count == normal.count + (subjectKept ? 1 : 0), "Unexpected retained thread count")
        let normalizedProjects = try JSONDecoder.storage.decode([Project].self, from: JSONEncoder.storage.encode(projects))
        try check(library.projects == normalizedProjects, "Normal project fields changed")
        try check(normal.allSatisfy { library.threads.contains($0) }, "Normal thread fields changed")
        let model = ModelHarness()
        model.projects = library.projects
        model.threads = library.threads
        if subjectKept {
            guard let recovered = model.thread(subject.id) else { throw Failure(message: "Recoverable chat was lost") }
            if damaged {
                try checkClosed(recovered, in: model)
                var otherFields = recovered
                otherFields.controlWorkspace = nil
                try check(otherFields == preservedSubject, "Repair changed fields other than controlWorkspace")
            } else {
                let expected = try JSONDecoder.storage.decode(ChatThread.self, from: rawData)
                try check(recovered == expected, "Valid record changed")
                if name == "preparing" {
                    try rejects(.workspacePreparing) { _ = try model.executionDirectory(for: recovered) }
                } else {
                    let path = try model.executionDirectory(for: recovered)
                    let expectedPath = ["ready", "ready_unenforced"].contains(name) ? subject.worktreePath! : project.path
                    try check(path == expectedPath, "Valid workspace directory changed")
                }
            }
        } else {
            try check(model.thread(subject.id) == nil, "Other undecodable fields were forced into the library")
        }

        // Exercise the real save preparation and encoding; writer queues/App bootstrap are outside this fixture.
        try Storage.prepareLibraryWrite(library, to: Storage.libraryURL)
        try JSONEncoder.storage.encode(library).write(to: Storage.libraryURL, options: .atomic)
        guard case .loaded(let reloaded) = Storage.loadLibraryRecovering() else {
            throw Failure(message: "Saved recovery did not reload cleanly")
        }
        try check(reloaded.threads == library.threads && reloaded.projects == library.projects, "Saved recovery changed on reload")
        model.threads = reloaded.threads
        if damaged && subjectKept {
            guard let recovered = model.thread(subject.id) else { throw Failure(message: "Reload lost recovered chat") }
            try checkClosed(recovered, in: model)
        }
        if damaged || name == "previous_fallback" {
            try check(try Data(contentsOf: backupURL) == original, "Save/reload changed recovery backup")
        }
        return ["strict decoding", "retained and skipped counts", "raw backup and quarantine", "unchanged other fields", "independent workspace-state and execution checks", "save/reload"]
    }
}
