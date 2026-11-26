#!/usr/bin/env python3
"""Exercise production send/discovery methods with in-memory RPC gates.

No provider, socket, user configuration, or user attachment is opened. Only the
Swift compiler and the resulting isolated fixture executable are launched. Run
this from the lead checkout; heads do not execute it.
"""
from pathlib import Path
import os
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
PROVIDERS = ROOT / "Tivano/Services/Providers"


def declaration(path: Path, marker: str) -> str:
    source = path.read_text()
    start = source.index(marker)
    opening = source.index("{", start)
    depth, end = 1, opening + 1
    while depth and end < len(source):
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    if depth:
        raise ValueError(f"Unterminated declaration: {path}: {marker}")
    # Access control is the only change to extracted declarations.
    return source[start:end].replace("private ", "")


def methods(file: str, *markers: str) -> str:
    return "\n".join(declaration(PROVIDERS / file, marker) for marker in markers) + "\n"


def unique_declaration(path: Path, marker: str) -> str:
    count = path.read_text().count(marker)
    if count != 1:
        raise ValueError(f"{path}: marker {marker!r} found {count} times, expected 1")
    return declaration(path, marker)


def source_block(text: str, marker: str, label: str) -> str:
    count = text.count(marker)
    if count != 1:
        raise ValueError(f"{label}: marker {marker!r} found {count} times, expected 1")
    start = text.index(marker)
    opening = text.find("{", start)
    if opening == -1:
        raise ValueError(f"{label}: marker {marker!r} has no opening brace")
    depth, end = 1, opening + 1
    while depth and end < len(text):
        depth += (text[end] == "{") - (text[end] == "}")
        end += 1
    if depth:
        raise ValueError(f"{label}: unterminated block for {marker!r}")
    return text[start:end]


def extract_calls(text: str, prefix: str, label: str) -> list[str]:
    calls = []
    cursor = 0
    while True:
        start = text.find(prefix, cursor)
        if start == -1:
            break
        opening = start + len(prefix) - 1
        depth, end = 1, opening + 1
        while depth and end < len(text):
            depth += (text[end] == "(") - (text[end] == ")")
            end += 1
        if depth:
            raise ValueError(f"{label}: unterminated call for {prefix!r}")
        calls.append(text[start:end])
        cursor = end
    if not calls:
        raise ValueError(f"{label}: expected at least one call to {prefix!r}")
    return calls


