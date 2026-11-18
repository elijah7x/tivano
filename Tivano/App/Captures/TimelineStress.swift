#if DEBUG
import AppKit
import Darwin
import QuartzCore
import ScreenCaptureKit
import SwiftUI

enum ProbeKnobs {
    static let rawValue = ProcessInfo.processInfo.environment["TIVANO_PROBE_OFF"] ?? ""
    private static let offNames = Set(
        rawValue.split(separator: ",").map {
            String($0).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    )

    static func isOff(_ name: String) -> Bool {
        offNames.contains(name)
    }
}

/// Chat-timeline jitter stress for a `--website-captures` process.
///
///     open -n -W "Tivano.app" --args --website-captures <folder> --timeline-stress
///
/// Uses the real model, chat window and mock threads. Reply text is rehearsed, so no
/// provider session starts. Scroll input is posted as wheel events so the timeline's
/// own monitor can see it. This file does not call the timeline's viewport repair.
@MainActor
enum TimelineStress {
    private static var budgetSeconds: TimeInterval = 300
    private static var deadline = Date.now
    private static var phases: [[String: String]] = []
    private static var missingStills: [String] = []

    private static let longThreadID = WebsiteCaptures.composerThreadID
    private static let shortThreadID = WebsiteCaptures.freshThreadID
    private static let fastHistoryThreadID = WebsiteCaptures.ID.diffPopover

    static func run(model: AppModel) async {
        guard let output = CaptureRun.outputDirectory else { return }
        await model.bootstrap()
        guard model.isLibraryLoaded, !model.threads.isEmpty else {
            WebsiteCaptures.log("stress library failed to load")
            exit(1)
        }
        deadline = Date.now.addingTimeInterval(budgetSeconds)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(budgetSeconds))
            WebsiteCaptures.log("stress out of time, quitting")
            saveReport(listFiles: true)
            exit(2)
        }
        // Hydra's panel and intro would cover the column this run is here to watch.
        // Auto-merge stays off in the capture defaults; turning Hydra off keeps a
        // finished rehearsal from sending heads.
        model.settings.hasSeenHydraIntro = true
        model.settings.hydraEnabled = false
        WebsiteCaptures.log("stress start \(output.path)")

        let stage = Stage(model: model)
        stage.show(size: NSSize(width: 1320, height: 860))
        await stage.ensureActive()
        guard let window = appWindow(), NSApp.isActive, window.isKeyWindow else {
            note("blocked", "foreground desktop unavailable; unlock the host before running")
            saveReport(listFiles: true)
            exit(2)
        }
        guard let content = try? await SCShareableContent.currentProcess, !content.displays.isEmpty else {
            note("blocked", "no capturable display for this process")
            saveReport(listFiles: true)
            exit(2)
        }
        if model.sidebar.isVisible { model.sidebar.toggle() }
        model.selectedThreadID = longThreadID
        try? await Task.sleep(for: .milliseconds(700))
        let recorder = Recorder(output: output, stage: stage)

        await seed(model)
        await pinnedStill(recorder, stage)
        await grow(model, recorder, stage)
        await scrollAway(recorder, stage)
        await switchThreads(model, recorder, stage)
        await resizeWindow(stage, recorder)
        await occlude(stage, recorder)
        await composer(model, recorder, stage)

