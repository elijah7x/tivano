import Foundation
@testable import Tivano

@main
struct AcceptanceIntegration {
    struct Failure: Error { let message: String }
    @MainActor static var checks: [[String: Any]] = []
    static func require(_ value: Bool, _ message: String) throws {
        if !value { throw Failure(message: message) }
    }
    @MainActor static func check(_ name: String, _ body: () async throws -> Void) async {
        do { try await body(); checks.append(["name": name, "passed": true]); print("PASS \(name)") }
        catch { checks.append(["name": name, "passed": false, "error": String(describing: error)]); print("FAIL \(name): \(error)") }
    }
    @MainActor static func wait(_ condition: () -> Bool) async throws {
        let deadline = Date.now.addingTimeInterval(20)
        while !condition() {
            try require(Date.now < deadline, "integration deadline")
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    static var evidence: URL { URL(fileURLWithPath: ProcessInfo.processInfo.environment["T08_EVIDENCE"]!) }
    static var executable: URL { URL(fileURLWithPath: ProcessInfo.processInfo.environment["T08_OMP"]!) }
    static func cleanEnvironment(home: URL) -> [String: String] {
        ["HOME": home.path, "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin", "LANG": "en_US.UTF-8", "TMPDIR": home.appendingPathComponent("tmp").path]
    }
    @MainActor static func config(_ directory: URL, model: String? = nil, effort: String? = nil) -> SessionConfiguration {
        SessionConfiguration(provider: .omp, executable: executable, workingDirectory: directory,
            environment: cleanEnvironment(home: directory), resumeID: nil, resumeAt: nil, model: model,
            effort: effort, runtimeMode: .fullAccess, interactionMode: .build, apiKey: nil)
    }

    @MainActor static func catalog() async {
        if CommandLine.arguments.contains("--real-account") {
            await check("real-cli-auth-catalog-current-model-registry") {
                let environment = ProcessInfo.processInfo.environment
                let list = try await OmpCLI.listModels(executable: executable, environment: environment)
                let raw = JSONValue.parse(try Data(contentsOf: evidence.appendingPathComponent("models-home.json")))!
                let expected = Set((raw["models"]?.array ?? []).compactMap { row -> String? in
                    guard let provider = row["provider"]?.string, let id = row["id"]?.string else { return nil }
                    return provider + "/" + id
                })
                try require(Set(list.map(\.id)) == expected, "real CLI catalog mismatch")
                let providers = Set((raw["models"]?.array ?? []).compactMap { $0["provider"]?.string }).sorted().joined(separator: ", ")
                let auth = await OmpCLI.authStatus(executable: executable, environment: environment)
                try require(auth == .signedIn(providers), "auth provider mismatch")
                let current = list.filter(\.isDefault)
                let state = JSONValue.parse(try Data(contentsOf: evidence.appendingPathComponent("current-state.json")))!
                let model = state["data"]?["model"]
                let selector = (model?["provider"]?.string ?? "") + "/" + (model?["id"]?.string ?? "")
                try require(current.map(\.id) == [selector], "current model mismatch")
                for row in raw["models"]?.array ?? [] {
                    let id = (row["provider"]?.string ?? "") + "/" + (row["id"]?.string ?? "")
                    try require(list.first(where: { $0.id == id })?.efforts == (row["thinking"]?.array ?? []).compactMap(\.string), "effort catalog mismatch")
                }
                let app = AppModel()
                await app.bootstrap()
                app.providers.updateCatalog(list, for: .omp)
                try require(app.providers.models(for: .omp) == list, "registry altered OMP catalog")
                try require(app.saveBeforeQuit(), "private library save failed")
                print("CATALOG count=\(list.count) current=\(selector) authProviders=\(providers)")
            }
        }
        await check("real-cli-no-login-empty-home") {
            let home = evidence.appendingPathComponent("empty-home")
            try FileManager.default.createDirectory(at: home.appendingPathComponent("tmp"), withIntermediateDirectories: true)
            let environment = cleanEnvironment(home: home)
            let auth = await OmpCLI.authStatus(executable: executable, environment: environment)
            try require(auth == .signedOut, "empty HOME did not sign out")
            do { _ = try await OmpCLI.listModels(executable: executable, environment: environment); throw Failure(message: "empty catalog accepted") }
            catch is ProviderError { }
        }
        await check("cli-errors-malformed-and-nonzero-fault-injection") {
            let home = evidence.appendingPathComponent("cli-errors")
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            for (name, script) in [("nonzero", "#!/bin/sh\necho FIXTURE_CLI_FAILURE >&2\nexit 7\n"), ("malformed", "#!/bin/sh\necho not-json\n") ] {
                let file = home.appendingPathComponent(name)
                try script.write(to: file, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
                let auth = await OmpCLI.authStatus(executable: file, environment: cleanEnvironment(home: home))
                try require(auth == .unknown, "failed CLI incorrectly reported login")
                do { _ = try await OmpCLI.listModels(executable: file, environment: cleanEnvironment(home: home)); throw Failure(message: "failed CLI catalog accepted") }
                catch is ProviderError { }
            }
        }
        await check("cli-update-private-layout-and-optional-live-read-only") {
            let environment = ProcessInfo.processInfo.environment
            if CommandLine.arguments.contains("--real-account") {
                let live = try await CLIUpdates.channel(for: .omp, executable: executable, environment: environment)
                guard case .homebrew(_, let token, false) = live else { throw Failure(message: "real brew OMP ownership not recognized") }
                try require(token == "omp", "wrong brew formula")
            }
            let root = evidence.appendingPathComponent("ownership")
            func file(_ path: String) throws -> URL {
                let url = root.appendingPathComponent(path)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try "#!/bin/sh\nexit 99\n".write(to: url, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
                return url
            }
            let npm = try file("prefix/bin/npm")
            let npmCLI = try file("prefix/lib/node_modules/@oh-my-pi/pi-coding-agent/dist/cli.js")
            let channel = try await CLIUpdates.channel(for: .omp, executable: npmCLI, environment: environment)
            guard case .npm(let tool, let package, let prefix, "latest") = channel else { throw Failure(message: "private npm layout not recognized") }
            try require(tool == npm.path && package == "@oh-my-pi/pi-coding-agent" && prefix == root.appendingPathComponent("prefix").path, "wrong npm install ownership")
            let bun = try file("bin/bun")
            let bunCLI = try file("bun-global/node_modules/@oh-my-pi/pi-coding-agent/dist/cli.js")
            var bunEnv = environment
            bunEnv["PATH"] = bun.deletingLastPathComponent().path
            bunEnv["BUN_INSTALL_GLOBAL_DIR"] = root.appendingPathComponent("bun-global").path
            bunEnv["BUN_INSTALL_BIN"] = root.appendingPathComponent("bun-bin").path
            let bunChannel = try await CLIUpdates.channel(for: .omp, executable: bunCLI, environment: bunEnv)
            guard case .bun(_, let bunPackage, let global, let bin, "latest") = bunChannel else { throw Failure(message: "private bun layout not recognized") }
            try require(bunPackage == package && global == bunEnv["BUN_INSTALL_GLOBAL_DIR"] && bin == bunEnv["BUN_INSTALL_BIN"], "wrong bun ownership")
            let unmanaged = try file("unmanaged/omp")
            let unknown = try await CLIUpdates.channel(for: .omp, executable: unmanaged, environment: environment)
            try require(unknown == nil, "unmanaged binary assigned installer")
            if CommandLine.arguments.contains("--real-account") {
                let latest = try await CLIUpdates.latestVersion(.omp, installed: "18.9.1", channel: nil, executable: unmanaged, environment: environment)
                try require(latest != nil && CLIUpdates.compare(latest!, with: "18.9.1") != .unparsed, "official package latest missing")
            }
            try require(CLIUpdates.compare("18.9.2", with: "18.9.1") == .newer && CLIUpdates.compare("18.9.1", with: "18.9.1") == .equal, "version comparison failed")
            print("CLI_UPDATES npm=\(channel!.command) bun=\(bunChannel!.command) (invocations inspected, never executed)")
        }
        await check("invalid-initial-model-and-effort-rejected-without-launch") {
            let home = evidence.appendingPathComponent("selection")
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            for c in [config(home, model: "not-a-selector"), config(home, model: "provider/"), config(home, effort: "invalid-effort")] {
                let session = OmpSession(configuration: c)
                do { _ = try await session.start(); session.stop(); throw Failure(message: "invalid selection accepted") }
                catch is ProviderError { }
                try require(!session.isRunning, "invalid selection launched")
            }
        }
    }

    @MainActor static func liveRuntime() async {
        await check("actual-app-factory-omp-mcp-approvals-fork-resume-stop") {
            let project = Project(name: "Runtime loopback fixture", path: evidence.appendingPathComponent("runtime-project").path)
            try FileManager.default.createDirectory(at: project.url, withIntermediateDirectories: true)
            let thread = ChatThread(projectID: project.id, provider: .omp, model: "tivano-offline/offline", effort: "off", runtimeMode: .supervised)
            var library = Library(); library.projects = [project]; library.threads = [thread]
            try JSONEncoder.storage.encode(library).write(to: Storage.libraryURL, options: .atomic)
            let app = AppModel(); app.settings.textGeneration = .off; app.settings.hydraEnabled = false
            app.settings.setBinaryPath(executable.path, for: .omp)
            await app.bootstrap()
            let server = MCPResolvedServer(id: "fixture", name: "Fixture MCP", command: ProcessInfo.processInfo.environment["T08_PYTHON"], args: [ProcessInfo.processInfo.environment["T08_MCP_SERVER"]!], env: ["T08_MCP_ROOT": evidence.appendingPathComponent("runtime-markers").path])
            try MCPProviderConfig.claude([server]).data().write(to: MCPPaths.claudeConfigURL, options: .atomic)
            let runtime = app.runtime(for: thread.id); await runtime.ensureLoaded()
            func prompt(_ id: String, tool: String, input: [String: Any]) throws -> String {
                "TIVANO_GATE_CASE " + String(decoding: try JSONSerialization.data(withJSONObject: ["id": id, "tool": tool, "input": input], options: [.sortedKeys]), as: UTF8.self)
            }
            @MainActor func send(_ text: String, approve: Bool, expectedApprovals: Int) async throws {
                let count = runtime.turns.count
                var answered = Set<String>()
                runtime.draft.text = text; runtime.send()
                try await wait { runtime.turns.count > count }
                let deadline = Date.now.addingTimeInterval(30)
                while runtime.isRunning {
                    for request in runtime.approvals where answered.insert(request.id).inserted {
                        guard let option = request.options.first(where: { $0.role == (approve ? .approve : .decline) }) else { throw Failure(message: "approval option missing") }
                        runtime.resolve(request, option: option)
                    }
                    try require(Date.now < deadline, "actual runtime turn deadline")
                    try await Task.sleep(for: .milliseconds(10))
                }
                try require(answered.count == expectedApprovals, "actual runtime approval count mismatch")
                try require(runtime.turns.last?.status == .completed, "actual runtime turn failed")
            }
            let write = try prompt("runtime-approve", tool: "write", input: ["path": "xd://mcp__fixture__write_marker", "content": "{\"marker\":\"approved.txt\"}"])
            try await send(write, approve: true, expectedApprovals: 1)
            try require(FileManager.default.fileExists(atPath: evidence.appendingPathComponent("runtime-markers/approved.txt").path), "MCP approved write missing")
            // Send the next round while automatic /rename may still be in flight.
            let deny = try prompt("runtime-deny", tool: "write", input: ["path": "xd://mcp__fixture__write_marker", "content": "{\"marker\":\"denied.txt\"}"])
            try await send(deny, approve: false, expectedApprovals: 1)
            try require(!FileManager.default.fileExists(atPath: evidence.appendingPathComponent("runtime-markers/denied.txt").path), "MCP denied write happened")
            try require(runtime.entries.contains { if case .tool(let call) = $0.item.content { return call.status == .declined }; return false }, "denial row not rejected")
            app.rename(thread.id, to: "Owner loopback title")
            app.updateThread(thread.id) { $0.runtimeMode = .fullAccess }
            let errorPrompt = try prompt("runtime-mcp-error", tool: "write", input: ["path": "xd://mcp__fixture__tool_error", "content": "{\"marker\":\"failed.txt\"}"])
            try await send(errorPrompt, approve: false, expectedApprovals: 0)
            try require(runtime.entries.contains { if case .tool(let call) = $0.item.content { return call.status == .failed && call.output.contains("FIXTURE_MCP_FAILURE") }; return false }, "MCP error row falsely completed")
            try require(app.thread(thread.id)?.title == "Owner loopback title", "automatic title overwrote user title")
            let todo = try prompt("runtime-todo", tool: "todo", input: ["op": "init", "i": "fixture checklist", "items": ["fixture todo", "Blocked", "Abandoned"]])
            try await send(todo, approve: false, expectedApprovals: 0)
            @MainActor func lastTodos(_ runtime: ThreadRuntime) -> [TodoStep] {
                runtime.entries.compactMap { if case .todos(let rows) = $0.item.content { return rows }; return nil }.last ?? []
            }
            try require(lastTodos(runtime).count == 3 && lastTodos(runtime)[0].status == .active, "real todo init missing from runtime")
            let todoDone = try prompt("runtime-xd-todo", tool: "write", input: ["path": "xd://todo", "content": "{\"op\":\"done\",\"i\":\"Complete first\",\"task\":\"fixture todo\"}"])
            try await send(todoDone, approve: false, expectedApprovals: 0)
            try require(lastTodos(runtime).first?.status == .done, "xd todo completion not mapped")
            let todoBlocked = try prompt("runtime-block-todo", tool: "todo", input: ["op": "block", "i": "External wait", "task": "Blocked", "reason": "Acceptance fixture"])
            try await send(todoBlocked, approve: false, expectedApprovals: 0)
            try require(lastTodos(runtime).first(where: { $0.text.contains("Blocked") })?.status == .pending, "blocked todo not pending")
            let original = app.thread(thread.id)?.providerSessionID
            // Repeated text must rewind the nearest expected turn, not an earlier match.
            let repeated = try prompt("runtime-repeat", tool: "read", input: ["path": evidence.appendingPathComponent("runtime-markers/approved.txt").path])
            try await send(repeated, approve: false, expectedApprovals: 0)
            try await send(repeated, approve: false, expectedApprovals: 0)
            let removed = runtime.turns.last!.id
            try require(try await runtime.revert(to: removed, restoreFiles: false), "runtime rewind failed")
            let fork = app.thread(thread.id)?.providerSessionID
            try require(fork != nil && fork != original && FileManager.default.fileExists(atPath: fork!), "fork path not new/persisted")
            try require(app.flushForQuit(), "fork flush failed")
            try await send(repeated, approve: false, expectedApprovals: 0)
            try require(app.thread(thread.id)?.providerSessionID == fork, "resume changed fork path")
            runtime.saveNow()
            let gateDirectory = OmpCLI.supportDirectory.appendingPathComponent("gates")
            let ownGates = try FileManager.default.contentsOfDirectory(at: gateDirectory, includingPropertiesForKeys: nil)
            try require(ownGates.count == 1, "runtime leaked replacement gates")
            let surviving = ownGates[0]
            try FileManager.default.setAttributes([.modificationDate: Date.now.addingTimeInterval(-172800)], ofItemAtPath: surviving.path)
            var peerConfig = config(project.url, model: "tivano-offline/offline", effort: "off")
            peerConfig.environment = ProcessInfo.processInfo.environment
            let peer = OmpSession(configuration: peerConfig)
            _ = try await peer.start()
            try require(FileManager.default.fileExists(atPath: surviving.path), "new session deleted old active gate")
            for (model, effort) in [(nil, "invalid-effort" as String?), ("unknown-provider/not-a-model" as String?, nil)] {
                do {
                    try await peer.send(TurnInput(text: "Must not reach model", images: [], model: model, effort: effort, runtimeMode: .fullAccess, interactionMode: .build))
                    throw Failure(message: "invalid live selection accepted")
                } catch is ProviderError { }
            }
            var peerCompleted = false
            peer.onEvent = { event in if case .turnCompleted(let status, _) = event { peerCompleted = status == .completed } }
            try await peer.send(TurnInput(text: repeated, images: [], model: "tivano-offline/reasoning", effort: "high", runtimeMode: .fullAccess, interactionMode: .build))
            try await wait { peerCompleted }
            await peer.stopAndWait(timeout: 3)
            try require(FileManager.default.fileExists(atPath: surviving.path), "peer stop deleted runtime gate")
            try require(app.saveBeforeQuit(), "runtime save/stop failed")
            try await wait { (try? FileManager.default.contentsOfDirectory(atPath: gateDirectory.path).isEmpty) == true }
            let saved = try Storage.loadLibrary().get()
            try require(saved.threads[0].providerSessionID == fork && saved.threads[0].title == "Owner loopback title", "real fork/custom title not saved")
            let restored = AppModel(); restored.settings.textGeneration = .off; restored.settings.hydraEnabled = false
            restored.settings.setBinaryPath(executable.path, for: .omp); await restored.bootstrap()
            let reloaded = restored.runtime(for: thread.id); await reloaded.ensureLoaded()
            try require(reloaded.turns.count == runtime.turns.count, "actual runtime reload lost turns")
            try require(lastTodos(reloaded).first?.status == .done, "real checklist not saved/reloaded")
            reloaded.draft.text = repeated; reloaded.send()
            try await wait { reloaded.isRunning }
            try await wait { !reloaded.isRunning }
            try require(reloaded.turns.last?.status == .completed && restored.thread(thread.id)?.providerSessionID == fork, "process-like App reload did not resume fork")
            try require(restored.saveBeforeQuit(), "restored runtime stop failed")
            print("REAL_RUNTIME turns=\(reloaded.turns.count) fork=\(fork!)")
        }
    }

    @MainActor static func persistence() async {
        await check("capture-storage-defaults-mcp-config-and-bridge-isolation") {
            guard let root = CaptureRun.storageRoot else { throw Failure(message: "no capture root") }
            try require(Storage.root == root && StoragePaths.root == root, "store escaped root")
            try require(Storage.worktreesDirectory.path.hasPrefix(root.path + "/state/"), "worktrees escaped root")
            let bridge = try MCPBridge.installBridge()
            try require(bridge.path.hasPrefix(root.path + "/"), "bridge escaped root")
            try require(MCPPaths.claudeConfigURL.path.hasPrefix(root.path + "/"), "MCP config escaped root")
            try require(CaptureRun.suiteName.hasPrefix(CaptureRun.outputDirectory!.path + "/"), "defaults escaped capture folder")
            CaptureRun.defaults!.set("fixture-private", forKey: "t08-isolation")
            try require(CaptureRun.defaults!.synchronize(), "private settings sync failed")
            let preferences = URL(fileURLWithPath: CaptureRun.suiteName + ".plist")
            try require(FileManager.default.fileExists(atPath: preferences.path), "settings not physically inside capture folder")
            try OmpCLI.installExtension().path.write(to: evidence.appendingPathComponent("exported-extension-path.txt"), atomically: true, encoding: .utf8)
            try bridge.path.write(to: evidence.appendingPathComponent("exported-bridge-path.txt"), atomically: true, encoding: .utf8)
            let server = MCPResolvedServer(id: "fixture", name: "Fixture MCP", command: ProcessInfo.processInfo.environment["T08_PYTHON"], args: [ProcessInfo.processInfo.environment["T08_MCP_SERVER"]!], env: ["T08_MCP_ROOT": evidence.appendingPathComponent("mcp-markers").path])
            let payload = MCPProviderConfig.claude([server])
            try payload.data().write(to: MCPPaths.claudeConfigURL, options: .atomic)
            try payload.data().write(to: evidence.appendingPathComponent("exported-mcp-config.json"), options: .atomic)
            print("ROOT \(root.path) SUITE \(CaptureRun.suiteName)")
        }
        await check("actual-library-app-auto-lowering-save-reload-dedup") {
            let project = Project(name: "T08 synthetic", path: evidence.appendingPathComponent("private-project").path)
            try FileManager.default.createDirectory(at: project.url, withIntermediateDirectories: true)
            var thread = ChatThread(projectID: project.id, provider: .claude, model: nil, effort: nil, runtimeMode: .auto)
            thread.providerSessionID = evidence.appendingPathComponent("original.jsonl").path
            var library = Library(); library.projects = [project]; library.threads = [thread]
            var raw = try JSONSerialization.jsonObject(with: JSONEncoder.storage.encode(library)) as! [String: Any]
            var rows = raw["threads"] as! [[String: Any]]; rows[0]["provider"] = "omp"; raw["threads"] = rows
            try JSONSerialization.data(withJSONObject: raw).write(to: Storage.libraryURL, options: .atomic)
            let app = AppModel(); app.settings.textGeneration = .off
            await app.bootstrap()
            try require(app.thread(thread.id)?.runtimeMode == .autoAcceptEdits, "old Auto not lowered")
            try require(app.alert?.title == "Permissions changed", "lowering alert missing")
            app.alert = nil
            app.updateThread(thread.id) { $0.runtimeMode = .auto }
            try require(app.alert == nil, "lowering alert repeated")
            try require(app.flushForQuit(), "normalized library save failed")
            let saved = try Data(contentsOf: Storage.libraryURL)
            let normalized = try JSONDecoder.storage.decode(Library.self, from: saved)
            try require(normalized.threads[0].runtimeMode == .autoAcceptEdits, "lowering not persisted")
            let restored = AppModel(); restored.settings.textGeneration = .off
            await restored.bootstrap()
            try require(restored.thread(thread.id)?.runtimeMode == .autoAcceptEdits && restored.alert == nil, "reload normalization/alert wrong")
            try require(app.saveBeforeQuit() && restored.saveBeforeQuit(), "private App teardown save failed")
        }
        await check("actual-runtime-title-todo-resume-token-ledger-store-reload") {
            let app = AppModel(); app.settings.textGeneration = .off; await app.bootstrap()
            let thread = app.threads[0]
            let runtime = app.runtime(for: thread.id); await runtime.ensureLoaded()
            runtime.rehearseTurn("Synthetic protocol events, not a model round")
            runtime.rehearse(.title("OMP fallback title"))
            try require(app.thread(thread.id)?.title == "OMP fallback title", "fallback title not applied")
            app.rename(thread.id, to: "Owner custom title")
            runtime.rehearse(.title("Must not overwrite"))
            try require(app.thread(thread.id)?.title == "Owner custom title", "provider overwrote custom title")
            runtime.rehearse(.todos([TodoStep(text: "First", status: .pending)]))
            runtime.rehearse(.todos([TodoStep(text: "First", status: .done)]))
            let forkPath = evidence.appendingPathComponent("fork.jsonl").path
            runtime.rehearse(.sessionReady(sessionID: forkPath))
            try require(app.thread(thread.id)?.providerSessionID == forkPath, "fork resume path not updated")
            runtime.rehearse(.tokenSpend(TokenSpend(provider: .omp, totalTokens: 123)))
            runtime.rehearse(.tokenSpend(TokenSpend(provider: .omp, totalTokens: 999, agentID: "native-child")))
            try require(runtime.turns.last?.tokenSpends?.reduce(0, { $0 + $1.totalTokens }) == 123, "lead turn includes child spend or duplicate")
            // The adapter owns ledger recording; the runtime owns turn spend. Exercise
            // the real ledger separately with this synthetic spend, not a ledger shim.
            TokenLedger.shared.record(TokenSpend(provider: .omp, totalTokens: 123))
            try require(TokenLedger.shared.dailyTotals.values.reduce(0, +) == 123, "ledger record failed")
            TokenLedger.shared.flushLiveSpend()
            runtime.rehearse(.messageCompleted(id: "unicode", text: "fixture 中文🙂e\u{301}"))
            runtime.rehearse(.turnCompleted(status: .completed, error: nil))
            try await wait { !runtime.isRunning }
            runtime.saveNow()
            try require(app.flushForQuit(), "runtime flush failed")
            guard let doc = Storage.decodeDocument(thread.id) else { throw Failure(message: "thread document not saved") }
            let todos = doc.items.compactMap { item -> [TodoStep]? in if case .todos(let rows) = item.content { return rows }; return nil }
            try require(todos.count == 1 && todos[0][0].status == .done, "checklist duplicated or not saved")
            try require(doc.items.contains { if case .assistant(let message) = $0.content { return message.text == "fixture 中文🙂e\u{301}" }; return false }, "Unicode not persisted")
            let savedLibrary = try Storage.loadLibrary().get()
            try require(savedLibrary.threads[0].providerSessionID == forkPath && savedLibrary.threads[0].hasCustomTitle, "library lost fork/title")
            let restored = AppModel(); await restored.bootstrap()
            let restoredRuntime = restored.runtime(for: thread.id); await restoredRuntime.ensureLoaded()
            try require(restoredRuntime.entries.contains { if case .todos(let rows) = $0.item.content { return rows[0].status == .done }; return false }, "runtime reload lost todo")
            try require(app.saveBeforeQuit() && restored.saveBeforeQuit(), "runtime teardown failed")
        }
    }

    @MainActor static func main() async {
        guard CaptureRun.isEnabled, let root = CaptureRun.storageRoot else { fatalError("isolated capture root required") }
        signal(SIGPIPE, SIG_IGN)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if CommandLine.arguments.contains("--ledger-reload") {
            await check("actual-token-ledger-process-reload") {
                try require(TokenLedger.shared.dailyTotals.values.reduce(0, +) == 123, "ledger did not survive process restart")
            }
        } else if CommandLine.arguments.contains("--second-root") {
            await check("second-capture-root-isolated") {
                try require(CaptureRun.defaults?.string(forKey: "t08-isolation") == nil, "capture settings crossed roots")
                let bridge = try MCPBridge.installBridge()
                try require(bridge.path.hasPrefix(root.path + "/"), "second bridge escaped root")
                print("ROOT \(root.path) SUITE \(CaptureRun.suiteName)")
            }
        } else if CommandLine.arguments.contains("--cli") { await catalog() }
        else if CommandLine.arguments.contains("--runtime") { await liveRuntime() }
        else { await persistence() }
        let passed = checks.allSatisfy { $0["passed"] as? Bool == true }
        let summary: [String: Any] = ["passed": passed, "realAccountQueries": CommandLine.arguments.contains("--real-account"),
            "skipped": CommandLine.arguments.contains("--cli") && !CommandLine.arguments.contains("--real-account") ? ["account catalog/current-model/usage", "live installation ownership", "online registry"] : [], "checks": checks, "root": root.path, "suite": CaptureRun.suiteName,
            "scope": "Actual Debug App module loaded by a CLI harness, without SwiftUI/App entry or GUI launch. Actual Library/Store/TokenLedger/AppModel/ThreadRuntime; rehearsal events explicitly synthetic."]
        let name = CommandLine.arguments.contains("--runtime") ? "runtime-integration-summary.json" : CommandLine.arguments.contains("--cli") ? "cli-integration-summary.json" : CommandLine.arguments.contains("--second-root") ? "second-root-summary.json" : CommandLine.arguments.contains("--ledger-reload") ? "ledger-reload-summary.json" : "store-integration-summary.json"
        try! JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys]).write(to: evidence.appendingPathComponent(name))
        exit(passed ? 0 : 1)
    }
}