def check_source_invariants() -> None:
    app_model = ROOT / "Tivano/App/AppModel.swift"
    runtime = ROOT / "Tivano/App/Runtime/ThreadRuntime.swift"
    hydra = ROOT / "Tivano/App/AppModel+Hydra.swift"

    # 1. Auto-shelve teardown must not unregister memoryPressureObserver; isolated deinit must.
    stop_auto_shelve = unique_declaration(app_model, "    private func stopAutoShelveSchedule()")
    if "memoryPressureObserver" in stop_auto_shelve:
        raise AssertionError("AppModel.stopAutoShelveSchedule() must not reference memoryPressureObserver")
    isolated_deinit = unique_declaration(app_model, "    isolated deinit")
    if "NotificationCenter.default.removeObserver(memoryPressureObserver)" not in isolated_deinit:
        raise AssertionError("AppModel.isolated deinit must remove memoryPressureObserver")

    # 2. ThreadRuntime.install(_:prepared:) must preserve an in-memory forwardedContinuation.
    install = unique_declaration(
        runtime, "    private func install(_ document: ThreadDocument, prepared: Bool = false)"
    )
    forwarded_lines = [line.strip() for line in install.splitlines() if "forwardedContinuation =" in line]
    if not forwarded_lines:
        raise AssertionError("ThreadRuntime.install(_:prepared:) is missing forwardedContinuation assignment")
    for line in forwarded_lines:
        if "?? forwardedContinuation" not in line:
            raise AssertionError(
                f"ThreadRuntime.install(_:prepared:) must preserve forwardedContinuation with '?? forwardedContinuation': {line}"
            )

    # 3. Busy/reverting refuseBlock must defer refusals instead of starting a turn;
    #    finishTurn (via finalizeTurn after flushHydraReports) and startHydraReportTurn must drain them.
    refuse_block = unique_declaration(
        runtime, "    private func refuseBlock(_ message: String, dropped: String) -> DelegationOutcome"
    )
    busy_refusal = source_block(refuse_block, "guard phase == .idle, !isReverting else {", "ThreadRuntime.refuseBlock")
    if "deferredRefusals.append(" not in busy_refusal:
        raise AssertionError("ThreadRuntime.refuseBlock(_:dropped:) must append to deferredRefusals when busy or reverting")
    if "startTurn" in busy_refusal:
        raise AssertionError("ThreadRuntime.refuseBlock(_:dropped:) must not call startTurn when busy or reverting")

    finish_turn = unique_declaration(
        runtime, "    private func finishTurn(status: TurnStatus, turnID: UUID?, error: String? = nil) async"
    )
    if "await finalizeTurn(" not in finish_turn:
        raise AssertionError("ThreadRuntime.finishTurn must delegate to finalizeTurn")
    finalize_turn = unique_declaration(
        runtime, "    private func finalizeTurn(status: TurnStatus, turnID: UUID?, error: String? = nil) async"
    )
    flush_marker = "if !continues, status != .interrupted, flushHydraReports() { continues = true }"
    deferred_marker = "if !continues, status != .interrupted, !deferredRefusals.isEmpty {"
    if flush_marker not in finalize_turn:
        raise AssertionError("ThreadRuntime.finalizeTurn is missing trailing flushHydraReports() check")
    deferred_branch = source_block(finalize_turn, deferred_marker, "ThreadRuntime.finalizeTurn")
    if finalize_turn.index(flush_marker) >= finalize_turn.index(deferred_marker):
        raise AssertionError("ThreadRuntime.finalizeTurn must drain deferredRefusals after flushHydraReports()")
    for required in (
        "deferredRefusals.joined(",
        "deferredRefusals.removeAll()",
        "continues = true",
        "startRefusalTurn(refusal)",
    ):
        if required not in deferred_branch:
            raise AssertionError(f"ThreadRuntime.finalizeTurn deferredRefusals branch missing {required!r}")
    if "if status == .interrupted { deferredRefusals.removeAll() }" not in finalize_turn:
        raise AssertionError("ThreadRuntime.finalizeTurn must drop deferredRefusals when the user stops the turn")
    # A refusal starts only on a lead still idle once loaded; otherwise it stays internal.
    start_refusal = unique_declaration(runtime, "    private func startRefusalTurn(_ message: String)")
    guard_marker = "guard phase == .idle, !isReverting else {"
    refusal_guard = source_block(start_refusal, guard_marker, "ThreadRuntime.startRefusalTurn")
    if "deferredRefusals.append(message)" not in refusal_guard or "startTurn" in refusal_guard:
        raise AssertionError("ThreadRuntime.startRefusalTurn must keep the refusal internal when the lead is busy")
    if start_refusal.index(guard_marker) >= start_refusal.index("await startTurn(text: message, attachments: [], hydraHeads: [])"):
        raise AssertionError("ThreadRuntime.startRefusalTurn must check the lead is idle before startTurn")
    clear_queued = unique_declaration(runtime, "    func clearQueuedHydraHeads()")
    if "deferredRefusals.removeAll()" not in clear_queued:
        raise AssertionError("ThreadRuntime.clearQueuedHydraHeads() must drop deferredRefusals")

    start_report_turn = unique_declaration(runtime, "    private func startHydraReportTurn() async")
    for required in ("let refused = deferredRefusals.map", "deferredRefusals.removeAll()", "let text = refused + "):
        if required not in start_report_turn:
            raise AssertionError(f"ThreadRuntime.startHydraReportTurn() missing {required!r}")
    if start_report_turn.index("let refused = deferredRefusals.map") >= start_report_turn.index("deferredRefusals.removeAll()"):
        raise AssertionError("ThreadRuntime.startHydraReportTurn() must read deferredRefusals before removeAll()")

    # 4. failHydraRoute and hydraHeadStartedWaiting must pass endsStreaming: false to appendHydraNote.
    for marker, label in (
        ("    private func failHydraRoute(_ id: UUID, _ message: String) -> Bool", "AppModel.failHydraRoute"),
        ("    func hydraHeadStartedWaiting(_ id: UUID)", "AppModel.hydraHeadStartedWaiting"),
    ):
        body = unique_declaration(hydra, marker)
        for call in extract_calls(body, "appendHydraNote(", label):
            if "endsStreaming: false" not in call:
                raise AssertionError(f"{label} must pass endsStreaming: false to appendHydraNote: {call}")



