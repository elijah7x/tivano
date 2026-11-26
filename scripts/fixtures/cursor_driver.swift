// Standalone system-cursor driver for CursorRepro `--cursor-repro`.
// Compile: swiftc -O cursor_driver.swift -o cursor_driver
// Usage:   cursor_driver <run-dir>

import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

struct DriverPoint: Codable {
    let x: Double
    let y: Double

    var cgPoint: CGPoint { CGPoint(x: x, y: y) }
}

struct DriverRect: Decodable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

struct CursorReady: Decodable {
    let pid: Int32
    let windowNumber: Int
    let windowFrame: DriverRect
    let textPoint: DriverPoint
    var sidebarRowB: DriverPoint
    var sidebarRows: [DriverPoint]
    var projectHeaders: [DriverPoint]
    let emptyChatPoints: [DriverPoint]
    let composerPoint: DriverPoint
    let readyAt: Double
    let readyAtWallClock: Double
    let threadB: String
    let rowsResolved: Bool?
    let sidebarRowBTitle: String?
    let sidebarRowTitles: [String]?
    let projectHeaderTitles: [String]?
}

struct CursorSample: Codable {
    let t: Double
    let scenario: String
    let phase: String
    let region: String
    let cursor: String
    let hotSpotX: Double
    let hotSpotY: Double
    let imageWidth: Double
    let imageHeight: Double
}

struct PhaseReport: Codable {
    let phase: String
    let sampleCounts: [String: Int]
    let transitionCounts: [String: Int]
    let totalSamples: Int
    let samples: [CursorSample]
}

struct ScenarioReport: Codable {
    let scenario: String
    let textHoverIbeamFraction: Double
    let textHoverSanityPassed: Bool
    let phases: [PhaseReport]
}

struct DriverReport: Codable {
    let startedAt: String
    let verdict: String
    let reason: String
    let scenarios: [ScenarioReport]
}

struct DriverError: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private final class SampleState {
    private let lock = NSLock()
    private var samples: [CursorSample] = []
    private var phaseOrder: [(scenario: String, phase: String)] = []
    private var scenario = "startup"
    private var phase = "startup"
    private var transitionUntil = 0.0
    private(set) var running = true

    func setPhase(scenario: String, phase: String) {
        lock.lock()
        if self.scenario != scenario || self.phase != phase {
            phaseOrder.append((scenario, phase))
        }
        self.scenario = scenario
        self.phase = phase
        transitionUntil = 0
        lock.unlock()
    }

    func departing() {
        lock.lock()
        transitionUntil = .infinity
        lock.unlock()
    }

    func arrived() {
        lock.lock()
        transitionUntil = Date().timeIntervalSince1970 + 0.150
        lock.unlock()
    }

    func record(origin: Date, references: CursorReferences) {
        let now = Date()
        let cursor = NSCursor.currentSystem
        let classification = references.classify(cursor)
        let hotSpot = cursor?.hotSpot ?? .zero
        let imageSize = cursor?.image.size ?? .zero

        lock.lock()
        let region = now.timeIntervalSince1970 < transitionUntil ? "transition" : "steady"
        if running {
            samples.append(CursorSample(
                t: now.timeIntervalSince(origin),
                scenario: scenario,
                phase: phase,
                region: region,
                cursor: classification,
                hotSpotX: Double(hotSpot.x),
                hotSpotY: Double(hotSpot.y),
                imageWidth: Double(imageSize.width),
                imageHeight: Double(imageSize.height)
            ))
        }
        lock.unlock()
    }

    func stop() {
        lock.lock()
        running = false
        lock.unlock()
    }

    func snapshot() -> (samples: [CursorSample], order: [(scenario: String, phase: String)]) {
        lock.lock()
        defer { lock.unlock() }
        return (samples, phaseOrder)
    }
}

private struct CursorReference {
    let hotSpot: NSPoint
    let tiff: Data?
}

private struct CursorReferences {
    let ibeam: CursorReference
    let arrow: CursorReference
    let hand: CursorReference

