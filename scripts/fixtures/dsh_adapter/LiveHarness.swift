import Foundation
import Darwin

@MainActor final class LiveRecorder {
    var text = ""
    var ends: [TurnStatus] = []
    var tools = 0
    var approvals = 0
    func consume(_ event: ProviderEvent) {
        switch event {
        case .messageDelta(_, let value): text += value
        case .turnCompleted(let status, _): ends.append(status)
        case .toolStarted: tools += 1
        case .approval, .question: approvals += 1
        default: break
        }
    }
}

@main struct LiveHarness {
    @MainActor static var created: [String] = []
    @MainActor static var prompts = 0
    static let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["DSH_TEST_ROOT"]!)
    static let executable = URL(fileURLWithPath: CommandLine.arguments[1])
    @MainActor static func turn(_ session: ACPSession, _ recorder: LiveRecorder, text: String, model: String, effort: String, final: Bool) async throws {
        guard prompts < 8 else { throw ProviderError.failed("Fixture prompt budget exhausted") }
        prompts += 1
        try await session.send(TurnInput(text: text, images: [], model: model, effort: effort,
                                        runtimeMode: .supervised, interactionMode: .build, isFinalReport: final))
        let deadline = Date.now.addingTimeInterval(60)
        while recorder.ends.isEmpty && Date.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        guard recorder.ends == [.completed], recorder.tools == 0, recorder.approvals == 0 else {
            throw ProviderError.failed("Fixture turn incomplete or used tools")
        }
    }
    @MainActor static func check(_ mode: DshAgentMode, model: ModelOption, effort: String) async -> [String: Any] {
        let cwd = root.appendingPathComponent(mode.rawValue)
        let marker = "DSH_TEST_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        var sessions: [ACPSession] = []
        var passed = false
        var stage = "start"
        do {
            try Task.checkCancellation()
            try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
            func make(resume: String? = nil, final: Bool = false) -> (ACPSession, LiveRecorder) {
                var config = SessionConfiguration(provider: .dsh, executable: executable, workingDirectory: cwd,
                    environment: ProcessInfo.processInfo.environment, runtimeMode: .supervised, interactionMode: .build,
                    dshMode: mode)
                config.model = model.id
                config.effort = effort
                config.resumeID = resume
                config.dshFinalReport = final
                let session = ACPSession(configuration: config)
                let recorder = LiveRecorder()
                session.onEvent = { recorder.consume($0) }
                sessions.append(session)
                return (session, recorder)
            }
            let (initial, first) = make()
            let id = try await initial.start()
            created.append(id)
            print("created-session \(id)")
            fflush(stdout)
            stage = "initial-turn"
            try await turn(initial, first, text: "Do not use tools. Remember exactly \(marker). Reply only with this marker.", model: model.id, effort: effort, final: false)
            guard first.text.contains(marker) else { throw ProviderError.failed("Fixture marker missing") }
            await initial.stopAndWait(timeout: 5)
            stage = "report-resume"
            let (reporter, report) = make(resume: id, final: true)
            let resumedID = try await reporter.start()
            guard resumedID == id else { throw ProviderError.failed("Fixture resume changed identity") }
            stage = "report-turn"
            try await turn(reporter, report, text: "Do not use tools. Reply only with the exact marker I asked you to remember.", model: model.id, effort: effort, final: true)
            guard report.text.contains(marker) else { throw ProviderError.failed("Fixture history lost") }
            passed = true
        } catch { /* Keep provider error text and responses out of persisted logs. */ }
        for session in sessions { await session.stopAndWait(timeout: 5) }
        return ["mode": mode.rawValue, "passed": passed, "lastStage": stage]
    }
    @MainActor static func main() async {
        var rows: [[String: Any]] = []
        var catalogPassed = false
        let work = Task { @MainActor in
        do {
            let models = try await ACPSession.probeModels(provider: .dsh, executable: executable, environment: ProcessInfo.processInfo.environment)
            for model in models { print("catalog-model \(model.id) \(model.name) efforts=\(model.efforts)") }
            guard let model = models.first(where: { $0.id.contains("deepseek-account") && ($0.name + $0.id).lowercased().contains("flash") }),
                  let effort = ["low", "off", "none"].first(where: { model.efforts.contains($0) }) else {
                throw ProviderError.failed("No account Flash low/off model; no fallback")
            }
            catalogPassed = true
            for pair: [DshAgentMode] in [[.standard, .ptc], [.minimal, .creator]] {
                try Task.checkCancellation()
                async let first = check(pair[0], model: model, effort: effort)
                async let second = check(pair[1], model: model, effort: effort)
                rows += await [first, second]
            }
        } catch {
            let message = error.localizedDescription.lowercased()
            let category = message.contains("patch") ? "patch-validation" : message.contains("timed out") ? "timeout" : message.contains("no account flash") ? "model-selection" : "catalog-startup"
            print("catalog-error-category \(category) type=\(String(reflecting: type(of: error))) code=\((error as? RPCError)?.code ?? (error as NSError).code)")
            for keyword in ["ENOENT", "EACCES", "EPERM", "404", "401", "403", "permission", "credential", "plugin", "module", "directory", "session", "EOF", "exited", "initialize", "invalid", "parameter", "selection", "output", "Resource", "not permitted"] where message.contains(keyword.lowercased()) { print("catalog-error-keyword \(keyword)") }
        }
        }
        let watchdog = Task {
            do { try await Task.sleep(for: .seconds(300)) } catch { return }
            work.cancel()
        }
        await work.value
        watchdog.cancel()
        let passed = catalogPassed && rows.count == 4 && rows.allSatisfy { $0["passed"] as? Bool == true }
        let result: [String: Any] = ["passed": passed, "catalogPassed": catalogPassed, "prompts": prompts,
                                   "sessions": created, "results": rows,
                                   "scope": "Production Swift ACP/DSH/Shell with existing account; no App UI or Hydra coordinator"]
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: root.appendingPathComponent("live-result.json"))
            print(String(decoding: data, as: UTF8.self))
        }
        exit(passed ? 0 : 1)
    }
}