swift = "import Foundation\nimport CoreFoundation\nimport OSLog\n"
swift += (ROOT / "Tivano/Core/Support/JSONValue.swift").read_text()
swift += r'''
// Dependencies outside the send lifecycle are in-memory fixtures. Gates ignore
// cancellation deliberately: the caller must reject their late successful reply.
actor Gate {
    private var waiting: [CheckedContinuation<JSONValue, Never>] = []
    var count: Int { waiting.count }
    func wait() async -> JSONValue {
        await withCheckedContinuation { waiting.append($0) }
    }
    func release(_ value: JSONValue = ["success": true]) {
        let pending = waiting
        waiting.removeAll()
        for continuation in pending { continuation.resume(returning: value) }
    }
}

struct Attachment: Sendable {
    var mimeType = "image/png"
    var isImage: Bool { true }
    var path = "fixture.png"
    var name = "fixture.png"
    var gate: Gate?
    static func base64Images(_ images: [Attachment]) async -> [(image: Attachment, base64: String)] {
        var result: [(image: Attachment, base64: String)] = []
        for var image in images {
            let reply = await image.gate?.wait()
            image.mimeType = reply?["mimeType"]?.string ?? "image/jpeg"
            result.append((image, reply?["base64"]?.string ?? "eA=="))
        }
        return result
    }
}
enum RuntimeMode { case supervised, fullAccess }
enum InteractionMode { case build, plan }
enum ProviderKind { case acp, minimaxCode, dsh, kimi, antigravity }
struct SessionConfiguration { var provider = ProviderKind.acp; var dshFinalReport = false; var model: String? }
struct TurnInput {
    var text = "fixture"
    var images: [Attachment] = []
    var model: String?
    var effort: String?
    var fastMode = false
    var runtimeMode = RuntimeMode.supervised
    var interactionMode = InteractionMode.build
    var isFinalReport = false
}
enum TurnStatus: Equatable { case completed, interrupted, failed }
enum ProviderEvent {
    case turnStarted(providerTurnID: String?)
    case turnCompleted(status: TurnStatus, error: String?)
    case requestResolved(id: String)
    case modeChanged(InteractionMode)
    case messageCompleted(id: String, text: String)
    case notice(Notice)
    case tokenSpend(TokenSpend)
}
struct TokenSpend { var provider: ProviderKind; var totalTokens: Int; var model: String? }
@MainActor final class TokenLedger { static let shared = TokenLedger(); func record(spend: Int) {} }
final class AntigravityLogTailer { func setTurnActive(_ active: Bool) {}; func shutDown() {} }
@MainActor enum AntigravitySession { static func loginHint(in text: String) -> String? { nil } }
struct Notice { enum Level { case warning }; var level: Level; var message: String }
enum TextCleanup { static func stripANSI(_ value: String) -> String { value } }
enum ProviderError: Error { case notRunning, failed(String) }
enum ClaudeAccountValidationError: Error { case identityChanged, verificationFailed }
struct ClaudeCredentialError: Error {}
struct RPCError: Error { var code = 0; var message = "fixture" }
enum AppText { static func localized(_ text: String) -> String { text } }
extension String { var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) } }
enum PiCLI { static let thinkingLevels = ["high"] }
enum OmpCLI { static let thinkingLevels = ["high"] }
struct PendingReplies { mutating func resolveAll(_ value: JSONValue) {} }

@MainActor final class StdioProcess {
    var isRunning = true
    var sent: [JSONValue] = []
    func send(_ message: JSONValue) { sent.append(message) }
    func write(_ data: Data) { sent.append(JSONValue.parse(data)!) }
    func terminate() { isRunning = false }
    var prompts: [JSONValue] { sent.filter { $0["type"]?.string == "prompt" } }
}
@MainActor final class JSONRPCConnection {
    var isClosed = false
    var gates: [String: Gate] = [:]
    var requests: [String] = []
    func request(_ method: String, _ params: JSONValue) async throws -> JSONValue {
        requests.append(method)
        if let gate = gates[method] { return await gate.wait() }
        return ["stopReason": "end_turn"]
    }
    func close() { isClosed = true }
    func notify(_ method: String, _ params: JSONValue) {}
    func respond(to id: String, result: JSONValue) {}
}
@MainActor enum MiniMaxPermissionGuard {
    static func end(_ session: ACPSession) -> String? { nil }
    static func clear() {}
}
@MainActor final class Events {
    var started = 0
    var statuses: [TurnStatus] = []
    func receive(_ event: ProviderEvent) {
        switch event {
        case .turnStarted: started += 1
        case .turnCompleted(let status, _): statuses.append(status)
        case .requestResolved, .modeChanged, .messageCompleted, .notice, .tokenSpend: break
        }
    }
}
@MainActor protocol ProviderSession: AnyObject {
    var onEvent: ((ProviderEvent) -> Void)? { get set }
    func send(_ input: TurnInput) async throws
    func interrupt() async
    func stop()
}
@MainActor final class ACPSession: ProviderSession {
    var onEvent: ((ProviderEvent) -> Void)?
    var configuration = SessionConfiguration()
    var connection: JSONRPCConnection? = JSONRPCConnection()
    var sessionID: String? = "fixture"
    var isReady = true
    var isStopping = false
    var runtimeMode = RuntimeMode.supervised
    var dshReportGuardReady = true
    var promptActive = false
    var promptPreparing = false
    var promptGeneration: UUID?
    var cancelRequested = false
    var cancelDeadline: Task<Void, Never>?
    var miniMaxPermissionGuarded = false
    var currentMiniMaxPermission: String?
    var miniMaxRestoreTask: Task<Void, Never>?
    var messageID: String?
    var thoughtID: String?
    var promptProducedOutput = false
    var eventTask: Task<Void, Never>?
    var pendingPermissions: [String: String] = [:]
    var pendingQuestions: [String: String] = [:]
    var todoToolCallIDs: Set<String> = []
    var toolKinds: [String: String] = [:]
    var toolInputs: [String: String] = [:]
    var currentModel: String?
    var antigravityLogTailer: AntigravityLogTailer?
    var antigravityEmittedRetryAttempts: Set<Int> = []
    static func antigravityErrorText(_ error: Error, tail: String = "") -> String { error.localizedDescription }
    func applySelection(model: String?, effort: String?, fastMode: Bool, interaction: InteractionMode, generation: UUID?) async throws {
        _ = try await connection?.request("fixture/selection", [:])
    }
    func cancelQuestions(_ connection: JSONRPCConnection) {}
    func restoreMiniMaxPermission(_ original: String) async {}
    static func miniMaxFailure(_ error: RPCError, operation: String) -> String { error.message }
    static func dshFailure(_ error: Error) -> String { error.localizedDescription }
    static func isDshBridgeDisposed(_ error: Error) -> Bool { false }
    static var kimiLoginRequired: Error { ProviderError.notRunning }
    func reopen() { connection = JSONRPCConnection(); isStopping = false; isReady = true }
'''
swift += methods("ACPSession.swift", "    func send(", "    private func continuePromptPreparation(",
                 "    func interrupt(", "    func stop()", "    private func finishPrompt(")
