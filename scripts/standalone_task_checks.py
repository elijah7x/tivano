#!/usr/bin/env python3
"""Exercise production task persistence and directory resolution without launching Tivano."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def declaration(path: str, marker: str) -> str:
    source = (ROOT / path).read_text()
    start = source.index(marker)
    opening = source.index("{", start)
    depth, end = 1, opening + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


# Unrelated provider and presentation types are stubbed; model encoding, filesystem
# writes and directory resolution below come directly from production source.
swift = r'''
import Foundation
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
enum CaptureRun {
    static let storageRoot: URL? = URL(fileURLWithPath: CommandLine.arguments[1])
    static let defaults: UserDefaults? = UserDefaults(suiteName: "task-checks-" + UUID().uuidString)
}
enum AppInfo { static let libraryName = "Unused task checks" }
enum Chrome { static func localized(_ key: String) -> String { key } }
enum ProviderError: Error { case failed(String), notRunning }
'''
for path in ("Tivano/Core/Support/Coding.swift", "Tivano/Core/Models/LocalControl.swift",
             "Tivano/Core/Models/Library.swift",
             "Tivano/Core/Support/StoragePaths.swift"):
    swift += "\n" + (ROOT / path).read_text()
swift += r'''
enum Storage {
    static let root = StoragePaths.root
    static let libraryURL = root.appendingPathComponent("library.json")
    static let preStandaloneLibraryURL = root.appendingPathComponent("library-before-standalone.json")
'''
swift += declaration("Tivano/Services/Store/Storage.swift", "    nonisolated static func prepareLibraryWrite(")
swift += "\n}\n"
swift += r'''
final class ModelHarness {
    var projects: [Project] = []
    var threads: [ChatThread] = []
    var selectedThread: ChatThread?
    final class Settings { var lastThreadAffiliation: ThreadAffiliation? }
    let settings = Settings()
    struct Runtime {
        var isRunning = false
        var isLoadingHistory = false
        var turns: [Int] = []
        var hasSentPrompts = false
    }
    var runtimes: [UUID: Runtime] = [:]
    var creatingWorktrees: Set<UUID> = []
    func existingRuntime(for id: UUID) -> Runtime? { runtimes[id] }
    func children(of id: UUID) -> [ChatThread] { threads.filter { $0.parentThreadID == id } }
    func project(_ id: UUID?) -> Project? { projects.first { $0.id == id } }
    func thread(_ id: UUID) -> ChatThread? { threads.first { $0.id == id } }
'''
for marker in ("    func executionDirectory(for", "    func ensureExecutionDirectory(for",
               "    var currentAffiliation:", "    func canChangeThreadAffiliation("):
    swift += "\n" + declaration("Tivano/App/AppModel.swift", marker)
swift += "\n}\n"
swift += r'''
func check(_ condition: @autoclosure () throws -> Bool, _ message: String) {
    let result = try! condition()
    precondition(result, message)
}
func expectFailure(line: UInt = #line, _ operation: () throws -> Void) {
    do { try operation() } catch { return }
    preconditionFailure("Expected an error at test line \(line)")
}
func makeThread(_ projectID: UUID? = nil) -> ChatThread {
    ChatThread(projectID: projectID, provider: .codex, model: nil, effort: nil, runtimeMode: .supervised)
}

@main struct Checks {
    static func main() throws {
        setbuf(stdout, nil)
        let encoder = JSONEncoder.storage
        let decoder = JSONDecoder.storage
        let manager = FileManager.default
        let root = StoragePaths.root
        var project = Project(name: "Existing", path: "/example/project")
        project.icon = .emoji("🛠️")
        let oldID = UUID()
        let old = Data("{\"id\":\"\(oldID)\",\"projectID\":\"\(project.id)\"}".utf8)
        let restored = try decoder.decode(ChatThread.self, from: old)
        check(restored.projectID == project.id && restored.hasStartedTurn, "Legacy affiliation or send boundary changed")
        let task = makeThread()
        let taskData = try encoder.encode(task)
        let restoredTask = try decoder.decode(ChatThread.self, from: taskData)
        check(restoredTask.affiliation == .standalone && !restoredTask.hasStartedTurn, "Task round trip lost affiliation")
        let invalid = Data("{\"id\":\"\(oldID)\",\"projectID\":42}".utf8)
        expectFailure { _ = try decoder.decode(ChatThread.self, from: invalid) }
        let badUUID = Data("{\"id\":\"\(oldID)\",\"projectID\":\"invalid\"}".utf8)
        expectFailure { _ = try decoder.decode(ChatThread.self, from: badUUID) }
        var library = Library()
        library.projects = [project]
        library.threads = [restored, task]
        let roundTrip = try decoder.decode(Library.self, from: encoder.encode(library))
        check(roundTrip.projects[0].icon == .emoji("🛠️"), "Existing emoji disappeared")
        project.icon = .symbol("hammer.fill")
        let symbolProject = try decoder.decode(Project.self, from: encoder.encode(project))
        check(symbolProject.icon == project.icon, "Existing symbol disappeared")
        for affiliation in [ThreadAffiliation.project(project.id), .standalone] {
            let decoded = try decoder.decode(ThreadAffiliation.self, from: encoder.encode(affiliation))
            check(decoded == affiliation, "Remembered affiliation changed")
        }
        print("PASS: legacy library, icons, task and preference round trips, malformed project IDs")

        let model = ModelHarness()
        model.projects = [project]
        let other = makeThread()
        check(model.currentAffiliation == .standalone, "First use must allow a task")
        model.settings.lastThreadAffiliation = .project(project.id)
        check(model.currentAffiliation == .project(project.id), "Forgot last project")
        model.selectedThread = task
        check(model.currentAffiliation == .standalone, "Task selection fell back to a project")
        model.selectedThread = nil
        model.settings.lastThreadAffiliation = .standalone
        model.threads = [restored]
        check(model.currentAffiliation == .standalone, "Remembered task fell back to old history")
        model.threads.append(task)
        check(model.canChangeThreadAffiliation(task.id), "New draft cannot change location")
        check(!model.canChangeThreadAffiliation(restored.id), "Legacy history can change location")
        model.creatingWorktrees.insert(task.id)
        check(!model.canChangeThreadAffiliation(task.id), "Worktree creation can race location changes")
        model.creatingWorktrees.remove(task.id)
        model.runtimes[task.id] = ModelHarness.Runtime(turns: [1])
        check(!model.canChangeThreadAffiliation(task.id), "Loaded history can change location")
        model.runtimes[task.id] = nil
        var sent = task
        sent.hasStartedTurn = true
        model.threads = [try decoder.decode(ChatThread.self, from: encoder.encode(sent))]
        check(!model.canChangeThreadAffiliation(task.id), "Restart lost first-message boundary")
        print("PASS: current/recent affiliation and first-message/worktree switch boundaries")

        var placedFirst = task
        var placedLast = other
        let day = Calendar.current.startOfDay(for: task.updatedAt)
        placedFirst.activityOrder = 0
        placedFirst.activityOrderDay = day
        placedLast.activityOrder = 1
        placedLast.activityOrderDay = day
        check(ChatThread.orderedByActivity([placedLast, placedFirst]).map(\.id) == [task.id, other.id], "Task drag order lost")
        placedLast.updatedAt = Calendar.current.date(byAdding: .day, value: 1, to: day)!
        check(ChatThread.orderedByActivity([placedFirst, placedLast]).first?.id == other.id, "Stale drag order beats fresh activity")
        print("PASS: task ordering and stale drag-order expiry")

        var helper = makeThread()
        helper.parentThreadID = task.id
        model.threads = [task, other, helper]
        let taskDirectory = try model.executionDirectory(for: task)
        let otherDirectory = try model.executionDirectory(for: other)
        let helperDirectory = try model.executionDirectory(for: helper)
        check(taskDirectory != otherDirectory, "Tasks share a workspace")
        check(taskDirectory == helperDirectory, "Helper left its task workspace")
        check(!manager.fileExists(atPath: root.path), "Read-only directory resolution wrote to disk")
        _ = try model.ensureExecutionDirectory(for: helper)
        check(manager.fileExists(atPath: taskDirectory), "Workspace was not created")
        check(!manager.fileExists(atPath: otherDirectory), "Unrelated workspace was created")
        let payload = URL(fileURLWithPath: taskDirectory).appendingPathComponent("result.txt")
        try Data("keep".utf8).write(to: payload)
        _ = try model.ensureExecutionDirectory(for: restoredTask)
        check(try Data(contentsOf: payload) == Data("keep".utf8), "Resume overwrote task files")
        var linked = makeThread(project.id)
        linked.worktreePath = "/example/worktree"
        check(try model.executionDirectory(for: linked) == linked.worktreePath, "Project worktree lost priority")
        helper.hydra = HydraHeadInfo(targetCheckout: "/example/explicit")
        helper.worktreePath = "/example/head-copy"
        check(try model.executionDirectory(for: helper) == helper.worktreePath, "Hydra copy lost priority")
        expectFailure { _ = try model.executionDirectory(for: makeThread(UUID())) }
        helper.hydra = nil
        helper.parentThreadID = UUID()
        expectFailure { _ = try model.executionDirectory(for: helper) }
        var cycle = task
        cycle.parentThreadID = helper.id
        helper.parentThreadID = cycle.id
        model.threads = [cycle, helper]
        expectFailure { _ = try model.executionDirectory(for: cycle) }
        print("PASS: task isolation, helper routing, explicit worktrees, restart files and missing/cyclic ancestry")

        var legacyLibrary = Library()
        legacyLibrary.projects = [project]
        legacyLibrary.threads = [restored]
        let original = try encoder.encode(legacyLibrary)
        try original.write(to: Storage.libraryURL)
        try Storage.prepareLibraryWrite(legacyLibrary, to: Storage.libraryURL)
        check(!manager.fileExists(atPath: Storage.preStandaloneLibraryURL.path), "Legacy-only save created migration backup")
        try Storage.prepareLibraryWrite(library, to: Storage.libraryURL)
        let backup = try Data(contentsOf: Storage.preStandaloneLibraryURL)
        check(backup == original, "Backup does not preserve original library")
        try encoder.encode(library).write(to: Storage.libraryURL, options: .atomic)
        try Storage.prepareLibraryWrite(library, to: Storage.libraryURL)
        check(try Data(contentsOf: Storage.preStandaloneLibraryURL) == original, "Later save replaced migration backup")
        try manager.removeItem(at: Storage.preStandaloneLibraryURL)
        try manager.createDirectory(at: Storage.preStandaloneLibraryURL, withIntermediateDirectories: false)
        expectFailure { try Storage.prepareLibraryWrite(library, to: Storage.libraryURL) }
        print("PASS: pre-migration backup, no overwrite and invalid-backup failure")
    }
}
'''
with tempfile.TemporaryDirectory(prefix="tivano-task-checks-") as temporary:
    directory = Path(temporary)
    source, binary = directory / "Checks.swift", directory / "checks"
    source.write_text(swift)
    subprocess.run(["xcrun", "swiftc", "-parse-as-library", str(source), "-o", str(binary)], check=True)
    subprocess.run([str(binary), str(directory / "isolated-library")], check=True)
