import Foundation
import Darwin

struct AssertionFailure: Error { let message: String }

@MainActor final class Recorder {
    var ends: [TurnStatus] = []
    var text = ""
    var approvals: [ApprovalRequest] = []
    var resolved: [String] = []
    var edits: [String: [FileEdit]] = [:]
    var statuses: [String: ToolCall.Status] = [:]
    var exitCodes: [String: Int] = [:]
    var models: [ModelOption] = []
    var current: String?
    var kinds: [String: ToolCall.Kind] = [:]
    var titles: [String: String] = [:]
    var failures: [String] = []
    func consume(_ event: ProviderEvent) {
        switch event {
        case .turnCompleted(let status, let error):
            ends.append(status)
            if let error { failures.append(error) }
        case .exited(let error): if let error { failures.append(error) }
        case .messageDelta(_, let value): text += value
        case .approval(let value): approvals.append(value)
        case .requestResolved(let id): resolved.append(id)
        case .toolStarted(let id, let call):
            edits[id] = call.edits; statuses[id] = call.status
            kinds[id] = call.kind; titles[id] = call.title
        case .toolUpdated(let id, let update):
            if let value = update.kind { kinds[id] = value }
            if let value = update.title { titles[id] = value }
            if let value = update.edits { edits[id] = value }
            if let value = update.status { statuses[id] = value }
            if let value = update.exitCode { exitCodes[id] = value }
        case .models(let value, let selected): models = value; current = selected
        default: break
        }
    }
    var snapshot: [String: Any] {
        ["turns": ends.map { String(describing: $0) }, "text": text,
         "approvals": approvals.map { ["id": $0.id, "title": $0.title, "detail": $0.detail ?? ""] },
         "failures": failures, "toolKinds": kinds.mapValues { String(describing: $0) }, "toolTitles": titles,
         "resolved": resolved, "editCount": edits.values.reduce(0) { $0 + $1.count },
         "currentModel": current ?? "", "defaultModels": models.filter(\.isDefault).map(\.id)]
    }
}