swift += "\n}\n"

swift += r'''
@MainActor class PiRPCSession: ProviderSession {
    var onEvent: ((ProviderEvent) -> Void)?
    var process: StdioProcess? = StdioProcess()
    var started = true
    var stopped = false
    var turnActive = false
    var preparationID: UUID?
    var interruptRequested = false
    var runtimeMode = RuntimeMode.supervised
    var interactionMode = InteractionMode.build
    var model: String?
    var effort: String?
    var contextWindow: Int?
    var turnCounter = 0
    var turnError: String?
    var lastReplyText = ""
    var toolNames: [String: String] = [:]
    var toolInputs: [String: JSONValue] = [:]
    var editSnapshots: [String: String] = [:]
    var gateURL: URL?
    var readTask: Task<Void, Never>?
    var pendingResponses = PendingReplies()
    var requestGate: Gate?
    var busyTurnError: String { "fixture is still on the last turn." }
    func request(_ fields: [String: JSONValue]) async -> JSONValue {
        if let requestGate { return await requestGate.wait() }
        return ["success": true]
    }
    func writeGate(finalReport: Bool) throws {}
    func validateBeforeBusyCheck(_ input: TurnInput) throws {}
    func validateModesForTurn(_ input: TurnInput) throws {}
    func prepareTurn(_ input: TurnInput, preparation: UUID, process: StdioProcess) async throws -> Bool { true }
    func makePromptFields(for input: TurnInput, turnNumber: Int) -> (fields: [String: JSONValue], promptID: String?) {
        (["type": .string("prompt"), "message": .string(input.text)], nil)
    }
    func willStartTurn(input: TurnInput, promptID: String?) {}
    func clearRequests() {}
    func removeLaunchFiles() {}
    func reopen() { process = StdioProcess(); stopped = false; started = true; requestGate = nil }
'''
swift += methods("PiRPCSession.swift", "    var isRunning: Bool", "    func send(",
                 "    @concurrent\n    private static func encodePrompt(",
                 "    func continuePreparation(", "    func interrupt(", "    func stop()")
swift += "\n}\n"

swift += "\n@MainActor final class PiSession: PiRPCSession {\n"
swift += methods("PiSession.swift", "    override func prepareTurn(")
swift += "\n}\n"

