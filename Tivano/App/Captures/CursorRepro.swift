#if DEBUG
import AppKit
import CoreGraphics
import Darwin
import Foundation
import QuartzCore

/// External-HID repro for an I-beam left behind by a streaming, hidden chat column.
///
///     open -n -W "Tivano.app" --args --website-captures <folder> --cursor-repro
///
/// All replies are rehearsed in the isolated capture library; no provider session starts.
@MainActor
enum CursorRepro {
    nonisolated private static let budgetSeconds: TimeInterval = 240
    private static let windowSize = NSSize(width: 1320, height: 860)
    private static let projectAName = "Cursor repro primary"
    private static let projectBName = "Cursor repro secondary"
    private static let threadATitle = "Cursor repro streaming"
    private static let threadBTitle = "Cursor repro empty"
    private static let otherThreadTitles = [
        "Cursor repro notes",
        "Cursor repro layout",
        "Cursor repro review",
    ]
    private static let lastReplyMarker = "Cursor glyph target stays on this line"
    private static let streamID = "cursor-repro-stream"

    private static var deadline = Date.now
    private static var loggedSidebarEntries = false
    private static var report = Report()
    private static var trace: TraceLog?
    private static var streamTask: Task<Void, Never>?
    private static var streamingRuntime: ThreadRuntime?
    private static var lastSelectedThreadID: UUID?

    private struct Point: Codable, Sendable {
        let x: Double
        let y: Double
    }

    private struct Rect: Codable, Sendable {
        let x: Double
        let y: Double
        let width: Double
        let height: Double
    }

    private struct Ready: Encodable, Sendable {
        let pid: Int32
        let windowNumber: Int
        let windowFrame: Rect
        let textPoint: Point
        let sidebarRowB: Point
        let sidebarRows: [Point]
        let projectHeaders: [Point]
        let emptyChatPoints: [Point]
        let composerPoint: Point
        let readyAt: Double
        let readyAtWallClock: Double
        let threadA: String
        let threadB: String
        let coordinateSpace: String
        /// SwiftUI builds its accessibility tree only for an outside client, so when the app
        /// cannot place the sidebar rows itself the driver finds them by these titles.
        let rowsResolved: Bool
        let sidebarRowBTitle: String
        let sidebarRowTitles: [String]
        let projectHeaderTitles: [String]
    }

    private struct Report: Encodable {
        var startedAt = ISO8601DateFormatter().string(from: .now)
        var budgetSeconds = 240
        var status = "running"
        var blockedReason: String?
        var threadA: String?
        var threadB: String?
        var sidebarRows: [String] = []
        var projectHeaders: [String] = []
        var acceptsMouseMovedEvents: Bool?
        var readyFiles: [String] = []
        var notes: [[String: String]] = []
        var files: [String]?
    }

    private struct HarnessError: Error, LocalizedError, CustomStringConvertible {
        let description: String
        var errorDescription: String? { description }
    }

    private struct TraceRecord: Encodable {
        let t: Double
        let event: String
        let windowNumber: Int?
        let location: Point?
        let hitChain: [String]
        let selectedThreadID: String?
        let cursor: String?
        let from: String?
        let to: String?
        let source: String?
    }

    @MainActor
    private final class TraceLog {
        private let handle: FileHandle?
        private let encoder = JSONEncoder()

        init(url: URL) {
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            handle = try? FileHandle(forWritingTo: url)
        }

        func input(_ event: NSEvent, model: AppModel) {
            let eventWindow = event.window
            var chain: [String] = []
            if let content = eventWindow?.contentView {
                var view = content.hitTest(event.locationInWindow)
                while let current = view, chain.count < 4 {
                    chain.append(String(describing: type(of: current)))
                    view = current.superview
                }
            }
            append(TraceRecord(
                t: CACurrentMediaTime(),
                event: event.type.traceName,
                windowNumber: eventWindow?.windowNumber ?? event.windowNumber,
                location: Point(x: Double(event.locationInWindow.x), y: Double(event.locationInWindow.y)),
                hitChain: chain,
                selectedThreadID: model.selectedThreadID?.uuidString,
                cursor: Self.classify(NSCursor.current),
                from: nil,
                to: nil,
                source: nil
            ))
        }