        note("done", "quitting")
        saveReport(listFiles: true)
        exit(missingStills.isEmpty ? 0 : 1)
    }

    static func runHistory(model: AppModel) async {
        guard CaptureRun.isEnabled, let output = CaptureRun.outputDirectory else { return }
        phases.removeAll()
        missingStills.removeAll()
        await model.bootstrap()
        guard model.isLibraryLoaded, !model.threads.isEmpty else {
            WebsiteCaptures.log("stress library failed to load")
            exit(1)
        }
        deadline = Date.now.addingTimeInterval(budgetSeconds)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(budgetSeconds))
            WebsiteCaptures.log("stress out of time, quitting")
            saveReport(listFiles: true)
            exit(2)
        }
        model.settings.hasSeenHydraIntro = true
        model.settings.hydraEnabled = false
        WebsiteCaptures.log("history-scroll start \(output.path)")

        let stage = Stage(model: model)
        stage.show(size: NSSize(width: 1320, height: 860))
        await stage.ensureActive()
        guard let window = appWindow(), NSApp.isActive, window.isKeyWindow else {
            note("blocked", "foreground desktop unavailable; unlock the host before running")
            saveReport(listFiles: true)
            exit(2)
        }
        guard let content = try? await SCShareableContent.currentProcess, !content.displays.isEmpty else {
            note("blocked", "no capturable display for this process")
            saveReport(listFiles: true)
            exit(2)
        }
        if model.sidebar.isVisible { model.sidebar.toggle() }
        // Keep the target thread unmounted while seeding so opening it starts on the
        // initial tail window (12 blocks, 48 hidden) rather than the live-append path.
        model.selectedThreadID = nil
        try? await Task.sleep(for: .milliseconds(300))
        let recorder = Recorder(output: output, stage: stage)

        await historyScroll(model, recorder, stage)

        note("done", "quitting")
        saveReport(listFiles: true)
        exit(missingStills.isEmpty ? 0 : 1)
    }

    static func runHistoryFlick(model: AppModel) async {
        guard CaptureRun.isEnabled, let output = CaptureRun.outputDirectory else { return }
        phases.removeAll()
        missingStills.removeAll()
        await model.bootstrap()
        guard model.isLibraryLoaded, !model.threads.isEmpty else {
            WebsiteCaptures.log("stress library failed to load")
            exit(1)
        }
        deadline = Date.now.addingTimeInterval(budgetSeconds)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(budgetSeconds))
            WebsiteCaptures.log("stress out of time, quitting")
            saveReport(listFiles: true)
            exit(2)
        }
        model.settings.hasSeenHydraIntro = true
        model.settings.hydraEnabled = false
        WebsiteCaptures.log("history-flick start \(output.path)")

        let stage = Stage(model: model)
        stage.show(size: NSSize(width: 1320, height: 860))
        await stage.ensureActive()
        guard let window = appWindow(), NSApp.isActive, window.isKeyWindow else {
            note("blocked", "foreground desktop unavailable; unlock the host before running")
            saveReport(listFiles: true)
            exit(2)
        }
        guard let content = try? await SCShareableContent.currentProcess, !content.displays.isEmpty else {
            note("blocked", "no capturable display for this process")
            saveReport(listFiles: true)
            exit(2)
        }
        if model.sidebar.isVisible { model.sidebar.toggle() }
        // Keep the target thread unmounted while seeding so opening it starts on the
        // initial tail window (12 blocks, 48 hidden) rather than the live-append path.
        model.selectedThreadID = nil
        try? await Task.sleep(for: .milliseconds(300))
        let recorder = Recorder(output: output, stage: stage)

        let outcome = await historyFlick(model, recorder, stage)
        switch outcome {
        case .blockedOrOutOfTime:
            note("done", "quitting (blocked/out-of-time)")
            saveReport(listFiles: true)
            exit(2)
        case .passed, .failed:
            let passed = outcome == .passed && missingStills.isEmpty
            note("done", "quitting (\(passed ? "PASS" : "FAIL"))")
            saveReport(listFiles: true)
            exit(passed ? 0 : 1)
        }
    }

    static func runHeldDrag(model: AppModel) async {
        guard CaptureRun.isEnabled, let output = CaptureRun.outputDirectory else { return }
        phases.removeAll()
        missingStills.removeAll()
        await model.bootstrap()
        guard model.isLibraryLoaded, !model.threads.isEmpty else {
            WebsiteCaptures.log("stress library failed to load")
            exit(1)
        }
        deadline = Date.now.addingTimeInterval(budgetSeconds)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(budgetSeconds))
            WebsiteCaptures.log("stress out of time, quitting")
            saveReport(listFiles: true)
            exit(2)
        }
        model.settings.hasSeenHydraIntro = true
        model.settings.hydraEnabled = false
        WebsiteCaptures.log("held-drag start \(output.path)")

        let stage = Stage(model: model)
        stage.show(size: NSSize(width: 1320, height: 860))
        await stage.ensureActive()
        guard let window = appWindow(), NSApp.isActive, window.isKeyWindow else {
            note("blocked", "foreground desktop unavailable; unlock the host before running")
            saveReport(listFiles: true)
            exit(2)
        }
        if model.sidebar.isVisible { model.sidebar.toggle() }
        // Keep the target thread unmounted while seeding so opening it starts pinned at the end.
        model.selectedThreadID = nil
        try? await Task.sleep(for: .milliseconds(300))

        let passed = await heldDrag(model, output: output)

        note("done", "quitting (\(passed ? "PASS" : "FAIL"))")
        saveReport(listFiles: true)
        exit(passed ? 0 : 1)
    }

    // MARK: - Phases

    private static func historyScroll(_ model: AppModel, _ recorder: Recorder, _ stage: Stage) async {
        let seeded = await seedHistory(
            model,
            threadID: shortThreadID,
            count: 60,
            noteName: "history-seed",
            minSecondsLeft: 50
        )
        guard seeded > 0, secondsLeft() > 40 else {
            note("history-open", "skipped after seeding \(seeded) turns, \(Int(secondsLeft()))s left")
            return
        }

        guard let openedSlow = await openAndSettleHistory(
            model,
            threadID: shortThreadID,
            recorder: recorder,
            stage: stage,
            shotName: "history-bottom",
            noteName: "history-open",
            turnsSeeded: seeded,
            minSecondsLeft: 38
        ) else { return }
        let window = openedSlow.window
        let scroll = openedSlow.scroll

        let calibration = await calibrateUpwardWheel(window: window, scroll: scroll)
        let directWheel = calibration.direct
        let upSign = calibration.upSign
        let wheelMode = calibration.mode

        // Return to the exact bottom before step 1 so slow scroll starts cleanly at Turn 60.
        var resetSteps = 0
        while let gap = bottomGap(scroll), gap > 4, resetSteps < 8, secondsLeft() > 35 {
            await burst(-upSign * 160, times: 3, window: window, scroll: scroll, direct: directWheel)
            resetSteps += 1
        }
        try? await Task.sleep(for: .milliseconds(250))

        let baselineViewport = max(240, unobstructedViewportRect(in: scroll).height)
        var prevDocHeight = Int((scroll.documentView?.bounds.height ?? 0).rounded())
        let estimatedPageHeight = max(
            Double(baselineViewport) * 1.2,
            Double(prevDocHeight) * Double(TimelineWindow.page) / Double(TimelineWindow.initial)
        )
        let twoPageThreshold = Int((estimatedPageHeight * 2.0).rounded())

        let slowStop = RecordingStop()
        let slowMaxSeconds = max(10.0, secondsLeft() - 24)
        let slowRecording = Task { await recordWindow("history-slow", seconds: slowMaxSeconds, stop: slowStop) }
        let startWait = Date.now.addingTimeInterval(1.5)
        while !slowStop.started, Date.now < startWait {
            try? await Task.sleep(for: .milliseconds(40))
        }

        var slowSteps = 0
        var totalGrowth = 0
        var maxStepGrowth = 0
        var stepsToTop: Int?

        for step in 1...40 {
            guard secondsLeft() > 28 else {
                note("history-slow-budget", "stopped before step \(step), \(Int(secondsLeft()))s left")
                break
            }
            guard let liveWindow = appWindow(), let liveScroll = timelineScroll(in: liveWindow) else {
                note("history-slow-abort", "lost timeline scroll view at step \(step)")
                break
            }
            let viewport = max(240, unobstructedViewportRect(in: liveScroll).height)
            let tickPixels = Int32(max(24, (viewport * 0.2).rounded())) * upSign
            for tick in 0..<3 {
                sendWheel(tickPixels, window: liveWindow, scroll: liveScroll, direct: directWheel)
                if tick < 2 { try? await Task.sleep(for: .milliseconds(20)) }
            }
            let settleMs = secondsLeft() > 75 ? 360 : 180
            try? await Task.sleep(for: .milliseconds(settleMs))

            let offset = scrollOffset(liveScroll)
            let docHeight = Int((liveScroll.documentView?.bounds.height ?? 0).rounded())
            let growth = docHeight - prevDocHeight
            prevDocHeight = docHeight
            slowSteps = step
            totalGrowth += growth
            if growth > maxStepGrowth { maxStepGrowth = growth }

            let topTurn = visibleTopTurn(in: liveScroll).map(String.init) ?? "unknown"
            let shotName = String(format: "history-slow-%02d", step)
            await shoot(recorder, stage, shotName)
            note(shotName, "step=\(step) offset=\(offset) docHeight=\(docHeight) growth=\(growth) topTurn=\(topTurn) wheel=\(wheelMode)")

            if offset == 0, mountedLowestTurn(in: liveScroll) == 1 {
                try? await Task.sleep(for: .milliseconds(120))
                let settledOffset = scrollOffset(liveScroll)
                let settledHeight = Int((liveScroll.documentView?.bounds.height ?? 0).rounded())
                if settledOffset == 0, settledHeight == docHeight {
                    stepsToTop = step
                    break
                }
            }
        }

        try? await Task.sleep(for: .milliseconds(150))
        slowStop.stopped = true
        await slowRecording.value

        var fastEvents = 0
        var fastTopTurnText = "skipped"

        if secondsLeft() > 22 {
            // Keep the second thread unmounted while seeding so opening it starts on the
            // initial tail window (12 blocks, 48 hidden), matching the slow-scroll opening.
            model.selectedThreadID = nil
            try? await Task.sleep(for: .milliseconds(300))

            let fastSeeded = await seedHistory(
                model,
                threadID: fastHistoryThreadID,
                count: 60,
                noteName: "history-fast-seed",
                minSecondsLeft: 14
            )
            if fastSeeded > 0,
               let openedFast = await openAndSettleHistory(
                   model,
                   threadID: fastHistoryThreadID,
                   recorder: recorder,
                   stage: stage,
                   shotName: "history-fast-bottom",
                   noteName: "history-fast-open",
                   turnsSeeded: fastSeeded,
                   minSecondsLeft: 12
               ) {
                let fastWindow = openedFast.window
                let fastScroll = openedFast.scroll

                let fastStop = RecordingStop()
                let fastMaxSeconds = max(12.0, secondsLeft() - 4)
                let fastRecording = Task { await recordWindow("history-fast", seconds: fastMaxSeconds, stop: fastStop) }
                let fastWait = Date.now.addingTimeInterval(1.5)
                while !fastStop.started, Date.now < fastWait {
                    try? await Task.sleep(for: .milliseconds(40))
                }
                try? await Task.sleep(for: .milliseconds(120))

                let fastTick = upSign * 44
                for _ in 0..<400 {
                    guard secondsLeft() > 5 else { break }
                    sendWheel(fastTick, window: fastWindow, scroll: fastScroll, direct: directWheel)
                    fastEvents += 1
                    try? await Task.sleep(for: .milliseconds(16))
                    if fastEvents.isMultiple(of: 5),
                       let topTurn = visibleTopTurn(in: fastScroll),
                       topTurn <= 20 {
                        break
                    }
                }

                let settleSeconds = min(1.0, max(0, secondsLeft() - 3))
                if settleSeconds > 0.05 {
                    try? await Task.sleep(for: .seconds(settleSeconds))
                }
                fastStop.stopped = true
                await fastRecording.value

                let fastEndOffset = scrollOffset(fastScroll)
                let fastEndHeight = Int((fastScroll.documentView?.bounds.height ?? 0).rounded())
                let fastEndGap = bottomGap(fastScroll) ?? -1
                let fastEndTopTurn = visibleTopTurn(in: fastScroll)
                let fastEndLowestTurn = mountedLowestTurn(in: fastScroll)
                let reachedTurn1 = fastEndTopTurn == 1 || (fastEndOffset == 0 && fastEndLowestTurn == 1)
                fastTopTurnText = fastEndTopTurn.map(String.init) ?? "unknown"
                let fastLowestTurnText = fastEndLowestTurn.map(String.init) ?? "unknown"

                await shoot(recorder, stage, "history-fast-end")
                note(
                    "history-fast-scroll",
                    "events=\(fastEvents) intervalMs=16 topTurn=\(fastTopTurnText) lowestTurn=\(fastLowestTurnText) endOffset=\(fastEndOffset) docHeight=\(fastEndHeight) endGap=\(fastEndGap) reachedTurn1=\(reachedTurn1 ? "true" : "false") wheel=\(wheelMode)"
                )
            } else {
                note("history-fast-scroll", "skipped after seeding \(fastSeeded) turns, \(Int(secondsLeft()))s left")
            }
        } else {
            note("history-fast-scroll", "skipped, \(Int(secondsLeft()))s left")
        }

        let avgGrowth = slowSteps > 0 ? Double(totalGrowth) / Double(slowSteps) : 0
        let cascade = maxStepGrowth > twoPageThreshold
        let topStepsText = stepsToTop.map(String.init) ?? "not-reached"
        let summaryDetail = String(
            format: "slowSteps=%d avgGrowth=%.1fpt maxStepGrowth=%dpt twoPageThreshold=%dpt suspectedCascade=%@ stepsToTop=%@ fastEvents=%d fastTopTurn=%@ wheel=%@",
            slowSteps, avgGrowth, maxStepGrowth, twoPageThreshold,
            cascade ? "true" : "false", topStepsText, fastEvents, fastTopTurnText, wheelMode
        )
        WebsiteCaptures.log("stress history-summary: \(summaryDetail)")
        phases.append([
            "name": "history-summary",
            "detail": summaryDetail,
            "slowSteps": String(slowSteps),
            "avgGrowthPt": String(format: "%.1f", avgGrowth),
            "maxStepGrowthPt": String(maxStepGrowth),
            "estimatedPageHeightPt": String(Int(estimatedPageHeight.rounded())),
            "twoPageThresholdPt": String(twoPageThreshold),
            "suspectedCascade": cascade ? "true" : "false",
            "stepsToTop": topStepsText,
            "fastEvents": String(fastEvents),
            "fastTopTurn": fastTopTurnText,
            "wheelMode": wheelMode,
        ])
        saveReport(listFiles: false)
    }

    private enum HistoryFlickOutcome: Equatable {
        case passed
        case failed
        case blockedOrOutOfTime
    }

    private struct HistoryFlickRect: Codable {
        let x: Double
        let y: Double
        let width: Double
        let height: Double
    }

    private struct HistoryFlickReady: Codable {
        let pid: Int32
        let windowNumber: Int
        let point: HeldDragPoint
        let windowFrame: HistoryFlickRect
        let upSign: Int32
        let viewport: Double
        let flicks: Int
        let readyAt: Double
        let readyAtWallClock: Double
    }

    private struct HistoryFlickObservedEvent: Encodable {
        let time: Double
        let phase: UInt
        let momentumPhase: UInt
        let scrollingDeltaY: Double
        let windowNumber: Int
    }

    private struct HistoryFlickFrameJump: Encodable {
        let time: Double
        let size: Double
        let deltaP: Double
        let observedDelta: Double
    }

    private struct HistoryFlickSample: Encodable {
        let index: Int
        let injected: Double
        let observed: Double
        let discrepancy: Double
        let clamped: Bool
        let docHeightStart: Double
        let docHeightEnd: Double
        let historyPageLoaded: Bool
        let frameJumps: [HistoryFlickFrameJump]
    }

    private struct HistoryFlickSamplesReport: Encodable {
        let verdict: String
        let delivery: String
        let upSign: Int32
        let viewport: Double
        let observedEventsCount: Int
        let flicksCount: Int
        let unclampedFlicksCount: Int
        let pageLoads: Int
        let maxAbsDiscrepancy: Double
        let flicksOver24pt: Int
        let frameJumpsCount: Int
        let flicks: [HistoryFlickSample]
        let observedEvents: [HistoryFlickObservedEvent]
    }

    private struct FlickScrollSnapshot {
        let p: Double
        let docHeight: Double
        let clipMinY: Double
        let topInset: Double

        var isClampedAtTop: Bool {
            clipMinY <= -topInset + 1.0
        }
    }

    private struct TimedFlickSnapshot {
        let monoTime: CFTimeInterval
        let snapshot: FlickScrollSnapshot
    }

    @MainActor
    private final class HistoryFlickObservedBuffer {
        struct RawEvent {
            let monoTime: CFTimeInterval
            let phase: NSEvent.Phase
            let momentumPhase: NSEvent.Phase
            let scrollingDeltaY: Double
            let windowNumber: Int
            let preBeganSnapshot: FlickScrollSnapshot?
        }

        var initialSnapshot: FlickScrollSnapshot?
        var initialSnapshotMonoTime: CFTimeInterval?
        var events: [RawEvent] = []
    }

    private static let historyFlickCount = 60

    private static func historyFlick(_ model: AppModel, _ recorder: Recorder, _ stage: Stage) async -> HistoryFlickOutcome {
        guard let output = CaptureRun.outputDirectory else { return .failed }
        let seeded = await seedHistory(
            model,
            threadID: shortThreadID,
            count: 60,
            noteName: "flick-seed",
            minSecondsLeft: 50
        )
        guard seeded > 0, secondsLeft() > 40 else {
            note("flick-open", "skipped after seeding \(seeded) turns, \(Int(secondsLeft()))s left")
            return .blockedOrOutOfTime
        }

        guard let opened = await openAndSettleHistory(
            model,
            threadID: shortThreadID,
            recorder: recorder,
            stage: stage,
            shotName: "flick-bottom",
            noteName: "flick-open",
            turnsSeeded: seeded,
            minSecondsLeft: 38
        ) else {
            return secondsLeft() <= 38 ? .blockedOrOutOfTime : .failed
        }
        let window = opened.window
        let scroll = opened.scroll

        // External HID uses the AppKit convention (same as held-drag): positive scrollingDeltaY moves toward the top.
        let upSign: Int32 = 1
        var resetSteps = 0
        while let gap = bottomGap(scroll), gap > 4, resetSteps < 8, secondsLeft() > 35 {
            await burst(-upSign * 160, times: 3, window: window, scroll: scroll, direct: true)
            resetSteps += 1
        }
        if resetSteps > 0 {
            try? await Task.sleep(for: .milliseconds(250))
        }
        guard let startGap = bottomGap(scroll), startGap <= 8 else {
            note("flick-pinned", "not at bottom before ready (gap=\(bottomGap(scroll).map(String.init) ?? "nil"))")
            return .failed
        }
        note("flick-pinned", "pinned at end gap=\(startGap) delivery=hid upSign=\(upSign)")

        let baselineViewport = Double(max(240, unobstructedViewportRect(in: scroll).height))

        let flickStop = RecordingStop()
        let flickMaxSeconds = max(15.0, secondsLeft() - 16)
        let flickRecording = Task { await recordWindow("history-flick", seconds: flickMaxSeconds, stop: flickStop) }
        let startWait = Date.now.addingTimeInterval(1.5)
        while !flickStop.started, Date.now < startWait {
            try? await Task.sleep(for: .milliseconds(40))
        }

        await shoot(recorder, stage, "flick-start")

        let buffer = HistoryFlickObservedBuffer()
        var monitor: Any? = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            guard event.window === window else { return event }
            let now = CACurrentMediaTime()
            let liveScroll = timelineScroll(in: window) ?? scroll
            if buffer.initialSnapshot == nil, let snap = readScrollSnapshot(liveScroll) {
                buffer.initialSnapshot = snap
                buffer.initialSnapshotMonoTime = now - 0.000_001
            }
            let preBegan = event.phase.contains(.began) ? readScrollSnapshot(liveScroll) : nil
            let lineScroll = liveScroll.verticalLineScroll
            let preciseDelta = Double(
                event.hasPreciseScrollingDeltas
                    ? event.scrollingDeltaY
                    : event.scrollingDeltaY * lineScroll
            )
            buffer.events.append(HistoryFlickObservedBuffer.RawEvent(
                monoTime: now,
                phase: event.phase,
                momentumPhase: event.momentumPhase,
                scrollingDeltaY: preciseDelta,
                windowNumber: event.window?.windowNumber ?? event.windowNumber,
                preBeganSnapshot: preBegan
            ))
            return event
        }
        defer {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }

        var latestPreEventSnap = readScrollSnapshot(scroll)
        var latestPreEventMono = CACurrentMediaTime()

        let point = timelineCGPoint(window: window, scroll: scroll)
        let winFrame = windowCGRect(window)
        let ready = HistoryFlickReady(
            pid: getpid(),
            windowNumber: window.windowNumber,
            point: HeldDragPoint(x: Double(point.x), y: Double(point.y)),
            windowFrame: winFrame,
            upSign: upSign,
            viewport: baselineViewport,
            flicks: historyFlickCount,
            readyAt: CACurrentMediaTime(),
            readyAtWallClock: Date().timeIntervalSince1970
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let readyData = try? encoder.encode(ready) else {
            flickStop.stopped = true
            await flickRecording.value
            note("history-flick-ready", "failed to encode history-flick-ready.json")
            return .failed
        }
        do {
            try readyData.write(to: output.appendingPathComponent("history-flick-ready.json"), options: .atomic)
        } catch {
            flickStop.stopped = true
            await flickRecording.value
            note("history-flick-ready", "failed to write history-flick-ready.json: \(error.localizedDescription)")
            return .failed
        }
        note(
            "history-flick-ready",
            String(
                format: "pid=%d window=%d point=(%.1f,%.1f) windowFrame=(%.1f,%.1f,%.1f,%.1f) upSign=%d viewport=%.1f flicks=%d",
                getpid(), window.windowNumber, point.x, point.y,
                winFrame.x, winFrame.y, winFrame.width, winFrame.height,
                upSign, baselineViewport, historyFlickCount
            )
        )

        let waitStart = Date.now
        let waitDeadline = waitStart.addingTimeInterval(30.0)
        while Date.now < waitDeadline, secondsLeft() > 8 {
            if !buffer.events.isEmpty { break }
            if let liveWindow = appWindow(), let liveScroll = timelineScroll(in: liveWindow),
               let snap = readScrollSnapshot(liveScroll) {
                latestPreEventSnap = snap
                latestPreEventMono = CACurrentMediaTime()
            }
            try? await Task.sleep(for: .milliseconds(8))
        }

        guard let firstEvent = buffer.events.first else {
            if let activeMonitor = monitor {
                NSEvent.removeMonitor(activeMonitor)
                monitor = nil
            }
            flickStop.stopped = true
            await flickRecording.value
            await shoot(recorder, stage, "flick-end")
            note(
                "history-flick-hid-wait",
                "failed: no scrollWheel event matched window=\(window.windowNumber) within 30s"
            )
            _ = evaluateHistoryFlick(
                samples: [],
                rawEvents: [],
                upSign: upSign,
                viewport: baselineViewport,
                output: output
            )
            return .failed
        }

        note(
            "history-flick-hid-started",
            String(
                format: "first event phase=%lu momentum=%lu after %.2fs",
                firstEvent.phase.rawValue,
                firstEvent.momentumPhase.rawValue,
                Date.now.timeIntervalSince(waitStart)
            )
        )

        var samples: [TimedFlickSnapshot] = []
        if let seedSnap = buffer.initialSnapshot ?? latestPreEventSnap {
            let seedTime = buffer.initialSnapshotMonoTime ?? min(latestPreEventMono, firstEvent.monoTime - 0.000_001)
            samples.append(TimedFlickSnapshot(monoTime: seedTime, snapshot: seedSnap))
        }

        while secondsLeft() > 6 {
            if let liveWindow = appWindow(), let liveScroll = timelineScroll(in: liveWindow),
               let snap = readScrollSnapshot(liveScroll) {
                samples.append(TimedFlickSnapshot(monoTime: CACurrentMediaTime(), snapshot: snap))
            }
            if let lastMono = buffer.events.last?.monoTime,
               CACurrentMediaTime() - lastMono >= 1.5 {
                break
            }
            try? await Task.sleep(for: .milliseconds(8))
        }

        if let activeMonitor = monitor {
            NSEvent.removeMonitor(activeMonitor)
            monitor = nil
        }

        try? await Task.sleep(for: .milliseconds(100))
        flickStop.stopped = true
        await flickRecording.value
        await shoot(recorder, stage, "flick-end")

        let passed = evaluateHistoryFlick(
            samples: samples,
            rawEvents: buffer.events,
            upSign: upSign,
            viewport: baselineViewport,
            output: output
        )
        return passed ? .passed : .failed
    }

    private static func evaluateHistoryFlick(
        samples: [TimedFlickSnapshot],
        rawEvents: [HistoryFlickObservedBuffer.RawEvent],
        upSign: Int32,
        viewport: Double,
        output: URL
    ) -> Bool {
        let sortedSamples = samples.sorted { $0.monoTime < $1.monoTime }
        let sortedEvents = rawEvents.sorted { $0.monoTime < $1.monoTime }
        let originMono = sortedEvents.first?.monoTime ?? sortedSamples.first?.monoTime ?? CACurrentMediaTime()

        let observedEvents = sortedEvents.map { event in
            HistoryFlickObservedEvent(
                time: event.monoTime - originMono,
                phase: event.phase.rawValue,
                momentumPhase: event.momentumPhase.rawValue,
                scrollingDeltaY: event.scrollingDeltaY,
                windowNumber: event.windowNumber
            )
        }

        var allJumps: [(monoTime: CFTimeInterval, jump: HistoryFlickFrameJump)] = []
        if sortedSamples.count >= 2 {
            var eventCursor = 0
            while eventCursor < sortedEvents.count, sortedEvents[eventCursor].monoTime <= sortedSamples[0].monoTime {
                eventCursor += 1
            }
            for idx in 1..<sortedSamples.count {
                let prev = sortedSamples[idx - 1]
                let curr = sortedSamples[idx]
                var intervalObserved = 0.0
                while eventCursor < sortedEvents.count, sortedEvents[eventCursor].monoTime <= curr.monoTime {
                    if sortedEvents[eventCursor].monoTime > prev.monoTime {
                        intervalObserved += sortedEvents[eventCursor].scrollingDeltaY
                    }
                    eventCursor += 1
                }
                let deltaP = curr.snapshot.p - prev.snapshot.p
                let diff = deltaP - intervalObserved
                let topClampedNoGrowth = (prev.snapshot.isClampedAtTop || curr.snapshot.isClampedAtTop)
                    && abs(curr.snapshot.docHeight - prev.snapshot.docHeight) <= 1.0
                if !topClampedNoGrowth, abs(diff) > 40.0 {
                    allJumps.append((
                        monoTime: curr.monoTime,
                        jump: HistoryFlickFrameJump(
                            time: curr.monoTime - originMono,
                            size: diff,
                            deltaP: deltaP,
                            observedDelta: intervalObserved
                        )
                    ))
                }
            }
        }

        let beganIndices = sortedEvents.indices.filter { sortedEvents[$0].phase.contains(.began) }
        var flickSamples: [HistoryFlickSample] = []
        flickSamples.reserveCapacity(beganIndices.count)

        for (pos, beganIdx) in beganIndices.enumerated() {
            let flickIndex = pos + 1
            let nextBeganIdx = pos + 1 < beganIndices.count ? beganIndices[pos + 1] : sortedEvents.count
            let slice = beganIdx..<nextBeganIdx
            let momEndIdx = slice.last {
                sortedEvents[$0].momentumPhase.contains(.ended) || sortedEvents[$0].momentumPhase.contains(.cancelled)
            }
            let lastMomIdx = slice.last { !sortedEvents[$0].momentumPhase.isEmpty }
            let fingerEndIdx = slice.last {
                sortedEvents[$0].phase.contains(.ended) || sortedEvents[$0].phase.contains(.cancelled)
            }
            let endIdx = momEndIdx ?? lastMomIdx ?? fingerEndIdx ?? (nextBeganIdx - 1)

            let beganEvent = sortedEvents[beganIdx]
            let endEvent = sortedEvents[endIdx]
            // Positive precise-adjusted scrollingDeltaY moves toward the top, which increases P.
            let injected = sortedEvents[beganIdx...endIdx].reduce(0.0) { $0 + $1.scrollingDeltaY }

            guard let startSnap = beganEvent.preBeganSnapshot ?? snapshotJustBefore(beganEvent.monoTime, in: sortedSamples) else {
                continue
            }

            let wantEndTime = endEvent.monoTime + 0.150
            let endSnap: FlickScrollSnapshot
            let measureEndTime: CFTimeInterval
            if nextBeganIdx < sortedEvents.count, sortedEvents[nextBeganIdx].monoTime <= wantEndTime {
                let nextBegan = sortedEvents[nextBeganIdx]
                endSnap = nextBegan.preBeganSnapshot ?? snapshotJustBefore(nextBegan.monoTime, in: sortedSamples) ?? startSnap
                measureEndTime = nextBegan.monoTime
            } else {
                endSnap = snapshotAtOrAfter(wantEndTime, in: sortedSamples) ?? startSnap
                measureEndTime = wantEndTime
            }

            let observed = endSnap.p - startSnap.p
            let discrepancy = observed - injected
            let clampedInWindow = sortedSamples.contains {
                $0.monoTime >= beganEvent.monoTime && $0.monoTime <= measureEndTime && $0.snapshot.isClampedAtTop
            }
            let clamped = startSnap.isClampedAtTop || endSnap.isClampedAtTop || clampedInWindow
            let pageLoaded = endSnap.docHeight - startSnap.docHeight > 1.0

            let jumpLower = pos == 0 ? -Double.infinity : beganEvent.monoTime
            let jumpUpper = nextBeganIdx < sortedEvents.count ? sortedEvents[nextBeganIdx].monoTime : Double.infinity
            let flickJumps = allJumps
                .filter { $0.monoTime >= jumpLower && $0.monoTime < jumpUpper }
                .map(\.jump)

            let record = HistoryFlickSample(
                index: flickIndex,
                injected: injected,
                observed: observed,
                discrepancy: discrepancy,
                clamped: clamped,
                docHeightStart: startSnap.docHeight,
                docHeightEnd: endSnap.docHeight,
                historyPageLoaded: pageLoaded,
                frameJumps: flickJumps
            )
            flickSamples.append(record)
            WebsiteCaptures.log(
                "stress flick-\(String(format: "%02d", flickIndex)): injected=\(String(format: "%.1f", injected))pt observed=\(String(format: "%.1f", observed))pt discrepancy=\(String(format: "%.1f", discrepancy))pt clamped=\(clamped) pageLoaded=\(pageLoaded) jumps=\(flickJumps.count) docHeight=\(Int(startSnap.docHeight.rounded()))->\(Int(endSnap.docHeight.rounded()))"
            )
        }

        let unclamped = flickSamples.filter { !$0.clamped }
        let pageLoads = flickSamples.filter(\.historyPageLoaded).count
        let maxAbsDiscrepancy = unclamped.map { abs($0.discrepancy) }.max() ?? 0.0
        let flicksOver24 = unclamped.filter { abs($0.discrepancy) > 24.0 }.count
        let frameJumpsCount = allJumps.count
        // A short or stalled sequence proves nothing: every flick must arrive and history
        // must actually page in under the reader, which is the case being measured.
        let sequenceComplete = flickSamples.count == historyFlickCount
        // The failure being guarded: a history page landing uncompensated, which moves the
        // reader by a large part of a page between two samples. Per-flick discrepancy and the
        // small frame jumps are reported but not judged: flicks overlap their neighbours'
        // momentum, so their segmentation alone swings by tens of points either way.
        let pageJumps = allJumps.filter { abs($0.jump.size) > viewport / 2 }.count
        let passed = sequenceComplete && pageLoads >= 2 && !unclamped.isEmpty && pageJumps == 0
        let verdict = passed ? "PASS" : "FAIL"

        let samplesFile = "history-flick-samples.json"
        let samplesReport = HistoryFlickSamplesReport(
            verdict: verdict,
            delivery: "hid",
            upSign: upSign,
            viewport: viewport,
            observedEventsCount: observedEvents.count,
            flicksCount: flickSamples.count,
            unclampedFlicksCount: unclamped.count,
            pageLoads: pageLoads,
            maxAbsDiscrepancy: maxAbsDiscrepancy,
            flicksOver24pt: flicksOver24,
            frameJumpsCount: frameJumpsCount,
            flicks: flickSamples,
            observedEvents: observedEvents
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let encoded = try? encoder.encode(samplesReport) {
            try? encoded.write(to: output.appendingPathComponent(samplesFile), options: .atomic)
        }

        let summaryDetail = "verdict=\(verdict) sequenceComplete=\(sequenceComplete) delivery=hid observedEvents=\(observedEvents.count) flicks=\(flickSamples.count) unclampedFlicks=\(unclamped.count) pageLoads=\(pageLoads) maxAbsDiscrepancy=\(String(format: "%.1f", maxAbsDiscrepancy))pt flicksOver24pt=\(flicksOver24) frameJumps=\(frameJumpsCount) pageJumps=\(pageJumps) viewport=\(Int(viewport.rounded()))pt"
        WebsiteCaptures.log("stress history-flick-summary: \(summaryDetail)")
        phases.append([
            "name": "history-flick-summary",
            "verdict": verdict,
            "detail": summaryDetail,
            "delivery": "hid",
            "observedEvents": String(observedEvents.count),
            "flicks": String(flickSamples.count),
            "unclampedFlicks": String(unclamped.count),
            "pageLoads": String(pageLoads),
            "maxAbsDiscrepancyPt": String(format: "%.1f", maxAbsDiscrepancy),
            "flicksOver24pt": String(flicksOver24),
            "frameJumps": String(frameJumpsCount),
            "viewportPt": String(Int(viewport.rounded())),
            "samplesFile": samplesFile,
        ])
        saveReport(listFiles: false)
        return passed
    }

    private static func readScrollSnapshot(_ scroll: NSScrollView) -> FlickScrollSnapshot? {
        guard let document = scroll.documentView else { return nil }
        let docHeight = Double(document.bounds.height)
        let clipMinY = Double(scroll.contentView.bounds.minY)
        let topInset = Double(scroll.contentInsets.top)
        return FlickScrollSnapshot(
            p: docHeight - clipMinY,
            docHeight: docHeight,
            clipMinY: clipMinY,
            topInset: topInset
        )
    }

    private static func snapshotJustBefore(
        _ time: CFTimeInterval,
        in samples: [TimedFlickSnapshot]
    ) -> FlickScrollSnapshot? {
        if let idx = samples.lastIndex(where: { $0.monoTime <= time }) {
            return samples[idx].snapshot
        }
        return samples.first?.snapshot
    }

    private static func snapshotAtOrAfter(
        _ time: CFTimeInterval,
        in samples: [TimedFlickSnapshot]
    ) -> FlickScrollSnapshot? {
        if let idx = samples.firstIndex(where: { $0.monoTime >= time }) {
            return samples[idx].snapshot
        }
        return samples.last?.snapshot
    }

    private static func windowCGRect(_ window: NSWindow) -> HistoryFlickRect {
        let frame = window.frame
        let displayHeight = CGDisplayBounds(CGMainDisplayID()).height
        return HistoryFlickRect(
            x: Double(frame.minX),
            y: Double(displayHeight - frame.maxY),
            width: Double(frame.width),
            height: Double(frame.height)
        )
    }

    private enum HeldDragRouting: String {
        case pid = "pid"
        case appQueue = "app-queue"
        case externalHid = "external-hid"
    }

    private struct HeldDragPoint: Codable {
        let x: Double
        let y: Double
    }

    private struct HeldDragReady: Codable {
        let pid: Int32
        let windowNumber: Int
        let point: HeldDragPoint
        let upSign: Int32
        let readyAt: Double
        let readyAtWallClock: Double
    }

    private struct HeldDragObservedEvent: Encodable {
        let time: Double
        let phase: UInt
        let momentumPhase: UInt
        let scrollingDeltaY: Double
        let windowNumber: Int
    }

    private struct HeldDragSamplesReport: Encodable {
        let samples: [HeldDragSample]
        let observedEvents: [HeldDragObservedEvent]
    }

    @MainActor
    private final class HeldDragObservedBuffer {
        struct RawEvent {
            let date: Date
            let phase: NSEvent.Phase
            let momentumPhase: NSEvent.Phase
            let deltaY: Double
            let windowNumber: Int
        }

        var events: [RawEvent] = []
    }

    private struct HeldDragSample: Encodable {
        let time: Double
        let stage: String
        let offset: Double
        let docHeight: Double
        let visibleHeight: Double
        let distanceFromBottom: Double
        let topTurn: Int?
    }

    private static func heldDrag(_ model: AppModel, output: URL) async -> Bool {
        let seeded = await seedHistory(
            model,
            threadID: shortThreadID,
            count: 24,
            noteName: "held-drag-seed",
            minSecondsLeft: 40
        )
        guard seeded > 0, secondsLeft() > 32 else {
            note("held-drag-open", "skipped after seeding \(seeded) turns, \(Int(secondsLeft()))s left")
            return false
        }
        guard let opened = await settleHistoryWindow(
            model,
            threadID: shortThreadID,
            maxGap: 2,
            noteName: "held-drag-open",
            turnsSeeded: seeded,
            minSecondsLeft: 28
        ) else { return false }
        let window = opened.window
        let scroll = opened.scroll

        guard verifyPhasedWheelRoundTrip(window: window, scroll: scroll) else { return false }

        let forceExternalHID = CommandLine.arguments.contains("--held-drag-hid")
        let routing: HeldDragRouting
        if forceExternalHID {
            routing = .externalHid
            note("held-drag-route", "external-hid")
        } else if let detected = await detectHeldDragRouting(window: window, scroll: scroll) {
            routing = detected
        } else {
            routing = .externalHid
            note("held-drag-route", "external-hid")
        }

        let upSign: Int32
        if routing == .externalHid {
            // In-app event posting cannot reach the local monitor with a window, so use the
            // AppKit convention: positive scrollWheel deltaY scrolls content toward the top.
            upSign = 1
            note("held-drag-calibrate", "upSign=1 mode=external-hid (AppKit positive-deltaY convention)")
        } else {
            guard let calibrated = await calibratePhasedUpwardSign(window: window, scroll: scroll, routing: routing) else {
                return false
            }
            upSign = calibrated
        }

        guard let startGap = bottomGap(scroll), startGap <= 4 else {
            note("held-drag-pinned", "not pinned at bottom before streaming (gap=\(bottomGap(scroll).map(String.init) ?? "nil"))")
            return false
        }
        note("held-drag-pinned", "pinned at end gap=\(startGap) routing=\(routing.rawValue) upSign=\(upSign)")

        let runtime = model.runtime(for: shortThreadID)
        let pieces = heldDragStreamPieces(count: 115)
        let streamID = "held-drag-stream"
        runtime.rehearseTurn("Continue streaming details while the reader holds the trackpad.")
        note("held-drag-stream-start", "pieces=\(pieces.count) intervalMs=180 loop=\(routing == .externalHid) running=\(runtime.isRunning)")

        let loopStream = routing == .externalHid
        // `--held-drag-quiet-hold` holds the reply still while fingers are down, so the run
        // isolates the drag timeouts from growth (fast growth alone leaves any follow band).
        let quietHold = CommandLine.arguments.contains("--held-drag-quiet-hold")
        let streamGate = HeldDragStreamGate()
        let streamTask = Task { @MainActor in
            var index = 0
            while !Task.isCancelled, secondsLeft() > 3 {
                if !loopStream, index >= pieces.count { break }
                if streamGate.paused {
                    try? await Task.sleep(for: .milliseconds(50))
                    continue
                }
                runtime.rehearse(.messageDelta(id: streamID, text: pieces[index % pieces.count]))
                index += 1
                try? await Task.sleep(for: .milliseconds(180))
            }
        }
        defer { streamTask.cancel() }

        try? await Task.sleep(for: .seconds(2.0))
        let preHoldGap = bottomGap(scroll) ?? -1
        note("held-drag-pre-hold", "streamed=2.0s gap=\(preHoldGap) running=\(runtime.isRunning)")

        if routing == .externalHid {
            return await runExternalHidHeldDrag(
                window: window,
                scroll: scroll,
                runtime: runtime,
                streamID: streamID,
                streamTask: streamTask,
                streamGate: streamGate,
                quietHold: quietHold,
                upSign: upSign,
                output: output
            )
        }

        let sampleOrigin = Date.now
        var samples: [HeldDragSample] = []

        @discardableResult
        func recordSample(stage: String) -> HeldDragSample? {
            guard let sample = captureHeldDragSample(scroll: scroll, since: sampleOrigin, stage: stage) else { return nil }
            samples.append(sample)
            return sample
        }

        func sampleFor(stage: String, seconds: TimeInterval, perTick: (() -> Bool)? = nil) async -> Bool {
            let stageEnd = Date.now.addingTimeInterval(seconds)
            while Date.now < stageEnd, secondsLeft() > 4 {
                if let perTick, !perTick() { return false }
                _ = recordSample(stage: stage)
                try? await Task.sleep(for: .milliseconds(16))
            }
            return true
        }

        if quietHold { streamGate.paused = true }
        guard sendPhasedWheel(routing: routing, window: window, scroll: scroll, deltaY: 0, phase: CGScrollPhase.mayBegin.rawValue) else {
            return false
        }
        note("held-drag-may-begin", "sent deltaY=0 phase=mayBegin")
        _ = await sampleFor(stage: "mayBegin", seconds: 0.05)

        guard sendPhasedWheel(routing: routing, window: window, scroll: scroll, deltaY: 0, phase: CGScrollPhase.began.rawValue) else {
            return false
        }
        note("held-drag-began", "sent deltaY=0 phase=began")
        _ = recordSample(stage: "began")
        try? await Task.sleep(for: .milliseconds(16))

        let dragDelta = upSign * 2
        note("held-drag-up-1", "sending deltaY=\(dragDelta) every ~16ms for 1.5s")
        guard await sampleFor(stage: "drag1", seconds: 1.5, perTick: {
            sendPhasedWheel(routing: routing, window: window, scroll: scroll, deltaY: dragDelta, phase: CGScrollPhase.changed.rawValue)
        }) else { return false }
        note("held-drag-up-1-done", "gap=\(bottomGap(scroll).map(String.init) ?? "nil") topTurn=\(visibleTopTurn(in: scroll).map(String.init) ?? "nil")")

        // Exceeds the old 2s/3s timeouts while fingers stay on the trackpad with no wheel events.
        note("held-drag-pause", "resting 3.0s with no wheel events")
        _ = await sampleFor(stage: "pause", seconds: 3.0)
        note("held-drag-pause-done", "gap=\(bottomGap(scroll).map(String.init) ?? "nil") topTurn=\(visibleTopTurn(in: scroll).map(String.init) ?? "nil")")

        note("held-drag-up-2", "sending deltaY=\(dragDelta) every ~16ms for 1.5s")
        guard await sampleFor(stage: "drag2", seconds: 1.5, perTick: {
            sendPhasedWheel(routing: routing, window: window, scroll: scroll, deltaY: dragDelta, phase: CGScrollPhase.changed.rawValue)
        }) else { return false }
        note("held-drag-up-2-done", "gap=\(bottomGap(scroll).map(String.init) ?? "nil") topTurn=\(visibleTopTurn(in: scroll).map(String.init) ?? "nil")")

        guard sendPhasedWheel(routing: routing, window: window, scroll: scroll, deltaY: 0, phase: CGScrollPhase.ended.rawValue) else {
            return false
        }
        streamGate.paused = false
        note("held-drag-ended", "sent deltaY=0 phase=ended")
        _ = recordSample(stage: "ended")
        try? await Task.sleep(for: .milliseconds(16))

        note("held-drag-post-ended", "streaming 4.0s with no input")
        _ = await sampleFor(stage: "postEnded", seconds: 4.0)
        note("held-drag-post-ended-done", "gap=\(bottomGap(scroll).map(String.init) ?? "nil") running=\(runtime.isRunning)")

        streamTask.cancel()
        await finish(runtime, id: streamID)

        return evaluateHeldDrag(
            samples: samples,
            observedEvents: [],
            routing: routing,
            upSign: upSign,
            output: output,
            requireCompleteSequence: false,
            sequenceComplete: true
        )
    }

    private static func captureHeldDragSample(
        scroll: NSScrollView,
        since origin: Date,
        stage: String
    ) -> HeldDragSample? {
        guard let document = scroll.documentView else { return nil }
        let visible = scroll.documentVisibleRect
        let docHeight = Double(document.bounds.height)
        let offset = Double(visible.minY)
        let visibleHeight = Double(visible.height)
        return HeldDragSample(
            time: Date.now.timeIntervalSince(origin),
            stage: stage,
            offset: offset,
            docHeight: docHeight,
            visibleHeight: visibleHeight,
            distanceFromBottom: docHeight - offset - visibleHeight,
            topTurn: visibleTopTurn(in: scroll)
        )
    }

    private static func runExternalHidHeldDrag(
        window: NSWindow,
        scroll: NSScrollView,
        runtime: ThreadRuntime,
        streamID: String,
        streamTask: Task<Void, Never>,
        streamGate: HeldDragStreamGate,
        quietHold: Bool,
        upSign: Int32,
        output: URL
    ) async -> Bool {
        let buffer = HeldDragObservedBuffer()
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            guard event.window === window else { return event }
            buffer.events.append(HeldDragObservedBuffer.RawEvent(
                date: Date.now,
                phase: event.phase,
                momentumPhase: event.momentumPhase,
                deltaY: Double(event.scrollingDeltaY),
                windowNumber: event.window?.windowNumber ?? event.windowNumber
            ))
            return event
        }
        defer {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }

        let point = timelineCGPoint(window: window, scroll: scroll)
        let ready = HeldDragReady(
            pid: getpid(),
            windowNumber: window.windowNumber,
            point: HeldDragPoint(x: Double(point.x), y: Double(point.y)),
            upSign: upSign,
            readyAt: CACurrentMediaTime(),
            readyAtWallClock: Date().timeIntervalSince1970
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let readyData = try? encoder.encode(ready) else {
            note("held-drag-ready", "failed to encode held-drag-ready.json")
            streamTask.cancel()
            await finish(runtime, id: streamID)
            return false
        }
        do {
            try readyData.write(to: output.appendingPathComponent("held-drag-ready.json"), options: .atomic)
        } catch {
            note("held-drag-ready", "failed to write held-drag-ready.json: \(error.localizedDescription)")
            streamTask.cancel()
            await finish(runtime, id: streamID)
            return false
        }
        note(
            "held-drag-ready",
            String(
                format: "pid=%d window=%d point=(%.1f,%.1f) upSign=%d",
                getpid(), window.windowNumber, point.x, point.y, upSign
            )
        )

        let waitStart = Date.now
        let waitDeadline = waitStart.addingTimeInterval(30.0)
        while Date.now < waitDeadline, secondsLeft() > 8 {
            if buffer.events.contains(where: { !$0.phase.isEmpty }) { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        guard let firstPhased = buffer.events.first(where: { !$0.phase.isEmpty }) else {
            note(
                "held-drag-hid-wait",
                "failed: no phased scrollWheel event matched window=\(window.windowNumber) within 30s (windowEvents=\(buffer.events.count))"
            )
            streamTask.cancel()
            await finish(runtime, id: streamID)
            return false
        }

        let sampleOrigin = firstPhased.date
        if quietHold { streamGate.paused = true }
        note("held-drag-quiet-hold", quietHold ? "stream paused while held" : "off")
        note(
            "held-drag-hid-started",
            String(format: "first phased event phase=%lu after %.2fs", firstPhased.phase.rawValue, firstPhased.date.timeIntervalSince(waitStart))
        )

        var samples: [HeldDragSample] = []
        let holdDeadline = Date.now.addingTimeInterval(20.0)
        var endEvent: HeldDragObservedBuffer.RawEvent?
        while Date.now < holdDeadline, secondsLeft() > 6 {
            if let sample = captureHeldDragSample(scroll: scroll, since: sampleOrigin, stage: "hid") {
                samples.append(sample)
            }
            if let foundEnd = buffer.events.first(where: {
                $0.date >= firstPhased.date && ($0.phase.contains(.ended) || $0.phase.contains(.cancelled))
            }) {
                endEvent = foundEnd
                break
            }
            try? await Task.sleep(for: .milliseconds(16))
        }

        if let endEvent {
            note("held-drag-ended", "observed phase=\(endEvent.phase.rawValue) events=\(buffer.events.count)")
            streamGate.paused = false
            note("held-drag-post-ended", "streaming 4.0s with no input")
            let postDeadline = Date.now.addingTimeInterval(4.0)
            while Date.now < postDeadline, secondsLeft() > 4 {
                if let sample = captureHeldDragSample(scroll: scroll, since: sampleOrigin, stage: "postEnded") {
                    samples.append(sample)
                }
                try? await Task.sleep(for: .milliseconds(16))
            }
            note("held-drag-post-ended-done", "gap=\(bottomGap(scroll).map(String.init) ?? "nil") running=\(runtime.isRunning)")
        } else {
            note("held-drag-hid-ended", "failed: timed out after 20s waiting for ended/cancelled phase (events=\(buffer.events.count))")
        }

        streamTask.cancel()
        await finish(runtime, id: streamID)

        let observedEvents = buffer.events.map { event in
            HeldDragObservedEvent(
                time: event.date.timeIntervalSince(sampleOrigin),
                phase: event.phase.rawValue,
                momentumPhase: event.momentumPhase.rawValue,
                scrollingDeltaY: event.deltaY,
                windowNumber: event.windowNumber
            )
        }.sorted { $0.time < $1.time }

        let derived = deriveHeldDragStages(samples: samples, observedEvents: observedEvents)
        return evaluateHeldDrag(
            samples: derived.samples,
            observedEvents: observedEvents,
            routing: .externalHid,
            upSign: upSign,
            output: output,
            requireCompleteSequence: true,
            sequenceComplete: derived.sequenceComplete
        )
    }

    private static func deriveHeldDragStages(
        samples: [HeldDragSample],
        observedEvents: [HeldDragObservedEvent]
    ) -> (samples: [HeldDragSample], sequenceComplete: Bool) {
        let phased = observedEvents.filter { $0.phase != 0 }
        guard let holdStartIdx = phased.firstIndex(where: {
            let phase = NSEvent.Phase(rawValue: $0.phase)
            return phase.contains(.mayBegin) || phase.contains(.began)
        }) else {
            return (samples, false)
        }
        let holdStartTime = phased[holdStartIdx].time
        let holdEndIdx = phased[holdStartIdx...].firstIndex(where: {
            let phase = NSEvent.Phase(rawValue: $0.phase)
            return phase.contains(.ended) || phase.contains(.cancelled)
        })
        let holdEndTime = holdEndIdx.map { phased[$0].time }

        let heldLastIdx = holdEndIdx ?? (phased.count - 1)
        var pauses: [(start: Double, end: Double)] = []
        if heldLastIdx > holdStartIdx {
            for idx in holdStartIdx..<heldLastIdx {
                let start = phased[idx].time
                let end = phased[idx + 1].time
                if end - start > 1.0 {
                    pauses.append((start: start, end: end))
                }
            }
        }

        let heldSlice = phased[holdStartIdx...heldLastIdx]
        let beganTime = heldSlice.first(where: { NSEvent.Phase(rawValue: $0.phase).contains(.began) })?.time
        let firstChangedTime = heldSlice.first(where: { NSEvent.Phase(rawValue: $0.phase).contains(.changed) })?.time
        let endedSampleIdx = holdEndTime.flatMap { endTime in samples.firstIndex(where: { $0.time >= endTime }) }

        let derived = samples.enumerated().map { idx, sample in
            let t = sample.time
            let stage: String
            if t < holdStartTime {
                stage = "preHold"
            } else if let endedSampleIdx, idx > endedSampleIdx {
                stage = "postEnded"
            } else if let endedSampleIdx, idx == endedSampleIdx {
                stage = "ended"
            } else if pauses.contains(where: { t > $0.start && t < $0.end }) {
                stage = "pause"
            } else if let firstChangedTime, t >= firstChangedTime {
                if let firstPause = pauses.first, t >= firstPause.end {
                    stage = "drag2"
                } else {
                    stage = "drag1"
                }
            } else if let beganTime, t >= beganTime {
                stage = "began"
            } else {
                stage = "mayBegin"
            }
            return HeldDragSample(
                time: sample.time,
                stage: stage,
                offset: sample.offset,
                docHeight: sample.docHeight,
                visibleHeight: sample.visibleHeight,
                distanceFromBottom: sample.distanceFromBottom,
                topTurn: sample.topTurn
            )
        }

        // Both drag bursts around one pause long enough to outlast the old 2s stillness timeout.
        let fullPause = pauses.first { $0.end - $0.start >= 2.8 }
        let drag1Seen = fullPause.map { pause in heldSlice.contains { NSEvent.Phase(rawValue: $0.phase).contains(.changed) && $0.time <= pause.start } } ?? false
        let drag2Seen = fullPause.map { pause in heldSlice.contains { NSEvent.Phase(rawValue: $0.phase).contains(.changed) && $0.time >= pause.end } } ?? false
        let sequenceComplete = holdEndTime != nil && firstChangedTime != nil && drag1Seen && drag2Seen
        return (derived, sequenceComplete)
    }

    private static func evaluateHeldDrag(
        samples: [HeldDragSample],
        observedEvents: [HeldDragObservedEvent],
        routing: HeldDragRouting,
        upSign: Int32,
        output: URL,
        requireCompleteSequence: Bool,
        sequenceComplete: Bool
    ) -> Bool {
        let samplesFile = "held-drag-samples.json"
        let report = HeldDragSamplesReport(samples: samples, observedEvents: observedEvents)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let encoded = try? encoder.encode(report) {
            try? encoded.write(to: output.appendingPathComponent(samplesFile), options: .atomic)
        }

        let holdStages: Set<String> = ["mayBegin", "began", "drag1", "pause", "drag2", "ended"]
        guard samples.count >= 2 else {
            note("held-drag-verdict", "verdict=FAIL insufficient samples=\(samples.count) routing=\(routing.rawValue)")
            return false
        }
        var snapBackViolations = 0
        var maxSnapDrop = 0.0
        for index in 1..<samples.count {
            let prev = samples[index - 1]
            let curr = samples[index]
            guard holdStages.contains(prev.stage), holdStages.contains(curr.stage) else { continue }
            let drop = prev.distanceFromBottom - curr.distanceFromBottom
            if drop > 2.0 {
                snapBackViolations += 1
                if drop > maxSnapDrop { maxSnapDrop = drop }
            }
        }

        let drag1StartIndex = samples.firstIndex(where: { $0.stage == "drag1" }) ?? samples.count
        let firstAwayIndex = samples.indices.first(where: { $0 >= drag1StartIndex && samples[$0].distanceFromBottom > 1.0 })
        let leftBottom = firstAwayIndex != nil
        var returnToBottomViolations = 0
        if let firstAwayIndex {
            for index in (firstAwayIndex + 1)..<samples.count where samples[index].distanceFromBottom <= 1.0 {
                returnToBottomViolations += 1
            }
        }

        let pauseSamples = samples.filter { $0.stage == "pause" }
        var pauseTopJumpViolations = 0
        var pauseOffsetSpan = 0.0
        if let pauseStart = pauseSamples.first?.time {
            let settledPause = pauseSamples.filter { $0.time - pauseStart >= 0.05 }
            let checkedPause = settledPause.isEmpty ? pauseSamples : settledPause
            if let baselineOffset = checkedPause.first?.offset {
                let baselineTopTurn = checkedPause.compactMap(\.topTurn).first
                var minOffset = baselineOffset
                var maxOffset = baselineOffset
                for sample in checkedPause {
                    if sample.offset < minOffset { minOffset = sample.offset }
                    if sample.offset > maxOffset { maxOffset = sample.offset }
                    let turnChanged = baselineTopTurn != nil && sample.topTurn != nil && sample.topTurn != baselineTopTurn
                    let offsetJumped = abs(sample.offset - baselineOffset) > 4.0
                    if turnChanged || offsetJumped {
                        pauseTopJumpViolations += 1
                    }
                }
                pauseOffsetSpan = maxOffset - minOffset
            }
        }

        let docGrowth = (samples.last?.docHeight ?? 0) - (samples.first?.docHeight ?? 0)
        let minGapAfterAway = firstAwayIndex.flatMap { idx in samples[idx...].map(\.distanceFromBottom).min() } ?? -1
        let maxGap = samples.map(\.distanceFromBottom).max() ?? -1
        let passed = snapBackViolations == 0
            && returnToBottomViolations == 0
            && pauseTopJumpViolations == 0
            && leftBottom
            && docGrowth > 20
            && (!requireCompleteSequence || sequenceComplete)

        let verdict = passed ? "PASS" : "FAIL"
        let detail = String(
            format: "verdict=%@ routing=%@ upSign=%d samples=%d observedEvents=%d sequenceComplete=%@ snapBackViolations=%d maxSnapDrop=%.2fpt returnToBottomViolations=%d leftBottom=%@ pauseTopJumpViolations=%d pauseOffsetSpan=%.2fpt minGapAfterAway=%.2fpt maxGap=%.2fpt docGrowth=%.1fpt",
            verdict, routing.rawValue, upSign, samples.count, observedEvents.count,
            sequenceComplete ? "true" : "false", snapBackViolations, maxSnapDrop,
            returnToBottomViolations, leftBottom ? "true" : "false", pauseTopJumpViolations,
            pauseOffsetSpan, minGapAfterAway, maxGap, docGrowth
        )
        WebsiteCaptures.log("stress held-drag-verdict: \(detail)")
        phases.append([
            "name": "held-drag-verdict",
            "verdict": verdict,
            "detail": detail,
            "routingMode": routing.rawValue,
            "upSign": String(upSign),
            "samples": String(samples.count),
            "observedEvents": String(observedEvents.count),
            "sequenceComplete": sequenceComplete ? "true" : "false",
            "samplesFile": samplesFile,
            "snapBackViolations": String(snapBackViolations),
            "maxSnapDropPt": String(format: "%.2f", maxSnapDrop),
            "returnToBottomViolations": String(returnToBottomViolations),
            "leftBottom": leftBottom ? "true" : "false",
            "pauseTopJumpViolations": String(pauseTopJumpViolations),
            "pauseOffsetSpanPt": String(format: "%.2f", pauseOffsetSpan),
            "minGapAfterAwayPt": String(format: "%.2f", minGapAfterAway),
            "maxGapPt": String(format: "%.2f", maxGap),
            "docGrowthPt": String(format: "%.1f", docGrowth),
        ])
        saveReport(listFiles: false)
        return passed
    }

    private static func verifyPhasedWheelRoundTrip(window: NSWindow, scroll: NSScrollView) -> Bool {
        let expected: [(raw: UInt32, phase: NSEvent.Phase, name: String)] = [
            (CGScrollPhase.mayBegin.rawValue, .mayBegin, "mayBegin"),
            (CGScrollPhase.began.rawValue, .began, "began"),
            (CGScrollPhase.changed.rawValue, .changed, "changed"),
            (CGScrollPhase.ended.rawValue, .ended, "ended"),
        ]
        for item in expected {
            guard let built = phasedWheelEvent(window: window, scroll: scroll, deltaY: item.raw == CGScrollPhase.changed.rawValue ? 2 : 0, phase: item.raw) else {
                note("held-drag-phase-check", "failed to build \(item.name) event")
                return false
            }
            if built.ns.phase != item.phase || !built.ns.momentumPhase.isEmpty || !built.ns.hasPreciseScrollingDeltas {
                note(
                    "held-drag-phase-check",
                    "mismatch for \(item.name): got phase=\(built.ns.phase.rawValue) expected=\(item.phase.rawValue) momentum=\(built.ns.momentumPhase.rawValue) precise=\(built.ns.hasPreciseScrollingDeltas)"
                )
                return false
            }
        }
        note("held-drag-phase-check", "verified mayBegin/began/changed/ended round-trip")
        return true
    }

    @MainActor
    private final class RoutingProbe {
        var sawEvent = false
        var matchedWindow = false
        var matchedPhase = false
        var observedWindowNumber: Int?

        func reset() {
            sawEvent = false
            matchedWindow = false
            matchedPhase = false
            observedWindowNumber = nil
        }
    }

    private static func detectHeldDragRouting(window: NSWindow, scroll: NSScrollView) async -> HeldDragRouting? {
        let probe = RoutingProbe()
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            probe.sawEvent = true
            probe.observedWindowNumber = event.window?.windowNumber ?? event.windowNumber
            if event.window === window { probe.matchedWindow = true }
            if event.phase == .mayBegin { probe.matchedPhase = true }
            return event
        }
        defer {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }

        guard let pidProbe = phasedWheelEvent(window: window, scroll: scroll, deltaY: 0, phase: CGScrollPhase.mayBegin.rawValue) else {
            note("held-drag-route", "failed to build probe event")
            return nil
        }
        pidProbe.cg.postToPid(getpid())
        let pidDeadline = Date.now.addingTimeInterval(0.3)
        while Date.now < pidDeadline, !(probe.sawEvent && probe.matchedWindow && probe.matchedPhase) {
            try? await Task.sleep(for: .milliseconds(10))
        }
        if probe.sawEvent && probe.matchedWindow && probe.matchedPhase {
            if let endProbe = phasedWheelEvent(window: window, scroll: scroll, deltaY: 0, phase: CGScrollPhase.ended.rawValue) {
                endProbe.cg.postToPid(getpid())
                try? await Task.sleep(for: .milliseconds(60))
            }
            note("held-drag-route", "mode=pid window=\(window.windowNumber)")
            return .pid
        }

        probe.reset()
        guard let queueProbe = phasedWheelEvent(window: window, scroll: scroll, deltaY: 0, phase: CGScrollPhase.mayBegin.rawValue) else {
            note("held-drag-route", "failed to build app-queue probe event")
            return nil
        }
        NSApp.postEvent(queueProbe.ns, atStart: false)
        let queueDeadline = Date.now.addingTimeInterval(0.3)
        while Date.now < queueDeadline, !(probe.sawEvent && probe.matchedWindow && probe.matchedPhase) {
            try? await Task.sleep(for: .milliseconds(10))
        }
        if probe.sawEvent && probe.matchedWindow && probe.matchedPhase {
            if let endProbe = phasedWheelEvent(window: window, scroll: scroll, deltaY: 0, phase: CGScrollPhase.ended.rawValue) {
                NSApp.postEvent(endProbe.ns, atStart: false)
                try? await Task.sleep(for: .milliseconds(60))
            }
            note("held-drag-route", "mode=app-queue window=\(window.windowNumber)")
            return .appQueue
        }

        note(
            "held-drag-route",
            "failed: neither pid nor app-queue delivered phased scrollWheel to local monitor (sawEvent=\(probe.sawEvent) matchedWindow=\(probe.matchedWindow) matchedPhase=\(probe.matchedPhase) observedWin=\(probe.observedWindowNumber.map(String.init) ?? "nil") expectedWin=\(window.windowNumber))"
        )
        return nil
    }

    private static func calibratePhasedUpwardSign(
        window: NSWindow,
        scroll: NSScrollView,
        routing: HeldDragRouting
    ) async -> Int32? {
        let startGap = bottomGap(scroll) ?? 0
        for candidateSign: Int32 in [1, -1] {
            let delta = candidateSign * 120
            _ = sendPhasedWheel(routing: routing, window: window, scroll: scroll, deltaY: 0, phase: CGScrollPhase.began.rawValue)
            for _ in 0..<3 {
                _ = sendPhasedWheel(routing: routing, window: window, scroll: scroll, deltaY: delta, phase: CGScrollPhase.changed.rawValue)
                try? await Task.sleep(for: .milliseconds(20))
            }
            _ = sendPhasedWheel(routing: routing, window: window, scroll: scroll, deltaY: 0, phase: CGScrollPhase.ended.rawValue)
            try? await Task.sleep(for: .milliseconds(150))
            let gap = bottomGap(scroll) ?? startGap
            if gap > startGap + 12 {
                var resetSteps = 0
                while let current = bottomGap(scroll), current > 2, resetSteps < 10 {
                    _ = sendPhasedWheel(routing: routing, window: window, scroll: scroll, deltaY: 0, phase: CGScrollPhase.began.rawValue)
                    for _ in 0..<3 {
                        _ = sendPhasedWheel(routing: routing, window: window, scroll: scroll, deltaY: -candidateSign * 160, phase: CGScrollPhase.changed.rawValue)
                        try? await Task.sleep(for: .milliseconds(16))
                    }
                    _ = sendPhasedWheel(routing: routing, window: window, scroll: scroll, deltaY: 0, phase: CGScrollPhase.ended.rawValue)
                    try? await Task.sleep(for: .milliseconds(120))
                    resetSteps += 1
                }
                // Let recent wheel input and scroll phase settle before starting the run.
                try? await Task.sleep(for: .milliseconds(400))
                note("held-drag-calibrate", "upSign=\(candidateSign) mode=\(routing.rawValue) probeGap \(startGap)->\(gap) resetGap=\(bottomGap(scroll).map(String.init) ?? "nil")")
                return candidateSign
            }
        }
        note("held-drag-calibrate", "failed: viewport did not move under \(routing.rawValue) (startGap=\(startGap))")
        return nil
    }

    @discardableResult
    private static func sendPhasedWheel(
        routing: HeldDragRouting,
        window: NSWindow,
        scroll: NSScrollView,
        deltaY: Int32,
        phase: UInt32
    ) -> Bool {
        guard let built = phasedWheelEvent(window: window, scroll: scroll, deltaY: deltaY, phase: phase) else {
            note("held-drag-phase-check", "failed to build event deltaY=\(deltaY) phase=\(phase)")
            return false
        }
        let expected: NSEvent.Phase = switch phase {
        case CGScrollPhase.mayBegin.rawValue: .mayBegin
        case CGScrollPhase.began.rawValue: .began
        case CGScrollPhase.changed.rawValue: .changed
        case CGScrollPhase.ended.rawValue: .ended
        default: []
        }
        guard built.ns.phase == expected else {
            note("held-drag-phase-check", "phase mismatch raw=\(phase) got=\(built.ns.phase.rawValue) expected=\(expected.rawValue)")
            return false
        }
        switch routing {
        case .pid:
            built.cg.postToPid(getpid())
        case .appQueue:
            NSApp.postEvent(built.ns, atStart: false)
        case .externalHid:
            return false
        }
        return true
    }

    private static func heldDragStreamPieces(count: Int) -> [String] {
        (1...count).map { index in
            if index.isMultiple(of: 6) {
                "\n\n### Stream step \(index)\n\n"
            } else if index.isMultiple(of: 3) {
                "Streamed sentence \(index) grows the active reply below the held viewport so any snap back toward the end shows up immediately. "
            } else {
                "Line \(index): keeping the reader anchored on an earlier turn while the bottom of the timeline keeps appending markdown text. "
            }
        }
    }

    private static func settleHistoryWindow(
        _ model: AppModel,
        threadID: UUID,
        maxGap: Int,
        noteName: String,
        turnsSeeded: Int,
        minSecondsLeft: TimeInterval
    ) async -> (window: NSWindow, scroll: NSScrollView)? {
        model.selectedThreadID = threadID
        // Let ThreadTimeline's initial `.task` finish its 250ms open page + 1.6s window settle.
        try? await Task.sleep(for: .milliseconds(2100))

        let settleDeadline = Date.now.addingTimeInterval(3.0)
        var settledChecks = 0
        while Date.now < settleDeadline, secondsLeft() > minSecondsLeft {
            if let window = appWindow(), let scroll = timelineScroll(in: window),
               let docHeight = scroll.documentView?.bounds.height,
               docHeight > scroll.bounds.height * 1.5,
               let gap = bottomGap(scroll), gap <= maxGap {
                settledChecks += 1
                if settledChecks >= 2 { break }
            } else {
                settledChecks = 0
            }
            try? await Task.sleep(for: .milliseconds(80))
        }

        guard let window = appWindow(), let scroll = timelineScroll(in: window) else {
            let summary = appWindow().map(scrollSummary) ?? "no window"
            note(noteName, "no timeline scroll view (\(summary))")
            return nil
        }

        let openOffset = scrollOffset(scroll)
        let openHeight = Int((scroll.documentView?.bounds.height ?? 0).rounded())
        let openGap = bottomGap(scroll) ?? -1
        let openTopTurn = visibleTopTurn(in: scroll).map(String.init) ?? "unknown"
        let openLowestTurn = mountedLowestTurn(in: scroll).map(String.init) ?? "unknown"
        note(noteName, "turns=\(turnsSeeded) offset=\(openOffset) docHeight=\(openHeight) gap=\(openGap) topTurn=\(openTopTurn) lowestTurn=\(openLowestTurn)")
        return (window, scroll)
    }

    private static func openAndSettleHistory(
        _ model: AppModel,
        threadID: UUID,
        recorder: Recorder,
        stage: Stage,
        shotName: String,
        noteName: String,
        turnsSeeded: Int,
        minSecondsLeft: TimeInterval
    ) async -> (window: NSWindow, scroll: NSScrollView)? {
        guard let settled = await settleHistoryWindow(
            model,
            threadID: threadID,
            maxGap: 8,
            noteName: noteName,
            turnsSeeded: turnsSeeded,
            minSecondsLeft: minSecondsLeft
        ) else { return nil }
        await shoot(recorder, stage, shotName)
        return settled
    }

    private static func seedHistory(
        _ model: AppModel,
        threadID: UUID,
        count: Int,
        noteName: String,
        minSecondsLeft: TimeInterval
    ) async -> Int {
        let runtime = model.runtime(for: threadID)
        let ready = Date.now.addingTimeInterval(5)
        while runtime.isLoadingHistory, Date.now < ready {
            try? await Task.sleep(for: .milliseconds(40))
        }
        var seeded = 0
        for turn in 1...count {
            guard secondsLeft() > minSecondsLeft else { break }
            await speak(
                runtime,
                id: "history-\(turn)",
                user: historyQuestion(turn),
                answer: historyAnswer(turn)
            )
            seeded = turn
        }
        note(noteName, "\(seeded) of \(count) turns on \(threadID.uuidString) running=\(runtime.isRunning)")
        return seeded
    }

    private static func historyQuestion(_ turn: Int) -> String {
        if !turn.isMultiple(of: 2) {
            return "Turn \(turn) - question: Does row \(turn) keep the 14pt top inset?"
        } else if turn.isMultiple(of: 4) {
            return "Turn \(turn) - question: Walk the anchor math and inset alignment for page check \(turn), then show the constraint lines."
        } else {
            return "Turn \(turn) - question: Summarize the strip spacing and clip bounds behavior on check \(turn)."
        }
    }

    private static func historyAnswer(_ turn: Int) -> String {
        if !turn.isMultiple(of: 2) {
            return "Turn \(turn) - answer: Keep 14pt on the top edge of row \(turn) so it matches the leading inset."
        }
        if turn.isMultiple(of: 4) {
            return [
                "Turn \(turn) - answer: Long layout note for check \(turn). When an older page lands above the viewport, the anchor row returns to its prior viewport offset minus any wheel movement recorded in flight.",
                "",
                "- `attachmentInset` stays 14pt on both top and leading edges",
                "- `restoreDelta` subtracts `readerDelta` accumulated from wheel input",
                "- `mountedWindow` keeps offscreen blocks in measured spacers",
                "",
                "Paragraph A (turn \(turn)). Measuring newly inserted rows while holding the bottom anchor avoids pushing visible text out from under a resting reader, and the single restore pass moves the clip view once all row frames in the page report.",
                "",
                "Paragraph B (turn \(turn)). Keeping prose widths stable across the column prevents secondary height churn after the history page settles.",
                "",
                "```swift",
                "let delta = HistoryAnchorMath.restoreDelta(",
                "    anchorMinY: frame.minY,",
                "    anchorOffset: request.anchorOffset,",
                "    readerDelta: tracking.historyReaderDelta",
                ")",
                "```",
                "",
                "Turn \(turn) - answer closing: clip restoration finishes before clearing `historyLoadPending` on check \(turn).",
            ].joined(separator: "\n")
        }
        return [
            "Turn \(turn) - answer: Medium check \(turn) keeps the strip inset even on both edges while scrolling upward.",
            "",
            "- leading edge uses 14pt padding",
            "- top edge matches the 14pt inset instead of stack spacing",
            "- scroll anchor stays pinned only within 48pt of the end",
            "",
            "Turn \(turn) - answer note: verify the pill clears smoothly once earlier rows mount above row \(turn).",
        ].joined(separator: "\n")
    }

    private static func calibrateUpwardWheel(
        window: NSWindow,
        scroll: NSScrollView
    ) async -> (direct: Bool, upSign: Int32, mode: String) {
        let startGap = bottomGap(scroll) ?? 0
        for candidateSign: Int32 in [1, -1] {
            let delta = candidateSign * 160
            guard let probe = wheelEvent(window: window, scroll: scroll, deltaY: delta) else { continue }
            probe.cgEvent?.postToPid(getpid())
            try? await Task.sleep(for: .milliseconds(60))
            for _ in 0..<2 {
                if let extra = wheelEvent(window: window, scroll: scroll, deltaY: delta) {
                    extra.cgEvent?.postToPid(getpid())
                }
                try? await Task.sleep(for: .milliseconds(30))
            }
            try? await Task.sleep(for: .milliseconds(140))
            let gap = bottomGap(scroll) ?? startGap
            if gap > startGap + 12 {
                note("history-wheel", "pid-posted sign=\(candidateSign) gap \(startGap)->\(gap) window=\(window.windowNumber)")
                return (false, candidateSign, "pid-posted")
            }
        }
        let afterPosted = bottomGap(scroll) ?? startGap
        for candidateSign: Int32 in [1, -1] {
            let delta = candidateSign * 160
            guard let probe = wheelEvent(window: window, scroll: scroll, deltaY: delta) else { continue }
            scroll.scrollWheel(with: probe)
            try? await Task.sleep(for: .milliseconds(40))
            scroll.scrollWheel(with: probe)
            try? await Task.sleep(for: .milliseconds(140))
            let directGap = bottomGap(scroll) ?? afterPosted
            if directGap > afterPosted + 12 {
                note("history-wheel", "direct-fallback sign=\(candidateSign) postedGap=\(afterPosted) directGap=\(directGap)")
                return (true, candidateSign, "direct-fallback")
            }
        }
        note("history-wheel", "unmoved startGap=\(startGap) afterPosted=\(afterPosted)")
        return (true, 1, "direct-fallback-unmoved")
    }

    private static func sendWheel(_ deltaY: Int32, window: NSWindow, scroll: NSScrollView, direct: Bool) {
        guard let event = wheelEvent(window: window, scroll: scroll, deltaY: deltaY) else { return }
        if direct {
            scroll.scrollWheel(with: event)
        } else {
            event.cgEvent?.postToPid(getpid())
        }
    }

    private static func scrollOffset(_ scroll: NSScrollView) -> Int {
        max(0, Int((scroll.contentView.bounds.minY + scroll.contentInsets.top).rounded()))
    }

    private static func unobstructedViewportRect(in scroll: NSScrollView) -> NSRect {
        let visible = scroll.documentVisibleRect
        let insets = scroll.contentInsets
        let height = visible.height - insets.top - insets.bottom
        guard height > 60 else { return visible }
        return NSRect(x: visible.minX, y: visible.minY + insets.top, width: visible.width, height: height)
    }

    private static func visibleTopTurn(in scroll: NSScrollView) -> Int? {
        guard let document = scroll.documentView else { return nil }
        let viewport = unobstructedViewportRect(in: scroll)
        var lowest: Int?
        for view in findAll(NSTextView.self, in: document) {
            guard !(view is ComposerNSTextView),
                  !view.isHiddenOrHasHiddenAncestor,
                  view.bounds.width > 1, view.bounds.height > 1 else { continue }
            let frame = view.convert(view.bounds, to: document)
            let overlap = frame.intersection(viewport)
            guard !overlap.isNull, !overlap.isEmpty, overlap.height > 2, overlap.width > 2 else { continue }
            for turn in parseTurnNumbers(in: view.string) {
                if let current = lowest {
                    if turn < current { lowest = turn }
                } else {
                    lowest = turn
                }
            }
        }
        return lowest
    }

    private static func mountedLowestTurn(in scroll: NSScrollView) -> Int? {
        guard let document = scroll.documentView else { return nil }
        var lowest: Int?
        for view in findAll(NSTextView.self, in: document) {
            guard !(view is ComposerNSTextView),
                  !view.isHiddenOrHasHiddenAncestor,
                  view.bounds.width > 1, view.bounds.height > 1 else { continue }
            for turn in parseTurnNumbers(in: view.string) {
                if let current = lowest {
                    if turn < current { lowest = turn }
                } else {
                    lowest = turn
                }
            }
        }
        return lowest
    }

    private static func parseTurnNumbers(in text: String) -> [Int] {
        var numbers: [Int] = []
        var remainder = text[...]
        while let range = remainder.range(of: "Turn ") {
            let afterTurn = remainder[range.upperBound...]
            let digits = afterTurn.prefix { $0.isWholeNumber && $0.isASCII }
            if !digits.isEmpty {
                let afterDigits = afterTurn[digits.endIndex...]
                if afterDigits.hasPrefix(" -"), let value = Int(digits) {
                    numbers.append(value)
                }
            }
            remainder = afterTurn
        }
        return numbers
    }

    /// Three finished turns: a short pair, a long markdown body, then a short closer,
    /// so the column rests on mixed row heights.
    private static func seed(_ model: AppModel) async {
        let runtime = model.runtime(for: longThreadID)
        let ready = Date.now.addingTimeInterval(5)
        while runtime.isLoadingHistory, Date.now < ready {
            try? await Task.sleep(for: .milliseconds(40))
        }
        await speak(runtime, id: "stress-short", user: "How far from the top?", answer: "Use the same 14pt on the top.")
        await speak(runtime, id: "stress-long", user: "Walk every inset in the strip, and say which ones match.", answer: longBody())
        await speak(runtime, id: "stress-closer", user: "One line, then stop.", answer: "The build is the check.")
        try? await Task.sleep(for: .milliseconds(500))
        note("seed", "three turns on \(longThreadID.uuidString) running=\(runtime.isRunning)")
    }

    /// One frame every 5 seconds for 60 seconds, this process's window only.
    /// `Recorder` already refuses any window that is not ours.
    private static func pinnedStill(_ recorder: Recorder, _ stage: Stage) async {
        let span = min(60.0, max(0, secondsLeft() - 90))
        guard span >= 5 else {
            note("pinned-still", "skipped, \(Int(secondsLeft()))s left")
            return
        }
        let gapBefore = appWindow().flatMap { timelineScroll(in: $0) }.flatMap { bottomGap($0) }
        await shoot(recorder, stage, "pinned-before")
        let motion = Task { await recordWindow("pinned-motion", seconds: 12) }
        let start = Date.now
        var frames = 0
        while Date.now.timeIntervalSince(start) < span, secondsLeft() > 20 {
            let slot = start.addingTimeInterval(Double(frames) * 5)
            let pause = slot.timeIntervalSinceNow
            if pause > 0.05 { try? await Task.sleep(for: .seconds(pause)) }
            if Date.now.timeIntervalSince(start) >= span { break }
            let gap = appWindow().flatMap { timelineScroll(in: $0) }.flatMap { bottomGap($0) }
            WebsiteCaptures.log("stress pinned \(frames) gap=\(gap.map(String.init) ?? "nil")")
            await shoot(recorder, stage, String(format: "pinned-%02d", frames))
            frames += 1
        }
        let rest = span - Date.now.timeIntervalSince(start)
        if rest > 0.05 { try? await Task.sleep(for: .seconds(rest)) }
        let gapAfter = appWindow().flatMap(timelineScroll).flatMap(bottomGap)
        await shoot(recorder, stage, "pinned-after")
        let elapsed = Date.now.timeIntervalSince(start)
        await motion.value
        note("pinned-still", String(format: "%.1fs of %.0fs, %d frames every 5s, gap %@ -> %@, this process window only", elapsed, span, frames, gapBefore.map(String.init) ?? "nil", gapAfter.map(String.init) ?? "nil"))
    }

    /// A rehearsed reply that keeps growing, then a finished turn sitting still.
    private static func grow(_ model: AppModel, _ recorder: Recorder, _ stage: Stage) async {
        guard secondsLeft() > 25 else {
            note("grow", "skipped, \(Int(secondsLeft()))s left")
            return
        }
        model.selectedThreadID = longThreadID
        let runtime = model.runtime(for: longThreadID)
        runtime.rehearseTurn("Keep going on the insets.")
        let pieces = growthPieces()
        let started = Date.now
        for (index, piece) in pieces.enumerated() {
            guard secondsLeft() > 20 else { break }
            runtime.rehearse(.messageDelta(id: "stress-grow", text: piece))
            try? await Task.sleep(for: .milliseconds(650))
            if index == 2 { await shoot(recorder, stage, "grow-start") }
        }
        let streamed = Date.now.timeIntervalSince(started)
        try? await Task.sleep(for: .milliseconds(250))
        await shoot(recorder, stage, "grow-end")
        await finish(runtime, id: "stress-grow")
        let motion = Task { await recordWindow("grow-motion", seconds: 12) }
        let still: TimeInterval = min(15, max(0, secondsLeft() - 70))
        if still > 0.2 { try? await Task.sleep(for: .seconds(still)) }
        await shoot(recorder, stage, "grow-still")
        await motion.value
        note("grow", String(format: "streamed %.1fs across %d pieces, then still %.1fs, running=%@", streamed, pieces.count, still, runtime.isRunning ? "true" : "false"))
    }

    /// Wheel events at the timeline. The sign is whichever direction leaves the bottom.
    /// A direct `scrollWheel` is only a labeled fallback when the posted event does not move.
    private static func scrollAway(_ recorder: Recorder, _ stage: Stage) async {
        guard secondsLeft() > 20 else {
            note("scroll", "skipped, \(Int(secondsLeft()))s left")
            return
        }
        guard let window = appWindow() else {
            note("scroll", "no window")
            return
        }
        var scroll = timelineScroll(in: window)
        if scroll == nil {
            try? await Task.sleep(for: .milliseconds(400))
            scroll = timelineScroll(in: window)
        }
        guard let scroll else {
            note("scroll", "no timeline scroll view (\(scrollSummary(in: window)))")
            return
        }
        let startGap = bottomGap(scroll) ?? 0
        guard let probeEvent = wheelEvent(window: window, scroll: scroll, deltaY: 160) else {
            note("scroll", "could not build a wheel event")
            return
        }
        probeEvent.cgEvent?.postToPid(getpid())
        try? await Task.sleep(for: .milliseconds(80))
        for _ in 0..<3 {
            if let event = wheelEvent(window: window, scroll: scroll, deltaY: 160) {
                event.cgEvent?.postToPid(getpid())
            }
            try? await Task.sleep(for: .milliseconds(40))
        }
        try? await Task.sleep(for: .milliseconds(150))
        var gap = bottomGap(scroll) ?? startGap
        var how = "pid-posted dy=\(probeEvent.scrollingDeltaY) target-window=\(window.windowNumber)"
        var directWheel = false
        var away: Int32 = gap > startGap + 12 ? 160 : -160
        if abs(gap - startGap) <= 12 {
            scroll.scrollWheel(with: probeEvent)
            try? await Task.sleep(for: .milliseconds(150))
            let direct = bottomGap(scroll) ?? gap
            how += " posted-gap \(startGap)->\(gap) direct-gap \(direct)"
            if abs(direct - startGap) > 12 {
                directWheel = true
                how += " direct-fallback"
                away = direct > startGap ? 160 : -160
                gap = direct
            } else {
                how += " viewport did not move"
            }
        }
        var steps = 0
        while let current = bottomGap(scroll), current < 400, steps < 10, secondsLeft() > 18 {
            await burst(away, times: 4, window: window, scroll: scroll, direct: directWheel)
            steps += 1
        }
        let awayGap = bottomGap(scroll)
        try? await Task.sleep(for: .seconds(min(8, max(0, secondsLeft() - 16))))
        await shoot(recorder, stage, "scroll-up")
        var backSteps = 0
        while let current = bottomGap(scroll), current > 48, backSteps < 14, secondsLeft() > 12 {
            await burst(-away, times: 4, window: window, scroll: scroll, direct: directWheel)
            backSteps += 1
        }
        try? await Task.sleep(for: .seconds(min(4, max(0, secondsLeft() - 10))))
        let backGap = bottomGap(scroll)
        await shoot(recorder, stage, "scroll-back")
        note("scroll", "\(how); away=\(away) steps=\(steps) gap \(startGap) -> \(awayGap.map(String.init) ?? "nil") -> \(backGap.map(String.init) ?? "nil")")
    }

    private static func switchThreads(_ model: AppModel, _ recorder: Recorder, _ stage: Stage) async {
        guard secondsLeft() > 12 else {
            note("switch", "skipped, \(Int(secondsLeft()))s left")
            return
        }
        let count = 22
        for index in 1...count {
            guard secondsLeft() > 8 else {
                note("switch", "stopped at \(index - 1) of \(count)")
                return
            }
            let short = !index.isMultiple(of: 2)
            model.selectedThreadID = short ? shortThreadID : longThreadID
            try? await Task.sleep(for: .milliseconds(index == 1 || index == count ? 450 : 260))
            if index == 1 { await shoot(recorder, stage, "switch-short") }
            if index == count { await shoot(recorder, stage, "switch-long") }
        }
        note("switch", "\(count) switches between \(longThreadID.uuidString) and \(shortThreadID.uuidString), ended on long")
    }

    /// `Stage.resize` sets the frame. It does not drag the resize box, so a live-resize
    /// notification may not fire. The frame change itself is real.
    private static func resizeWindow(_ stage: Stage, _ recorder: Recorder) async {
        guard secondsLeft() > 10 else {
            note("resize", "skipped, \(Int(secondsLeft()))s left")
            return
        }
        let sizes = resizeSizes()
        var seen = Set<String>()
        for index in 0..<22 {
            guard secondsLeft() > 8 else {
                note("resize", "stopped at \(index) of 22, frames \(seen.sorted().joined(separator: " "))")
                return
            }
            stage.resize(to: sizes[index % sizes.count])
            try? await Task.sleep(for: .milliseconds(200))
            if let frame = appWindow()?.frame {
                seen.insert("\(Int(frame.width.rounded()))x\(Int(frame.height.rounded()))")
            }
            if index == 0 { await shoot(recorder, stage, "resize-narrow") }
            if index == 21 { await shoot(recorder, stage, "resize-wide") }
        }
        note("resize", "22 setFrame calls, distinct \(seen.sorted().joined(separator: " "))")
    }

    /// The capture backdrop is ordered over the chat window, then the chat window is
    /// brought back. `Recorder.still` activates the app, so a covered frame is not shot.
    /// `occlusionState` is logged as AppKit reports it. No visibility callback is sent.
    private static func occlude(_ stage: Stage, _ recorder: Recorder) async {
        guard secondsLeft() > 8 else {
            note("occlude", "skipped, \(Int(secondsLeft()))s left")
            return
        }
        var occluded = 0
        var visible = 0
        var firstRaw: UInt?
        let motion = Task { await recordWindow("occlude-motion", seconds: 12) }
        for index in 0..<22 {
            guard secondsLeft() > 6 else {
                note("occlude", "stopped at \(index) of 22, occluded=\(occluded) visible=\(visible)")
                return
            }
            guard let app = appWindow(), let cover = coverWindow(otherThan: app) else {
                note("occlude", "no cover window at \(index)")
                return
            }
            cover.order(.above, relativeTo: app.windowNumber)
            try? await Task.sleep(for: .milliseconds(160))
            if firstRaw == nil { firstRaw = app.occlusionState.rawValue }
            if app.occlusionState.contains(.visible) { visible += 1 } else { occluded += 1 }
            app.makeKeyAndOrderFront(nil)
            cover.order(.below, relativeTo: app.windowNumber)
            NSApp.activate(ignoringOtherApps: true)
            try? await Task.sleep(for: .milliseconds(160))
        }
        await stage.ensureActive()
        await shoot(recorder, stage, "occlude-front")
        await motion.value
        note("occlude", "22 covers, occlusionState occluded=\(occluded) visible=\(visible) firstRaw=\(firstRaw.map(String.init) ?? "nil")")
    }

    /// Shift-return inserts a line. A plain return would send the draft to a provider.
    /// If the key events do not land, the draft is set on the model and the log says so.
    private static func composer(_ model: AppModel, _ recorder: Recorder, _ stage: Stage) async {
        guard secondsLeft() > 6 else {
            note("composer", "skipped, \(Int(secondsLeft()))s left")
            return
        }
        model.selectedThreadID = longThreadID
        await stage.ensureActive()
        try? await Task.sleep(for: .milliseconds(300))
        let runtime = model.runtime(for: longThreadID)
        guard let window = appWindow() else {
            note("composer", "no window")
            return
        }
        guard let textView = findAll(ComposerNSTextView.self, in: window.contentView).first else {
            runtime.draft.text = composerLines.joined(separator: "\n")
            try? await Task.sleep(for: .milliseconds(400))
            await shoot(recorder, stage, "composer-grown")
            runtime.draft.text = ""
            try? await Task.sleep(for: .milliseconds(250))
            await shoot(recorder, stage, "composer-cleared")
            note("composer", "field not found; draft set on the model, then cleared")
            return
        }
        let focused = window.makeFirstResponder(textView)
        let empty = textView.string
        await shoot(recorder, stage, "composer-empty")
        var typed = 0
        for (index, line) in composerLines.enumerated() {
            for character in line { if sendKey(character, window: window) { typed += 1 } }
            if index < composerLines.count - 1, sendKey("\n", window: window) { typed += 1 }
            try? await Task.sleep(for: .milliseconds(180))
        }
        try? await Task.sleep(for: .milliseconds(200))
        var grown = textView.string
        var via = "keys"
        if !grown.contains("\n") {
            runtime.draft.text = composerLines.joined(separator: "\n")
            try? await Task.sleep(for: .milliseconds(350))
            grown = textView.string
            via = "keys-missed-draft-set"
        }
        await shoot(recorder, stage, "composer-grown")
        let selection = await selectAllAndDelete(textView, window: window)
        try? await Task.sleep(for: .milliseconds(200))
        var cleared = textView.string
        if !cleared.isEmpty {
            runtime.draft.text = ""
            try? await Task.sleep(for: .milliseconds(250))
            cleared = textView.string
            via += "+draft-cleared"
        }
        await shoot(recorder, stage, "composer-cleared")
        let lines = grown.components(separatedBy: "\n").count
        note("composer", "focus=\(focused) typed=\(typed) empty=\(empty.count) grown=\(grown.count) lines=\(lines) left=\(cleared.count) selection=\(selection) via=\(via)")
    }

    // MARK: - Model

    private static func speak(_ runtime: ThreadRuntime, id: String, user: String, answer: String) async {
        runtime.rehearseTurn(user)
        runtime.rehearse(.messageDelta(id: id, text: answer))
        await finish(runtime, id: id)
    }

    private static func finish(_ runtime: ThreadRuntime, id: String) async {
        runtime.rehearse(.messageCompleted(id: id, text: ""))
        runtime.rehearse(.turnCompleted(status: .completed, error: nil))
        let limit = Date.now.addingTimeInterval(8)
        while runtime.isRunning, Date.now < limit {
            try? await Task.sleep(for: .milliseconds(40))
        }
        if runtime.isRunning { WebsiteCaptures.log("stress \(id) still running") }
    }

    private static func longBody() -> String {
        var lines = [
            "## Attachment insets",
            "",
            "The strip pads the leading edge and leaves the top on the stack default.",
            "",
            "- `attachmentInset` is 14pt",
            "- the top uses the stack spacing",
            "- the photo hugs the pill",
            "",
        ]
        for index in 1...28 {
            if index.isMultiple(of: 4) {
                lines.append("Note \(index). The row stays one line.")
            } else {
                lines.append("Paragraph \(index). The draft photo should sit as far from the top of the pill as it sits from the left, and the label on the strip should name the photo so the gap is obvious when the window changes size.")
            }
            if index.isMultiple(of: 7) {
                lines.append("")
                lines.append("```")
                lines.append("padding(.top, attachmentInset)")
                lines.append("padding(.leading, attachmentInset)")
                lines.append("```")
                lines.append("")
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func growthPieces() -> [String] {
        (1...24).map { index in
            if index.isMultiple(of: 5) {
                "\n\n\(index). Short.\n\n"
            } else if index.isMultiple(of: 3) {
                "Sentence \(index) stays with the paragraph so the block grows by one line. "
            } else {
                "The inset note \(index) is a longer line: the photo needs the same 14pt gap on the top as on the leading edge, and the row should stay put once the text stops. "
            }
        }
    }

    // MARK: - Window and input

    private static func appWindow() -> NSWindow? {
        let titled = NSApp.windows.filter { $0.styleMask.contains(.titled) && $0.isVisible }
        if let match = titled.first(where: { $0.title == AppInfo.name }) { return match }
        if titled.isEmpty { return nil }
        WebsiteCaptures.log("stress window titles=\(titled.map(\.title).joined(separator: ","))")
        return titled.first
    }

    private static func coverWindow(otherThan app: NSWindow) -> NSWindow? {
        NSApp.windows
            .filter { $0 !== app && !$0.styleMask.contains(.titled) && $0.isVisible }
            .max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
    }

    private static func timelineScroll(in window: NSWindow) -> NSScrollView? {
        findAll(NSScrollView.self, in: window.contentView)
            .filter {
                !$0.isHiddenOrHasHiddenAncestor
                    && !($0.documentView is ComposerNSTextView)
                    && $0.bounds.height > 120
                    && $0.bounds.width > 200
            }
            .max { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }
    }

    /// Points of document below the visible rect. Zero is the bottom of the thread.
    private static func bottomGap(_ scroll: NSScrollView) -> Int? {
        guard let document = scroll.documentView else { return nil }
        let visible = scroll.documentVisibleRect
        return Int((document.bounds.height - visible.maxY).rounded())
    }

    private static func scrollSummary(in window: NSWindow) -> String {
        guard let root = window.contentView else { return "no content" }
        return findAll(NSScrollView.self, in: root).map { scroll in
            let composer = scroll.documentView is ComposerNSTextView
            return "\(Int(scroll.bounds.width))x\(Int(scroll.bounds.height)) composer=\(composer)"
        }.joined(separator: ", ")
    }

    private static func resizeSizes() -> [NSSize] {
        let visible = (NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)).insetBy(dx: 24, dy: 24)
        let wide = NSSize(width: min(1320, visible.width), height: min(860, visible.height))
        let narrow = NSSize(
            width: min(900, max(640, visible.width * 0.62)).rounded(),
            height: min(580, max(480, visible.height * 0.62)).rounded()
        )
        let mid = NSSize(width: ((wide.width + narrow.width) / 2).rounded(), height: ((wide.height + narrow.height) / 2).rounded())
        let squat = NSSize(width: wide.width, height: narrow.height)
        return [narrow, wide, mid, squat]
    }

    private static func timelineCGPoint(window: NSWindow, scroll: NSScrollView) -> CGPoint {
        let bounds = scroll.convert(scroll.bounds, to: nil)
        let point = NSPoint(x: bounds.midX, y: bounds.midY)
        let screenPoint = window.convertToScreen(NSRect(origin: point, size: .zero)).origin
        return CGPoint(x: screenPoint.x, y: CGDisplayBounds(CGMainDisplayID()).height - screenPoint.y)
    }

    private static func buildWheelCGEvent(window: NSWindow, scroll: NSScrollView, deltaY: Int32) -> CGEvent? {
        guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: deltaY, wheel2: 0, wheel3: 0) else { return nil }
        cg.location = timelineCGPoint(window: window, scroll: scroll)
        cg.setIntegerValueField(.eventTargetUnixProcessID, value: Int64(getpid()))
        cg.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(window.windowNumber))
        cg.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(window.windowNumber))
        return cg
    }

    private static func wheelEvent(window: NSWindow, scroll: NSScrollView, deltaY: Int32) -> NSEvent? {
        guard let cg = buildWheelCGEvent(window: window, scroll: scroll, deltaY: deltaY),
              let event = NSEvent(cgEvent: cg), event.type == .scrollWheel else { return nil }
        return event
    }

    private static func phasedWheelEvent(
        window: NSWindow,
        scroll: NSScrollView,
        deltaY: Int32,
        phase: UInt32,
        momentumPhase: UInt32 = 0
    ) -> (cg: CGEvent, ns: NSEvent)? {
        guard let cg = buildWheelCGEvent(window: window, scroll: scroll, deltaY: deltaY) else { return nil }
        cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase))
        cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: Int64(momentumPhase))
        cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        if let ns = NSEvent(cgEvent: cg),
           ns.type == .scrollWheel,
           ns.hasPreciseScrollingDeltas,
           abs(ns.scrollingDeltaY - CGFloat(deltaY)) <= 0.01 {
            return (cg, ns)
        }
        cg.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(deltaY))
        cg.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: Double(deltaY))
        guard let ns = NSEvent(cgEvent: cg), ns.type == .scrollWheel else { return nil }
        return (cg, ns)
    }

    private static func burst(_ deltaY: Int32, times: Int, window: NSWindow, scroll: NSScrollView, direct: Bool) async {
        for _ in 0..<times {
            if let event = wheelEvent(window: window, scroll: scroll, deltaY: deltaY) {
                // Target only this process through Quartz. Directly queuing the
                // synthetic NSEvent left its windowNumber at zero in the baseline.
                if direct {
                    scroll.scrollWheel(with: event)
                } else {
                    event.cgEvent?.postToPid(getpid())
                }
            }
            try? await Task.sleep(for: .milliseconds(30))
        }
        try? await Task.sleep(for: .milliseconds(80))
    }

    private static let keyCodes: [Character: UInt16] = [
        "a": 0, "b": 11, "c": 8, "d": 2, "e": 14, "f": 3, "g": 5, "h": 4, "i": 34,
        "j": 38, "k": 40, "l": 37, "m": 46, "n": 45, "o": 31, "p": 35, "q": 12,
        "r": 15, "s": 1, "t": 17, "u": 32, "v": 9, "w": 13, "x": 7, "y": 16, "z": 6,
        " ": 49, ".": 47,
    ]

    private static let composerLines = [
        "The top inset is still the stack default.",
        "Match it to the leading fourteen points.",
        "The photo should sit off the pill edge.",
        "Then the build can confirm nothing else moved.",
    ]

    @discardableResult
    private static func sendKey(_ character: Character, window: NSWindow) -> Bool {
        let newline = character == "\n"
        let code: UInt16
        if newline {
            code = 36
        } else if let key = String(character).lowercased().first, let found = keyCodes[key] {
            code = found
        } else {
            WebsiteCaptures.log("stress composer: no key code for \(character)")
            return false
        }
        var flags: NSEvent.ModifierFlags = []
        if newline || (!newline && character.isUppercase) { flags.insert(.shift) }
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: flags,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: newline ? "\n" : String(character),
            charactersIgnoringModifiers: newline ? "\n" : String(character).lowercased(),
            isARepeat: false,
            keyCode: code
        ) else { return false }
        // The command delegate reads NSApp.currentEvent for Shift-Return. Directly
        // sending to the window bypasses that and can submit the draft instead.
        NSApp.postEvent(event, atStart: false)
        return true
    }

    /// Returns the selection after Command-A, as `location+length`.
    private static func selectAllAndDelete(_ textView: NSTextView, window: NSWindow) async -> String {
        guard let select = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0
        ), let delete = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, characters: "\u{7F}", charactersIgnoringModifiers: "\u{7F}", isARepeat: false, keyCode: 51
        ) else { return "no-event" }
        NSApp.postEvent(select, atStart: false)
        try? await Task.sleep(for: .milliseconds(80))
        let range = textView.selectedRange()
        NSApp.postEvent(delete, atStart: false)
        return "\(range.location)+\(range.length)"
    }

    private static func findAll<View: NSView>(_ type: View.Type, in root: NSView?) -> [View] {
        guard let root else { return [] }
        var found: [View] = []
        if let match = root as? View { found.append(match) }
        for child in root.subviews { found.append(contentsOf: findAll(type, in: child)) }
        return found
    }

    // MARK: - Record

    @MainActor
    private final class RecordingStop {
        var started = false
        var stopped = false
    }

    // Window-only ScreenCaptureKit recording preserves the one-frame motion that
    // the five-second stills miss. It never includes other applications or audio.
    private static func recordWindow(_ name: String, seconds: Double, stop: RecordingStop? = nil) async {
        defer { stop?.started = true }
        guard let window = appWindow(), let output = CaptureRun.outputDirectory else { return }
        do {
            let content = try await SCShareableContent.currentProcess
            guard let target = content.windows.first(where: {
                $0.windowID == CGWindowID(window.windowNumber) && $0.owningApplication?.processID == getpid()
            }) else {
                note(name, "window not shareable")
                return
            }
            let configuration = SCStreamConfiguration()
            let scale = window.backingScaleFactor
            configuration.width = Int(window.frame.width * scale) / 2 * 2
            configuration.height = Int(window.frame.height * scale) / 2 * 2
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
            configuration.showsCursor = false
            configuration.capturesAudio = false
            let settings = SCRecordingOutputConfiguration()
            settings.outputURL = output.appendingPathComponent("\(name).mp4")
            let completion = RecordingCompletion()
            let recording = SCRecordingOutput(configuration: settings, delegate: completion)
            let stream = SCStream(filter: SCContentFilter(desktopIndependentWindow: target), configuration: configuration, delegate: nil)
            try stream.addRecordingOutput(recording)
            try await stream.startCapture()
            stop?.started = true
            WebsiteCaptures.log("stress \(name) recording start window=\(window.windowNumber)")
            let recordStart = Date.now
            if let stop {
                while !stop.stopped, Date.now.timeIntervalSince(recordStart) < seconds, secondsLeft() > 3 {
                    try? await Task.sleep(for: .milliseconds(100))
                }
            } else {
                try? await Task.sleep(for: .seconds(seconds))
            }
            let recordedSeconds = Date.now.timeIntervalSince(recordStart)
            try await stream.stopCapture()
            let end = Date.now.addingTimeInterval(5)
            while !completion.finished, Date.now < end {
                try? await Task.sleep(for: .milliseconds(50))
            }
            let durationText = stop == nil ? "\(seconds)s" : String(format: "%.1fs", recordedSeconds)
            note(name, completion.error ?? (completion.finished ? "recorded \(durationText)" : "recording completion timed out"))
        } catch {
            note(name, "recording failed: \(error.localizedDescription)")
        }
    }

    @MainActor
    private final class RecordingCompletion: NSObject, SCRecordingOutputDelegate {
        var finished = false
        var error: String?

        nonisolated func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
            Task { @MainActor in self.finished = true }
        }

        nonisolated func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: any Error) {
            let message = error.localizedDescription
            Task { @MainActor in
                self.error = message
                self.finished = true
            }
        }
    }

    private static func secondsLeft() -> TimeInterval { deadline.timeIntervalSinceNow }

    @discardableResult
    private static func shoot(_ recorder: Recorder, _ stage: Stage, _ name: String) async -> Bool {
        await recorder.still(name, stage.captureRect)
        let url = CaptureRun.outputDirectory?.appendingPathComponent("\(name).png")
        let ok = url.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        if !ok {
            missingStills.append(name)
            WebsiteCaptures.log("stress still missing \(name)")
        }
        return ok
    }

    private static func note(_ name: String, _ detail: String) {
        WebsiteCaptures.log("stress \(name): \(detail)")
        phases.append(["name": name, "detail": detail])
        saveReport(listFiles: false)
    }

    private static func saveReport(listFiles: Bool) {
        guard let output = CaptureRun.outputDirectory else { return }
        func data(files: [String]?) -> Data? {
            var object: [String: Any] = [
                "budgetSeconds": Int(budgetSeconds),
                "phases": phases,
                "missingStills": missingStills,
            ]
            if let files { object["files"] = files }
            return try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        }
        let url = output.appendingPathComponent("stress.json")
        if let body = data(files: nil) { try? body.write(to: url, options: .atomic) }
        guard listFiles else { return }
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: output.path)) ?? []).sorted()
        if let body = data(files: names) { try? body.write(to: url, options: .atomic) }
    }
}