    init() {
        ibeam = Self.reference(NSCursor.iBeam)
        arrow = Self.reference(NSCursor.arrow)
        hand = Self.reference(NSCursor.pointingHand)
    }

    func classify(_ cursor: NSCursor?) -> String {
        guard let cursor else { return "other" }
        if matches(cursor, ibeam) { return "ibeam" }
        if matches(cursor, arrow) { return "arrow" }
        if matches(cursor, hand) { return "hand" }
        return "other"
    }

    private static func reference(_ cursor: NSCursor) -> CursorReference {
        CursorReference(hotSpot: cursor.hotSpot, tiff: cursor.image.tiffRepresentation)
    }

    private func matches(_ cursor: NSCursor, _ reference: CursorReference) -> Bool {
        guard let expected = reference.tiff, let actual = cursor.image.tiffRepresentation else { return false }
        return cursor.hotSpot == reference.hotSpot && actual == expected
    }
}

private final class CursorSampler {
    private let state = SampleState()
    private let group = DispatchGroup()
    private let references = CursorReferences()
    private var origin = Date()

    func start() {
        origin = Date()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            defer { self.group.leave() }
            while self.state.running {
                self.state.record(origin: self.origin, references: self.references)
                Thread.sleep(forTimeInterval: 0.025)
            }
        }
    }

    func setPhase(scenario: String, phase: String) {
        state.setPhase(scenario: scenario, phase: phase)
    }

    func departing() {
        state.departing()
    }

    func arrived() {
        state.arrived()
    }

    func stop() -> (samples: [CursorSample], order: [(scenario: String, phase: String)]) {
        state.stop()
        group.wait()
        return state.snapshot()
    }
}

private final class CursorDriver {
    let runDir: URL
    private let startedAt = Date()
    private let sampler = CursorSampler()
    private var source: CGEventSource?
    private var currentPoint = CGPoint.zero
    private var ready: CursorReady?

    init(runDir: URL) {
        self.runDir = runDir
    }

    func run() throws -> Int32 {
        guard CGPreflightPostEventAccess() else {
            throw DriverError(message: "CGPreflightPostEventAccess() is false; grant Post Event/Accessibility permission to this signed driver process")
        }
        guard let eventSource = CGEventSource(stateID: .hidSystemState) else {
            throw DriverError(message: "failed to create CGEventSource(.hidSystemState)")
        }
        source = eventSource
        let mouse = NSEvent.mouseLocation
        currentPoint = CGPoint(x: mouse.x, y: CGDisplayBounds(CGMainDisplayID()).height - mouse.y)

        let first = try waitForReady(named: "cursor-repro-ready.json", notBefore: startedAt.timeIntervalSince1970 - 30)
        ready = first
        log("ready", "pid=\(first.pid) window=\(first.windowNumber); points are CG global top-left coordinates")
        sampler.start()

        try runClickSwitch(ready: first)

        sampler.setPhase(scenario: "reset", phase: "reset")
        let resetAt = Date().timeIntervalSince1970
        try writeControl("reset")
        let second = try waitForReady(named: "cursor-repro-ready2.json", notBefore: resetAt - 1)
        ready = second
        log("ready2", "pid=\(second.pid) window=\(second.windowNumber)")
        try runProgrammaticSwitch(ready: second)

        // The recording that started this: the user clicked and selected reply text, then
        // switched. Native NSTextView selection tracking owns the cursor during the drag.
        sampler.setPhase(scenario: "reset", phase: "reset")
        let resetAt3 = Date().timeIntervalSince1970
        try writeControl("reset")
        let third = try waitForReady(named: "cursor-repro-ready2.json", notBefore: resetAt3 - 0.5)
        ready = third
        log("ready3", "pid=\(third.pid) window=\(third.windowNumber)")
        try runSelectSwitch(ready: third)
        // Last: typing changes the draft and the sidebar order the earlier scenarios rely on.
        try runComposerType(ready: third)

        let snapshot = sampler.stop()
        let report = evaluate(snapshot: snapshot)
        try writeJSON(report, named: "cursor-driver.json")
        try writeControl("cursor-repro-done")
        return report.verdict == "PASS" ? 0 : (report.verdict == "FAIL" ? 1 : 2)
    }

