#!/usr/bin/env python3
"""Exercise actual Voice teardown and AppModel activity accounting with gated IO."""
from pathlib import Path
import subprocess
import sys
import tempfile
sys.dont_write_bytecode = True
from local_control_domain_checks import declaration
ROOT = Path(__file__).resolve().parents[1]
VOICE = 'Tivano/App/Runtime/VoiceController.swift'
APP = 'Tivano/App/AppModel.swift'
swift = r'''
import AppKit
import Foundation
actor Gate {
    var waiting: CheckedContinuation<Void, Never>?
    func wait() async { await withCheckedContinuation { waiting = $0 } }
    func release() { waiting?.resume(); waiting = nil }
    var entered: Bool { waiting != nil }
}
@MainActor final class ThreadRuntime {
    var isRunning = false, isVoiceOrchestrator = false, isHydraMerging = false, isCLIStarting = false
    var hydraReviewRunning: String?
    var backgroundTasks: [Int] = []
    var isWaitingForLimit = false, hasWorkingHelpers = false
    enum Phase { case idle, running }
    var phase = Phase.idle
    var externalSubmission: Int?, session: Int?, providerHistoryOperation: Int?, pendingSend: Int?, followUpEdit: Int?, messageEdit: Int?, hydraLanding: Int?, headBudget: Int?
    var isReverting = false, isLoadingHistory = false, hydraFlushScheduled = false
    var controlInterrupts: [Int] = [], draft: [Int] = [], approvals: [Int] = [], questions: [Int] = []
    var hydraPendingReports: [Int] = [], hydraBatches: [Int] = [], hydraWaiting: [Int] = [], commandTrees: [Int] = [], foreignCommandBases: [Int] = [], commandSettles: [Int] = []
/* PERSISTED_STATE */
}
enum Mode { case off, on }
enum CaptureRun { static let isEnabled = false }
struct Settings { var taskSleepMode = Mode.on }
@MainActor final class SleepPrevention {
    var running = false
    func update(mode: Mode, hasRunningTasks: Bool) { running = hasRunningTasks }
}
@MainActor final class AppModel {
    var runtimes: [UUID: ThreadRuntime] = [:]
    var voice: VoiceController!
    struct Local { var hasPendingMutations = false }
    var localControl = Local(), settings = Settings()
    var hasActiveTurns = false, activeWorkIsLimitWait = false
    var taskSleepPrevention = SleepPrevention()
    func existingRuntime(for id: UUID) -> ThreadRuntime? { runtimes[id] }
'''
swift = swift.replace('/* PERSISTED_STATE */', declaration('Tivano/App/Runtime/ThreadRuntime.swift', '    var holdsOnlyPersistedState:'))
swift += declaration(APP, '    func updateTaskSleepPrevention(') + '\n'
swift += declaration(APP, '    private static func hasActiveTasks(') + '\n}\n'
swift += declaration('Tivano/Core/Models/Voice.swift', 'enum VoicePhase:')
swift += r'''
@MainActor final class FakeSession {
    var onVoiceNotification: (() -> Void)?, onVoiceClosed: (() -> Void)?
    var voiceThreadID: String? = "fixture"
    let gate = Gate()
    func voiceRequest(_ method: String, _ params: [String: String], seconds: Double) async throws -> Bool {
        await gate.wait(); return true
    }
}
@MainActor final class Host { func close() {} }
@MainActor final class VoiceController {
    weak var app: AppModel?
    var epoch = 0
    var task: Task<Void, Never>?, startDeadline: Task<Void, Never>?, levelsTask: Task<Void, Never>?, homeTask: Task<Void, Never>?
    var stopID: UUID?, threadID: UUID?
    var sleepObserver: NSObjectProtocol?
    var startSignals: AsyncStream<Bool>.Continuation?
    var realtimeSessionID: String?
    var session: FakeSession?, host: Host?
    var serverLive = false
    init(app: AppModel) { self.app = app }
'''
for marker in ('    private(set) var phase:', '    private var stopTask:', '    var isLive:', '    var hasPendingWork:', '    private func teardown('):
    swift += declaration(VOICE, marker).replace('private(set) ', '').replace('private ', '') + '\n'
swift += r'''
}
@main struct Checks {
    @MainActor static func until(_ predicate: () async -> Bool) async {
        for _ in 0..<20_000 { if await predicate() { return }; await Task.yield() }
        preconditionFailure("gate not reached")
    }
    @MainActor static func main() async {
        let app = AppModel(), id = UUID(), runtime = ThreadRuntime()
        app.voice = VoiceController(app: app)
        app.runtimes[id] = runtime
        app.updateTaskSleepPrevention()
        precondition(!app.hasActiveTurns)
        app.voice.phase = .checking
        precondition(app.hasActiveTurns && app.taskSleepPrevention.running && !app.activeWorkIsLimitWait)
        app.voice.phase = .starting
        precondition(app.hasActiveTurns)
        let session = FakeSession()
        app.voice.session = session
        app.voice.serverLive = true
        app.voice.teardown()
        app.voice.phase = .closed
        precondition(app.hasActiveTurns && app.voice.hasPendingWork)
        await until { await session.gate.entered }
        // Queue another stop while the previous one is still in its await.
        let run = Gate()
        app.voice.task = Task { await run.wait() }
        await until { await run.entered }
        app.voice.teardown()
        await session.gate.release()
        for _ in 0..<20 { await Task.yield() }
        precondition(app.hasActiveTurns && app.voice.hasPendingWork)
        await run.release()
        await until { !app.voice.hasPendingWork }
        precondition(!app.hasActiveTurns && !app.taskSleepPrevention.running)
        runtime.isWaitingForLimit = true
        app.updateTaskSleepPrevention()
        precondition(app.activeWorkIsLimitWait)
        precondition(runtime.holdsOnlyPersistedState)
        runtime.hydraReviewRunning = "fixture"
        precondition(!runtime.holdsOnlyPersistedState)
        app.updateTaskSleepPrevention()
        precondition(app.hasActiveTurns && !app.activeWorkIsLimitWait)
        runtime.hydraReviewRunning = nil
        precondition(runtime.holdsOnlyPersistedState)
        runtime.isWaitingForLimit = false
        app.updateTaskSleepPrevention()
        precondition(!app.hasActiveTurns)
        print("PASS: Voice checking/connecting/chained teardown and Hydra review activity barriers")
    }
}
'''
# JSONValue.string in the production teardown is a leaf dependency of the fake RPC.
swift = swift.replace('["threadId": .string(stoppingThread)]', '["threadId": stoppingThread]')
with tempfile.TemporaryDirectory(prefix='tivano-activity-audit-') as folder:
    out = Path(folder); source = out/'Checks.swift'; source.write_text(swift)
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-parse-as-library', str(source), '-o', str(out/'run')], check=True, timeout=120)
    subprocess.run([str(out/'run')], check=True, timeout=30)