extension TimelineStress {
    private struct SubagentLoopVariant: Encodable {
        let scenario: String
        let destination: String
        let width: Int
        let windowHeight: Int
        let chunkCharacters: Int
        let intervalMs: Int
        let cpuPercent: Double
        let maxGapMs: Double
        let longGaps: Int
        let deliveredChunks: Int
        let expectedChunks: Int
        let still: String
        let hot: Bool?
    }

    @MainActor
    private final class SubagentStreamDeliveries {
        var count = 0
    }

    private struct SubagentLoopMeasurement {
        let cpuPercent: Double
        let maxGapMs: Double
        let longGaps: Int
    }

    private struct SubagentLoopAfterCollapse: Encodable {
        let cpuPercent: Double
        let hot: Bool?
    }

    private struct SubagentLoopReport: Encodable {
        let osVersion: String
        let preferredScrollerStyle: String
        let knobsOff: String
        let variants: [SubagentLoopVariant]
        let afterCollapse: SubagentLoopAfterCollapse?
    }

    static func runSubagentPanelLoop(model: AppModel) async {
        guard CaptureRun.isEnabled, let output = CaptureRun.outputDirectory else { return }
        phases.removeAll()
        missingStills.removeAll()
        await model.bootstrap()
        guard model.isLibraryLoaded, !model.threads.isEmpty else {
            WebsiteCaptures.log("stress library failed to load")
            exit(1)
        }
        budgetSeconds = 600
        deadline = Date.now.addingTimeInterval(budgetSeconds)
        let timeoutTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(budgetSeconds))
            WebsiteCaptures.log("stress out of time, quitting")
            saveReport(listFiles: true)
            exit(2)
        }
        defer { timeoutTask.cancel() }

        model.settings.hasSeenHydraIntro = true
        model.settings.hydraEnabled = false
        WebsiteCaptures.log("subagent-panel-loop start \(output.path)")

        let stage = Stage(model: model)
        stage.show(size: NSSize(width: 1320, height: 860))
        await stage.ensureActive()
        guard let window = appWindow(), NSApp.isActive, window.isKeyWindow else {
            note("blocked", "foreground desktop unavailable; unlock the host before running")
            saveReport(listFiles: true)
            exit(2)
        }
        guard let content = try? await SCShareableContent.currentProcess, !content.displays.isEmpty else {
            note("blocked", "no capturable display for this process")
            saveReport(listFiles: true)
            exit(2)
        }
        if model.sidebar.isVisible { model.sidebar.toggle() }

        guard let parent = model.thread(longThreadID)
            ?? model.threads.first(where: { !$0.isArchived && !$0.isHydraHead && !$0.isHelper }) else {
            note("blocked", "no parent thread in mock library")
            saveReport(listFiles: true)
            exit(2)
        }
        model.selectedThreadID = parent.id
        try? await Task.sleep(for: .milliseconds(500))

        let recorder = Recorder(output: output, stage: stage)
        let answer = subagentStreamingAnswer()
        let windowHeight = 860
        var variants: [SubagentLoopVariant] = []
        let parentRuntime = model.runtime(for: parent.id)
        await parentRuntime.ensureLoaded()

        func runQuietScenario(scenario: String, destination: String, width: Int) async {
            guard secondsLeft() > 14 else {
                note("subagent-loop-budget", "stopped before \(scenario), \(Int(secondsLeft()))s left")
                saveReport(listFiles: true)
                exit(2)
            }
            WebsiteCaptures.log("subagent-panel-loop scenario \(scenario) start width=\(width) height=\(windowHeight) quiet=true")
            try? await Task.sleep(for: .seconds(1))
            let measurement = await measureSubagentStreamingWindow(seconds: 6.0)
            // A window recording after the measurement, for comparing the working title's
            // breath between builds frame by frame (TIVANO_PROBE_RECORD=1).
            if ProcessInfo.processInfo.environment["TIVANO_PROBE_RECORD"] == "1" {
                await recordWindow("breath-\(scenario)", seconds: 7)
            }
            let stillBase = "subagent-\(scenario)-\(windowHeight)"
            let stillFile = "\(stillBase).png"
            await shoot(recorder, stage, stillBase)
            let hot = measurement.cpuPercent >= 40
            note(
                stillBase,
                String(format: "destination=%@ width=%d windowHeight=%d quiet=true cpuPercent=%.1f maxGapMs=%.1f longGaps=%d hot=%@", destination, width, windowHeight, measurement.cpuPercent, measurement.maxGapMs, measurement.longGaps, hot ? "true" : "false")
            )
            variants.append(SubagentLoopVariant(
                scenario: scenario,
                destination: destination,
                width: width,
                windowHeight: windowHeight,
                chunkCharacters: 0,
                intervalMs: 0,
                cpuPercent: measurement.cpuPercent,
                maxGapMs: measurement.maxGapMs,
                longGaps: measurement.longGaps,
                deliveredChunks: 0,
                expectedChunks: 0,
                still: stillFile,
                hot: hot ? true : nil
            ))
        }

        if let existingPanel = model.panelSubagent(of: parent.id) {
            withAnimation(Chrome.panelSlide) {
                model.closeSubagent(existingPanel.id)
            }
            try? await Task.sleep(for: .milliseconds(1500))
        }
        guard !parentRuntime.isRunning, model.panelSubagent(of: parent.id) == nil else {
            note("blocked", "idle baseline could not stage an idle parent with no helper panel")
            saveReport(listFiles: true)
            exit(2)
        }
        await runQuietScenario(scenario: "idle-baseline", destination: "idle", width: 0)

        var helper = ChatThread(
            projectID: parent.projectID,
            provider: parent.provider,
            model: parent.model,
            effort: parent.effort,
            runtimeMode: parent.runtimeMode,
            fastMode: parent.fastMode
        )
        helper.parentThreadID = parent.id
        helper.isInPanel = true
        helper.title = "Helper panel loop"
        helper.hasCustomTitle = true
        model.insertThread(helper)

        let helperRuntime = model.runtime(for: helper.id)
        await helperRuntime.ensureLoaded()

        for turn in 1...2 {
            await speak(
                helperRuntime,
                id: "subagent-short-\(turn)",
                user: subagentLoopQuestion(turn),
                answer: subagentLoopAnswer(turn)
            )
        }

        let streamGate = HeldDragStreamGate()
        let pieces = heldDragStreamPieces(count: 20)
        var streamTask: Task<Void, Never>?
        defer { streamTask?.cancel() }
        var activeRuntime = helperRuntime
        var activeStreamID: String?

        func finishActiveTurn() async {
            streamTask?.cancel()
            streamTask = nil
            if let activeStreamID {
                await finish(activeRuntime, id: activeStreamID)
            }
            activeStreamID = nil
        }

        func startQuietRunningTurn(runtime: ThreadRuntime, streamID: String, prompt: String, initialDelta: String) async {
            await finishActiveTurn()
            activeRuntime = runtime
            activeStreamID = streamID
            streamGate.paused = false
            runtime.rehearseTurn(prompt)
            let countAfterPrompt = runtime.entries.count
            streamTask = Task { @MainActor in
                var index = 0
                while !Task.isCancelled, secondsLeft() > 3 {
                    if streamGate.paused {
                        try? await Task.sleep(for: .milliseconds(50))
                        continue
                    }
                    let text = index == 0 ? initialDelta : pieces[(index - 1) % pieces.count]
                    runtime.rehearse(.messageDelta(id: streamID, text: text))
                    index += 1
                    if index == 1 { streamGate.paused = true }
                    try? await Task.sleep(for: .milliseconds(180))
                }
            }
            let waitLimit = Date.now.addingTimeInterval(1.5)
            while runtime.entries.count <= countAfterPrompt, Date.now < waitLimit {
                try? await Task.sleep(for: .milliseconds(40))
            }
            try? await Task.sleep(for: .milliseconds(220))
            streamGate.paused = true
        }

        let defaultHeight = min(520.0, max(300.0, CGFloat(windowHeight) * 0.5))
        model.settings.panelSize = CGSize(width: 400, height: defaultHeight)
        stage.resize(to: NSSize(width: 1320, height: CGFloat(windowHeight)))
        await startQuietRunningTurn(
            runtime: helperRuntime,
            streamID: "subagent-stream-panel-400-quiet",
            prompt: "Keep monitoring the helper panel layout.",
            initialDelta: "Checking the helper panel width and working card layout while the turn stays running. "
        )
        try? await Task.sleep(for: .milliseconds(400))

        let scrollCount = findAll(NSScrollView.self, in: window.contentView)
            .filter { !$0.isHiddenOrHasHiddenAncestor && !($0.documentView is ComposerNSTextView) }
            .count
        guard model.subagent(of: parent.id)?.id == helper.id,
              model.panelSubagent(of: parent.id)?.id == helper.id,
              helperRuntime.isRunning,
              scrollCount >= 2 else {
            note("blocked", "helper panel did not appear (panelSubagent=\(model.panelSubagent(of: parent.id)?.id.uuidString ?? "nil") scrolls=\(scrollCount))")
            saveReport(listFiles: true)
            exit(2)
        }
        note("subagent-panel-staged", "helper=\(helper.id.uuidString) parent=\(parent.id.uuidString) running=\(helperRuntime.isRunning) scrolls=\(scrollCount)")
        await runQuietScenario(scenario: "panel-400-quiet", destination: "helper-panel", width: 400)

        await finishActiveTurn()
        withAnimation(Chrome.panelSlide) {
            model.closeSubagent(helper.id)
        }
        try? await Task.sleep(for: .seconds(1.5))
        await startQuietRunningTurn(
            runtime: parentRuntime,
            streamID: "subagent-stream-main-quiet",
            prompt: "Keep monitoring the main chat working card.",
            initialDelta: "Checking the main chat working card layout while the turn stays running. "
        )
        guard parentRuntime.isRunning, model.panelSubagent(of: parent.id) == nil else {
            note("blocked", "main quiet scenario could not stage a running parent with the helper panel closed")
            saveReport(listFiles: true)
            exit(2)
        }
        await runQuietScenario(scenario: "main-quiet", destination: "parent-main-chat", width: 400)
        await finishActiveTurn()

        if ProcessInfo.processInfo.environment["TIVANO_PROBE_QUIET_ONLY"] == "1" {
            writeSubagentLoopReport(output: output, variants: variants, afterCollapse: nil)
            note("done", "quitting after quiet scenarios")
            saveReport(listFiles: true)
            exit(0)
        }

        withAnimation(Chrome.panelSlide) {
            model.showSubagentPanel(helper.id)
        }
        try? await Task.sleep(for: .milliseconds(400))
        guard model.panelSubagent(of: parent.id)?.id == helper.id else {
            note("blocked", "helper panel did not reopen for streaming scenarios")
            saveReport(listFiles: true)
            exit(2)
        }

        func runScenario(
            scenario: String,
            destination: String,
            runtime: ThreadRuntime,
            width: Int,
            chunkCharacters: Int,
            intervalMs: Int,
            streamID: String,
            readyMarker: Bool = false
        ) async {
            guard secondsLeft() > 14 else {
                note("subagent-loop-budget", "stopped before \(scenario), \(Int(secondsLeft()))s left")
                saveReport(listFiles: true)
                exit(2)
            }
            WebsiteCaptures.log("subagent-panel-loop scenario \(scenario) start width=\(width) height=\(windowHeight) chunkCharacters=\(chunkCharacters) intervalMs=\(intervalMs) streamID=\(streamID)")

            streamTask?.cancel()
            streamTask = nil
            if let activeStreamID {
                await finish(activeRuntime, id: activeStreamID)
            }
            activeStreamID = nil

            let defaultHeight = min(520.0, max(300.0, CGFloat(windowHeight) * 0.5))
            model.settings.panelSize = CGSize(width: CGFloat(width), height: defaultHeight)
            stage.resize(to: NSSize(width: 1320, height: CGFloat(windowHeight)))

            let chunks = subagentStreamChunks(answer, characters: chunkCharacters)
            guard let firstChunk = chunks.first else {
                note("blocked", "streaming answer produced no chunks")
                saveReport(listFiles: true)
                exit(2)
            }
            activeRuntime = runtime
            activeStreamID = streamID
            streamGate.paused = false
            runtime.rehearseTurn("Produce the detailed final investigation with Markdown, code, a table, links, and long tokens.")
            runtime.rehearse(.messageDelta(id: streamID, text: firstChunk))
            // Paced by elapsed time: chunks that fall due during a main-thread stall are
            // delivered on the next wake, so a slow panel receives the same text as the control.
            let deliveries = SubagentStreamDeliveries()
            streamTask = Task { @MainActor in
                let start = ContinuousClock.now
                let interval = Duration.milliseconds(intervalMs)
                var index = 1
                while !Task.isCancelled, secondsLeft() > 3 {
                    if streamGate.paused {
                        try? await Task.sleep(for: .milliseconds(50))
                        continue
                    }
                    let due = Int((ContinuousClock.now - start) / interval)
                    while index <= due {
                        runtime.rehearse(.messageDelta(id: streamID, text: chunks[index % chunks.count]))
                        index += 1
                        deliveries.count += 1
                    }
                    try? await Task.sleep(until: start + interval * index, clock: .continuous)
                }
            }

            try? await Task.sleep(for: .seconds(1))
            if readyMarker {
                do {
                    try Data().write(to: output.appendingPathComponent("subagent-stream-ready"), options: .atomic)
                } catch {
                    note("blocked", "could not write subagent-stream-ready: \(error.localizedDescription)")
                    saveReport(listFiles: true)
                    exit(2)
                }
            }
            let deliveredBefore = deliveries.count
            let measurement = await measureSubagentStreamingWindow(seconds: 6.0)
            let deliveredChunks = deliveries.count - deliveredBefore
            let expectedChunks = Int((6000.0 / Double(intervalMs)).rounded())
            let stillBase = "subagent-\(scenario)-\(windowHeight)"
            let stillFile = "\(stillBase).png"
            await shoot(recorder, stage, stillBase)
            let hot = measurement.cpuPercent >= 40
            note(
                stillBase,
                String(format: "destination=%@ width=%d windowHeight=%d chunkCharacters=%d intervalMs=%d cpuPercent=%.1f maxGapMs=%.1f longGaps=%d hot=%@", destination, width, windowHeight, chunkCharacters, intervalMs, measurement.cpuPercent, measurement.maxGapMs, measurement.longGaps, hot ? "true" : "false")
            )
            variants.append(SubagentLoopVariant(
                scenario: scenario,
                destination: destination,
                width: width,
                windowHeight: windowHeight,
                chunkCharacters: chunkCharacters,
                intervalMs: intervalMs,
                cpuPercent: measurement.cpuPercent,
                maxGapMs: measurement.maxGapMs,
                longGaps: measurement.longGaps,
                deliveredChunks: deliveredChunks,
                expectedChunks: expectedChunks,
                still: stillFile,
                hot: hot ? true : nil
            ))
        }

        await runScenario(
            scenario: "panel-400-fast",
            destination: "helper-panel",
            runtime: helperRuntime,
            width: 400,
            chunkCharacters: 40,
            intervalMs: 16,
            streamID: "subagent-stream-panel-400-fast",
            readyMarker: true
        )
        await runScenario(
            scenario: "panel-400-large-chunks",
            destination: "helper-panel",
            runtime: helperRuntime,
            width: 400,
            chunkCharacters: 400,
            intervalMs: 50,
            streamID: "subagent-stream-panel-400-large-chunks"
        )
        await runScenario(
            scenario: "panel-520-fast",
            destination: "helper-panel",
            runtime: helperRuntime,
            width: 520,
            chunkCharacters: 40,
            intervalMs: 16,
            streamID: "subagent-stream-panel-520-fast"
        )

        guard secondsLeft() > 10 else {
            note("subagent-loop-budget", "stopped before after-collapse, \(Int(secondsLeft()))s left")
            saveReport(listFiles: true)
            exit(2)
        }
        streamTask?.cancel()
        streamTask = nil
        if let activeStreamID {
            await finish(activeRuntime, id: activeStreamID)
        }
        activeStreamID = nil
        withAnimation(Chrome.panelSlide) {
            model.closeSubagent(helper.id)
        }
        try? await Task.sleep(for: .seconds(1.5))
        let afterCollapseCPU = await measureProcessCPUPercent(seconds: 6.0)
        let afterCollapseHot = afterCollapseCPU >= 40
        note(
            "after-collapse",
            String(format: "cpuPercent=%.1f hot=%@ panelOpen=%@", afterCollapseCPU, afterCollapseHot ? "true" : "false", model.panelSubagent(of: parent.id) != nil ? "true" : "false")
        )

        await runScenario(
            scenario: "parent-control-400-fast",
            destination: "parent-main-chat",
            runtime: parentRuntime,
            width: 400,
            chunkCharacters: 40,
            intervalMs: 16,
            streamID: "subagent-stream-parent-control-400-fast"
        )
        await finishActiveTurn()

        writeSubagentLoopReport(
            output: output,
            variants: variants,
            afterCollapse: SubagentLoopAfterCollapse(
                cpuPercent: afterCollapseCPU,
                hot: afterCollapseHot ? true : nil
            )
        )

        note("done", "quitting")
        saveReport(listFiles: true)
        exit(missingStills.isEmpty ? 0 : 1)
    }

    private static var subagentPillDemoWindow: NSWindow?

    /// `--website-captures <folder> --subagent-pill-demo`: interactive preview of the
    /// in-stream working sub-agent pill (`HelpersWorkingRow`) with panels off. Leaves the
    /// window open without exiting so a human can inspect and click the pill.
    static func runSubagentPillDemo(model: AppModel) async {
        guard CaptureRun.isEnabled else { return }
        await model.bootstrap()
        guard model.isLibraryLoaded, let project = model.projects.first else { return }

        model.settings.hasSeenHydraIntro = true
        model.settings.hydraAutoOpensPanels = false

        let window = WindowManager.shared.makeCaptureWindow(size: NSSize(width: 1280, height: 800))
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        subagentPillDemoWindow = window

        var parent = ChatThread(
            projectID: project.id,
            provider: .claude,
            model: "opus",
            effort: "high",
            runtimeMode: .supervised
        )
        parent.title = "Sub-agent pill demo"
        parent.hasCustomTitle = true
        parent.branch = "main"
        model.insertThread(parent)

        let parentRuntime = model.runtime(for: parent.id)
        await parentRuntime.ensureLoaded()
        let demoTurns: [(String, String)] = [
            ("先看一下当前对话流底部的布局，子代理在后台运行但没弹窗时用户能看到什么？", "如果关闭了自动弹出面板，后台运行的子代理不会立刻占满右侧空间，而是在对话流末尾显示一条状态胶囊，方便随时点开查看。"),
            ("那如果主对话已经很长，需要一直滚到最下面才看得到吗？", "对，它会跟在最后一个区块后面，和工作状态指示处于同一视觉层级；点击胶囊后会直接把对应的子代理面板呼出来。"),
            ("普通子代理和 Hydra 并行团队都会走这一个入口吗？", "是的。普通子代理展示它的标题（比如“Walter is working”），多个隐藏的 Hydra 子代理则会汇总显示数量和头像标记。"),
            ("点击打开面板之后，胶囊会自动消失吗？", "会。当该子代理进入面板显示后，`HelpersWorkingRow` 不再把它算作隐藏运行态，胶囊随即收起；再次关闭面板时会重新出现。"),
            ("先把普通子代理派出去跑着，我看看底部胶囊的样式和点击手感。", "已经派发子代理 Walter 在后台运行，它当前未固定在面板中，你可以直接点击对话流底部的胶囊试一下。"),
        ]
        for (index, turn) in demoTurns.enumerated() {
            await speak(parentRuntime, id: "pill-demo-parent-\(index)", user: turn.0, answer: turn.1)
        }

        var walter = ChatThread(
            projectID: parent.projectID,
            provider: parent.provider,
            model: parent.model,
            effort: parent.effort,
            runtimeMode: parent.runtimeMode,
            fastMode: parent.fastMode
        )
        walter.parentThreadID = parent.id
        walter.isInPanel = false
        walter.title = "Walter"
        walter.hasCustomTitle = true
        walter.branch = "main"
        model.insertThread(walter)

        let walterRuntime = model.runtime(for: walter.id)
        await walterRuntime.ensureLoaded()
        await speak(
            walterRuntime,
            id: "pill-demo-walter-seed",
            user: "先确认 `HelpersWorkingRow` 的展示条件和点击动作。",
            answer: "已核对：`hydraAutoOpensPanels == false` 且 `!helper.isInPanel` 时，会在主对话末尾展示 `Walter is working`。"
        )
        walterRuntime.rehearseTurn("继续检查子代理面板打开与关闭后的胶囊切换状态。")
        walterRuntime.rehearse(.messageDelta(
            id: "pill-demo-walter-running",
            text: "正在核对隐藏子代理在对话流末尾的状态同步与面板展开动画，当前保持运行中以便交互测试。"
        ))

        var headsLead = ChatThread(
            projectID: project.id,
            provider: .claude,
            model: "opus",
            effort: "high",
            runtimeMode: .supervised
        )
        headsLead.title = "Sub-agent pill demo (heads)"
        headsLead.hasCustomTitle = true
        headsLead.branch = "main"
        headsLead.hydraSpawnCount = 2
        model.insertThread(headsLead)

        let headsLeadRuntime = model.runtime(for: headsLead.id)
        await headsLeadRuntime.ensureLoaded()
        headsLeadRuntime.isHydraPanelHidden = true
        await speak(
            headsLeadRuntime,
            id: "pill-demo-heads-seed",
            user: "同时派两个 Hydra 子代理检查面板收起时的汇总胶囊。",
            answer: "两个子代理已开始运行，当前 Hydra 面板处于隐藏状态，底部会显示汇总数量和头像。"
        )
        let headSpecs = [
            ("核对汇总胶囊文案", "正在检查多子代理同时运行时底部胶囊的计数与图标排列。"),
            ("验证面板切换状态", "正在验证点击胶囊后调用 `HydraButton.togglePanel` 恢复团队面板。"),
        ]
        for (index, spec) in headSpecs.enumerated() {
            var head = ChatThread(
                projectID: headsLead.projectID,
                provider: headsLead.provider,
                model: headsLead.model,
                effort: headsLead.effort,
                runtimeMode: headsLead.runtimeMode,
                fastMode: headsLead.fastMode
            )
            head.parentThreadID = headsLead.id
            head.isInPanel = true
            head.title = "\(HydraRoster.persona(at: index).name) · \(spec.0)"
            head.hasCustomTitle = true
            head.branch = "main"
            var info = HydraHeadInfo(index: index, task: spec.0, kind: .tivano, origin: .delegated)
            info.status = .running
            info.activity = spec.0
            head.hydra = info
            model.insertThread(head)

            let headRuntime = model.runtime(for: head.id)
            await headRuntime.ensureLoaded()
            headRuntime.rehearseTurn(spec.0)
            headRuntime.rehearse(.messageDelta(id: "pill-demo-head-\(index)", text: spec.1))
        }

        model.selectedThreadID = parent.id
        try? await Task.sleep(for: .milliseconds(150))
    }

    private static var splitReplyDemoWindow: NSWindow?

    /// Interactive: one finished turn whose two replies sit either side of a tool call, each
    /// with a numbered list from 1, so a person can drag-select across both replies.
    static func runSplitReplyDemo(model: AppModel) async {
        guard CaptureRun.isEnabled else { return }
        await model.bootstrap()
        guard model.isLibraryLoaded, let project = model.projects.first else { return }
        model.settings.hasSeenHydraIntro = true

        let window = WindowManager.shared.makeCaptureWindow(size: NSSize(width: 1280, height: 800))
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        splitReplyDemoWindow = window

        var thread = ChatThread(projectID: project.id, provider: .claude, model: "opus", effort: "high", runtimeMode: .supervised)
        thread.title = "Split reply demo"
        thread.hasCustomTitle = true
        thread.branch = "main"
        model.insertThread(thread)
        let runtime = model.runtime(for: thread.id)
        await runtime.ensureLoaded()

        let firstReply = """
        First reply paragraph one explains what we are checking before running the command.

        First reply paragraph two introduces the checklist:

        1. First item in reply one.
        2. Second item in reply one.
        """
        let secondReply = """
        Second reply paragraph one summarizes what the command confirmed.

        Second reply paragraph two starts its own list:

        1. First item in reply two.
        2. Second item in reply two.
        """
        runtime.rehearseTurn("Show two replies split by a tool call.")
        runtime.rehearse(.messageDelta(id: "split-reply-a", text: firstReply))
        runtime.rehearse(.messageCompleted(id: "split-reply-a", text: ""))
        runtime.rehearse(.toolStarted(id: "split-reply-tool", call: ToolCall(kind: .command, title: "swift test", detail: "SplitReplyTests")))
        runtime.rehearse(.toolUpdated(id: "split-reply-tool", update: ToolUpdate(output: "All checks passed.", status: .completed)))
        runtime.rehearse(.messageDelta(id: "split-reply-b", text: secondReply))
        await finish(runtime, id: "split-reply-b")
        model.selectedThreadID = thread.id
        guard CommandLine.arguments.contains("--split-reply-drag") else { return }
        await runSplitReplyDrag(window: window)
        exit(0)
    }

    private static func runSplitReplyDrag(window: NSWindow) async {
        guard let output = CaptureRun.outputDirectory else { return }
        try? await Task.sleep(for: .seconds(2))

        let views = findAll(LinkTextView.self, in: window.contentView)
        let firstView = views.first { $0.string.contains("First reply paragraph one") }
        let secondView = views.first { $0.string.contains("Second item in reply two") }
        let sameView = (firstView != nil) && (firstView === secondView)

        let start = firstView.flatMap {
            splitDragWindowPoint(in: $0, substring: "paragraph one", charOffset: 4, trailingEdge: false)
        }
        let end = secondView.flatMap {
            splitDragWindowPoint(in: $0, substring: "Second item in reply two.", charOffset: nil, trailingEdge: true)
        }

        let contentBoundsInWindow = window.contentView.map { $0.convert($0.bounds, to: nil) }
            ?? NSRect(origin: .zero, size: window.frame.size)
        let endOutsideContentBounds = end.map { !contentBoundsInWindow.contains($0) } ?? true
        if endOutsideContentBounds {
            WebsiteCaptures.log("split-reply-drag end outside content bounds: end=\(String(describing: end)) content=\(contentBoundsInWindow)")
        }

        snapshotWindowContent(window, to: output.appendingPathComponent("split-before.png"))

        var hitView = ""
        var drivenDirectly = false
        if let start, let end {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            let baseTime = ProcessInfo.processInfo.systemUptime
            let steps = 8
            var queued: [NSEvent] = []
            for step in 1...steps {
                let t = CGFloat(step) / CGFloat(steps)
                let point = NSPoint(
                    x: start.x + (end.x - start.x) * t,
                    y: start.y + (end.y - start.y) * t
                )
                if let drag = NSEvent.mouseEvent(
                    with: .leftMouseDragged,
                    location: point,
                    modifierFlags: [],
                    timestamp: baseTime + Double(step) * 0.01,
                    windowNumber: window.windowNumber,
                    context: nil,
                    eventNumber: step,
                    clickCount: 1,
                    pressure: 1
                ) {
                    queued.append(drag)
                }
            }
            if let up = NSEvent.mouseEvent(
                with: .leftMouseUp,
                location: end,
                modifierFlags: [],
                timestamp: baseTime + Double(steps + 1) * 0.01,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: steps + 1,
                clickCount: 1,
                pressure: 0
            ) {
                queued.append(up)
            }
            for event in queued {
                NSApp.postEvent(event, atStart: false)
            }
            if let down = NSEvent.mouseEvent(
                with: .leftMouseDown,
                location: start,
                modifierFlags: [],
                timestamp: baseTime,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 1
            ) {
                // Through the window first, as a click is delivered; if that reaches another
                // view (an overlay catching clicks), record it and drive the text view directly.
                hitView = window.contentView?.hitTest(window.contentView!.convert(start, from: nil)).map { String(describing: type(of: $0)) } ?? "nil"
                window.sendEvent(down)
                if (window.firstResponder as? NSTextView)?.selectedRange().length ?? 0 == 0, let firstView {
                    for event in queued { NSApp.postEvent(event, atStart: false) }
                    window.makeFirstResponder(firstView)
                    firstView.mouseDown(with: down)
                    drivenDirectly = true
                }
            }
            try? await Task.sleep(for: .milliseconds(500))
        }

        snapshotWindowContent(window, to: output.appendingPathComponent("split-after.png"))
        if let firstView { snapshotView(firstView, to: output.appendingPathComponent("split-after-text.png")) }

        let responderTextView = window.firstResponder as? NSTextView
        let selected: String = {
            guard let textView = responderTextView else { return "" }
            let ns = textView.string as NSString
            return textView.selectedRanges.compactMap { value -> String? in
                let range = value.rangeValue
                guard range.location != NSNotFound,
                      range.location >= 0,
                      range.location + range.length <= ns.length else { return nil }
                return ns.substring(with: range)
            }.joined()
        }()
        NSPasteboard.general.clearContents()
        NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil)
        let pasteboard = NSPasteboard.general.string(forType: .string) ?? ""

        let firstRaw = firstView?.attributedString().string ?? ""
        let firstViewText = String(firstRaw.prefix(4000))
        let oneDotMarkerCount = max(0, firstRaw.components(separatedBy: "1.\t").count - 1)
        let selectionCrossesReplies = selected.contains("First reply paragraph two") && selected.contains("Second item in reply two")

        let payload: [String: Any] = [
            "linkTextViewCount": views.count,
            "sameView": sameView,
            "start": start.map { [Double($0.x), Double($0.y)] } ?? [],
            "end": end.map { [Double($0.x), Double($0.y)] } ?? [],
            "endOutsideContentBounds": endOutsideContentBounds,
            "selected": selected,
            "pasteboard": pasteboard,
            "firstViewText": firstViewText,
            "oneDotMarkerCount": oneDotMarkerCount,
            "bothListsStartAtOne": oneDotMarkerCount >= 2,
            "selectionCrossesReplies": selectionCrossesReplies,
            "hitView": hitView,
            "drivenDirectly": drivenDirectly,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: output.appendingPathComponent("split-drag.json"), options: .atomic)
        }
        WebsiteCaptures.log(
            "split-reply-drag views=\(views.count) sameView=\(sameView) crosses=\(selectionCrossesReplies) oneDot=\(oneDotMarkerCount) endOutside=\(endOutsideContentBounds) selectedLen=\(selected.count) pasteboardLen=\(pasteboard.count)"
        )
    }

    private static func splitDragWindowPoint(
        in view: LinkTextView,
        substring: String,
        charOffset: Int?,
        trailingEdge: Bool
    ) -> NSPoint? {
        guard let layoutManager = view.layoutManager, let textContainer = view.textContainer else { return nil }
        let ns = view.string as NSString
        let found = ns.range(of: substring)
        guard found.location != NSNotFound, found.length > 0 else { return nil }
        let index = charOffset.map { found.location + $0 } ?? (found.location + found.length - 1)
        guard index >= 0, index < ns.length else { return nil }
        layoutManager.ensureLayout(for: textContainer)
        let glyphRange = layoutManager.glyphRange(forCharacterRange: NSRange(location: index, length: 1), actualCharacterRange: nil)
        guard glyphRange.location != NSNotFound, glyphRange.length > 0 else { return nil }
        var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        rect.origin.x += view.textContainerOrigin.x
        rect.origin.y += view.textContainerOrigin.y
        let local = NSPoint(x: trailingEdge ? rect.maxX : rect.midX, y: rect.midY)
        return view.convert(local, to: nil)
    }

    private static func snapshotView(_ view: NSView, to url: URL) {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: url, options: .atomic)
    }

    private static func snapshotWindowContent(_ window: NSWindow, to url: URL) {
        guard let contentView = window.contentView else { return }
        let bounds = contentView.bounds
        guard let rep = contentView.bitmapImageRepForCachingDisplay(in: bounds) else { return }
        contentView.cacheDisplay(in: bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: url, options: .atomic)
    }

    private static func writeSubagentLoopReport(
        output: URL,
        variants: [SubagentLoopVariant],
        afterCollapse: SubagentLoopAfterCollapse?
    ) {
        let scrollerStyle: String = switch NSScroller.preferredScrollerStyle {
        case .legacy: "legacy"
        case .overlay: "overlay"
        @unknown default: "unknown"
        }
        let report = SubagentLoopReport(
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            preferredScrollerStyle: scrollerStyle,
            knobsOff: ProbeKnobs.rawValue,
            variants: variants,
            afterCollapse: afterCollapse
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(report) {
            try? data.write(to: output.appendingPathComponent("subagent-loop.json"), options: .atomic)
        }
    }

    private static func measureSubagentStreamingWindow(seconds: TimeInterval) async -> SubagentLoopMeasurement {
        let monitor = SubagentLoopStallMonitor()
        monitor.start()
        let cpuPercent = await measureProcessCPUPercent(seconds: seconds)
        let stalls = monitor.stop()
        return SubagentLoopMeasurement(
            cpuPercent: cpuPercent,
            maxGapMs: stalls.maxGapMs,
            longGaps: stalls.longGaps
        )
    }

    private static func subagentStreamChunks(_ text: String, characters: Int) -> [String] {
        guard characters > 0 else { return [] }
        var chunks: [String] = []
        var start = text.startIndex
        while start < text.endIndex {
            let end = text.index(start, offsetBy: characters, limitedBy: text.endIndex) ?? text.endIndex
            chunks.append(String(text[start..<end]))
            start = end
        }
        return chunks
    }

    private static func subagentStreamingAnswer() -> String {
        var answer = """
        ## Final investigation

        The helper reproduced the narrow-panel slowdown while a long final answer was arriving at full provider speed. The result combines ordinary prose with [inline investigation notes](https://example.com/issues/56/investigation) so the rehearsal exercises the same Markdown parsing, layout, selection, and scrolling work as a real response.

        The first pass compared the visible helper transcript with the [main-column control](https://example.com/issues/56/control). It kept the parent thread selected, preserved the panel's floating presentation, and recorded evidence only after the stream had been running long enough to reach steady rendering rather than a single initial layout.

        The principal observations are:

        """
        let bullets = (1...8).map { index in
            "- Observation \(index): incoming deltas invalidate the visible Markdown blocks, the timeline remeasures their widths, and the viewport decides whether the reader should remain pinned to the latest output."
        }.joined(separator: "\n")
        answer += bullets

        let swiftCode = (1...36).map { line in
            "let renderedBlock\(line) = renderer.measure(chunks[\(line)], panelWidth: panelWidth, cursor: textOffsets[\(line)], following: isFollowing)"
        }.joined(separator: "\n")
        answer += """


        The following Swift excerpt is deliberately long enough to produce many wrapped lines and persistent syntax-highlighting work in the narrow panel:

        ```swift
        \(swiftCode)
        ```

        A second parser trace adds another fenced language and more long lines. The [renderer comparison](https://example.com/issues/56/renderer-comparison) links this trace to the visible result rather than treating code blocks as inert filler.

        """
        let pythonCode = (1...36).map { line in
            "delta_\(line) = parser.consume(chunks[\(line)], panel_width=panel_width, link_state=links[\(line)], invalidate=True)"
        }.joined(separator: "\n")
        answer += """
        ```python
        \(pythonCode)
        ```

        | Pass | Visible region | Parser work | Viewport result |
        | --- | --- | --- | --- |
        """
        let tableRows = (1...10).map { index in
            "| \(index) | Paragraph and code block \(index) | Inline links plus delimiters | Follow offset retained |"
        }.joined(separator: "\n")
        answer += "\n\(tableRows)"

        let longURL = "https://example.com/" + String(repeating: "stream-segment-", count: 12) + "final-result"
        let longPath = "/tmp/tivano-rehearsal/" + String(repeating: "directory-", count: 16) + "timeline-result.md"
        answer += """


        Long unbroken tokens make wrapping failures visible without depending on a particular font: \(longURL)

        The local diagnostic artifact uses another intentionally unbroken token: `\(longPath)`

        """
        var batch = 1
        while answer.count < 15_000 {
            answer += """

            ### Confirmation batch \(batch)

            This confirmation extends the realistic final answer while the helper remains live. It refers back to [evidence batch \(batch)](https://example.com/issues/56/evidence/\(batch)) and explains that parsing, text measurement, scrolling, and panel compositing all happen while another delta is already due.

            - Timeline pass \(batch): append the next fragment, preserve the reader's position, and remeasure every visible block affected by the growing response.
            - Markdown pass \(batch): retain unfinished inline delimiters, update link ranges, and keep fenced code highlighting stable as chunk boundaries move.
            - Layout pass \(batch): compare the narrow panel with the parent column using identical text and cadence rather than a paused transcript.

            Additional prose keeps the payload representative of a model summarizing a completed investigation. It includes enough words between structural elements to force ordinary paragraph wrapping as well as table and code rendering, and the next confirmation begins only after this complete section has entered the stream.

            """
            batch += 1
        }
        return answer
    }

    private static func processCPUTime() -> Double? {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return nil }
        let user = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000.0
        let sys = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000.0
        return user + sys
    }

    private static func measureProcessCPUPercent(seconds: TimeInterval) async -> Double {
        let startWall = ContinuousClock.now
        let startCPU = processCPUTime()
        try? await Task.sleep(for: .seconds(seconds))
        let endCPU = processCPUTime()
        let parts = (ContinuousClock.now - startWall).components
        let wall = Double(parts.seconds) + Double(parts.attoseconds) / 1e18
        guard let startCPU, let endCPU, wall > 0 else { return -1 }
        let raw = max(0, ((endCPU - startCPU) / wall) * 100.0)
        return (raw * 10.0).rounded() / 10.0
    }

    private static func subagentLoopQuestion(_ turn: Int) -> String {
        switch turn {
        case 1: "Check the helper panel width against the working indicator card."
        case 2: "Verify the scroll viewport when the transcript sits near the panel height."
        default: "Check layout pass \(turn) across the helper timeline and composer inset."
        }
    }

    private static func subagentLoopAnswer(_ turn: Int) -> String {
        """
        Pass \(turn) keeps the helper timeline inside the floating panel with 20pt horizontal padding on each side while the working card fixes its width at 380pt.

        This short seeded exchange keeps earlier timeline content above the live final answer used by the streaming scenarios.
        """
    }
}