        func threadSwitch(from: UUID?, to: UUID?, source: String) {
            append(TraceRecord(
                t: CACurrentMediaTime(),
                event: "thread-switch",
                windowNumber: nil,
                location: nil,
                hitChain: [],
                selectedThreadID: to?.uuidString,
                cursor: Self.classify(NSCursor.current),
                from: from?.uuidString,
                to: to?.uuidString,
                source: source
            ))
        }

        private func append(_ record: TraceRecord) {
            guard var data = try? encoder.encode(record) else { return }
            data.append(0x0A)
            try? handle?.write(contentsOf: data)
        }

        private static func classify(_ cursor: NSCursor) -> String {
            if cursor === NSCursor.iBeam { return "ibeam" }
            if cursor === NSCursor.arrow { return "arrow" }
            if cursor === NSCursor.pointingHand { return "hand" }
            if matches(cursor, NSCursor.iBeam) { return "ibeam" }
            if matches(cursor, NSCursor.arrow) { return "arrow" }
            if matches(cursor, NSCursor.pointingHand) { return "hand" }
            return "other"
        }

        private static func matches(_ cursor: NSCursor, _ reference: NSCursor) -> Bool {
            guard let expected = reference.image.tiffRepresentation,
                  let actual = cursor.image.tiffRepresentation else { return false }
            return cursor.hotSpot == reference.hotSpot && actual == expected
        }
    }