    func finishAfterError() {
        _ = sampler.stop()
        try? writeControl("cursor-repro-done")
    }

    private func runClickSwitch(ready: CursorReady) throws {
        let scenario = "click-switch"
        sampler.setPhase(scenario: scenario, phase: "text-hover")
        try move(to: ready.textPoint.cgPoint)
        try jiggle(around: ready.textPoint.cgPoint, seconds: 1.5)

        sampler.setPhase(scenario: scenario, phase: "travel")
        try move(to: ready.sidebarRowB.cgPoint)
        try click(at: ready.sidebarRowB.cgPoint, ready: ready)
        try waitForSelection(ready.threadB)
        Thread.sleep(forTimeInterval: 1.0)
        try runInspectionPhases(scenario: scenario, ready: ready)
    }

    /// The owner's report: type in the composer, move to the thread list, and the I-beam
    /// stays over the rows, even through a click on one. Only sidebar targets are measured:
    /// the chat pane behind holds reply text.
    private func runComposerType(ready: CursorReady) throws {
        let scenario = "composer-type"
        let composer = ready.composerPoint.cgPoint
        sampler.setPhase(scenario: scenario, phase: "text-hover")
        try move(to: composer)
        try jiggle(around: composer, seconds: 1.0)
        sampler.setPhase(scenario: scenario, phase: "type")
        try postClick(at: composer, clickState: 1)
        Thread.sleep(forTimeInterval: 0.3)
        for key: CGKeyCode in [4, 14, 37, 37, 31, 49, 13, 31, 15, 37, 2] { // "hello world"
            try postKey(key)
            Thread.sleep(forTimeInterval: 0.06)
        }
        Thread.sleep(forTimeInterval: 0.3)
        // The owner's path from the recording: a quick flick up over reply text, a pause there,
        // then a quick flick into the thread list (about 1500 px/s at 60 Hz).
        sampler.setPhase(scenario: scenario, phase: "reply-text")
        try move(to: ready.textPoint.cgPoint, step: 25, interval: 0.016)
        try jiggle(around: ready.textPoint.cgPoint, seconds: 1.0)
        for phase in ["sidebar-rows", "project-headers"] {
            sampler.setPhase(scenario: scenario, phase: phase)
            let points = phase == "sidebar-rows" ? ready.sidebarRows : ready.projectHeaders
            for point in points {
                try ensureAlive()
                try move(to: point.cgPoint, step: 25, interval: 0.016)
                try jiggle(around: point.cgPoint, seconds: 1.0)
            }
        }
        // And straight from the composer into the list, fast, without the stop over text.
        sampler.setPhase(scenario: scenario, phase: "type-2")
        try move(to: composer, step: 25, interval: 0.016)
        try postClick(at: composer, clickState: 1)
        for key: CGKeyCode in [4, 14, 37] { try postKey(key); Thread.sleep(forTimeInterval: 0.06) }
        sampler.setPhase(scenario: scenario, phase: "sidebar-rows-2")
        for point in ready.sidebarRows {
            try move(to: point.cgPoint, step: 25, interval: 0.016)
            try jiggle(around: point.cgPoint, seconds: 1.0)
        }
        // Back to the composer and clear the draft so later scenarios start clean.
        sampler.setPhase(scenario: scenario, phase: "cleanup")
        try move(to: composer)
        try postClick(at: composer, clickState: 1)
        for _ in 0..<14 { try postKey(51); Thread.sleep(forTimeInterval: 0.03) }
    }