swift += r'''
@MainActor final class OmpSession: PiRPCSession {
    var defaultModel: String? = "fixture/default"
    var activeModel: String?
    var promptID: String?
    var isFinalReport = false
    struct Failure {}
    var failure = Failure()
    var runningTools: [String] = []
    var toolsAwaitingAnswer: [String: String] = [:]
    var hiddenCalls: Set<String> = []
    static let finalReportPrompt = "fixture final report"
    func validateSelection(model: String?, effort: String?) throws {}
'''
swift += methods("OmpSession.swift", "    private func selectModel(",
                 "    override func validateBeforeBusyCheck(",
                 "    override func validateModesForTurn(",
                 "    override func prepareTurn(",
                 "    override func makePromptFields(",
                 "    override func willStartTurn(")
swift += "\n}\n"

swift += r'''
@MainActor final class ClaudeSession: ProviderSession {
    var onEvent: ((ProviderEvent) -> Void)?
    var process: StdioProcess? = StdioProcess()
    var turnActive = false
    var preparationID: UUID?
    var isStopping = false
    var permissionMode = "manual"
    var permissionModeIsConfirmed = false
    var runtimeMode = RuntimeMode.supervised
    var model: String?
    var interruptRequested = false
    var pendingTools: [String: String] = [:]
    var controlGate: Gate?
    static func modeName(_ runtime: RuntimeMode, _ interaction: InteractionMode) -> String { "manual" }
    func control(_ request: JSONValue) async throws -> JSONValue {
        if let controlGate { return await controlGate.wait() }
        return [:]
    }
    func validateAccountIdentity() async throws {}
    func clearBackgroundTasks() {}
    func invalidateContextUsage() {}
    func sendToolResponse(_ id: String, _ response: JSONValue) {}
'''
swift += methods("ClaudeSession.swift", "    var isRunning: Bool", "    func send(",
                 "    private func continuePreparation(", "    func interrupt(", "    func stop()",
                 "    private func writeUserMessage(")
swift += "\n}\n"
swift += r'''
@MainActor final class CopilotSession: ProviderSession {
    var onEvent: ((ProviderEvent) -> Void)?
    var connection: JSONRPCConnection? = JSONRPCConnection()
    var sessionID: String? = "fixture"
    var turnActive = false
    var sendID: UUID?
    var preparing = false
    var isStopping = false
    var interruptRequested = false
    var turnError: String?
    var shownReasoning = Set<Int>()
    var streamedMessages = Set<String>()
    var commandNames = Set<String>()
    var interactionMode = InteractionMode.build
    var toolNames: [String: String] = [:]
    var declinedTools = Set<String>()
    var taskBriefs: [String: String] = [:]
    var modesGate: Gate?
    var selectionGate: Gate?
    func applyModes(runtime: RuntimeMode, interaction: InteractionMode) async throws {
        if let modesGate { _ = await modesGate.wait() }
    }
    func applySelection(model: String?, effort: String?) async {
        if let selectionGate { _ = await selectionGate.wait() }
    }
    static func slashCommand(in text: String) -> (name: String, input: String)? { nil }
    func cancelPendingRequests() {}
    static func deadlineRequest(_ connection: JSONRPCConnection, _ method: String,
                                _ params: JSONValue = [:], seconds: Double = 5) async throws -> JSONValue {
        try await connection.request(method, params)
    }
'''
swift += methods("CopilotSession.swift", "    var isRunning: Bool", "    func send(",
                 "    private func continuePreparation(", "    private func beginTurn(",
                 "    private func sendPrompt(", "    private func invokeCommand(",
                 "    private func finishTurn(", "    func interrupt(", "    func stop()")
swift += "\n}\n"

hub = ROOT / "Tivano/Services/MCP/MCPHub.swift"
swift += r'''
struct MCPServerSpec: Sendable { var gate: Gate? }
actor MCPClient {
    let id: String
    let spec: MCPServerSpec
    init(id: String, spec: MCPServerSpec) { self.id = id; self.spec = spec }
    func listTools() async throws -> [MCPHub.Tool] {
        if let gate = spec.gate { _ = await gate.wait() }
        return [MCPHub.Tool(server: id, name: "fixture", description: "", inputSchema: [:])]
    }
    func stop() {} // A reply already in flight may still arrive after stop.
}
actor MCPHub {
    static let shared = MCPHub()
    var specs: [String: MCPServerSpec]?
    var clients: [String: MCPClient] = [:]
    var toolCache: [String: [Tool]] = [:]
    var combinedToolCache: [Tool]?
    var failed: Set<String> = []
    var generation = UUID()
    var shuttingDown = false
    static let log = Logger(subsystem: "dev.tivano.Tivano", category: "mcp-hub")
    func install(_ specs: [String: MCPServerSpec]) { self.specs = specs }
    nonisolated static func readSpecs() -> [String: MCPServerSpec] { ["fresh": MCPServerSpec()] }
'''
for marker in ("    struct Tool:", "    func tools()", "    func reload()", "    private func client("):
    swift += declaration(hub, marker) + "\n"