    static func run(model: AppModel) async {
        guard CaptureRun.isEnabled, let output = CaptureRun.outputDirectory else { return }
        report = Report()
        trace = nil
        streamTask = nil
        streamingRuntime = nil
        deadline = Date.now.addingTimeInterval(budgetSeconds)
        saveReport(to: output)
        await model.bootstrap()
        guard model.isLibraryLoaded,
              let projectA: Project = model.projects.first(where: { (project: Project) -> Bool in project.name == projectAName }),
              let projectB: Project = model.projects.first(where: { (project: Project) -> Bool in project.name == projectBName }),
              let threadA: ChatThread = model.threads.first(where: { (thread: ChatThread) -> Bool in thread.title == threadATitle }),
              let threadB: ChatThread = model.threads.first(where: { (thread: ChatThread) -> Bool in thread.title == threadBTitle })
        else {
            blocked("cursor capture library or seeded rows failed to load", output: output)
        }
        let otherThreads: [ChatThread] = otherThreadTitles.compactMap { (title: String) -> ChatThread? in
            model.threads.first(where: { (thread: ChatThread) -> Bool in thread.title == title })
        }
        guard otherThreads.count == otherThreadTitles.count else {
            blocked("one or more sidebar thread fixtures are missing", output: output)
        }
        report.threadA = threadA.id.uuidString
        report.threadB = threadB.id.uuidString
        report.sidebarRows = otherThreads.map(\.id.uuidString)
        report.projectHeaders = [projectA.id.uuidString, projectB.id.uuidString]
        model.settings.hasSeenHydraIntro = true
        model.settings.hydraEnabled = false
        model.settings.sidebarActivityView = false
        model.updateProject(projectA.id) { (project: inout Project) in project.isExpanded = true }
        model.updateProject(projectB.id) { (project: inout Project) in project.isExpanded = true }

        guard await seedFinishedThreads(model: model, threadA: threadA, otherThreads: otherThreads) else {
            blocked("a rehearsed finished turn did not complete", output: output)
        }

        WindowManager.shared.showMain()
        guard let window: NSWindow = appWindow() else {
            blocked("production main window unavailable", output: output)
        }
        window.setContentSize(windowSize)
        window.center()
        window.makeKeyAndOrderFront(nil)
        await ensureActive(window)
        guard NSApp.isActive, window.isKeyWindow else {
            blocked("foreground desktop or production main window unavailable; unlock the host before running", output: output)
        }
        if !model.sidebar.isVisible {
            model.sidebar.toggle()
            try? await Task.sleep(for: .milliseconds(500))
        }
        report.acceptsMouseMovedEvents = window.acceptsMouseMovedEvents
        let traceLog: TraceLog = TraceLog(url: output.appendingPathComponent("cursor-trace.jsonl"))
        trace = traceLog
        let monitor: Any? = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .leftMouseUp]) { (event: NSEvent) -> NSEvent? in
            traceLog.input(event, model: model)
            return event
        }
        defer {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }

        select(threadA.id, model: model, source: "initial")
        guard await pinAtBottom(window: window) else {
            blocked("thread A did not lay out pinned at the bottom", output: output)
        }

        let runtime: ThreadRuntime = model.runtime(for: threadA.id)
        streamingRuntime = runtime
        let prompt: String = "Continue the plain-prose reply while the cursor moves between chats."
        runtime.rehearseTurn(prompt)
        note("stream-start", "thread=\(threadA.id.uuidString) running=\(runtime.isRunning) intervalMs=150 loop=true")
        let pieces: [String] = streamPieces()
        streamTask = Task { @MainActor in
            var index: Int = 0
            while !Task.isCancelled, Date.now < deadline {
                let piece: String = pieces[index % pieces.count]
                runtime.rehearse(.messageDelta(id: streamID, text: piece))
                index += 1
                try? await Task.sleep(for: .milliseconds(150))
            }
        }

        do {
            let ready = try await resolveReady(
                window: window,
                model: model,
                threadA: threadA.id,
                threadB: threadB.id,
                otherThreads: otherThreads.map(\.id),
                projects: [projectA.id, projectB.id]
            )
            try write(ready, named: "cursor-repro-ready.json", output: output)
            report.readyFiles.append("cursor-repro-ready.json")
            note("ready", "cursor-repro-ready.json; all points use CG global top-left coordinates")
            saveReport(to: output)
        } catch {
            blocked("could not resolve ready points: \(error.localizedDescription)", output: output)
        }

        while Date.now < deadline {
            if FileManager.default.fileExists(atPath: output.appendingPathComponent("cursor-repro-done").path) {
                note("done", "driver requested completion")
                stopStreaming()
                let finishDeadline = Date.now.addingTimeInterval(5)
                while runtime.isRunning, Date.now < finishDeadline {
                    try? await Task.sleep(for: .milliseconds(40))
                }
                report.status = runtime.isRunning ? "completed-stream-still-running" : "completed"
                saveReport(to: output, listFiles: true)
                exit(0)
            }

            observeSelection(model: model, source: "event")

            if FileManager.default.fileExists(atPath: output.appendingPathComponent("reset").path) {
                try? FileManager.default.removeItem(at: output.appendingPathComponent("reset"))
                select(threadA.id, model: model, source: "reset")
                do {
                    let ready = try await resolveReady(
                        window: window,
                        model: model,
                        threadA: threadA.id,
                        threadB: threadB.id,
                        otherThreads: otherThreads.map(\.id),
                        projects: [projectA.id, projectB.id]
                    )
                    guard runtime.isRunning else {
                        throw HarnessError(description: "thread A stopped streaming before ready2")
                    }
                    try write(ready, named: "cursor-repro-ready2.json", output: output)
                    report.readyFiles.append("cursor-repro-ready2.json")
                    note("ready2", "thread A shown and streaming; fresh points written")
                    saveReport(to: output)
                } catch {
                    blocked("reset could not resolve ready2: \(error.localizedDescription)", output: output)
                }
            }

            if FileManager.default.fileExists(atPath: output.appendingPathComponent("switch-programmatic").path) {
                try? FileManager.default.removeItem(at: output.appendingPathComponent("switch-programmatic"))
                select(threadB.id, model: model, source: "switch-programmatic")
            }

            try? await Task.sleep(for: .milliseconds(50))
        }
        blocked("exceeded 120s overall timeout", output: output)
    }

    private static func seedFinishedThreads(model: AppModel, threadA: ChatThread, otherThreads: [ChatThread]) async -> Bool {
        let runtimeA = model.runtime(for: threadA.id)
        await runtimeA.ensureLoaded()
        for (index, answer) in finishedReplies.enumerated() {
            guard await finishTurn(runtime: runtimeA, id: "cursor-seed-a-\(index)", user: "Give me a clear project update for section \(index + 1).", answer: answer) else {
                return false
            }
        }
        for (index, thread) in otherThreads.enumerated() {
            let runtime = model.runtime(for: thread.id)
            await runtime.ensureLoaded()
            guard await finishTurn(
                runtime: runtime,
                id: "cursor-seed-short-\(index)",
                user: "Summarize the small follow-up.",
                answer: "The short review is complete. The wording is plain, the spacing is settled, and the follow-up is recorded."
            ) else { return false }
        }
        let secondaryThreads = model.threads.filter { $0.projectID.map({ model.project($0)?.name == projectBName }) == true }
        for (index, thread) in secondaryThreads.enumerated() {
            let runtime = model.runtime(for: thread.id)
            await runtime.ensureLoaded()
            guard await finishTurn(
                runtime: runtime,
                id: "cursor-seed-secondary-\(index)",
                user: "Leave a brief status note.",
                answer: "The secondary project has a complete note and no work is still running."
            ) else { return false }
        }
        return true
    }

    private static func finishTurn(runtime: ThreadRuntime, id: String, user: String, answer: String) async -> Bool {
        runtime.rehearseTurn(user)
        runtime.rehearse(.messageDelta(id: id, text: answer))
        runtime.rehearse(.messageCompleted(id: id, text: ""))
        runtime.rehearse(.turnCompleted(status: .completed, error: nil))
        let finishDeadline = Date.now.addingTimeInterval(8)
        while runtime.isRunning, Date.now < finishDeadline {
            try? await Task.sleep(for: .milliseconds(40))
        }
        return !runtime.isRunning
    }

    private static let finishedReplies = [
        """
        The first review found a small spacing issue near the reply card. The text remains readable while the window changes size, and the controls keep their usual order.

        We compared the behavior with the [layout notes](https://example.com/cursor/layout) and kept the simplest arrangement. No provider work or repository changes are needed for this fixture.

        The paragraph wraps into several ordinary lines so the hover path visits real glyphs rather than an empty part of the view.
        """,
        """
        The second pass checked the sidebar and the conversation together. Selecting another chat leaves the current runtime alive, while the visible controls still respond in the usual way.

        A short link to the [interaction checklist](https://example.com/cursor/interaction) keeps the Markdown path represented without making the reply depend on it.

        This closing paragraph adds enough settled prose to make the later glyph measurement stable.
        """,
        """
        The third reply is deliberately plain. It has several sentences, a calm cadence, and no code blocks or tool results that could distract from the pointer measurement.

        The [capture notes](https://example.com/cursor/capture) describe the same screen-coordinate convention used by the external driver.

        A final line keeps this finished turn visibly separate from the next one.
        """,
        """
        The fourth reply is the hover target for this run. Its first paragraph stays close to the bottom of the finished history while the next turn starts below it.

        The text mentions the [cursor reference](https://example.com/cursor/reference) but this sentence remains ordinary prose, so the expected pointer is the I-beam rather than the hand.

        \(lastReplyMarker) while the surrounding words wrap naturally across the available chat width. This last paragraph gives the layout manager a clear used line fragment to measure.
        """,
    ]

    private static func streamPieces() -> [String] {
        (1...24).map { index in
            let paragraphBreak = index.isMultiple(of: 4) ? "\n\n" : " "
            return "Streaming passage \(index) adds more plain prose to the running reply while the hidden column stays mounted and its finished paragraphs remain available for layout. The sentence keeps moving without starting any provider work.\(paragraphBreak)"
        }
    }

    private static func ensureActive(_ window: NSWindow) async {
        for _ in 0..<24 {
            if NSApp.isActive, window.isKeyWindow { break }
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            try? await Task.sleep(for: .milliseconds(250))
        }
        try? await Task.sleep(for: .milliseconds(450))
    }

    private static func appWindow() -> NSWindow? {
        NSApp.windows
            .filter { $0.styleMask.contains(.titled) && $0.isVisible }
            .first(where: { $0.title == AppInfo.name })
    }

    private static func pinAtBottom(window: NSWindow) async -> Bool {
        let settleDeadline = Date.now.addingTimeInterval(8)
        var stableChecks = 0
        while Date.now < settleDeadline {
            window.contentView?.layoutSubtreeIfNeeded()
            if let scroll = timelineScroll(in: window), let document = scroll.documentView {
                let clip = scroll.contentView
                let bottom = NSRect(
                    x: clip.bounds.minX,
                    y: max(0, document.bounds.height - clip.bounds.height),
                    width: clip.bounds.width,
                    height: clip.bounds.height
                )
                clip.scroll(to: clip.constrainBoundsRect(bottom).origin)
                scroll.reflectScrolledClipView(clip)
                let gap = document.bounds.height - scroll.documentVisibleRect.maxY
                if gap <= 4 {
                    stableChecks += 1
                    if stableChecks >= 3 { return true }
                } else {
                    stableChecks = 0
                }
            } else {
                stableChecks = 0
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    private static func timelineScroll(in window: NSWindow) -> NSScrollView? {
        findAll(NSScrollView.self, in: window.contentView)
            .filter {
                !$0.isHiddenOrHasHiddenAncestor
                    && $0.enclosingScrollView == nil
                    && !($0.documentView is ComposerNSTextView)
                    && $0.bounds.height > 120
                    && $0.bounds.width > 200
            }
            .max { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }
    }

    private static func resolveReady(
        window: NSWindow,
        model: AppModel,
        threadA: UUID,
        threadB: UUID,
        otherThreads: [UUID],
        projects: [UUID]
    ) async throws -> Ready {
        var lastError = "view hierarchy is not laid out"
        let resolveDeadline = Date.now.addingTimeInterval(8)
        while Date.now < resolveDeadline {
            window.contentView?.layoutSubtreeIfNeeded()
            do {
                return try resolveReadyNow(
                    window: window,
                    model: model,
                    threadA: threadA,
                    threadB: threadB,
                    otherThreads: otherThreads,
                    projects: projects
                )
            } catch {
                lastError = error.localizedDescription
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        throw HarnessError(description: lastError)
    }

    private static func resolveReadyNow(
        window: NSWindow,
        model: AppModel,
        threadA: UUID,
        threadB: UUID,
        otherThreads: [UUID],
        projects: [UUID]
    ) throws -> Ready {
        guard model.selectedThreadID == threadA else {
            throw HarnessError(description: "thread A is not selected")
        }
        guard model.runtime(for: threadA).isRunning else {
            throw HarnessError(description: "thread A is not streaming")
        }
        guard let scroll = timelineScroll(in: window) else {
            throw HarnessError(description: "visible chat timeline scroll view not found")
        }
        let textPoint = try renderedTextPoint(in: window)
        let accessibility = accessibilityEntries(in: window)
        let threadBTitle = try require(model.thread(threadB)?.title, "thread B title missing")
        let otherTitles = try otherThreads.map { id in
            try require(model.thread(id)?.title, "sidebar thread title missing for \(id.uuidString)")
        }
        let projectNames = try projects.map { id in
            try require(model.project(id)?.name, "project title missing for \(id.uuidString)")
        }
        var rowB = NSRect.zero
        var otherRows: [NSRect] = []
        var headers: [NSRect] = []
        var rowsResolved = true
        do {
            rowB = try rowFrame(title: threadBTitle, entries: accessibility, window: window)
            otherRows = try otherTitles.map { try rowFrame(title: $0, entries: accessibility, window: window) }
            headers = try projectNames.map { try projectTitleFrame(name: $0, entries: accessibility, window: window) }
        } catch {
            rowsResolved = false
            otherRows = []
            headers = []
            note("rows-unresolved", "\(error.localizedDescription); the driver resolves them through the system accessibility API")
        }
        guard let composer = findAll(ComposerNSTextView.self, in: window.contentView)
            .filter({ !$0.isHiddenOrHasHiddenAncestor && $0.bounds.width > 20 && $0.bounds.height > 10 })
            .max(by: { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height })
        else {
            throw HarnessError(description: "visible composer text view not found")
        }

        let chatRect = scroll.convert(scroll.bounds, to: nil)
        let usable = NSRect(
            x: chatRect.minX + 36,
            y: chatRect.minY + 30,
            width: chatRect.width - 72,
            height: chatRect.height - 126
        )
        guard usable.width > 240, usable.height > 180 else {
            throw HarnessError(description: "chat pane is too small for six empty-chat points")
        }
        var emptyPoints: [Point] = []
        for y in [0.28, 0.76] as [CGFloat] {
            for x in [0.18, 0.5, 0.82] as [CGFloat] {
                let windowPoint = NSPoint(x: usable.minX + usable.width * x, y: usable.minY + usable.height * y)
                emptyPoints.append(cgPoint(windowPoint, window: window))
            }
        }
        let frame = window.frame
        return Ready(
            pid: getpid(),
            windowNumber: window.windowNumber,
            windowFrame: Rect(
                x: Double(frame.minX),
                y: Double(CGDisplayBounds(CGMainDisplayID()).height - frame.maxY),
                width: Double(frame.width),
                height: Double(frame.height)
            ),
            textPoint: textPoint,
            sidebarRowB: cgPoint(NSPoint(x: rowB.midX, y: rowB.midY)),
            sidebarRows: otherRows.map { cgPoint(NSPoint(x: $0.midX, y: $0.midY)) },
            projectHeaders: headers.map { cgPoint(NSPoint(x: $0.midX, y: $0.midY)) },
            emptyChatPoints: emptyPoints,
            composerPoint: cgPoint(composer.convert(composer.bounds.center, to: nil), window: window),
            readyAt: CACurrentMediaTime(),
            readyAtWallClock: Date.now.timeIntervalSince1970,
            threadA: threadA.uuidString,
            threadB: threadB.uuidString,
            coordinateSpace: "CG global top-left; y = CGMainDisplayID height - AppKit screen y",
            rowsResolved: rowsResolved,
            sidebarRowBTitle: threadBTitle,
            sidebarRowTitles: otherTitles,
            projectHeaderTitles: projectNames
        )
    }

    private static func renderedTextPoint(in window: NSWindow) throws -> Point {
        let views = findAll(LinkTextView.self, in: window.contentView).filter {
            !$0.isHiddenOrHasHiddenAncestor
                && $0.window === window
                && ($0.textStorage?.string ?? $0.string).contains(lastReplyMarker)
                && $0.bounds.width > 20
                && $0.bounds.height > 8
        }
        for view in views {
            guard let layoutManager = view.layoutManager,
                  let textContainer = view.textContainer,
                  view.textStorage != nil else { continue }
            layoutManager.ensureLayout(for: textContainer)
            let markerRange = (view.string as NSString).range(of: lastReplyMarker)
            guard markerRange.location != NSNotFound else { continue }
            let glyphs = layoutManager.glyphRange(forCharacterRange: markerRange, actualCharacterRange: nil)
            // The pinned thread keeps streaming, so the finished reply may have scrolled
            // away by the time ready2 is resolved; bring its first marker line back.
            var firstLine: NSRect?
            layoutManager.enumerateLineFragments(forGlyphRange: glyphs) { _, usedRect, _, _, stop in
                if usedRect.width > 8, usedRect.height > 4 { firstLine = usedRect; stop.pointee = true }
            }
            if let firstLine, !view.visibleRect.contains(firstLine) {
                view.scrollToVisible(firstLine.insetBy(dx: 0, dy: -40))
                view.window?.displayIfNeeded()
            }
            var lines: [NSRect] = []
            layoutManager.enumerateLineFragments(forGlyphRange: glyphs) { _, usedRect, _, _, _ in
                if usedRect.width > 8, usedRect.height > 4, view.visibleRect.intersects(usedRect) {
                    lines.append(usedRect)
                }
            }
            for line in lines {
                let local = NSPoint(x: line.midX, y: line.midY)
                guard view.isOverText(at: local) else { continue }
                let windowRect = view.convert(line, to: nil)
                guard let content = window.contentView else { continue }
                let contentBounds = content.convert(content.bounds, to: nil)
                guard contentBounds.intersects(windowRect) else { continue }
                return cgPoint(NSPoint(x: windowRect.midX, y: windowRect.midY), window: window)
            }
        }
        // The streaming reply can push the marked reply out of the mounted window; any visible
        // line of reply text in the shown column exercises the same hover path.
        let fallback = findAll(LinkTextView.self, in: window.contentView).filter {
            !$0.isHiddenOrHasHiddenAncestor && $0.window === window && $0.isSelectable
                && $0.bounds.width > 20 && $0.bounds.height > 8
        }
        for view in fallback {
            guard let layoutManager = view.layoutManager, let textContainer = view.textContainer,
                  (view.textStorage?.length ?? 0) > 0 else { continue }
            layoutManager.ensureLayout(for: textContainer)
            var found: NSRect?
            let all = layoutManager.glyphRange(for: textContainer)
            layoutManager.enumerateLineFragments(forGlyphRange: all) { _, usedRect, _, _, stop in
                if usedRect.width > 60, usedRect.height > 4, view.visibleRect.insetBy(dx: 0, dy: 10).contains(usedRect),
                   view.isOverText(at: NSPoint(x: usedRect.minX + 30, y: usedRect.midY)) {
                    found = usedRect; stop.pointee = true
                }
            }
            guard let line = found, let content = window.contentView else { continue }
            let windowRect = view.convert(line, to: nil)
            guard content.convert(content.bounds, to: nil).intersects(windowRect) else { continue }
            WebsiteCaptures.log("cursor-repro text-point: marker line not visible; using a visible reply line")
            return cgPoint(NSPoint(x: windowRect.minX + 30, y: windowRect.midY), window: window)
        }
        throw HarnessError(description: "no visible rendered glyph line of reply text in thread A")
    }

    private struct AccessibilityEntry {
        let texts: [String]
        let role: NSAccessibility.Role?
        let frame: NSRect
    }

    private static func accessibilityEntries(in window: NSWindow) -> [AccessibilityEntry] {
        guard let root = window.contentView else { return [] }
        var entries: [AccessibilityEntry] = []
        var queue: [AnyObject] = [root]
        var visited = Set<ObjectIdentifier>()
        var cursor = 0
        while cursor < queue.count, cursor < 16_384 {
            let node = queue[cursor]
            cursor += 1
            guard visited.insert(ObjectIdentifier(node)).inserted else { continue }
            if let object = node as? NSObject {
                let texts = ["accessibilityTitle", "accessibilityLabel", "accessibilityValue"].compactMap { key in
                    (axValue(object, key) as? String).flatMap { $0.isEmpty ? nil : $0 }
                }
                let role = axValue(object, "accessibilityRole")
                    .flatMap { ($0 as? String).map(NSAccessibility.Role.init(rawValue:)) }
                var frame = (axValue(object, "accessibilityFrame") as? NSValue)?.rectValue ?? .zero
                if frame.width <= 1 || frame.height <= 1, let view = node as? NSView {
                    frame = window.convertToScreen(view.convert(view.bounds, to: nil))
                }
                if frame.width > 1, frame.height > 1, frame.intersects(window.frame) {
                    entries.append(AccessibilityEntry(texts: texts, role: role, frame: frame))
                }
                if let children = axValue(object, "accessibilityChildren") as? [Any] {
                    for child in children { queue.append(child as AnyObject) }
                }
            }
            if let view = node as? NSView {
                for subview in view.subviews { queue.append(subview) }
            }
        }
        return entries
    }

    private static func axValue(_ object: NSObject, _ key: String) -> Any? {
        guard object.responds(to: Selector(key)) else { return nil }
        return object.value(forKey: key)
    }

    private static func rowFrame(title: String, entries: [AccessibilityEntry], window: NSWindow) throws -> NSRect {
        let sidebarMaxX = window.frame.minX + SidebarLayout.defaultWidth + 40
        let inSidebar = entries.filter { $0.frame.midX < sidebarMaxX && $0.frame.height < 80 }
        // SwiftUI exposes a row as a button on some systems and as a group or cell holding the
        // title text on others; take the tightest element carrying the title.
        let tiers: [(AccessibilityEntry) -> Bool] = [
            { $0.role == .button && $0.texts.contains(title) },
            { $0.texts.contains(title) },
            { $0.texts.contains { $0.contains(title) } },
        ]
        for tier in tiers {
            let matches = inSidebar.filter(tier)
            if let row = matches.min(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) {
                return row.frame
            }
        }
        let sample = inSidebar.prefix(60).map { "\($0.role?.rawValue ?? "-"):\($0.texts.joined(separator: "|"))" }
        if !loggedSidebarEntries { loggedSidebarEntries = true } else { throw HarnessError(description: "accessibility row not found for '\(title)'") }
        WebsiteCaptures.log("cursor-repro sidebar entries (\(inSidebar.count) of \(entries.count)): \(sample.joined(separator: " ; "))")
        throw HarnessError(description: "accessibility row not found for '\(title)'")
    }

    private static func projectTitleFrame(name: String, entries: [AccessibilityEntry], window: NSWindow) throws -> NSRect {
        let row = try rowFrame(title: name, entries: entries, window: window)
        let titles = entries.filter {
            $0.role == .staticText
                && $0.texts.contains(name)
                && $0.frame.intersects(row)
                && $0.frame.width < row.width
                && $0.frame.height <= row.height
        }
        // When the row itself was matched by its title text, that text is the target.
        return titles.min(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height })?.frame ?? row
    }

    // CGEvent.location and the driver use global display coordinates with a top-left origin.
    private static func cgPoint(_ point: NSPoint, window: NSWindow) -> Point {
        let screen = window.convertToScreen(NSRect(origin: point, size: .zero)).origin
        return cgPoint(screen)
    }

    private static func cgPoint(_ appKitScreenPoint: NSPoint) -> Point {
        Point(
            x: Double(appKitScreenPoint.x),
            y: Double(CGDisplayBounds(CGMainDisplayID()).height - appKitScreenPoint.y)
        )
    }

    private static func findAll<View: NSView>(_ type: View.Type, in root: NSView?) -> [View] {
        guard let root else { return [] }
        var found: [View] = []
        if let match = root as? View { found.append(match) }
        for child in root.subviews { found.append(contentsOf: findAll(type, in: child)) }
        return found
    }

    private static func require(_ value: String?, _ message: String) throws -> String {
        guard let value, !value.isEmpty else { throw HarnessError(description: message) }
        return value
    }

    private static func select(_ id: UUID, model: AppModel, source: String) {
        let previous = model.selectedThreadID
        guard previous != id else {
            lastSelectedThreadID = id
            return
        }
        model.selectedThreadID = id
        lastSelectedThreadID = id
        trace?.threadSwitch(from: previous, to: id, source: source)
        note("thread-switch", "\(previous?.uuidString ?? "none") -> \(id.uuidString) source=\(source)")
    }

    private static func observeSelection(model: AppModel, source: String) {
        guard model.selectedThreadID != lastSelectedThreadID else { return }
        let previous = lastSelectedThreadID
        lastSelectedThreadID = model.selectedThreadID
        trace?.threadSwitch(from: previous, to: model.selectedThreadID, source: source)
        if let output = CaptureRun.outputDirectory {
            try? (model.selectedThreadID?.uuidString ?? "none").write(
                to: output.appendingPathComponent("selected-thread"), atomically: true, encoding: .utf8)
        }
        note("thread-switch", "\(previous?.uuidString ?? "none") -> \(model.selectedThreadID?.uuidString ?? "none") source=\(source)")
    }

    private static func stopStreaming() {
        streamTask?.cancel()
        streamTask = nil
        guard let runtime = streamingRuntime, runtime.isRunning else { return }
        runtime.rehearse(.messageCompleted(id: streamID, text: ""))
        runtime.rehearse(.turnCompleted(status: .completed, error: nil))
    }

    private static func write<Value: Encodable>(_ value: Value, named name: String, output: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: output.appendingPathComponent(name), options: .atomic)
    }

    private static func note(_ name: String, _ detail: String) {
        WebsiteCaptures.log("cursor-repro \(name): \(detail)")
        report.notes.append(["name": name, "detail": detail])
    }

    private static func saveReport(to output: URL, listFiles: Bool = false) {
        if listFiles {
            report.files = ((try? FileManager.default.contentsOfDirectory(atPath: output.path)) ?? []).sorted()
        }
        try? write(report, named: "cursor-repro.json", output: output)
    }

    private static func blocked(_ reason: String, output: URL) -> Never {
        stopStreaming()
        report.status = "blocked"
        report.blockedReason = reason
        note("blocked", reason)
        saveReport(to: output, listFiles: true)
        try? write(["reason": reason], named: "cursor-repro-blocked.json", output: output)
        WebsiteCaptures.log("cursor-repro blocked: \(reason)")
        exit(2)
    }
}

private extension NSEvent.EventType {
    var traceName: String {
        switch self {
        case .mouseMoved: "mouseMoved"
        case .leftMouseDown: "leftMouseDown"
        case .leftMouseUp: "leftMouseUp"
        default: "other"
        }
    }
}

private extension NSRect {
    var center: NSPoint { NSPoint(x: midX, y: midY) }
}
#endif
