#if DEBUG
import AppKit
import CryptoKit
import Foundation

@MainActor
enum DshNativeIntegrationProbe {
    static var isRequested: Bool { CommandLine.arguments.contains("--dsh-offline-native-probe") }
    private static let modes: [DshAgentMode] = CommandLine.arguments.contains("--dsh-native-no-pty")
        ? [.standard, .ptc, .creator] : [.standard, .ptc, .minimal, .creator]
    private static let scenarios = CommandLine.arguments.contains("--dsh-native-mcp-only")
        ? ["mcp", "bad-mcp"] : ["file", "mcp", "tool-failure", "bad-mcp"]
    private static let projectID = UUID()
    private static let threadIDs = modes.map { _ in UUID() }
    private static let brokenMCPThreadID = UUID()
    private static var marker = ""
    private struct Failure: Error { let message: String }

    static func prepare() {
        guard isRequested else { return }
        do {
            let fm = FileManager.default
            guard DshIntegrationConfiguration.isOfflineNative,
                  let output = CaptureRun.outputDirectory,
                  output.standardizedFileURL == output.resolvingSymlinksInPath(),
                  let root = CaptureRun.storageRoot,
                  let paths = DshIntegrationConfiguration.paths,
                  !fm.fileExists(atPath: root.path),
                  !fm.fileExists(atPath: output.appendingPathComponent("started").path),
                  let walk = fm.enumerator(at: output, includingPropertiesForKeys: [.isSymbolicLinkKey]) else {
                throw Failure(message: "Fresh canonical isolated paths required")
            }
            for case let url as URL in walk {
                guard try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
                    throw Failure(message: "Fixture symlinks forbidden")
                }
            }
            let data = try Data(contentsOf: output.appendingPathComponent("manifest.json"))
            guard let manifest = try JSONSerialization.jsonObject(with: data) as? [String: String],
                  manifest["fixture"] == "tivano-dsh-app-native-v1",
                  let token = manifest["marker"], UUID(uuidString: token) != nil,
                  let port = manifest["port"].flatMap(Int.init), (1024...65535).contains(port),
                  manifest["dsh"] == paths.executable.path,
                  manifest["dshSHA256"] == digest(try Data(contentsOf: paths.executable)),
                  manifest["app"] == Bundle.main.executableURL?.resolvingSymlinksInPath().path,
                  let executable = Bundle.main.executableURL,
                  manifest["appSHA256"] == digest(try Data(contentsOf: executable)),
                  try fm.contentsOfDirectory(atPath: paths.home.path).isEmpty,
                  try fm.contentsOfDirectory(atPath: output.appendingPathComponent("home").path).isEmpty,
                  let python = manifest["python"], python.hasPrefix("/"), fm.isExecutableFile(atPath: python),
                  manifest["mcpSHA256"] == digest(try Data(contentsOf: output.appendingPathComponent("mcp.py"))) else {
                throw Failure(message: "Fixture identity or pristine homes rejected")
            }
            marker = token
            try Data(token.utf8).write(to: output.appendingPathComponent("started"), options: .withoutOverwriting)
            try fm.createDirectory(at: root.appendingPathComponent("threads"), withIntermediateDirectories: true)
            guard let defaults = CaptureRun.defaults else { throw Failure(message: "Missing capture defaults") }
            defaults.removePersistentDomain(forName: CaptureRun.suiteName)
            defaults.set("dsh", forKey: "defaultProvider")
            defaults.set(ProviderKind.allCases.filter { $0 != .dsh }.map(\.rawValue), forKey: "disabledProviders")
            for key in ["hydraEnabled", "hydraQueueHeads", "hydraAlwaysHeads", "notifyWhenFinished", "chimeWhenFinished"] {
                defaults.set(false, forKey: key)
            }
            defaults.set(projectID.uuidString, forKey: "lastProjectID")
            defaults.synchronize()
            var project = Project(name: "Offline native DSH", path: output.appendingPathComponent("scratch").path)
            project.id = projectID
            var library = Library()
            library.projects = [project]
            library.threads = zip(modes, threadIDs).map { mode, id in
                var thread = ChatThread(projectID: projectID, provider: .dsh, model: nil, effort: nil, runtimeMode: .fullAccess)
                thread.id = id
                thread.dshMode = mode
                thread.title = "Offline native \(mode.rawValue)"
                thread.hasCustomTitle = true
                thread.hydraEnabled = false
                return thread
            }
            var broken = ChatThread(projectID: projectID, provider: .dsh, model: nil, effort: nil, runtimeMode: .fullAccess)
            broken.id = brokenMCPThreadID
            broken.dshMode = .standard
            broken.hydraEnabled = false
            library.threads.append(broken)
            try JSONEncoder.storage.encode(library).write(to: root.appendingPathComponent("library.json"), options: .withoutOverwriting)
            var server = MCPCustomServer(id: "custom-native-fixture", name: "Native fixture", kind: .stdio)
            server.command = python
            server.args = [output.appendingPathComponent("mcp.py").path, output.path, marker]
            var connection = MCPConnection(catalogID: server.id)
            connection.connectedAt = .now
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode([server]).write(to: root.appendingPathComponent("custom-mcp.json"), options: .withoutOverwriting)
            try encoder.encode([connection]).write(to: root.appendingPathComponent("mcp.json"), options: .withoutOverwriting)
        } catch {
            FileHandle.standardError.write(Data("Offline native preparation rejected: \(error)\n".utf8))
            // This runs before AppModel/LibraryAccess; never fall back to the user's library.
            exit(EXIT_FAILURE)
        }
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func run(model: AppModel) async {
        guard isRequested, let output = CaptureRun.outputDirectory else { return }
        var rows: [[String: Any]] = []
        var stage = "bootstrap"
        var failure: String?
        func save() {
            let result: [String: Any] = [
                "fixture": "tivano-dsh-app-native-v1", "marker": marker, "stage": stage,
                "status": failure == nil ? "pending-runner-reconciliation" : "failed",
                "failure": failure as Any? ?? NSNull(), "rows": rows,
                "modes": modes.map(\.rawValue), "scenarios": scenarios,
                "pid": ProcessInfo.processInfo.processIdentifier,
                "runtimeMode": "fullAccess inside runner sandbox",
                "uncovered": ["cloud model decisions", "UI interaction", "arbitrary plugins", "workspace-write/approvals (macOS rejects nested sandbox)"]
            ]
            do {
                let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
                try data.write(to: output.appendingPathComponent("app-result.json"), options: .atomic)
            } catch {
                FileHandle.standardError.write(Data("Could not save native fixture evidence: \(error)\n".utf8))
                exit(EXIT_FAILURE)
            }
        }
        save()
        let work = Task { @MainActor in
            do {
                guard !marker.isEmpty else { throw Failure(message: "Preparation was not called") }
                await model.bootstrap()
                let ready = Date.now.addingTimeInterval(20)
                while !model.isLibraryLoaded && Date.now < ready { try await Task.sleep(for: .milliseconds(50)) }
                guard model.isLibraryLoaded else { throw Failure(message: "Library not loaded") }
                await model.providers.refresh(.dsh)
                // Native ACP consumes the same MCPStore export; the Hub independently discovers it.
                let tools = await MCPHub.shared.tools()
                guard tools.contains(where: { $0.callName == "mcp__custom-native-fixture__touch" }) else {
                    throw Failure(message: "Normal MCPStore/Hub discovery missing fixture")
                }
                for (mode, id) in zip(modes, threadIDs) {
                    let runtime = model.runtime(for: id)
                    let loaded = Date.now.addingTimeInterval(20)
                    while runtime.isLoadingHistory && Date.now < loaded { try await Task.sleep(for: .milliseconds(50)) }
                    var sessionID: String?
                    for scenario in scenarios {
                        try Task.checkCancellation()
                        stage = "\(mode.rawValue)/\(scenario)"
                        save()
                        guard runtime.phase == .idle else { throw Failure(message: "Runtime not idle") }
                        let before = runtime.turns.count
                        var approvals: [[String: String]] = []
                        let tag = "NATIVE_FIXTURE:\(marker):\(mode.rawValue):\(scenario)"
                        runtime.draft.text = tag
                        runtime.send()
                        let deadline = Date.now.addingTimeInterval(60)
                        while Date.now < deadline {
                            try Task.checkCancellation()
                            guard runtime.questions.isEmpty else { throw Failure(message: "Unexpected question") }
                            for request in runtime.approvals {
                                let detail = request.title + " " + (request.detail ?? "")
                                guard detail.contains(marker),
                                      let option = request.options.first(where: { $0.role == .approve }) else {
                                    throw Failure(message: "Unrecognized approval; nothing approved")
                                }
                                approvals.append(["id": request.id, "detail": detail, "option": option.id])
                                runtime.resolve(request, option: option)
                            }
                            if runtime.turns.count > before && runtime.phase == .idle { break }
                            try await Task.sleep(for: .milliseconds(50))
                        }
                        guard runtime.turns.count == before + 1, runtime.phase == .idle,
                              let turn = runtime.turns.last else { throw Failure(message: "Turn deadline/count failed") }
                        let calls = runtime.entries.compactMap { entry -> ToolCall? in
                            guard entry.item.turnID == turn.id, case .tool(let call) = entry.item.content else { return nil }
                            return call
                        }
                        let sid = model.thread(id)?.providerSessionID
                        let row: [String: Any] = ["mode": mode.rawValue, "scenario": scenario,
                            "threadID": id.uuidString, "turnID": turn.id.uuidString,
                            "turnStatus": String(describing: turn.status), "phase": String(describing: runtime.phase),
                            "sessionID": sid as Any? ?? NSNull(), "approvals": approvals,
                            "approvalObserved": !approvals.isEmpty,
                            "tools": calls.map { ["title": $0.title, "detail": $0.detail ?? "",
                                                  "status": String(describing: $0.status), "output": $0.output,
                                                  "editPaths": $0.edits.map(\.path).joined(separator: "\n")] }]
                        rows.append(row)
                        save()
                        guard let sid, !sid.isEmpty, sessionID == nil || sessionID == sid else {
                            throw Failure(message: "Session missing or silently replaced")
                        }
                        sessionID = sid
                        guard !calls.isEmpty else { throw Failure(message: "No App tool events") }
                        if scenario == "file" || scenario == "mcp" {
                            guard turn.status == .completed, calls.contains(where: { $0.status == .completed }),
                                  !calls.contains(where: { $0.status == .failed }) else {
                                throw Failure(message: "Successful fixture not reflected in App")
                            }
                        } else {
                            guard calls.contains(where: { $0.status == .failed }) else {
                                throw Failure(message: "Tool failure not visible in App")
                            }
                        }
                    }
                    await runtime.stopSessionAndWait(timeout: 5)
                }
                stage = "mcp-startup-failure"
                save()
                try Data(marker.utf8).write(to: output.appendingPathComponent("fail-initialize"), options: .withoutOverwriting)
                let broken = model.runtime(for: brokenMCPThreadID)
                let loaded = Date.now.addingTimeInterval(20)
                while broken.isLoadingHistory && Date.now < loaded { try await Task.sleep(for: .milliseconds(50)) }
                guard !broken.isLoadingHistory, broken.phase == .idle else { throw Failure(message: "Broken-MCP thread not ready") }
                broken.draft.text = "NATIVE_MCP_STARTUP:" + marker
                broken.send()
                let deadline = Date.now.addingTimeInterval(60)
                while Date.now < deadline {
                    try Task.checkCancellation()
                    if !broken.turns.isEmpty && broken.phase == .idle { break }
                    try await Task.sleep(for: .milliseconds(50))
                }
                let sid = model.thread(brokenMCPThreadID)?.providerSessionID
                rows.append(["mode": "standard", "scenario": "mcp-startup",
                             "turnStatus": broken.turns.last.map { String(describing: $0.status) } ?? "missing",
                             "phase": String(describing: broken.phase), "sessionID": sid as Any? ?? NSNull()])
                guard broken.turns.count == 1, broken.turns.last?.status == .failed,
                      broken.phase == .idle, sid == nil else {
                    throw Failure(message: "Broken MCP did not fail before session admission")
                }
            } catch { failure = (error as? Failure)?.message ?? "Cancelled or runtime error: \(error)" }
        }
        let watchdog = Task {
            do { try await Task.sleep(for: .seconds(270)) } catch { return }
            work.cancel()
        }
        await work.value
        watchdog.cancel()
        stage = "cleanup"
        save()
        for id in threadIDs + [brokenMCPThreadID] { await model.existingRuntime(for: id)?.stopSessionAndWait(timeout: 2) }
        await MCPHub.shared.shutdown()
        stage = "finished"
        save()
        NSApp.terminate(nil)
    }
}
#endif
