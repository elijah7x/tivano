#if DEBUG
import AppKit
import Foundation

@MainActor
enum DshIntegrationProbe {
    private static let projectID = UUID()
    private static let modes: [DshAgentMode] = [.standard, .ptc, .minimal, .creator]
    private static let threadIDs = modes.map { _ in UUID() }
    private static var preparationIssue: String?

    static func prepare() {
        guard DshIntegrationConfiguration.isEnabled,
              let output = CaptureRun.outputDirectory,
              let root = CaptureRun.storageRoot,
              let defaults = CaptureRun.defaults else { return }
        do {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            guard !FileManager.default.fileExists(atPath: root.path) else {
                preparationIssue = "Use a fresh output directory; capture storage already exists."
                return
            }
            try FileManager.default.createDirectory(at: root.appendingPathComponent("threads"), withIntermediateDirectories: true)
            defaults.removePersistentDomain(forName: CaptureRun.suiteName)
            defaults.set("dsh", forKey: "defaultProvider")
            defaults.set("supervised", forKey: "defaultRuntimeMode")
            for key in ["hydraEnabled", "hydraQueueHeads", "hydraAlwaysHeads", "notifyWhenFinished", "chimeWhenFinished"] {
                defaults.set(false, forKey: key)
            }
            defaults.set(projectID.uuidString, forKey: "lastProjectID")
            defaults.synchronize()
            let work = root.appendingPathComponent("dsh-probe-work", isDirectory: true)
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            var project = Project(name: "DSH integration probe", path: work.path)
            project.id = projectID
            var library = Library()
            library.projects = [project]
            library.threads = zip(modes, threadIDs).map { mode, id in
                var thread = ChatThread(projectID: projectID, provider: .dsh, model: nil, effort: nil, runtimeMode: .supervised)
                thread.id = id
                thread.dshMode = mode
                thread.title = "DSH probe: \(mode.rawValue)"
                thread.hasCustomTitle = true
                return thread
            }
            try JSONEncoder.storage.encode(library).write(to: root.appendingPathComponent("library.json"), options: .atomic)
        } catch {
            preparationIssue = "Could not prepare the isolated probe library."
        }
    }

    static func run(model: AppModel) async {
        guard DshIntegrationConfiguration.isEnabled, let output = CaptureRun.outputDirectory else { return }
        await Run(model: model, output: output).start()
    }

    @MainActor private final class Run {
        let model: AppModel
        let output: URL
        var runtimes: [ThreadRuntime] = []
        var rows: [[String: Any]] = []
        var sends = 0
        var completed = 0
        var stage = "configuration"
        var status = "blocked"
        var reason = "Not started"
        var screenshots: [String] = []

        init(model: AppModel, output: URL) {
            self.model = model
            self.output = output
        }

        struct ProbeFailure: Error { let reason: String }

        func start() async {
            let work = Task { await exercise() }
            let deadline = Task {
                do { try await Task.sleep(for: .seconds(300)) } catch { return }
                work.cancel()
            }
            await work.value
            deadline.cancel()
            for runtime in runtimes { await runtime.stopSessionAndWait(timeout: 5) }
            save()
            NSApp.terminate(nil)
        }

