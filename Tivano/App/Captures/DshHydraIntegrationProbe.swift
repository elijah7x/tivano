#if DEBUG
import AppKit
import CryptoKit
import Foundation

@MainActor
enum DshHydraIntegrationProbe {
    private static let fixtureID = "tivano-dsh-offline-hydra-v1"
    private static let projectID = UUID()
    private static let leadID = UUID()
    private static var issue: String?
    private static var marker = ""
    private static var budget: Bool { CommandLine.arguments.contains("--dsh-offline-hydra-budget") }
    private struct Failure: Error { let message: String }

    static func prepare() {
        guard DshIntegrationConfiguration.isOfflineHydra else { return }
        do {
            guard let output = CaptureRun.outputDirectory, let root = CaptureRun.storageRoot,
                  let defaults = CaptureRun.defaults, let paths = DshIntegrationConfiguration.paths else {
                throw Failure(message: "Missing isolated capture paths")
            }
            let fm = FileManager.default
            for name in ["started", "dsh-hydra.json"] {
                guard !fm.fileExists(atPath: output.appendingPathComponent(name).path) else {
                    throw Failure(message: "Output was already used")
                }
            }
            guard !fm.fileExists(atPath: root.path) else { throw Failure(message: "Storage already exists") }
            let fixture = output.appendingPathComponent("fixture")
            guard paths.home == fixture.appendingPathComponent("home").resolvingSymlinksInPath(),
                  paths.executable == fixture.appendingPathComponent("fake-cli").resolvingSymlinksInPath(),
                  let walk = fm.enumerator(at: fixture, includingPropertiesForKeys: [.isSymbolicLinkKey]) else {
                throw Failure(message: "Unexpected fixture layout")
            }
            for case let url as URL in walk {
                guard try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
                    throw Failure(message: "Fixture symlinks are forbidden")
                }
            }
            let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: fixture.appendingPathComponent("manifest.json"))) as? [String: String]
            let executableData = try Data(contentsOf: paths.executable)
            let digest = SHA256.hash(data: executableData).map { String(format: "%02x", $0) }.joined()
            let fixtureHeader = "#!/usr/bin/env python3\n\"\"\"" + fixtureID + ": simulated ACP backend, never a tool executor."
            guard String(data: executableData, encoding: .utf8)?.hasPrefix(fixtureHeader) == true,
                  manifest?["fixture"] == fixtureID, manifest?["sha256"] == digest,
                  manifest?["scenario"] == (budget ? "budget" : "quick"),
                  let token = manifest?["marker"], UUID(uuidString: token) != nil,
                  try fm.contentsOfDirectory(atPath: paths.home.path).sorted() == ["fixture.json"],
                  try Data(contentsOf: paths.home.appendingPathComponent("fixture.json")) == Data(contentsOf: fixture.appendingPathComponent("manifest.json")) else {
                throw Failure(message: "Fixture identity or pristine credential-free home check failed")
            }
            marker = token
            try Data(fixtureID.utf8).write(to: output.appendingPathComponent("started"), options: .withoutOverwriting)
            try fm.createDirectory(at: root.appendingPathComponent("threads"), withIntermediateDirectories: true)
            defaults.removePersistentDomain(forName: CaptureRun.suiteName)
            defaults.set("dsh", forKey: "defaultProvider")
            defaults.set(ProviderKind.allCases.filter { $0 != .dsh }.map(\.rawValue), forKey: "disabledProviders")
            defaults.set(true, forKey: "hydraEnabled")
            defaults.set(true, forKey: "hydraIsolateHeads")
            defaults.set(1, forKey: "hydraMaxHeads")
            for key in ["hydraQueueHeads", "hydraAlwaysHeads", "hydraAutoMerge", "hydraReviewHeads", "notifyWhenFinished", "chimeWhenFinished"] {
                defaults.set(false, forKey: key)
            }
            defaults.set(projectID.uuidString, forKey: "lastProjectID")
            defaults.synchronize()
            let scratch = output.appendingPathComponent("scratch")
            guard fm.fileExists(atPath: scratch.appendingPathComponent(".git").path),
                  scratch.resolvingSymlinksInPath().path.hasPrefix(output.resolvingSymlinksInPath().path + "/") else {
                throw Failure(message: "Runner scratch repository missing")
            }
            guard let scratchFiles = fm.enumerator(at: scratch, includingPropertiesForKeys: [.isSymbolicLinkKey]) else {
                throw Failure(message: "Scratch could not be inspected")
            }
            for case let url as URL in scratchFiles {
                guard try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
                    throw Failure(message: "Scratch symlinks are forbidden")
                }
            }
            var project = Project(name: "Offline Hydra", path: scratch.path)
            project.id = projectID
            var lead = ChatThread(projectID: projectID, provider: .dsh, model: "deepseek-account/v4-flash", effort: nil, runtimeMode: .supervised)
            lead.id = leadID
            lead.hydraEnabled = true
            lead.title = "Offline Hydra probe"
            lead.hasCustomTitle = true
            var library = Library()
            library.projects = [project]
            library.threads = [lead]
            try JSONEncoder.storage.encode(library).write(to: root.appendingPathComponent("library.json"), options: .atomic)
        } catch {
            issue = (error as? Failure)?.message ?? "Fixture preparation failed"
            FileHandle.standardError.write(Data("Offline Hydra preparation rejected: \(issue!)\n".utf8))
            // Do not let AppModel or LibraryAccess initialize an unvalidated destination.
            exit(EXIT_FAILURE)
        }
    }

    static func run(model: AppModel) async {
        guard DshIntegrationConfiguration.isOfflineHydra, let output = CaptureRun.outputDirectory else { return }
        if let issue {
            try? Data(issue.utf8).write(to: output.appendingPathComponent("preparation-error.txt"), options: .withoutOverwriting)
            NSApp.terminate(nil)
            return
        }
        var stage = "preparation"
        var failure: String?
        var passed = false
        var headID: UUID?
        let allowance = budget ? HydraBudget.maxSeconds + HydraBudget.reportSeconds + 120 : 120
        func save() {
            let headStartedAt = headID.flatMap { model.existingRuntime(for: $0)?.turns.first?.startedAt }?.timeIntervalSince1970
            let result: [String: Any] = [
                "backend": "simulated ACP backend", "stage": stage,
                "status": passed ? "passed" : (failure == nil ? "running" : "failed"),
                "failedInvariants": failure.map { [$0] } ?? [],
                "quickCoordinator": budget ? "not-run" : (passed ? "passed" : "not-proven"),
                "budgetScenario": budget ? (passed ? "app-path-completed; runner wire assertions required" : "not-proven") : "not-run",
                "leadID": leadID.uuidString, "headID": headID?.uuidString ?? "",
                "maxSeconds": HydraBudget.maxSeconds, "reportSeconds": HydraBudget.reportSeconds,
                "overallSeconds": allowance,
                "headWorkStartedAt": headStartedAt as Any? ?? NSNull(),
                "uncovered": ["real account", "native tool guard enforcement", "MCP execution", "UI", "binary/source equivalence (operator attestation only)"],
            ]
            if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: output.appendingPathComponent("dsh-hydra.json"), options: .atomic)
            }
        }
        save()
        do {
            if let issue { throw Failure(message: issue) }
            guard DshIntegrationConfiguration.paths != nil, !marker.isEmpty else { throw Failure(message: "Fixture not prepared") }
            stage = "bootstrap"
            save()
            await model.bootstrap()
            let ready = Date.now.addingTimeInterval(20)
            while !model.isLibraryLoaded && Date.now < ready { try await Task.sleep(for: .milliseconds(100)) }
            guard model.isLibraryLoaded, model.thread(leadID)?.provider == .dsh else { throw Failure(message: "Isolated lead missing") }
            await model.providers.refresh(.dsh)
            await model.providers.loadCatalog(.dsh, force: true)
            let lead = model.runtime(for: leadID)
            let loaded = Date.now.addingTimeInterval(20)
            while lead.isLoadingHistory && Date.now < loaded { try await Task.sleep(for: .milliseconds(100)) }
            guard !lead.isLoadingHistory, lead.phase == .idle else { throw Failure(message: "Lead not ready") }
            stage = "coordinator"
            save()
            lead.draft.text = "OFFLINE_LEAD_START"
            lead.send()
            let deadline = Date.now.addingTimeInterval(allowance)
            while Date.now < deadline {
                try Task.checkCancellation()
                let heads = model.threads.filter { $0.isHydraHead }
                guard heads.count <= 1, model.threads.allSatisfy({ $0.provider == .dsh }) else { throw Failure(message: "Unexpected head count or provider") }
                for thread in model.threads {
                    let runtime = model.runtime(for: thread.id)
                    guard runtime.approvals.isEmpty, runtime.questions.isEmpty else { throw Failure(message: "Unexpected interactive request") }
                }
                if let head = heads.first {
                    headID = head.id
                    guard head.parentThreadID == leadID, model.hydraTeam(of: head.id).isEmpty else { throw Failure(message: "Wrong parent or nested delegation") }
                    // Let automatic copy release finish before the fixture terminates the app.
                    if head.hydra?.isFinished == true, head.worktreePath == nil, lead.phase == .idle, lead.turns.count >= 2 {
                        let worker = model.runtime(for: head.id)
                        guard let sid = head.providerSessionID, let leadSID = model.thread(leadID)?.providerSessionID, sid != leadSID,
                              head.hydra?.status == .completed, head.hydra?.summary?.contains(marker) == true,
                              lead.turns.count == 2, lead.turns.allSatisfy({ $0.status == .completed }),
                              worker.turns.count == (budget ? 2 : 1), worker.turns.last?.status == .completed,
                              !budget || worker.turns.first?.status == .interrupted else {
                            throw Failure(message: "Session, report or turn invariant failed")
                        }
                        let answer = lead.entries.compactMap { entry -> String? in
                            if case .assistant(let message) = entry.item.content { return message.text }
                            return nil
                        }.joined()
                        guard answer.contains("OFFLINE_LEAD_RECEIVED_" + marker) else { throw Failure(message: "Lead did not receive marker through report path") }
                        passed = true
                        break
                    }
                }
                try await Task.sleep(for: .milliseconds(250))
            }
            guard passed else { throw Failure(message: "Coordinator deadline exceeded") }
        } catch { failure = (error as? Failure)?.message ?? "Cancelled or runtime failure" }
        stage = "cleanup"
        save()
        for thread in model.threads where thread.id == leadID || thread.parentThreadID == leadID {
            await model.runtime(for: thread.id).stopSessionAndWait(timeout: 5)
        }
        stage = "finished"
        save()
        NSApp.terminate(nil)
    }
}
#endif