    private func postKey(_ key: CGKeyCode) throws {
        guard let source,
              let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false) else {
            throw DriverError(message: "failed to create key event \(key)")
        }
        down.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.01)
        up.post(tap: .cghidEventTap)
    }

    private func runSelectSwitch(ready: CursorReady) throws {
        let scenario = "select-switch"
        let text = ready.textPoint.cgPoint
        sampler.setPhase(scenario: scenario, phase: "text-hover")
        try move(to: text)
        try jiggle(around: text, seconds: 1.0)
        sampler.setPhase(scenario: scenario, phase: "select")
        // Double-click a word, then drag-select across the line.
        try postClick(at: text, clickState: 1)
        Thread.sleep(forTimeInterval: 0.08)
        try postClick(at: text, clickState: 2)
        Thread.sleep(forTimeInterval: 0.5)
        let start = text
        try move(to: start)
        try postMouse(type: .leftMouseDown, at: start, clickState: 1)
        var point = start
        for _ in 0..<20 {
            point.x += 6
            try postMouse(type: .leftMouseDragged, at: point, clickState: 1)
            Thread.sleep(forTimeInterval: 0.015)
        }
        try postMouse(type: .leftMouseUp, at: point, clickState: 1)
        currentPoint = point
        try jiggle(around: point, seconds: 0.8)
        sampler.setPhase(scenario: scenario, phase: "travel")
        try move(to: ready.sidebarRowB.cgPoint)
        try click(at: ready.sidebarRowB.cgPoint, ready: ready)
        try waitForSelection(ready.threadB)
        Thread.sleep(forTimeInterval: 1.0)
        try runInspectionPhases(scenario: scenario, ready: ready)
    }

    private func postClick(at point: CGPoint, clickState: Int64) throws {
        try postMouse(type: .leftMouseDown, at: point, clickState: clickState)
        Thread.sleep(forTimeInterval: 0.03)
        try postMouse(type: .leftMouseUp, at: point, clickState: clickState)
    }

    private func runProgrammaticSwitch(ready: CursorReady) throws {
        let scenario = "programmatic-switch"
        sampler.setPhase(scenario: scenario, phase: "text-hover")
        try move(to: ready.textPoint.cgPoint)
        try jiggle(around: ready.textPoint.cgPoint, seconds: 1.5)

        sampler.setPhase(scenario: scenario, phase: "text-after-switch")
        try writeControl("switch-programmatic")
        try waitForSelection(ready.threadB)
        try jiggle(around: ready.textPoint.cgPoint, seconds: 1.5)
        try runInspectionPhases(scenario: scenario, ready: ready)
    }

    private func runInspectionPhases(scenario: String, ready: CursorReady) throws {
        let phases = [
            ("empty-chat", ready.emptyChatPoints),
            ("sidebar-rows", ready.sidebarRows),
            ("project-headers", ready.projectHeaders),
            ("empty-chat-2", ready.emptyChatPoints),
        ]
        for (phase, points) in phases {
            sampler.setPhase(scenario: scenario, phase: phase)
            for point in points {
                try ensureAlive()
                try move(to: point.cgPoint)
                try jiggle(around: point.cgPoint, seconds: 1.0)
            }
        }
    }

    /// The app writes `selected-thread` on every switch; without thread B shown the
    /// inspection would judge the wrong chat, so a missing switch is inconclusive.
    private func waitForSelection(_ threadID: String) throws {
        let url = runDir.appendingPathComponent("selected-thread")
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if let text = try? String(contentsOf: url, encoding: .utf8),
               text.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(threadID) == .orderedSame {
                log("selected", threadID)
                return
            }
            Thread.sleep(forTimeInterval: 0.025)
        }
        throw DriverError(message: "thread B \(threadID) was not selected within 3s; inspection would be misleading")
    }

    private func move(to destination: CGPoint, step: CGFloat = 8, interval: TimeInterval = 0.010) throws {
        // Travel crosses legitimate text (the composer, replies); only arrival is judged.
        sampler.departing()
        let start = currentPoint
        let dx = destination.x - start.x
        let dy = destination.y - start.y
        let steps = max(1, Int(ceil(max(abs(dx), abs(dy)) / step)))
        for step in 1...steps {
            let fraction = CGFloat(step) / CGFloat(steps)
            let point = CGPoint(x: start.x + dx * fraction, y: start.y + dy * fraction)
            try postMouse(type: .mouseMoved, at: point)
            currentPoint = point
            Thread.sleep(forTimeInterval: interval)
        }
        currentPoint = destination
        sampler.arrived()
    }

    private func jiggle(around center: CGPoint, seconds: TimeInterval) throws {
        let end = Date().addingTimeInterval(seconds)
        var toggle = false
        while Date() < end {
            let point = CGPoint(x: center.x + (toggle ? 3 : -3), y: center.y)
            try postMouse(type: .mouseMoved, at: point)
            currentPoint = point
            toggle.toggle()
            Thread.sleep(forTimeInterval: 0.010)
        }
        try postMouse(type: .mouseMoved, at: center)
        currentPoint = center
    }

    private func click(at point: CGPoint, ready: CursorReady) throws {
        guard targetIsUnder(point: point, ready: ready) else {
            throw DriverError(message: "capture window \(ready.windowNumber) of pid \(ready.pid) is no longer under the sidebar click point; refusing to click another app")
        }
        try postMouse(type: .leftMouseDown, at: point)
        Thread.sleep(forTimeInterval: 0.050)
        try postMouse(type: .leftMouseUp, at: point)
        currentPoint = point
    }

    private func postMouse(type: CGEventType, at point: CGPoint, clickState: Int64 = 1) throws {
        guard let source,
              let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left)
        else {
            throw DriverError(message: "failed to create \(type.rawValue) mouse event")
        }
        event.location = point
        if type != .mouseMoved { event.setIntegerValueField(.mouseEventClickState, value: clickState) }
        event.post(tap: .cghidEventTap)
    }

    private func waitForReady(named name: String, notBefore: TimeInterval) throws -> CursorReady {
        let url = runDir.appendingPathComponent(name)
        log("wait-ready", "polling \(url.path) up to 60s")
        let waitDeadline = Date().addingTimeInterval(60)
        while Date() < waitDeadline {
            if let reason = blockedReason() {
                throw DriverError(message: "capture app blocked: \(reason)")
            }
            if let data = try? Data(contentsOf: url),
               var decoded = try? JSONDecoder().decode(CursorReady.self, from: data),
               decoded.readyAtWallClock >= notBefore {
                if decoded.rowsResolved == false { try resolveRowsThroughAccessibility(&decoded) }
                try validate(decoded, name: name)
                return decoded
            }
            Thread.sleep(forTimeInterval: 0.050)
        }
        throw DriverError(message: "timed out after 60s waiting for \(url.path)")
    }

    /// SwiftUI builds its accessibility tree only for an outside client, so the sidebar rows
    /// are found here by title through the system API (AXPosition is CG global top-left).
    private func resolveRowsThroughAccessibility(_ ready: inout CursorReady) throws {
        guard AXIsProcessTrusted() else {
            throw DriverError(message: "rows need the accessibility API but this process is not trusted")
        }
        guard let bTitle = ready.sidebarRowBTitle, let rowTitles = ready.sidebarRowTitles,
              let headerTitles = ready.projectHeaderTitles else {
            throw DriverError(message: "ready file lacks the sidebar titles needed for accessibility lookup")
        }
        let app = AXUIElementCreateApplication(ready.pid)
        AXUIElementSetMessagingTimeout(app, 2)
        let sidebarMaxX = ready.windowFrame.x + 380
        let deadline = Date().addingTimeInterval(8)
        var lastMissing = ""
        while Date() < deadline {
            let found = scanAccessibility(app, maxX: sidebarMaxX)
            func center(_ title: String) -> DriverPoint? {
                // A row's label can carry its status first ("本轮完成、<title>").
                guard let rect = found[title]
                    ?? found.first(where: { $0.key.hasSuffix("、" + title) || $0.key.hasSuffix(", " + title) })?.value
                else { return nil }
                return DriverPoint(x: Double(rect.midX), y: Double(rect.midY))
            }
            // Thread B and both headers are required; other rows may sit below the fold or
            // in a collapsed list, so any of them that are on screen will do.
            let required = [bTitle] + headerTitles
            let missing = required.filter { center($0) == nil }
            let rows = rowTitles.compactMap { center($0) }
            if missing.isEmpty, !rows.isEmpty {
                ready.sidebarRowB = center(bTitle)!
                ready.sidebarRows = rows
                ready.projectHeaders = headerTitles.map { center($0)! }
                log("ax-rows", "resolved thread B, \(rows.count) of \(rowTitles.count) other rows and \(headerTitles.count) headers through accessibility")
                return
            }
            lastMissing = (missing + (rows.isEmpty ? rowTitles : [])).joined(separator: ", ")
                + " | sidebar texts seen: " + found.keys.sorted().prefix(40).joined(separator: " / ")
            Thread.sleep(forTimeInterval: 0.3)
        }
        throw DriverError(message: "accessibility lookup did not find: \(lastMissing)")
    }

    /// The tightest frame carrying each exact title text in the sidebar column.
    private func scanAccessibility(_ root: AXUIElement, maxX: Double) -> [String: CGRect] {
        var result: [String: CGRect] = [:]
        var queue: [AXUIElement] = [root]
        var index = 0
        while index < queue.count, index < 20_000 {
            let element = queue[index]
            index += 1
            var frame = CGRect.null
            var positionRef: CFTypeRef?
            var sizeRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionRef) == .success,
               AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
               let positionRef, let sizeRef {
                var point = CGPoint.zero
                var size = CGSize.zero
                AXValueGetValue(positionRef as! AXValue, .cgPoint, &point)
                AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
                frame = CGRect(origin: point, size: size)
            }
            if !frame.isNull, frame.width > 1, frame.height > 1, frame.height < 80, Double(frame.midX) < maxX {
                for attribute in [kAXTitleAttribute, kAXValueAttribute, kAXDescriptionAttribute] {
                    var value: CFTypeRef?
                    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
                          let text = value as? String, !text.isEmpty else { continue }
                    if let existing = result[text], existing.width * existing.height <= frame.width * frame.height { continue }
                    result[text] = frame
                }
            }
            var children: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
               let list = children as? [AXUIElement] {
                queue.append(contentsOf: list)
            }
        }
        return result
    }

    private func validate(_ value: CursorReady, name: String) throws {
        guard (1...3).contains(value.sidebarRows.count) else {
            throw DriverError(message: "\(name) contains \(value.sidebarRows.count) sidebarRows; expected 1-3")
        }
        guard value.projectHeaders.count == 2 else {
            throw DriverError(message: "\(name) contains \(value.projectHeaders.count) projectHeaders; expected 2")
        }
        guard value.emptyChatPoints.count == 6 else {
            throw DriverError(message: "\(name) contains \(value.emptyChatPoints.count) emptyChatPoints; expected 6")
        }
    }

    private func blockedReason() -> String? {
        let url = runDir.appendingPathComponent("cursor-repro-blocked.json")
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONDecoder().decode([String: String].self, from: data)
        else { return nil }
        return object["reason"]
    }

    private func ensureAlive() throws {
        guard let ready, kill(ready.pid, 0) == 0 else {
            throw DriverError(message: "capture app exited before the scenario finished")
        }
    }

    private func targetIsUnder(point: CGPoint, ready: CursorReady) -> Bool {
        guard kill(ready.pid, 0) == 0,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return false }
        for info in windows {
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict),
                  bounds.contains(point)
            else { continue }
            return (info[kCGWindowNumber as String] as? Int) == ready.windowNumber
                && (info[kCGWindowOwnerPID as String] as? Int32) == ready.pid
        }
        return false
    }

    private func evaluate(snapshot: (samples: [CursorSample], order: [(scenario: String, phase: String)])) -> DriverReport {
        var scenarioReports: [ScenarioReport] = []
        var sanityPassed = true
        var failureCount = 0
        let measuredPhases = Set(["empty-chat", "sidebar-rows", "project-headers", "empty-chat-2", "sidebar-rows-2"])

        for scenario in ["composer-type", "click-switch", "programmatic-switch", "select-switch"] {
            let scenarioSamples = snapshot.samples.filter { $0.scenario == scenario }
            let hover = scenarioSamples.filter { $0.phase == "text-hover" && $0.region == "steady" }
            let hoverIbeam = hover.filter { $0.cursor == "ibeam" }.count
            let fraction = hover.isEmpty ? 0 : Double(hoverIbeam) / Double(hover.count)
            let scenarioSanity = fraction >= 0.50
            sanityPassed = sanityPassed && scenarioSanity

            let orderedPhases = snapshot.order.filter { $0.scenario == scenario }.map { $0.phase }
            var phaseReports: [PhaseReport] = []
            for phase in orderedPhases {
                let samples = scenarioSamples.filter { $0.phase == phase }
                let steady = samples.filter { $0.region == "steady" }
                let transition = samples.filter { $0.region == "transition" }
                let counts = countsByCursor(steady)
                let transitionCounts = countsByCursor(transition)
                let measuredIbeam = measuredPhases.contains(phase) ? counts["ibeam", default: 0] : 0
                failureCount += measuredIbeam
                printSummary(
                    scenario: scenario,
                    phase: phase,
                    total: samples.count,
                    counts: counts,
                    transitionCounts: transitionCounts,
                    measuredIbeam: measuredIbeam
                )
                phaseReports.append(PhaseReport(
                    phase: phase,
                    sampleCounts: counts,
                    transitionCounts: transitionCounts,
                    totalSamples: samples.count,
                    samples: samples
                ))
            }
            scenarioReports.append(ScenarioReport(
                scenario: scenario,
                textHoverIbeamFraction: fraction,
                textHoverSanityPassed: scenarioSanity,
                phases: phaseReports
            ))
        }

        let verdict: String
        let reason: String
        if !sanityPassed {
            verdict = "INCONCLUSIVE"
            reason = "a text-hover phase recorded fewer than 50% I-beam samples; cursor detection or text targeting is broken"
        } else if failureCount > 0 {
            verdict = "FAIL"
            reason = "\(failureCount) steady I-beam samples occurred over empty chat, sidebar rows, or project headers"
        } else {
            verdict = "PASS"
            reason = "both text-hover sanity checks passed and no steady I-beam occurred in a measured non-text phase"
        }
        log("verdict", "\(verdict): \(reason)")
        return DriverReport(
            startedAt: ISO8601DateFormatter().string(from: startedAt),
            verdict: verdict,
            reason: reason,
            scenarios: scenarioReports
        )
    }

    private func countsByCursor(_ samples: [CursorSample]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for sample in samples { counts[sample.cursor, default: 0] += 1 }
        return counts
    }

    private func printSummary(
        scenario: String,
        phase: String,
        total: Int,
        counts: [String: Int],
        transitionCounts: [String: Int],
        measuredIbeam: Int
    ) {
        let steadyText = counts.keys.sorted().map { "\($0):\(counts[$0] ?? 0)" }.joined(separator: ",")
        let transitionText = transitionCounts.keys.sorted().map { "\($0):\(transitionCounts[$0] ?? 0)" }.joined(separator: ",")
        print("[\(scenario)] \(phase) samples=\(total) steady={\(steadyText)} transition={\(transitionText)} measuredIbeam=\(measuredIbeam)")
        fflush(stdout)
    }

    private func writeControl(_ name: String) throws {
        try Data().write(to: runDir.appendingPathComponent(name), options: .atomic)
    }

    private func writeJSON<Value: Encodable>(_ value: Value, named name: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: runDir.appendingPathComponent(name), options: .atomic)
    }

    private func log(_ stage: String, _ detail: String = "") {
        let suffix = detail.isEmpty ? "" : " \(detail)"
        print("[\(ISO8601DateFormatter().string(from: Date()))] \(stage)\(suffix)")
        fflush(stdout)
    }
}

guard CommandLine.arguments.count == 2 else {
    fputs("Usage: cursor_driver <run-dir>\n", stderr)
    exit(2)
}

_ = NSApplication.shared
let runDir = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
private let driver = CursorDriver(runDir: runDir)
do {
    let result = try driver.run()
    exit(result)
} catch {
    fputs("ERROR: \(error.localizedDescription)\n", stderr)
    fflush(stderr)
    driver.finishAfterError()
    exit(2)
}