swift += r'''
}
@MainActor final class DiscoveryHarness {
    var mcpTools: [MCPHub.Tool] = []
    var didLoadMCPTools = false
    var interrupted = false
    var isStopping = false
'''
swift += methods("OpenAICompatibleSession.swift", "    private func discoverMCPTools(")
swift += r'''
}
@MainActor final class SendOwnershipHarness {
    var session: (any ProviderSession)?
    var sessionEpoch = 1
    var runtimeTurnGeneration: UInt64 = 1
    var runtimeOwnerTurnID: UUID?
    var currentTurnID: UUID?
    var sendInterruptedTurnID: UUID?
    var providerCompletedTurnID: UUID?
'''
swift += declaration(ROOT / "Tivano/App/Runtime/ThreadRuntime.swift", "    private func ownsSendResult(")
swift += r'''
}

@main struct Checks {
    @MainActor static func waitFor(_ predicate: () async -> Bool) async {
        for _ in 0..<20_000 {
            if await predicate() { return }
            await Task.yield()
        }
        preconditionFailure("Fixture failed to reach its controlled suspension")
    }

    @MainActor static func acpPreparation(images: Bool) async throws {
        let session = ACPSession(), events = Events(), gate = Gate()
        session.onEvent = { events.receive($0) }
        let oldConnection = session.connection!
        if !images { oldConnection.gates["fixture/selection"] = gate }
        let input = TurnInput(images: images ? [Attachment(gate: gate)] : [])
        let old = Task { try await session.send(input) }
        await waitFor { await gate.count == 1 }
        await session.interrupt()
        precondition(oldConnection.isClosed && events.statuses == [.interrupted])
        // Reuse the object adversarially. Production may instead create a new one.
        session.reopen()
        let next = session.connection!, reply = Gate()
        next.gates["session/prompt"] = reply
        try await session.send(TurnInput())
        await waitFor { await reply.count == 1 }
        let nextGeneration = session.promptGeneration
        await gate.release()
        try await old.value
        precondition(!oldConnection.requests.contains("session/prompt"))
        precondition(session.promptActive && session.promptGeneration == nextGeneration)
        precondition(events.statuses == [.interrupted] && events.started == 1)
        await reply.release(["stopReason": "end_turn"])
        await waitFor { events.statuses.count == 2 }
        precondition(events.statuses == [.interrupted, .completed])
    }

    @MainActor static func acpLatePrompt() async throws {
        let session = ACPSession(), events = Events(), oldReply = Gate(), nextReply = Gate()
        session.onEvent = { events.receive($0) }
        session.connection!.gates["session/prompt"] = oldReply
        try await session.send(TurnInput())
        await waitFor { await oldReply.count == 1 }
        session.stop()
        session.reopen()
        session.connection!.gates["session/prompt"] = nextReply
        try await session.send(TurnInput())
        await waitFor { await nextReply.count == 1 }
        await oldReply.release(["stopReason": "end_turn"])
        for _ in 0..<100 { await Task.yield() }
        precondition(events.statuses.isEmpty && session.promptActive)
        await nextReply.release(["stopReason": "end_turn"])
        await waitFor { events.statuses.count == 1 }
        precondition(events.statuses == [.completed])
    }

    @MainActor static func piPreparation(images: Bool) async throws {
        let session = PiSession(), events = Events(), gate = Gate()
        session.onEvent = { events.receive($0) }
        let oldProcess = session.process!
        if !images { session.requestGate = gate }
        let old = Task { try await session.send(TurnInput(images: images ? [Attachment(gate: gate)] : [], model: images ? nil : "fixture/old")) }
        await waitFor { await gate.count == 1 }
        await session.interrupt()
        precondition(!oldProcess.isRunning && events.statuses == [.interrupted])
        session.reopen()
        let next = session.process!
        try await session.send(TurnInput())
        await gate.release()
        try await old.value
        precondition(oldProcess.prompts.isEmpty && next.prompts.count == 1)
        precondition(session.turnActive && events.started == 1 && events.statuses == [.interrupted])
        session.stop()
    }

    @MainActor static func ompPreparation(images: Bool) async throws {
        let session = OmpSession(), events = Events(), gate = Gate()
        session.onEvent = { events.receive($0) }
        let oldProcess = session.process!
        if !images { session.requestGate = gate }
        let old = Task { try await session.send(TurnInput(images: images ? [Attachment(gate: gate)] : [], model: images ? nil : "fixture/old")) }
        await waitFor { await gate.count == 1 }
        await session.interrupt()
        precondition(!oldProcess.isRunning && events.statuses == [.interrupted])
        session.reopen()
        let next = session.process!
        try await session.send(TurnInput(model: "fixture/new"))
        let id = session.promptID
        await gate.release()
        try await old.value
        precondition(oldProcess.prompts.isEmpty && next.prompts.count == 1)
        precondition(session.promptID == id && session.model == "fixture/new")
        precondition(session.turnActive && events.started == 1 && events.statuses == [.interrupted])
        session.stop()
    }

    @MainActor static func payloads() async throws {
        let pi = PiSession(), omp = OmpSession()
        try await pi.send(TurnInput(images: [Attachment()]))
        try await omp.send(TurnInput(images: [Attachment()]))
        for payload in [pi.process!.prompts[0], omp.process!.prompts[0]] {
            precondition(payload["images"]?[0]?["mimeType"]?.string == "image/jpeg")
            precondition(payload["images"]?[0]?["data"]?.string == "eA==")
        }
        // JSON escaping makes the actual wire payload exceed 32 MB while the text
        // itself remains smaller. Rejection must leave the idle CLI reusable.
        let input = TurnInput(text: String(repeating: "\"", count: 17 * 1024 * 1024))
        let largePi = PiSession(), largeOmp = OmpSession()
        do { try await largePi.send(input); preconditionFailure("Pi accepted oversized JSON") }
        catch ProviderError.failed { }
        do { try await largeOmp.send(input); preconditionFailure("OMP accepted oversized JSON") }
        catch ProviderError.failed { }
        precondition(largePi.isRunning && !largePi.turnActive && largePi.process!.prompts.isEmpty)
        precondition(largeOmp.isRunning && !largeOmp.turnActive && largeOmp.process!.prompts.isEmpty)
        try await largePi.send(TurnInput())
        try await largeOmp.send(TurnInput())
    }

    @MainActor static func taskCancellation(_ session: any ProviderSession) async throws {
        let events = Events(), gate = Gate()
        session.onEvent = { events.receive($0) }
        let old = Task { try await session.send(TurnInput(images: [Attachment(gate: gate)])) }
        await waitFor { await gate.count == 1 }
        old.cancel()
        await gate.release()
        try await old.value
        precondition(events.started == 0 && events.statuses == [.interrupted])
    }

    @MainActor static func discovery(reload: Bool) async throws {
        let hub = MCPHub.shared, gate = Gate(), session = DiscoveryHarness()
        await hub.reload()
        await hub.install(["a": MCPServerSpec(), "b": MCPServerSpec(gate: gate)])
        let old = Task { try await session.discoverMCPTools() }
        await waitFor { await gate.count == 1 }
        if reload { await hub.reload() } else { old.cancel() }
        await gate.release()
        do { try await old.value; preconditionFailure("Incomplete discovery was committed") }
        catch is CancellationError { }
        precondition(!session.didLoadMCPTools && session.mcpTools.isEmpty)
        if !reload {
            let retry = Task { try await session.discoverMCPTools() }
            await waitFor { await gate.count == 1 }
            await gate.release()
            try await retry.value
            precondition(session.mcpTools.map(\.server) == ["a", "b"])
        } else {
            try await session.discoverMCPTools()
            precondition(session.mcpTools.map(\.server) == ["fresh"])
            await hub.reload()
            await hub.install(["reloaded": MCPServerSpec()])
            let reloaded = try await hub.tools()
            precondition(reloaded.map(\.server) == ["reloaded"])
        }
        precondition(session.didLoadMCPTools)
    }

    @MainActor static func ownership() {
        let runtime = SendOwnershipHarness(), provider = PiSession(), id = UUID()
        runtime.session = provider
        runtime.currentTurnID = id
        runtime.runtimeOwnerTurnID = id
        func owns() -> Bool { runtime.ownsSendResult(turnID: id, provider: provider, epoch: 1, runtimeGeneration: 1) }
        precondition(owns())
        runtime.currentTurnID = nil
        precondition(!owns())
        runtime.providerCompletedTurnID = id
        precondition(owns()) // Synchronous completion is a valid receipt.
        runtime.sendInterruptedTurnID = id
        precondition(!owns()) // Even after finalization cleared currentTurnID.
        runtime.sendInterruptedTurnID = nil
        runtime.currentTurnID = UUID()
        precondition(!owns())
        runtime.currentTurnID = id
        runtime.session = PiSession()
        precondition(!owns())
        runtime.session = provider
        runtime.sessionEpoch = 2
        precondition(!owns())
        runtime.sessionEpoch = 1
        runtime.runtimeTurnGeneration = 2
        precondition(!owns())
    }

    @MainActor static func claudePreparation(images: Bool) async throws {
        let old = ClaudeSession(), events = Events(), gate = Gate()
        old.onEvent = { events.receive($0) }
        if !images { old.controlGate = gate }
        let process = old.process!
        let pending = Task { try await old.send(TurnInput(images: images ? [Attachment(gate: gate)] : [])) }
        await waitFor { await gate.count == 1 }
        await old.interrupt()
        precondition(!old.isRunning && events.statuses == [.interrupted])
        let next = ClaudeSession()
        try await next.send(TurnInput())
        await gate.release()
        try await pending.value
        precondition(events.started == 0 && process.sent.isEmpty)
        precondition(next.process!.sent.count == 1 && next.turnActive)
    }

    @MainActor static func copilotPreparation(selection: Bool) async throws {
        let old = CopilotSession(), events = Events(), gate = Gate()
        old.onEvent = { events.receive($0) }
        if selection { old.selectionGate = gate } else { old.modesGate = gate }
        let connection = old.connection!
        let pending = Task { try await old.send(TurnInput()) }
        await waitFor { await gate.count == 1 }
        await old.interrupt()
        precondition(!old.isRunning && events.statuses == [.interrupted])
        let next = CopilotSession()
        try await next.send(TurnInput())
        await gate.release()
        try await pending.value
        precondition(events.started == 0 && !connection.requests.contains("session.send"))
        precondition(next.connection!.requests.contains("session.send") && next.turnActive)
    }

    @MainActor static func copilotLateCommand(replaced: Bool) async throws {
        let session = CopilotSession(), gate = Gate(), events = Events()
        session.onEvent = { events.receive($0) }
        session.sendID = UUID()
        session.beginTurn()
        let connection = session.connection!
        connection.gates["session.commands.invoke"] = gate
        let pending = Task { try await session.invokeCommand("fixture", input: "input") }
        await waitFor { await gate.count == 1 }
        await session.interrupt()
        session.finishTurn(aborted: true)
        if replaced { session.sendID = UUID(); session.beginTurn() }
        await gate.release(["kind": "agent-prompt", "prompt": "late command"])
        try await pending.value
        precondition(!connection.requests.contains("session.send"))
        precondition(session.turnActive == replaced)
        precondition(events.statuses == [.interrupted])
    }

    @MainActor static func main() async throws {
        for images in [false, true] {
            try await claudePreparation(images: images)
            try await copilotPreparation(selection: images)
            try await acpPreparation(images: images)
            try await piPreparation(images: images)
            try await ompPreparation(images: images)
        }
        try await copilotLateCommand(replaced: false)
        try await copilotLateCommand(replaced: true)
        try await acpLatePrompt()
        try await payloads()
        let sessions: [any ProviderSession] = [ACPSession(), PiSession(), OmpSession(), ClaudeSession()]
        for session in sessions { try await taskCancellation(session) }
        try await discovery(reload: false)
        try await discovery(reload: true)
        ownership()
        print("PASS: extracted ACP/Pi/OMP/Claude/Copilot preparation Stop, replacement and late reply guards")
        print("PASS: encoded payload limit, MIME, MCP cancellation/reload retry, runtime send ownership")
    }
}
'''

check_source_invariants()
print("PASS: AppModel observer lifecycle, forwardedContinuation preservation, deferred Hydra refusals and appendHydraNote streaming guards")

with tempfile.TemporaryDirectory(prefix="tivano-runtime-audit-") as folder:
    out = Path(folder)
    source, binary = out / "Checks.swift", out / "checks"
    source.write_text(swift)
    subprocess.run(["xcrun", "swiftc", "-swift-version", "6", "-parse-as-library",
                    str(source), "-o", str(binary)], check=True, cwd=out, timeout=180)
    environment = os.environ.copy()
    environment.update(HOME=str(out), TMPDIR=str(out))
    subprocess.run([str(binary)], check=True, cwd=out, env=environment, timeout=90)