@main struct Harness {
    @MainActor static var observations: [String: Any] = [:]
    @MainActor static var sessions: [ACPSession] = []
    @MainActor static var recorders: [Recorder] = []
    static let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["DSH_TEST_ROOT"]!)
    static let name = ProcessInfo.processInfo.environment["DSH_TEST_CASE"]!
    static let executable = URL(fileURLWithPath: CommandLine.arguments[1])

    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw AssertionFailure(message: message) }
    }
    @MainActor static func wait(_ condition: () -> Bool) async throws {
        let start = Date.now
        while !condition() {
            if Date.now.timeIntervalSince(start) > 5 { throw AssertionFailure(message: "Expected event absent after 5 seconds") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    static func input(model: String? = nil) -> TurnInput {
        TurnInput(text: "fixture", images: [], model: model, effort: nil, runtimeMode: .supervised, interactionMode: .build)
    }
    @MainActor static func make(_ label: String = "one") -> (ACPSession, Recorder) {
        var env = ProcessInfo.processInfo.environment
        env["DSH_TEST_LABEL"] = label
        var config = SessionConfiguration(provider: name.hasPrefix("acp-") ? .grok : .dsh, executable: executable, workingDirectory: root,
                                          environment: env, runtimeMode: .supervised, interactionMode: .build)
        if name.hasPrefix("resume-") { config.resumeID = "original-session" }
        if name == "resume-permission" { config.runtimeMode = .fullAccess }
        if name == "final-report" || name == "report-guard-missing" { config.dshFinalReport = true }
        let session = ACPSession(configuration: config)
        let recorder = Recorder()
        session.onEvent = { recorder.consume($0) }
        sessions.append(session)
        recorders.append(recorder)
        return (session, recorder)
    }
    @MainActor static func wire() -> [[String: Any]] {
        let files = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.lastPathComponent.hasPrefix("wire-") }.flatMap { url -> [[String: Any]] in
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            return text.split(separator: "\n").compactMap { line in
                (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
            }
        }
    }
    @MainActor static func exercise() async throws {
        if name == "credential-records" {
            let valid = "version: 1\nrecords:\n  deepseek-account-platform/default:\n    kind: grant\n    payload:\n      version: 1\n      token: fixture-only\n      issuer: https://example.invalid\n"
            try require(DshCLI.hasAccountRecord(in: valid), "Canonical local account record not detected")
            for invalid in ["# deepseek-account-platform/default\n", "records:\n  deepseek-account-platform/default: {}\n", valid.replacingOccurrences(of: "token: fixture-only", with: "token: ''"), valid.replacingOccurrences(of: "kind: grant", with: "kind: api-key"), valid.replacingOccurrences(of: "records:", with: "refs:"), valid.replacingOccurrences(of: "payload:", with: "unrelated:")] {
                try require(!DshCLI.hasAccountRecord(in: invalid), "Invalid/comment/empty record treated as account")
            }
            return
        }
        if name == "patch-validation" {
            let env = ProcessInfo.processInfo.environment
            let args = DshCLI.launchArguments(mode: .minimal, delegationOff: false, environment: env)
            let warningFile = root.appendingPathComponent("patch-warnings.txt")
            let optional = args.first { $0.hasSuffix("minimal-optional.yml") }!
            let required = args.first { $0.hasSuffix("minimal.yml") }!
            for (warning, expected) in [("", true), ("dsh: [\(required)] patch: entry \"tool-bash\" not found", false), ("", true), ("dsh: [\(optional)] patch: entry \"tool-working-directory\" not found", true), ("dsh: [/external/minimal-optional.yml] patch: entry \"tool-working-directory\" not found", false)] {
                try warning.write(to: warningFile, atomically: false, encoding: .utf8)
                let accepted = await DshCLI.patchesApply(executable: executable, arguments: args, environment: env)
                try require(accepted == expected, "Patch diagnostic stale or optional file falsely exempted")
            }
            return
        }
        if name == "probe-unusable-route" {
            let models = try await ACPSession.probeModels(provider: .dsh, executable: executable, environment: ProcessInfo.processInfo.environment)
            let flash = "[\"deepseek-account\",\"deepseek-v4-flash\"]"
            try require(models.count == 2 && models.filter(\.isDefault).map(\.id) == [flash], "Unavailable route lost Flash default")
            let selections = wire().filter { $0["method"] as? String == "session/set_config_option" }.compactMap { ($0["params"] as? [String: Any])?["value"] as? String }
            try require(selections.last == flash && selections.allSatisfy { !$0.contains("deepseek-official") }, "Probe restored unavailable route or failed to restore Flash")
            return
        }
        if name == "probe" || name == "probe-timeout" || name == "probe-default" {
            do {
                let models = try await ACPSession.probeModels(provider: .dsh, executable: executable, environment: ProcessInfo.processInfo.environment)
                observations["models"] = models.map(\.id)
                observations["defaultsAfterProbe"] = models.filter(\.isDefault).map(\.id)
                if name == "probe-default" {
                    try require(models.filter(\.isDefault).map(\.id) == ["deepseek-account/v4-flash"], "Full probe replaced non-Pro default")
                }
                try require(name != "probe-timeout", "Unanswered probe selection unexpectedly succeeded")
                try require(Set(models.map(\.id)) == Set(["deepseek-account/v4-flash", "deepseek-account/v4-pro"]), "Probe lost models")
            } catch is AssertionFailure { throw AssertionFailure(message: "Probe result violated expectation") }
            catch {
                observations["probeError"] = String(describing: error)
                try require(name == "probe-timeout", "Normal probe failed")
            }
            return
        }
        let (session, r) = make()
        if name == "startup-failure" {
            var failed = false
            do { _ = try await session.start() } catch { failed = true; observations["startError"] = String(describing: error) }
            try await Task.sleep(for: .milliseconds(300))
            let alive = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix("alive-") }
            observations["aliveBeforeCallerStop"] = alive
            try require(failed && !session.isRunning && alive.isEmpty, "Failed start left a live peer before caller cleanup")
            return
        }
        if name == "resume-permission" {
            _ = try await session.start()
            try await Task.sleep(for: .milliseconds(200))
            let allowed = wire().contains { frame in
                let outcome = (frame["result"] as? [String: Any])?["outcome"] as? [String: Any]
                return frame["id"] as? String == "old-permission" && outcome?["optionId"] as? String == "allow"
            }
            try require(!allowed, "Old-session permission automatically approved during recovery")
            return
        }
        if name.hasPrefix("resume-") || name == "mixed-mcp" {
            var failed = false
            do { observations["startedID"] = try await session.start() }
            catch { failed = true; observations["startError"] = String(describing: error) }
            let frames = wire()
            if name.hasPrefix("resume-") {
                if name != "resume-unsupported" {
                    try require(frames.contains { $0["method"] as? String == "session/resume" }, "Resume not attempted")
                }
                try require(!frames.contains { $0["method"] as? String == "session/new" }, "Resume failure silently created a new session")
                try require(failed, "Resume failure must be surfaced, including explicitly missing history")
            } else {
                let attempts = frames.filter { $0["method"] as? String == "session/new" }
                let lists = attempts.map { ($0["params"] as? [String: Any])?["mcpServers"] as? [[String: Any]] ?? [] }
                observations["mcpAttempts"] = lists
                try require(!lists.isEmpty && lists.allSatisfy { $0.contains { $0["name"] as? String == "healthy" } }, "Mixed failure silently removed healthy MCP server")
                try require(failed || lists.count > 1, "Mixed MCP failure neither surfaced nor retried selectively")
            }
            return
        }
        _ = try await session.start()
        if name == "default-model" {
            try require(r.current == "deepseek-account/v4-flash", "Current model overwritten")
            try require(r.models.filter(\.isDefault).map(\.id) == ["deepseek-account/v4-flash"], "Non-Pro current model default overwritten by Pro")
            try require(!wire().contains { ($0["method"] as? String)?.hasPrefix("session/set_") == true }, "Unrequested selection sent")
            return
        }
        if name == "selection-timeout" {
            var failed = false
            do { try await session.send(input(model: "deepseek-account/v4-pro")) }
            catch { failed = true; observations["selectionError"] = String(describing: error) }
            try require(failed && r.ends.isEmpty, "Unanswered selection must fail without a phantom turn")
            return
        }
        if name == "repeat-start" {
            _ = try await session.start()
            await session.stopAndWait(timeout: 5)
            try await Task.sleep(for: .milliseconds(200))
            let alive = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix("alive-") }
            observations["aliveAfterStop"] = alive
            try require(alive.isEmpty && !session.isRunning, "Repeated start orphaned a peer")
            return
        }
        if name == "parallel" {
            let (other, second) = make("two")
            _ = try await other.start()
            try await session.send(input())
            try await other.send(input())
            try await wait { r.ends.count == 1 && second.ends.count == 1 }
            try require(r.text == "one" && second.text == "two", "Parallel sessions crossed event streams")
            try require(r.ends == [.completed] && second.ends == [.completed], "Parallel completion mismatch")
            return
        }
        if name == "cancel-rebuild" {
            for index in 0..<8 {
                let (active, recorder) = index == 0 ? (session, r) : make("cycle-\(index)")
                if index != 0 { _ = try await active.start() }
                try await active.send(input())
                try await wait { recorder.approvals.count == 1 }
                await active.interrupt()
                try await wait { !recorder.ends.isEmpty }
                await active.stopAndWait(timeout: 5)
                try await Task.sleep(for: .milliseconds(100))
                try require(recorder.ends == [.interrupted] && recorder.resolved.count == 1, "Cancel/rebuild duplicated completion or resolution")
            }
            return
        }
        if name == "report-guard-missing" {
            var turn = input()
            turn.isFinalReport = true
            var refused = false
            do { try await session.send(turn) } catch { refused = true }
            try require(refused && !wire().contains { $0["method"] as? String == "session/prompt" }, "Missing guard dispatched report prompt")
            return
        }
        if name == "final-report" {
            var turn = input()
            turn.isFinalReport = true
            do { try await session.send(turn) }
            catch {
                observations["safety"] = "safe-refusal"
                observations["fullCompletion"] = "unsupported"
                observations["sendError"] = String(describing: error)
                try require(!wire().contains { $0["method"] as? String == "session/prompt" }, "Rejected only after dispatching final report")
                throw AssertionFailure(message: "Safe refusal is not full final-report support")
            }
            try await wait { !r.ends.isEmpty || !r.approvals.isEmpty }
            try await Task.sleep(for: .milliseconds(200))
            let executed = FileManager.default.fileExists(atPath: root.appendingPathComponent("fixture-tool-executed").path)
            observations["safety"] = executed ? "unsafe-tool-execution" : "no-simulated-execution"
            observations["fullCompletion"] = !executed && r.ends == [.completed] && r.text == "final report" && r.approvals.isEmpty ? "supported-in-simulation" : "unsupported"
            try require(!executed, "Final report allowed simulated tool execution")
            try require(r.ends == [.completed] && r.text == "final report" && r.approvals.isEmpty, "Final report did not complete tool-free")
            return
        }
        try await session.send(input(model: name == "acp-selection" ? "deepseek-account/v4-pro" : nil))
        if name == "acp-permission" || name == "acp-cancel" {
            try await wait { r.approvals.count == 1 }
            if name == "acp-cancel" { await session.interrupt() }
            else { session.resolveApproval(r.approvals[0].id, optionID: "allow") }
        }
        if name == "typed-ids" || name == "late-input" || name == "cancel" {
            try await wait { r.approvals.count >= (name == "typed-ids" ? 2 : 1) }
            if name == "typed-ids" {
                try require(Set(r.approvals.map(\.id)).count == 2, "Integer 1 and string 1 share an approval identity")
                session.resolveApproval(r.approvals[0].id, optionID: "allow")
                session.resolveApproval(r.approvals[1].id, optionID: "deny")
            } else if name == "cancel" {
                await session.interrupt()
            } else {
                let approval = r.approvals[0]
                try require((approval.title + " " + (approval.detail ?? "")).contains("echo late-approval-detail"), "Approval omitted incremental command input")
                session.resolveApproval(approval.id, optionID: "allow")
            }
        }
        try await wait { !r.ends.isEmpty }
        try await Task.sleep(for: .milliseconds(150))
        try require(r.ends == [(name == "cancel" || name == "acp-cancel") ? .interrupted : .completed], "Turn did not complete exactly once with expected status")
        if name == "event-flood" {
            try require(r.text == String(repeating: "x", count: 2000), "Flood lost or duplicated text")
        } else if name == "dsh-bash-exit" || name == "acp-bash-exit" {
            let dsh = name == "dsh-bash-exit"
            try require(r.statuses["failure"] == (dsh ? .failed : .completed), "Exit presentation crossed provider boundary or lost failure")
            try require(r.exitCodes["failure"] == (dsh ? 17 : nil), "Exit marker not scoped to DSH")
            for id in ["body", "ptc", "read", "typed"] {
                try require(r.statuses[id] == .completed, "Non-bash/body/typed output incorrectly marked failed")
            }
            try require(r.exitCodes["typed"] == 0 && r.exitCodes["ptc"] == nil && r.exitCodes["body"] == nil, "Structured exit or opaque output mishandled")
        } else if name == "incremental-kind" {
            try require(r.kinds["tool"] == .command && r.titles["tool"] == "Running fixture command", "Incremental title lost protocol kind or title")
        } else if name == "acp-selection" {
            try require(r.text == "one" && wire().contains { ($0["method"] as? String)?.hasPrefix("session/set_") == true }, "ACP selection or message lost")
        } else if name == "acp-cancel" {
            try require(r.resolved.count == 1, "ACP cancellation did not resolve permission once")
        } else if name == "acp-permission" {
            try require(wire().contains { (($0["result"] as? [String: Any])?["outcome"] as? [String: Any])?["optionId"] as? String == "allow" }, "ACP approval not delivered")
        }
        if name == "two-turns" {
            try await session.send(input())
            try await wait { r.ends.count >= 2 }
            try await Task.sleep(for: .milliseconds(150))
            try require(r.ends == [.completed, .completed] && r.text == "oneone", "Two turns did not each complete exactly once")
        } else if name == "wrong-session" {
            try require(r.text == "one" && r.approvals.isEmpty, "Foreign session messages or permissions escaped isolation")
        } else if name == "failed-edit" || name == "failed-write" {
            try require(r.statuses["tool"] == .failed, "Failed tool was not marked failed")
            try require((r.edits["tool"] ?? []).isEmpty, "Failed operation still claims actual file edits")
            let content = try String(contentsOf: root.appendingPathComponent("unchanged.txt"), encoding: .utf8)
            try require(content == "before", "Fixture file unexpectedly changed")
        } else if name == "cancel" {
            try require(r.resolved.count == 1, "Cancelled permission left unresolved")
        } else if name == "typed-ids" {
            let responses = wire().filter { $0["method"] == nil && $0["result"] != nil }
            let integer = responses.first { $0["id"] is NSNumber }
            let string = responses.first { $0["id"] as? String == "1" }
            func selected(_ frame: [String: Any]?) -> String? {
                ((frame?["result"] as? [String: Any])?["outcome"] as? [String: Any])?["optionId"] as? String
            }
            try require(selected(integer) == "allow" && selected(string) == "deny", "Typed approvals delivered to wrong RPC request")
        }
    }
    @MainActor static func main() async {
        var failure: String?
        do { try await exercise() } catch { failure = String(describing: error) }
        for session in sessions { await session.stopAndWait(timeout: 5) }
        try? await Task.sleep(for: .milliseconds(200))
        observations["events"] = recorders.map(\.snapshot)
        observations["wire"] = wire()
        let alive = (try? FileManager.default.contentsOfDirectory(atPath: root.path))?.filter { $0.hasPrefix("alive-") } ?? []
        observations["aliveAfterStop"] = alive
        if !alive.isEmpty && failure == nil { failure = "Peer remains alive after stopAndWait" }
        let result: [String: Any] = ["name": name, "passed": failure == nil, "error": failure ?? "", "observed": observations]
        do {
            let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: root.appendingPathComponent("result.json"))
            print(String(decoding: data, as: UTF8.self))
        } catch { exit(2) }
        exit(failure == nil ? 0 : 1)
    }
}