private final class SubagentLoopStallMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    private var previousTick: ContinuousClock.Instant?
    private var maximumGapMs = 0.0
    private var longGapCount = 0

    func start() {
        lock.lock()
        previousTick = ContinuousClock.now
        lock.unlock()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        self.timer = timer
        timer.schedule(deadline: .now() + .milliseconds(10), repeating: .milliseconds(10))
        timer.setEventHandler { [weak self] in
            self?.tick()
        }
        timer.resume()
    }

    func stop() -> (maxGapMs: Double, longGaps: Int) {
        timer?.cancel()
        timer = nil
        // The interval since the last tick counts too: a stall still running at the end
        // of the window would otherwise go unrecorded.
        tick()
        lock.lock()
        defer { lock.unlock() }
        return ((maximumGapMs * 10).rounded() / 10, longGapCount)
    }

    private func tick() {
        let now = ContinuousClock.now
        lock.lock()
        defer { lock.unlock() }
        if let previousTick {
            let parts = (now - previousTick).components
            let gapMs = Double(parts.seconds) * 1000 + Double(parts.attoseconds) / 1e15
            maximumGapMs = max(maximumGapMs, gapMs)
            if gapMs > 250 {
                longGapCount += 1
            }
        }
        previousTick = now
    }
}
#endif

@MainActor
private final class HeldDragStreamGate {
    var paused = false
}
