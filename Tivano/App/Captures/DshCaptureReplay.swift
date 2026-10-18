#if DEBUG
import AppKit
import Foundation

@MainActor
enum DshCaptureReplay {
    static var isEnabled: Bool {
        CaptureRun.isEnabled && CommandLine.arguments.contains("--dsh-ui-replay")
    }

    private struct Report: Decodable {
        struct Mode: Decodable {
            let mode: String
            let threadID: UUID
            let status: String
            let completedRequests: Int
            let firstMarkerMatched: Bool
            let memoryMarkerMatched: Bool
        }
        let schemaVersion: Int
        let status: String
        let sendCalls: Int
        let completedRequests: Int
        let modes: [Mode]
    }

    private struct TurnFile: Decodable {
        let revisions: [String: StoredTurn]
    }

    private enum Failure: String, Error {
        case invalidArguments = "invalid-arguments"
        case overlappingPaths = "overlapping-paths"
        case destinationExists = "destination-exists"
        case unsafeSource = "unsafe-source-path"
        case incompleteReport = "incomplete-report"
        case missingHistory = "missing-or-invalid-history"
        case nonSyntheticHistory = "non-synthetic-history"
        case preparationFailed = "preparation-failed"
        case libraryUnavailable = "library-unavailable"
        case historyUnavailable = "history-unavailable"
        case locked = "session-locked"
        case sessionUnknown = "session-state-unavailable"
        case windowInvisible = "window-not-visible"
        case notForeground = "not-foreground"
        case screenshotMissing = "screenshot-missing-or-invalid"
    }

    private static let modes = ["standard", "ptc", "minimal", "creator"]
    private static var rows: [Report.Mode] = []
    private static var output: URL?