        func exercise() async {
            do {
                guard DshIntegrationConfiguration.paths != nil else {
                    throw ProbeFailure(reason: "Explicit valid executable/home and a separate fresh capture output are required.")
                }
                if let preparationIssue { throw ProbeFailure(reason: preparationIssue) }
                stage = "library"
                await model.bootstrap()
                let libraryDeadline = Date.now.addingTimeInterval(20)
                while !model.isLibraryLoaded && Date.now < libraryDeadline { try await Task.sleep(for: .milliseconds(50)) }
                guard model.isLibraryLoaded, threadIDs.allSatisfy({ model.thread($0) != nil }) else {
                    throw ProbeFailure(reason: "Isolated library was not ready.")
                }
                stage = "catalog"
                save()
                await model.providers.refresh(.dsh)
                await model.providers.loadCatalog(.dsh, force: true)
                try Task.checkCancellation()
                guard let choice = model.providers.models(for: .dsh).first(where: {
                    $0.id.contains("deepseek-account") && ($0.name + $0.id).lowercased().contains("flash")
                }), let effort = ["low", "off", "none"].first(where: { choice.efforts.contains($0) }) else {
                    throw ProbeFailure(reason: "No account-route Flash with advertised low/off effort; no prompt sent.")
                }
                let captureStage = Stage(model: model)
                captureStage.show(size: Stage.wide)
                let recorder = Recorder(output: output, stage: captureStage)
                for (mode, id) in zip(modes, threadIDs) {
                    try Task.checkCancellation()
                    stage = mode.rawValue
                    model.updateThread(id) { thread in
                        thread.model = choice.id
                        thread.effort = effort
                        thread.hydraEnabled = false
                    }
                    model.openThread(id)
                    let runtime = model.runtime(for: id)
                    runtimes.append(runtime)
                    let readyDeadline = Date.now.addingTimeInterval(20)
                    while runtime.isLoadingHistory && Date.now < readyDeadline { try await Task.sleep(for: .milliseconds(50)) }
                    guard !runtime.isLoadingHistory else { throw ProbeFailure(reason: "Thread history was not ready.") }
                    let marker = "DSH_TEST_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
                    var row: [String: Any] = ["mode": mode.rawValue, "threadID": id.uuidString, "status": "failed", "completedRequests": 0]
                    do {
                        try await turn(runtime, text: "Do not use tools. Remember exactly \(marker). Reply only with this marker.", marker: marker)
                        row["firstMarkerMatched"] = true
                        row["completedRequests"] = 1
                        try await turn(runtime, text: "Do not use tools. Reply only with the exact marker I asked you to remember.", marker: marker)
                        row["memoryMarkerMatched"] = true
                        row["completedRequests"] = 2
                        row["status"] = "completed"
                    } catch {
                        row["reason"] = (error as? ProbeFailure)?.reason ?? "Cancelled or timed out."
                    }
                    row["sessionID"] = model.thread(id)?.providerSessionID as Any? ?? NSNull()
                    rows.append(row)
                    save()
                    await runtime.stopSessionAndWait(timeout: 5)
                    try Task.checkCancellation()
                    await recorder.still("dsh-integration-\(mode.rawValue)", captureStage.captureRect)
                    let image = "dsh-integration-\(mode.rawValue).png"
                    if FileManager.default.fileExists(atPath: output.appendingPathComponent(image).path) { screenshots.append(image) }
                    guard row["status"] as? String == "completed" else {
                        throw ProbeFailure(reason: "A mode failed; subsequent prompts were not sent.")
                    }
                }
                status = "completed"
                reason = "All eight real App turns completed and matched their synthetic markers."
            } catch {
                status = sends == 0 ? "blocked" : "failed"
                reason = (error as? ProbeFailure)?.reason ?? "Cancelled or overall deadline exceeded."
            }
        }

        func turn(_ runtime: ThreadRuntime, text: String, marker: String) async throws {
            try Task.checkCancellation()
            guard sends < 8, runtime.phase == .idle else { throw ProbeFailure(reason: "Prompt budget or idle-state guard failed.") }
            let count = runtime.turns.count
            runtime.draft.text = text
            sends += 1
            runtime.send()
            let deadline = Date.now.addingTimeInterval(60)
            while Date.now < deadline {
                try Task.checkCancellation()
                guard runtime.approvals.isEmpty, runtime.questions.isEmpty else {
                    throw ProbeFailure(reason: "Unexpected approval or question; nothing approved.")
                }
                if runtime.turns.count > count, runtime.phase == .idle, let turn = runtime.turns.last {
                    guard turn.status == .completed else { throw ProbeFailure(reason: "App turn did not complete successfully.") }
                    let entries = runtime.entries.filter { $0.item.turnID == turn.id }
                    guard !entries.contains(where: { if case .tool = $0.item.content { return true }; return false }) else {
                        throw ProbeFailure(reason: "Unexpected tool activity.")
                    }
                    let answer = entries.compactMap { entry -> String? in
                        if case .assistant(let message) = entry.item.content { return message.text }
                        return nil
                    }.joined()
                    guard answer.contains(marker) else { throw ProbeFailure(reason: "Synthetic marker did not match.") }
                    completed += 1
                    return
                }
                try await Task.sleep(for: .milliseconds(50))
            }
            throw ProbeFailure(reason: "Round exceeded 60 seconds.")
        }

        func save() {
            let result: [String: Any] = [
                "schemaVersion": 1, "status": status, "stage": stage, "reason": reason,
                "modes": rows, "sendCalls": sends, "completedRequests": completed,
                "budget": ["maximumUserPrompts": 8, "maximumPromptsPerMode": 2,
                           "maximumActiveSessions": 2, "roundTimeoutSeconds": 60, "overallTimeoutSeconds": 300],
                "screenshots": screenshots, "visualReview": "pending-lead-inspection",
                "unverified": ["Hydra lead/head scheduling", "MCP", "tool execution", "performance", "guarded report transition"],
                "cleanup": "Only this probe's runtimes receive bounded stop-and-wait; the external account sessions are retained for scoped lead cleanup.",
            ]
            if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: output.appendingPathComponent("dsh-integration.json"), options: .atomic)
            }
        }
    }
}
#endif