    static func prepare() {
        do {
            let args = CommandLine.arguments
            guard let index = args.firstIndex(of: "--dsh-ui-replay"),
                  args.indices.contains(index + 1), !args[index + 1].hasPrefix("--"),
                  !args.contains("--dsh-integration-probe"),
                  let destination = CaptureRun.outputDirectory else { throw Failure.invalidArguments }
            let source = URL(fileURLWithPath: args[index + 1], isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
            let target = destination.standardizedFileURL.resolvingSymlinksInPath()
            guard !contains(source, target), !contains(target, source) else { throw Failure.overlappingPaths }
            // Reserve a new output, not just new storage: stale PNGs must never count as evidence.
            guard !FileManager.default.fileExists(atPath: target.path),
                  (try? destination.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink != true
            else { throw Failure.destinationExists }
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            output = target

            let report: Report
            do {
                report = try JSONDecoder().decode(Report.self, from: sourceData("dsh-integration.json", root: source))
            } catch let failure as Failure { throw failure }
            catch { throw Failure.incompleteReport }
            guard report.schemaVersion == 1, report.status == "completed", report.sendCalls == 8,
                  report.completedRequests == 8, report.modes.count == 4,
                  Set(report.modes.map(\.mode)) == Set(modes),
                  Set(report.modes.map(\.threadID)).count == 4,
                  report.modes.allSatisfy({ $0.status == "completed" && $0.completedRequests == 2 && $0.firstMarkerMatched && $0.memoryMarkerMatched })
            else { throw Failure.incompleteReport }
            rows = modes.compactMap { mode in report.modes.first { $0.mode == mode } }
            let original = try JSONDecoder.storage.decode(Library.self, from: sourceData("storage/library.json", root: source))
            let root = target.appendingPathComponent("storage", isDirectory: true)
            let work = root.appendingPathComponent("replay-work", isDirectory: true)
            var project = Project(name: "DSH integration replay", path: work.path)
            var library = Library()
            var documents: [ThreadDocument] = []
            for row in rows {
                let matches = original.threads.filter { $0.id == row.threadID }
                guard matches.count == 1, let thread = matches.first,
                      thread.provider == .dsh, thread.dshMode?.rawValue == row.mode,
                      thread.title == "DSH probe: \(row.mode)",
                      original.projects.contains(where: { $0.id == thread.projectID && $0.name == "DSH integration probe" })
                else { throw Failure.missingHistory }
                if documents.isEmpty { project.id = thread.projectID }
                let document = try loadDocument(row.threadID, source: source)
                try validateSynthetic(document)
                documents.append(document)
                // Keep display metadata, but never retain source working paths, session handles or automation.
                var replay = ChatThread(projectID: project.id, provider: .dsh, model: thread.model, effort: thread.effort, runtimeMode: thread.runtimeMode)
                replay.id = thread.id
                replay.title = thread.title
                replay.hasCustomTitle = true
                replay.createdAt = thread.createdAt
                replay.updatedAt = thread.updatedAt
                replay.dshMode = thread.dshMode
                replay.hydraEnabled = false
                replay.lastStatus = .completed
                library.threads.append(replay)
            }
            library.projects = [project]
            try FileManager.default.createDirectory(at: root.appendingPathComponent("threads"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            for document in documents {
                try JSONEncoder.storage.encode(document).write(to: root.appendingPathComponent("threads/\(document.threadID.uuidString).json"), options: .atomic)
            }
            try JSONEncoder.storage.encode(library).write(to: root.appendingPathComponent("library.json"), options: .atomic)
            guard let defaults = CaptureRun.defaults else { throw Failure.preparationFailed }
            defaults.removePersistentDomain(forName: CaptureRun.suiteName)
            defaults.set("dsh", forKey: "defaultProvider")
            defaults.set("supervised", forKey: "defaultRuntimeMode")
            defaults.set(project.id.uuidString, forKey: "lastProjectID")
            for key in ["hydraEnabled", "hydraQueueHeads", "hydraAlwaysHeads", "notifyWhenFinished", "chimeWhenFinished"] {
                defaults.set(false, forKey: key)
            }
            defaults.synchronize()
            try save(status: "blocked", reason: "capture-not-started", captures: [])
        } catch {
            let reason = (error as? Failure)?.rawValue ?? Failure.preparationFailed.rawValue
            try? save(status: "blocked", reason: reason, captures: [])
            FileHandle.standardError.write(Data("DSH UI replay blocked: \(reason)\n".utf8))
            // Fail before LibraryAccess or AppModel can touch an unvalidated destination.
            exit(EXIT_FAILURE)
        }
    }

    private static func contains(_ parent: URL, _ child: URL) -> Bool {
        parent.path == child.path || child.path.hasPrefix(parent.path.hasSuffix("/") ? parent.path : parent.path + "/")
    }

    private static func sourceData(_ relative: String, root: URL) throws -> Data {
        let file = root.appendingPathComponent(relative).standardizedFileURL
        guard contains(root, file), file.resolvingSymlinksInPath() == file else { throw Failure.unsafeSource }
        guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true, values.isSymbolicLink != true else { throw Failure.missingHistory }
        return try Data(contentsOf: file)
    }

    private static func loadDocument(_ id: UUID, source: URL) throws -> ThreadDocument {
        do {
            var document = try JSONDecoder.storage.decode(ThreadDocument.self, from: sourceData("storage/threads/\(id.uuidString).json", root: source))
            guard document.threadID == id else { throw Failure.missingHistory }
            var storedTurns: [TurnRecord] = []
            var storedItems: [TimelineItem] = []
            for reference in document.turnIndex ?? [] {
                let file = try JSONDecoder.storage.decode(TurnFile.self, from: sourceData("storage/threads/\(id.uuidString).turns/\(reference.id.uuidString).json", root: source))
                guard let stored = file.revisions[String(reference.revision)], stored.turn.id == reference.id else { throw Failure.missingHistory }
                storedTurns.append(stored.turn)
                storedItems += stored.items
                document.itemPositions = (document.itemPositions ?? [:]).merging(stored.itemPositions) { _, new in new }
            }
            document.turns = storedTurns + document.turns
            document.items = storedItems + document.items
            if document.turnIndex != nil {
                let positions = document.itemPositions ?? [:]
                document.items.sort { (positions[$0.id] ?? 0) < (positions[$1.id] ?? 0) }
            }
            // Flatten only the referenced revisions into the supported legacy format.
            document.turnIndex = nil
            return document
        } catch let failure as Failure { throw failure }
        catch { throw Failure.missingHistory }
    }

    private static func validateSynthetic(_ document: ThreadDocument) throws {
        guard document.turns.count == 2, Set(document.turns.map(\.id)).count == 2,
              document.turns.allSatisfy({ $0.status == .completed }),
              document.followUps.isEmpty, document.continuation == nil, document.hydraMerges.isEmpty
        else { throw Failure.nonSyntheticHistory }
        let users = document.items.compactMap { item -> UserMessage? in
            if case .user(let message) = item.content { return message }
            return nil
        }
        let prefix = "Do not use tools. Remember exactly "
        let suffix = ". Reply only with this marker."
        guard users.count == 2, users.allSatisfy({ $0.attachments.isEmpty && !$0.isFromHydra }),
              users[0].text.hasPrefix(prefix), users[0].text.hasSuffix(suffix),
              users[1].text == "Do not use tools. Reply only with the exact marker I asked you to remember."
        else { throw Failure.nonSyntheticHistory }
        let marker = String(users[0].text.dropFirst(prefix.count).dropLast(suffix.count))
        guard marker.hasPrefix("DSH_TEST_"), marker.count == 41,
              marker.dropFirst(9).allSatisfy({ "0123456789abcdef".contains($0) }),
              !document.items.contains(where: { if case .tool = $0.content { return true }; return false })
        else { throw Failure.nonSyntheticHistory }
        for turn in document.turns {
            let items = document.items.filter { $0.turnID == turn.id }
            guard items.filter({ if case .user = $0.content { return true }; return false }).count == 1,
                  items.compactMap({ item -> String? in
                      if case .assistant(let message) = item.content, !message.isStreaming { return message.text }
                      return nil
                  }).joined().contains(marker)
            else { throw Failure.nonSyntheticHistory }
        }
    }

    static func run(model: AppModel) async {
        guard let output else { return }
        var captures: [[String: Any]] = []
        var failure: Failure?
        await model.bootstrap()
        if !model.isLibraryLoaded || !rows.allSatisfy({ model.thread($0.threadID) != nil }) {
            failure = .libraryUnavailable
        } else {
            let stage = Stage(model: model)
            stage.show(size: Stage.wide)
            let recorder = Recorder(output: output, stage: stage)
            for row in rows {
                model.openThread(row.threadID)
                let runtime = model.runtime(for: row.threadID)
                let deadline = Date.now.addingTimeInterval(20)
                while runtime.isLoadingHistory && Date.now < deadline {
                    try? await Task.sleep(for: .milliseconds(50))
                }
                var issue: Failure? = runtime.isLoadingHistory || runtime.turns.count != 2 ? .historyUnavailable : nil
                await stage.ensureActive()
                try? await Task.sleep(for: .milliseconds(700))
                issue = issue ?? visibilityFailure(stage)
                let name = "dsh-replay-\(row.mode)"
                if issue == nil { await recorder.still(name, stage.captureRect, activate: false) }
                issue = issue ?? visibilityFailure(stage)
                let imageURL = output.appendingPathComponent(name + ".png")
                let exists = FileManager.default.fileExists(atPath: imageURL.path)
                let image = NSImage(contentsOf: imageURL)
                if issue == nil && (!exists || image == nil) { issue = .screenshotMissing }
                let frame = stage.windowFrame ?? .zero
                captures.append([
                    "mode": row.mode, "sourceThreadID": row.threadID.uuidString,
                    "status": issue == nil ? "captured" : "blocked",
                    "reason": issue?.rawValue ?? "pending-visual-inspection",
                    "screenshot": name + ".png", "screenshotExists": exists,
                    "windowFrame": [frame.minX, frame.minY, frame.width, frame.height],
                    "backingScaleFactor": stage.contentWindow?.backingScaleFactor ?? 0,
                    "contentZoom": 1, "contentZoomNote": "No app zoom; fresh capture defaults",
                    "appActive": NSApp.isActive, "windowKey": stage.contentWindow?.isKeyWindow ?? false,
                    "windowVisible": stage.contentWindow?.isVisible ?? false,
                    "windowOcclusionVisible": stage.contentWindow?.occlusionState.contains(.visible) ?? false
                ])
                failure = failure ?? issue
                try? save(status: "blocked", reason: "capture-in-progress", captures: captures)
            }
        }
        do {
            try save(status: failure == nil ? "captured" : "blocked", reason: failure?.rawValue ?? "pending-visual-inspection", captures: captures)
        } catch {
            FileHandle.standardError.write(Data("DSH UI replay blocked: report-write-failed\n".utf8))
        }
        NSApp.terminate(nil)
    }

    private static func visibilityFailure(_ stage: Stage) -> Failure? {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return .sessionUnknown }
        if session["CGSSessionScreenIsLocked"] as? Bool == true { return .locked }
        guard session[kCGSessionOnConsoleKey as String] as? Bool == true else { return .sessionUnknown }
        guard let window = stage.contentWindow, window.isVisible, !window.isMiniaturized,
              window.occlusionState.contains(.visible), window.screen != nil,
              window.frame.width > 0, window.frame.height > 0 else { return .windowInvisible }
        guard NSApp.isActive, window.isKeyWindow else { return .notForeground }
        return nil
    }

    private static func save(status: String, reason: String, captures: [[String: Any]]) throws {
        guard let output else { return }
        let report: [String: Any] = [
            "schemaVersion": 1, "status": status, "reason": reason,
            "sourceThreadIDs": rows.map { $0.threadID.uuidString }, "captures": captures,
            "sendCalls": 0, "providerPolicy": "history-only; warmup and session creation disabled",
            "visualReview": "unverified", "performance": "unverified"
        ]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("dsh-ui-replay.json"), options: .atomic)
    }
}
#endif
