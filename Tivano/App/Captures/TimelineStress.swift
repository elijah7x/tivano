#if DEBUG
import AppKit
import AVFoundation
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

    static func runMidScroll(model: AppModel) async {
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
        let scenario = MidScrollScenario.fromCommandLine()
        let traceURL = timelineTraceURL()
        let traceExistedBeforeRun = traceURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        let runStartClock = captureClockPair()
        WebsiteCaptures.log("mid-scroll start \(output.path) flags=\(scenario.activeFlags.joined(separator: ","))")

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
        model.selectedThreadID = nil
        try? await Task.sleep(for: .milliseconds(300))
        let recorder = Recorder(output: output, stage: stage)

        let outcome = await midScroll(
            model,
            recorder,
            stage,
            scenario: scenario,
            traceExistedBeforeRun: traceExistedBeforeRun,
            runStartClock: runStartClock
        )
        switch outcome {
        case .blockedOrOutOfTime:
            note("done", "quitting (blocked/out-of-time)")
            saveReport(listFiles: true)
            exit(2)
        case .inconclusive:
            note("done", "quitting (INCONCLUSIVE)")
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

    // MARK: - Mid-scroll bidirectional HID stress

    private static let midScrollTurnCount = 60
    private static let midScrollHistoryTurnCount = 80
    private static let midScrollFlickBatch = 20
    private static let midScrollDragCount = 10
    private static let midScrollExpectedFlicks = midScrollFlickBatch * 4
    private static let midScrollExpectedGestures = midScrollExpectedFlicks + midScrollDragCount
    private static let midScrollFlickChangedSteps = 12
    private static let midScrollMomentumSteps = 21
    private static let midScrollDragChangedSteps = 60
    private static let midScrollExpectedEvents =
        midScrollExpectedFlicks * (1 + midScrollFlickChangedSteps + 1 + midScrollMomentumSteps + 1)
        + midScrollDragCount * (1 + midScrollDragChangedSteps + 1)
    private static let midScrollDragStepCycle: [Int32] = [6, 7, 8, 9, 10]
    private static let midScrollMeasurementMethod = "docMinY-minus-trace-compensation+nsScrollView-clipBounds"
    private static let midScrollColdForgetNotification = Notification.Name("TivanoDebugForgetRowMemories")
    private static let midScrollLayoutShiftThresholdPt = 4.0
    /// Longest sample interval during input before a reversed jump could hide in it.
    private static let midScrollMaxSampleGapSec: CFTimeInterval = 0.05
    private static let midScrollMaxHitchSec: CFTimeInterval = 0.2
    private static let midScrollMaxUnmatchedPairRatio = 0.02
    private static let midScrollResizeDeltaPt: CGFloat = 120
    private static let midScrollReflowWindowSec: CFTimeInterval = 0.300

    private struct MidScrollScenario {
        let cold: Bool
        let history: Bool
        let mix: Bool
        let resize: Bool
        let serif: Bool

        var activeFlags: [String] {
            var flags = ["--mid-scroll"]
            if cold { flags.append("--mid-scroll-cold") }
            if history { flags.append("--mid-scroll-history") }
            if mix { flags.append("--mid-scroll-mix") }
            if resize { flags.append("--mid-scroll-resize") }
            if serif { flags.append("--mid-scroll-serif") }
            return flags
        }

        static func fromCommandLine() -> Self {
            let args = CommandLine.arguments
            return Self(
                cold: args.contains("--mid-scroll-cold"),
                history: args.contains("--mid-scroll-history"),
                mix: args.contains("--mid-scroll-mix"),
                resize: args.contains("--mid-scroll-resize"),
                serif: args.contains("--mid-scroll-serif")
            )
        }
    }

    private struct MidScrollReflowWindow {
        enum Category: String {
            case resize
            case serif
        }

        let category: Category
        let kind: String
        let startMono: CFTimeInterval
        let endMono: CFTimeInterval
    }

    private struct MidScrollReflowWindowRecord: Encodable {
        let category: String
        let kind: String
        let start: Double
        let end: Double
    }

    private struct MidScrollCodeBlockCandidate {
        let turn: Int
        let lineCount: Int
        let precedingID: String
        let followingID: String
    }

    private struct MidScrollSeedResult {
        let seeded: Int
        let legacyTurnEndCount: Int
        let turnRowKinds: [Int: String]
        let seededRowKinds: [String: Int]
        let skippedRowKinds: [String]
        let codeBlockCandidates: [MidScrollCodeBlockCandidate]
        let longActivityTurns: [Int]
    }

    private enum MidScrollOutcome: Equatable {
        case passed
        case failed
        case inconclusive
        case blockedOrOutOfTime
    }

    private struct MidScrollClockPair {
        let mono: CFTimeInterval
        let wall: TimeInterval
    }

    private struct MidScrollTraceClockAlignment {
        let t0Mono: CFTimeInterval?
        let method: String
        let birthtimeVsObservedDeltaMs: Double?
    }

    private struct MidScrollRecordingAudit {
        let finishedSuccessfully: Bool
        let startMonoTime: CFTimeInterval?
        let endMonoTime: CFTimeInterval?
        let recordedDuration: TimeInterval
        let assetDuration: TimeInterval?
        let errorDescription: String?
    }

    private struct MidScrollExpandedBlockTarget {
        let turn: Int
        let lineCount: Int
        let precedingBlockID: String
        let followingBlockID: String
        let collapsedHeight: Double
        let expandedHeight: Double
        let anchorDocY: Double
    }

    private struct MidScrollExpandedBlockResult {
        let status: String
        let turn: Int?
        let lineCount: Int?
        let collapsedHeight: Double?
        let expandedHeight: Double?
        let restoredHeight: Double?
        let evictedDuringRun: Bool?
        let detail: String

        static func unavailable(_ detail: String) -> Self {
            Self(
                status: "unavailable",
                turn: nil,
                lineCount: nil,
                collapsedHeight: nil,
                expandedHeight: nil,
                restoredHeight: nil,
                evictedDuringRun: nil,
                detail: detail
            )
        }
    }

    private enum MidScrollPrepareResult {
        case ready(
            window: NSWindow,
            scroll: NSScrollView,
            tracking: TimelineScrollTracking?,
            expandedBlock: MidScrollExpandedBlockTarget?,
            expandedStepsTurns: [Int]
        )
        case inconclusive(String)
        case failed
    }

    private static let midScrollSamplePatch = """
    diff --git a/Tivano/App/Views/Composer/ComposerView.swift b/Tivano/App/Views/Composer/ComposerView.swift
    --- a/Tivano/App/Views/Composer/ComposerView.swift
    +++ b/Tivano/App/Views/Composer/ComposerView.swift
    @@ -12,8 +12,10 @@ struct DraftAttachments: View {
                     }
                 }
    -            .padding(.leading, attachmentInset)
    +            .padding(.top, attachmentInset)
    +            .padding(.leading, attachmentInset)
    +            .accessibilityLabel("Draft photo")
                 .transition(.scale.combined(with: .opacity))
             }
         }

    """

    private struct MidScrollReady: Codable {
        let pid: Int32
        let windowNumber: Int
        let point: HeldDragPoint
        let windowFrame: HistoryFlickRect
        let upSign: Int32
        let viewport: Double
        let readyAt: Double
        let readyAtWallClock: Double
    }

    private struct MidScrollSnapshot {
        let monoTime: CFTimeInterval
        let clipMinY: Double
        let docHeight: Double
        let topInset: Double
        let viewportHeight: Double
        let topMargin: Double
        let bottomMargin: Double
        let historyLoadPending: Bool
        let visibleBlocks: [String: Double]
        let visibleTextIDs: Set<String>
        let mountedBlocks: [String: Double]
        let mountedTextIDs: Set<String>

        var isAtTopEnd: Bool { topMargin <= 1.0 }
        var isAtBottomEnd: Bool { bottomMargin <= 1.0 }
    }

    @MainActor
    private final class MidScrollObservedBuffer {
        struct RawEvent {
            let monoTime: CFTimeInterval
            let phase: NSEvent.Phase
            let momentumPhase: NSEvent.Phase
            let scrollingDeltaY: Double
            let windowNumber: Int
        }

        var initialSnapshot: MidScrollSnapshot?
        var initialSnapshotMonoTime: CFTimeInterval?
        var events: [RawEvent] = []
        var phaseBeganCount = 0
        var phaseEndedCount = 0
        var momentumEndedCount = 0
        var postedColdBeforeStage3 = false
        var postedColdBeforeStage4 = false
        var coldResetMonoTimes: [CFTimeInterval] = []
        var startedResizeSequence = false
        var startedSerifSequence = false
        var resizeTask: Task<Void, Never>?
        var serifTask: Task<Void, Never>?
        var resizeWindows: [MidScrollReflowWindow] = []
        var serifWindows: [MidScrollReflowWindow] = []
    }

    private struct MidScrollJumpRecord: Encodable {
        let timestamp: Double
        let blockID: String
        let contentMotion: Double
        let expectedMotion: Double
        let jump: Double
        let rawClipDelta: Double
        let prevScreenMinY: Double
        let currScreenMinY: Double
        let docHeightPrev: Double
        let docHeightCurr: Double
        let matchedByFallback: Bool
    }

    private struct MidScrollLayoutShiftRecord: Encodable {
        let timestamp: Double
        let blockID: String
        let rowKind: String
        let prevDocMinY: Double
        let currDocMinY: Double
        let docDelta: Double
        let compensationMovedY: Double
        let layoutShift: Double
        let rawClipDelta: Double
        let docHeightPrev: Double
        let docHeightCurr: Double
        let matchedByFallback: Bool
    }

    private struct MidScrollSampleRecord: Encodable {
        let time: Double
        let clipMinY: Double
        let rawClipDelta: Double?
        let docHeight: Double
        let topMargin: Double
        let bottomMargin: Double
        let historyLoadPending: Bool
        let blockID: String?
        let prevDocMinY: Double?
        let currDocMinY: Double?
        let docDelta: Double?
        let compensationMovedY: Double?
        let layoutShift: Double?
        let reflowWindow: String?
        let duringGesture: Bool?
        let matchedByFallback: Bool?
        let contentMotion: Double?
        let expectedMotion: Double?
        let jump: Double?
        let visibleBlocks: [String: Double]
    }

    private struct MidScrollCompensationEvent: Encodable {
        let event: String
        let t: Int?
        let alignedTime: Double?
        let seq: Int?
        let source: String?
        let rowID: String?
        let delta: Double?
        let growth: Double?
        let restoreDelta: Double?
        let historyReaderDelta: Double?
        let beforeY: Double?
        let afterY: Double?
        let movedY: Double?
        let skipped: Bool?
        let reason: String?
    }

    private struct MidScrollTraceParseResult {
        let enabled: Bool
        let path: String?
        let traceStartT: Int?
        let traceCapped: Bool
        let compensations: [MidScrollCompensationEvent]
        let appliedCount: Int
        let skippedCount: Int
        let skippedReasons: [String: Int]
        let totalAppliedMovedY: Double
        let historyLoadCount: Int
        let historyCompensations: [MidScrollCompensationEvent]
        let historyAppliedCount: Int
        let historySkippedCount: Int
        let historySkippedReasons: [String: Int]
        let historyTotalAppliedMovedY: Double
        let historySyncShiftsAppliedCount: Int
        let historyRestoresAppliedCount: Int
    }

    private struct MidScrollSamplesReport: Encodable {
        let verdict: String
        let verdictReasons: [String]
        let scenarioFlags: [String]
        let coldMode: Bool
        let historyMode: Bool
        let mixMode: Bool
        let resizeMode: Bool
        let serifMode: Bool
        let seededTurnCount: Int
        let seededRowKinds: [String: Int]
        let skippedRowKinds: [String]
        let expandedStepsTurns: [Int]
        let turnRowKinds: [String: String]
        let coldMemoryResetTimes: [Double]
        let delivery: String
        let upSign: Int32
        let viewport: Double
        let measurementMethod: String
        let expectedEventsCount: Int
        let expectedGesturesCount: Int
        let observedEventsCount: Int
        let observedGesturesCount: Int
        let observedEndedCount: Int
        let observedMomentumEndedCount: Int
        let allEventsArrived: Bool
        let historyLoadHappened: Bool
        let historyPagesLoadedCount: Int
        let hitTopEnd: Bool
        let hitBottomEnd: Bool
        let minTopMarginPt: Double
        let minBottomMarginPt: Double
        let recordingExists: Bool
        let recordingFinishedSuccessfully: Bool
        let recordingCoveredEvents: Bool
        let recordingDurationSec: Double
        let recordingAssetDurationSec: Double?
        let recordingRequiredEndOffsetSec: Double?
        let recordingActualEndOffsetSec: Double?
        let recordingError: String?
        let stillsComplete: Bool
        let samplesCount: Int
        let pairsCount: Int
        let unmatchedTransitionsCount: Int
        let unmatchedTransitionsRatio: Double
        let unmatchedLargeClipDuringGestureCount: Int
        let fallbackTransitionsCount: Int
        let maxAbsLayoutShift: Double
        let layoutShiftsOver4pt: Int
        let layoutShiftsOver20pt: Int
        let layoutShiftsOver40pt: Int
        let topLayoutShifts: [MidScrollLayoutShiftRecord]
        let resizeWindowTimes: [MidScrollReflowWindowRecord]
        let resizeWindowPairsCount: Int
        let resizeWindowShiftsOver4pt: Int
        let resizeWindowShiftsOver20pt: Int
        let resizeWindowShiftsOver40pt: Int
        let resizeWindowMaxAbsShift: Double
        let topResizeWindowShifts: [MidScrollLayoutShiftRecord]
        let serifWindowTimes: [MidScrollReflowWindowRecord]
        let serifWindowPairsCount: Int
        let serifWindowShiftsOver4pt: Int
        let serifWindowShiftsOver20pt: Int
        let serifWindowShiftsOver40pt: Int
        let serifWindowMaxAbsShift: Double
        let topSerifWindowShifts: [MidScrollLayoutShiftRecord]
        let reflowWindowSampleGaps: Int
        let maxAbsJump: Double
        let jumpsOver4pt: Int
        let jumpsOver20pt: Int
        let jumpsOver40pt: Int
        let topJumps: [MidScrollJumpRecord]
        let timelineTraceEnabled: Bool
        let timelineTracePath: String?
        let timelineTraceCapped: Bool
        let traceClockAlignmentMethod: String
        let traceClockBirthtimeVsObservedDeltaMs: Double?
        let aboveViewportCompensationsCount: Int
        let aboveViewportCompensationsAppliedCount: Int
        let aboveViewportCompensationsSkippedCount: Int
        let aboveViewportCompensationsSkippedReasons: [String: Int]
        let aboveViewportCompensationTotalMovedY: Double
        let aboveViewportCompensations: [MidScrollCompensationEvent]
        let historyCompensationsCount: Int
        let historyCompensationsAppliedCount: Int
        let historyCompensationsSkippedCount: Int
        let historyCompensationsSkippedReasons: [String: Int]
        let historyCompensationTotalMovedY: Double
        let historySyncShiftsAppliedCount: Int
        let historyRestoresAppliedCount: Int
        let historyCompensations: [MidScrollCompensationEvent]
        let expandedBlockRestored: String
        let expandedBlockTurn: Int?
        let expandedBlockLineCount: Int?
        let expandedBlockCollapsedHeight: Double?
        let expandedBlockExpandedHeight: Double?
        let expandedBlockRestoredHeight: Double?
        let expandedBlockEvictedDuringRun: Bool?
        let samples: [MidScrollSampleRecord]
        let observedEvents: [HistoryFlickObservedEvent]
    }

    private static func captureClockPair() -> MidScrollClockPair {
        let m1 = CACurrentMediaTime()
        let wall = Date().timeIntervalSince1970
        let m2 = CACurrentMediaTime()
        return MidScrollClockPair(mono: (m1 + m2) * 0.5, wall: wall)
    }

    private final class MidScrollTraceTailTracker {
        let url: URL
        private var offset: UInt64
        private(set) var minT0Mono: CFTimeInterval?
        private(set) var calibrationSamples = 0

        init(url: URL) {
            self.url = url
            let currentSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value ?? 0
            self.offset = currentSize
        }

        func poll(nowMono: CFTimeInterval) {
            guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value,
                  size > offset else { return }
            guard let handle = try? FileHandle(forReadingFrom: url) else { return }
            defer { try? handle.close() }
            do {
                try handle.seek(toOffset: offset)
                guard let data = try handle.readToEnd(), !data.isEmpty else { return }
                guard let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else { return }
                let consumed = data.distance(from: data.startIndex, to: lastNewline) + 1
                offset += UInt64(consumed)
                let slice = data.prefix(consumed)
                guard let chunk = String(data: slice, encoding: .utf8) else { return }
                for line in chunk.split(separator: "\n", omittingEmptySubsequences: true) {
                    guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                          let tMs = (obj["t"] as? NSNumber)?.intValue else { continue }
                    let candidateT0 = nowMono - Double(tMs) / 1000.0
                    if let existing = minT0Mono {
                        if candidateT0 < existing { minT0Mono = candidateT0 }
                    } else {
                        minT0Mono = candidateT0
                    }
                    calibrationSamples += 1
                }
            } catch {
                return
            }
        }
    }

    private static func loadMP4Duration(at url: URL) async -> TimeInterval? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration) else { return nil }
        let seconds = CMTimeGetSeconds(duration)
        return seconds.isFinite && seconds > 0 ? seconds : nil
    }

    private static func midScroll(
        _ model: AppModel,
        _ recorder: Recorder,
        _ stage: Stage,
        scenario: MidScrollScenario,
        traceExistedBeforeRun: Bool,
        runStartClock: MidScrollClockPair
    ) async -> MidScrollOutcome {
        guard let output = CaptureRun.outputDirectory else { return .failed }
        let turnCount = scenario.history ? midScrollHistoryTurnCount : midScrollTurnCount
        let seedResult = await seedMidScroll(
            model,
            threadID: shortThreadID,
            count: turnCount,
            scenario: scenario,
            output: output,
            minSecondsLeft: 95
        )
        guard seedResult.seeded == turnCount, secondsLeft() > 85 else {
            note("mid-scroll-open", "aborted after seeding \(seedResult.seeded)/\(turnCount) turns, \(Int(secondsLeft()))s left")
            return secondsLeft() <= 85 ? .blockedOrOutOfTime : .failed
        }

        guard let opened = await settleHistoryWindow(
            model,
            threadID: shortThreadID,
            maxGap: 8,
            noteName: "mid-scroll-open",
            turnsSeeded: seedResult.seeded,
            minSecondsLeft: 80
        ) else {
            return secondsLeft() <= 80 ? .blockedOrOutOfTime : .failed
        }
        let window = opened.window
        let scroll = opened.scroll
        let upSign: Int32 = 1

        let liveWindow: NSWindow
        let liveScroll: NSScrollView
        let liveTracking: TimelineScrollTracking?
        let expandedBlockTarget: MidScrollExpandedBlockTarget?
        let expandedStepsTurns: [Int]
        let prepareOutcome: MidScrollPrepareResult
        if scenario.history {
            prepareOutcome = await prepareHistoryTail(
                window: window,
                scroll: scroll,
                upSign: upSign,
                recorder: recorder,
                stage: stage
            )
        } else {
            prepareOutcome = await loadAllHistoryAndCenter(
                window: window,
                scroll: scroll,
                upSign: upSign,
                recorder: recorder,
                stage: stage,
                turnCount: turnCount,
                codeBlockCandidates: seedResult.codeBlockCandidates,
                longActivityTurns: seedResult.longActivityTurns,
                expandSteps: scenario.mix
            )
        }
        switch prepareOutcome {
        case .ready(
            let preparedWindow,
            let preparedScroll,
            let preparedTracking,
            let preparedExpanded,
            let preparedExpandedSteps
        ):
            liveWindow = preparedWindow
            liveScroll = preparedScroll
            liveTracking = preparedTracking
            expandedBlockTarget = preparedExpanded
            expandedStepsTurns = preparedExpandedSteps
        case .inconclusive:
            return .inconclusive
        case .failed:
            return secondsLeft() <= 60 ? .blockedOrOutOfTime : .failed
        }
        let baselineViewport = Double(max(240, unobstructedViewportRect(in: liveScroll).height))
        let originalWindowFrame = liveWindow.frame
        let originalSerif = TypeScale.shared.serif

        let midStop = RecordingStop()
        let midMaxSeconds = max(20.0, secondsLeft() - 16)
        let midRecording = Task { await recordWindow("mid-scroll", seconds: midMaxSeconds, stop: midStop) }
        let startWait = Date.now.addingTimeInterval(1.5)
        while !midStop.started, Date.now < startWait {
            try? await Task.sleep(for: .milliseconds(40))
        }

        await shoot(recorder, stage, "mid-scroll-start")

        let traceURL = timelineTraceURL()
        let traceBaselineLines = currentTimelineTraceLineCount()
        let traceTailTracker = traceURL.map(MidScrollTraceTailTracker.init)
        let buffer = MidScrollObservedBuffer()
        var monitor: Any? = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            guard event.window === liveWindow else { return event }
            let now = CACurrentMediaTime()
            let currentScroll = timelineScroll(in: liveWindow) ?? liveScroll
            let currentTracking = liveTracking ?? timelineTracking(in: currentScroll)
            if buffer.initialSnapshot == nil,
               let snap = readMidScrollSnapshot(currentScroll, tracking: currentTracking, monoTime: now - 0.000_001) {
                buffer.initialSnapshot = snap
                buffer.initialSnapshotMonoTime = snap.monoTime
            }
            let lineScroll = currentScroll.verticalLineScroll
            let preciseDelta = Double(
                event.hasPreciseScrollingDeltas
                    ? event.scrollingDeltaY
                    : event.scrollingDeltaY * lineScroll
            )
            buffer.events.append(MidScrollObservedBuffer.RawEvent(
                monoTime: now,
                phase: event.phase,
                momentumPhase: event.momentumPhase,
                scrollingDeltaY: preciseDelta,
                windowNumber: event.window?.windowNumber ?? event.windowNumber
            ))
            if event.phase.contains(.began) {
                buffer.phaseBeganCount += 1
            }
            if event.phase.contains(.ended) {
                buffer.phaseEndedCount += 1
            }
            if event.momentumPhase.contains(.ended) {
                buffer.momentumEndedCount += 1
            }
            if scenario.cold,
               !buffer.postedColdBeforeStage3,
               buffer.momentumEndedCount >= midScrollFlickBatch * 2 {
                buffer.postedColdBeforeStage3 = true
                buffer.coldResetMonoTimes.append(now)
                NotificationCenter.default.post(name: midScrollColdForgetNotification, object: nil)
            }
            if scenario.cold,
               buffer.postedColdBeforeStage3,
               !buffer.postedColdBeforeStage4,
               buffer.phaseEndedCount >= midScrollFlickBatch * 2 + midScrollDragCount {
                buffer.postedColdBeforeStage4 = true
                buffer.coldResetMonoTimes.append(now)
                NotificationCenter.default.post(name: midScrollColdForgetNotification, object: nil)
            }
            if scenario.resize,
               !buffer.startedResizeSequence,
               buffer.phaseBeganCount >= midScrollFlickBatch * 2 + 2 {
                buffer.startedResizeSequence = true
                let targetWindow = liveWindow
                let origFrame = originalWindowFrame
                buffer.resizeTask = Task { @MainActor in
                    let shrinkStart = CACurrentMediaTime()
                    let shrunkFrame = NSRect(
                        x: (origFrame.origin.x + midScrollResizeDeltaPt * 0.5).rounded(),
                        y: origFrame.origin.y,
                        width: max(600, origFrame.size.width - midScrollResizeDeltaPt),
                        height: origFrame.size.height
                    )
                    buffer.resizeWindows.append(MidScrollReflowWindow(
                        category: .resize,
                        kind: "resize-shrink",
                        startMono: shrinkStart,
                        endMono: shrinkStart + midScrollReflowWindowSec
                    ))
                    targetWindow.setFrame(shrunkFrame, display: true)
                    do {
                        try await Task.sleep(for: .seconds(1))
                    } catch {
                        targetWindow.setFrame(origFrame, display: true)
                        return
                    }
                    let restoreStart = CACurrentMediaTime()
                    buffer.resizeWindows.append(MidScrollReflowWindow(
                        category: .resize,
                        kind: "resize-restore",
                        startMono: restoreStart,
                        endMono: restoreStart + midScrollReflowWindowSec
                    ))
                    targetWindow.setFrame(origFrame, display: true)
                    try? await Task.sleep(for: .seconds(1))
                }
            }
            if scenario.serif,
               !buffer.startedSerifSequence,
               buffer.phaseBeganCount >= midScrollFlickBatch * 2 + midScrollDragCount + 2 {
                buffer.startedSerifSequence = true
                buffer.serifTask = Task { @MainActor in
                    let onStart = CACurrentMediaTime()
                    buffer.serifWindows.append(MidScrollReflowWindow(
                        category: .serif,
                        kind: "serif-on",
                        startMono: onStart,
                        endMono: onStart + midScrollReflowWindowSec
                    ))
                    TypeScale.shared.serif = true
                    do {
                        try await Task.sleep(for: .seconds(1))
                    } catch {
                        TypeScale.shared.serif = originalSerif
                        return
                    }
                    let offStart = CACurrentMediaTime()
                    buffer.serifWindows.append(MidScrollReflowWindow(
                        category: .serif,
                        kind: "serif-off",
                        startMono: offStart,
                        endMono: offStart + midScrollReflowWindowSec
                    ))
                    TypeScale.shared.serif = false
                    try? await Task.sleep(for: .seconds(1))
                }
            }
            return event
        }
        defer {
            if let monitor { NSEvent.removeMonitor(monitor) }
            buffer.resizeTask?.cancel()
            buffer.serifTask?.cancel()
            if scenario.resize, liveWindow.frame != originalWindowFrame {
                liveWindow.setFrame(originalWindowFrame, display: true)
            }
            if scenario.serif, TypeScale.shared.serif != originalSerif {
                TypeScale.shared.serif = originalSerif
            }
        }

        var latestPreEventSnap = readMidScrollSnapshot(liveScroll, tracking: liveTracking, monoTime: CACurrentMediaTime())

        let point = timelineCGPoint(window: liveWindow, scroll: liveScroll)
        let winFrame = windowCGRect(liveWindow)
        let ready = MidScrollReady(
            pid: getpid(),
            windowNumber: liveWindow.windowNumber,
            point: HeldDragPoint(x: Double(point.x), y: Double(point.y)),
            windowFrame: winFrame,
            upSign: upSign,
            viewport: baselineViewport,
            readyAt: CACurrentMediaTime(),
            readyAtWallClock: Date().timeIntervalSince1970
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let readyData = try? encoder.encode(ready) else {
            midStop.stopped = true
            await midRecording.value
            note("mid-scroll-ready", "failed to encode mid-scroll-ready.json")
            return .failed
        }
        do {
            try readyData.write(to: output.appendingPathComponent("mid-scroll-ready.json"), options: .atomic)
        } catch {
            midStop.stopped = true
            await midRecording.value
            note("mid-scroll-ready", "failed to write mid-scroll-ready.json: \(error.localizedDescription)")
            return .failed
        }
        note(
            "mid-scroll-ready",
            String(
                format: "pid=%d window=%d point=(%.1f,%.1f) windowFrame=(%.1f,%.1f,%.1f,%.1f) upSign=%d viewport=%.1f expectedGestures=%d expectedEvents=%d flags=%@",
                getpid(), liveWindow.windowNumber, point.x, point.y,
                winFrame.x, winFrame.y, winFrame.width, winFrame.height,
                upSign, baselineViewport, midScrollExpectedGestures, midScrollExpectedEvents,
                scenario.activeFlags.joined(separator: ",")
            )
        )

        let waitStart = Date.now
        let waitDeadline = waitStart.addingTimeInterval(30.0)
        while Date.now < waitDeadline, secondsLeft() > 10 {
            if !buffer.events.isEmpty { break }
            if let currentWindow = appWindow(), let currentScroll = timelineScroll(in: currentWindow) {
                let currentTracking = liveTracking ?? timelineTracking(in: currentScroll)
                if let snap = readMidScrollSnapshot(currentScroll, tracking: currentTracking, monoTime: CACurrentMediaTime()) {
                    latestPreEventSnap = snap
                }
            }
            traceTailTracker?.poll(nowMono: CACurrentMediaTime())
            try? await Task.sleep(for: .milliseconds(8))
        }

        guard let firstEvent = buffer.events.first else {
            if let activeMonitor = monitor {
                NSEvent.removeMonitor(activeMonitor)
                monitor = nil
            }
            midStop.stopped = true
            await midRecording.value
            await shoot(recorder, stage, "mid-scroll-end")
            note(
                "mid-scroll-hid-wait",
                "failed: no scrollWheel event matched window=\(liveWindow.windowNumber) within 30s"
            )
            let mp4URL = output.appendingPathComponent("mid-scroll.mp4")
            let assetDuration = await loadMP4Duration(at: mp4URL)
            let recordingAudit = MidScrollRecordingAudit(
                finishedSuccessfully: midStop.finishedSuccessfully,
                startMonoTime: midStop.startMonoTime,
                endMonoTime: midStop.endMonoTime,
                recordedDuration: midStop.recordedDuration,
                assetDuration: assetDuration,
                errorDescription: midStop.errorDescription
            )
            let traceResult = parseTimelineTraceEvents(afterLineOffset: traceBaselineLines)
            let clockAlignment = resolveTraceClockAlignment(
                url: traceURL,
                traceResult: traceResult,
                traceExistedBeforeRun: traceExistedBeforeRun,
                runStartClock: runStartClock,
                observedMinT0Mono: traceTailTracker?.minT0Mono
            )
            _ = evaluateMidScroll(
                samples: [],
                rawEvents: [],
                upSign: upSign,
                viewport: baselineViewport,
                endHasEarlierPill: hasEarlierMessagesPill(in: liveScroll),
                traceResult: traceResult,
                clockAlignment: clockAlignment,
                recordingAudit: recordingAudit,
                expandedResult: .unavailable("no scrollWheel events received"),
                scenario: scenario,
                seedResult: seedResult,
                expandedStepsTurns: expandedStepsTurns,
                coldResetMonoTimes: buffer.coldResetMonoTimes,
                resizeWindows: buffer.resizeWindows,
                serifWindows: buffer.serifWindows,
                timedOut: secondsLeft() <= 10,
                output: output
            )
            return secondsLeft() <= 10 ? .blockedOrOutOfTime : .failed
        }

        note(
            "mid-scroll-hid-started",
            String(
                format: "first event phase=%lu momentum=%lu after %.2fs",
                firstEvent.phase.rawValue,
                firstEvent.momentumPhase.rawValue,
                Date.now.timeIntervalSince(waitStart)
            )
        )

        var samples: [MidScrollSnapshot] = []
        if let seedSnap = buffer.initialSnapshot ?? latestPreEventSnap {
            let seedTime = min(seedSnap.monoTime, firstEvent.monoTime - 0.000_001)
            samples.append(MidScrollSnapshot(
                monoTime: seedTime,
                clipMinY: seedSnap.clipMinY,
                docHeight: seedSnap.docHeight,
                topInset: seedSnap.topInset,
                viewportHeight: seedSnap.viewportHeight,
                topMargin: seedSnap.topMargin,
                bottomMargin: seedSnap.bottomMargin,
                historyLoadPending: seedSnap.historyLoadPending,
                visibleBlocks: seedSnap.visibleBlocks,
                visibleTextIDs: seedSnap.visibleTextIDs,
                mountedBlocks: seedSnap.mountedBlocks,
                mountedTextIDs: seedSnap.mountedTextIDs
            ))
        }

        var finishedQuietTail = false
        while secondsLeft() > 8 {
            let now = CACurrentMediaTime()
            if let currentWindow = appWindow(), let currentScroll = timelineScroll(in: currentWindow) {
                let currentTracking = liveTracking ?? timelineTracking(in: currentScroll)
                if let snap = readMidScrollSnapshot(currentScroll, tracking: currentTracking, monoTime: now) {
                    samples.append(snap)
                }
            }
            traceTailTracker?.poll(nowMono: CACurrentMediaTime())
            if let lastMono = buffer.events.last?.monoTime,
               CACurrentMediaTime() - lastMono >= 1.5 {
                finishedQuietTail = true
                break
            }
            try? await Task.sleep(for: .milliseconds(8))
        }

        if let activeMonitor = monitor {
            NSEvent.removeMonitor(activeMonitor)
            monitor = nil
        }
        buffer.resizeTask?.cancel()
        buffer.serifTask?.cancel()
        if scenario.resize, liveWindow.frame != originalWindowFrame {
            liveWindow.setFrame(originalWindowFrame, display: true)
        }
        if scenario.serif, TypeScale.shared.serif != originalSerif {
            TypeScale.shared.serif = originalSerif
        }

        if scenario.cold {
            note(
                "mid-scroll-cold-resets",
                String(
                    format: "posted=%d beforeStage3=%@ beforeStage4=%@",
                    buffer.coldResetMonoTimes.count,
                    buffer.postedColdBeforeStage3 ? "true" : "false",
                    buffer.postedColdBeforeStage4 ? "true" : "false"
                )
            )
        }
        if scenario.resize {
            note(
                "mid-scroll-resize",
                "started=\(buffer.startedResizeSequence) windows=\(buffer.resizeWindows.count) deltaPt=\(Int(midScrollResizeDeltaPt))"
            )
        }
        if scenario.serif {
            note(
                "mid-scroll-serif",
                "started=\(buffer.startedSerifSequence) windows=\(buffer.serifWindows.count)"
            )
        }

        try? await Task.sleep(for: .milliseconds(150))
        midStop.stopped = true
        await midRecording.value
        await shoot(recorder, stage, "mid-scroll-end")

        let finalScroll = appWindow().flatMap(timelineScroll(in:)) ?? liveScroll
        let endHasEarlierPill = hasEarlierMessagesPill(in: finalScroll)
        let mp4URL = output.appendingPathComponent("mid-scroll.mp4")
        let assetDuration = await loadMP4Duration(at: mp4URL)
        let recordingAudit = MidScrollRecordingAudit(
            finishedSuccessfully: midStop.finishedSuccessfully,
            startMonoTime: midStop.startMonoTime,
            endMonoTime: midStop.endMonoTime,
            recordedDuration: midStop.recordedDuration,
            assetDuration: assetDuration,
            errorDescription: midStop.errorDescription
        )

        let traceResult = parseTimelineTraceEvents(afterLineOffset: traceBaselineLines)
        let clockAlignment = resolveTraceClockAlignment(
            url: traceURL,
            traceResult: traceResult,
            traceExistedBeforeRun: traceExistedBeforeRun,
            runStartClock: runStartClock,
            observedMinT0Mono: traceTailTracker?.minT0Mono
        )

        let expandedResult: MidScrollExpandedBlockResult
        if let expandedBlockTarget {
            expandedResult = await verifyExpandedCodeBlock(
                target: expandedBlockTarget,
                samples: samples,
                window: appWindow() ?? liveWindow,
                scroll: finalScroll,
                tracking: liveTracking,
                turnCount: turnCount
            )
        } else {
            expandedResult = .unavailable(
                scenario.history
                    ? "skipped in --mid-scroll-history mode"
                    : "no >120-line code block was expanded before readiness"
            )
        }

        let timedOut = !finishedQuietTail

        let outcome = evaluateMidScroll(
            samples: samples,
            rawEvents: buffer.events,
            upSign: upSign,
            viewport: baselineViewport,
            endHasEarlierPill: endHasEarlierPill,
            traceResult: traceResult,
            clockAlignment: clockAlignment,
            recordingAudit: recordingAudit,
            expandedResult: expandedResult,
            scenario: scenario,
            seedResult: seedResult,
            expandedStepsTurns: expandedStepsTurns,
            coldResetMonoTimes: buffer.coldResetMonoTimes,
            resizeWindows: buffer.resizeWindows,
            serifWindows: buffer.serifWindows,
            timedOut: timedOut,
            output: output
        )
        return outcome
    }

    private static func loadAllHistoryAndCenter(
        window: NSWindow,
        scroll: NSScrollView,
        upSign: Int32,
        recorder: Recorder,
        stage: Stage,
        turnCount: Int,
        codeBlockCandidates: [MidScrollCodeBlockCandidate],
        longActivityTurns: [Int],
        expandSteps: Bool
    ) async -> MidScrollPrepareResult {
        var currentWindow = window
        var currentScroll = scroll
        var currentTracking = timelineTracking(in: currentScroll)

        // Step 1: Unpin from bottom through real upward scroll input.
        var unpinAttempts = 0
        while (bottomGap(currentScroll) ?? 0) < 120, unpinAttempts < 4, secondsLeft() > 75 {
            currentTracking?.noteWheelInput(offsetDelta: -160)
            await burst(upSign * 160, times: 3, window: currentWindow, scroll: currentScroll, direct: true)
            unpinAttempts += 1
        }

        // Step 2: Load every earlier history page until Turn 1 is mounted and hidden == 0.
        var loadPasses = 0
        var allLoaded = false
        while loadPasses < 32, secondsLeft() > 70 {
            if let liveWin = appWindow(), let liveScr = timelineScroll(in: liveWin) {
                currentWindow = liveWin
                currentScroll = liveScr
                currentTracking = timelineTracking(in: liveScr) ?? currentTracking
            }
            let lowestTurn = mountedLowestTurn(in: currentScroll)
            let pillVisible = hasEarlierMessagesPill(in: currentScroll)
            let pending = currentTracking?.historyLoadPending ?? false
            if lowestTurn == 1, !pillVisible, !pending {
                try? await Task.sleep(for: .milliseconds(250))
                let confirmLowest = mountedLowestTurn(in: currentScroll)
                let confirmPill = hasEarlierMessagesPill(in: currentScroll)
                let confirmPending = currentTracking?.historyLoadPending ?? false
                if confirmLowest == 1, !confirmPill, !confirmPending {
                    allLoaded = true
                    break
                }
            }
            currentTracking?.noteWheelInput(offsetDelta: -240)
            let clip = currentScroll.contentView
            let topTarget = NSRect(
                origin: NSPoint(x: clip.bounds.minX, y: -currentScroll.contentInsets.top),
                size: clip.bounds.size
            )
            clip.scroll(to: clip.constrainBoundsRect(topTarget).origin)
            currentScroll.reflectScrolledClipView(clip)
            sendWheel(upSign * 120, window: currentWindow, scroll: currentScroll, direct: true)
            try? await Task.sleep(for: .milliseconds(300))

            let pendingDeadline = Date.now.addingTimeInterval(4.0)
            while (currentTracking?.historyLoadPending ?? false), Date.now < pendingDeadline, secondsLeft() > 68 {
                try? await Task.sleep(for: .milliseconds(50))
            }
            loadPasses += 1
        }

        guard allLoaded else {
            let lowestText = mountedLowestTurn(in: currentScroll).map(String.init) ?? "nil"
            let pillVisible = hasEarlierMessagesPill(in: currentScroll)
            let pending = currentTracking?.historyLoadPending ?? false
            note(
                "mid-scroll-load-all",
                "failed after \(loadPasses) passes: lowestTurn=\(lowestText) earlierPill=\(pillVisible) historyLoadPending=\(pending)"
            )
            return .failed
        }

        // Let the final top page's measurements finish settling.
        try? await Task.sleep(for: .milliseconds(450))
        let loadedDocHeight = Double(currentScroll.documentView?.bounds.height ?? 0)
        note(
            "mid-scroll-load-all",
            "loaded all \(turnCount) turns in \(loadPasses) passes lowestTurn=1 hidden=0 docHeight=\(Int(loadedDocHeight.rounded()))"
        )

        // Step 3: Move the reader to the middle of the thread, expand one >120-line code block
        // near the middle (for post-run persistence reporting), optionally expand seeded >60-step
        // turns in `--mid-scroll-mix`, re-center, and require 4 stable settle samples before
        // publishing readiness.
        func scrollToMiddle(_ scr: NSScrollView, tracking: TimelineScrollTracking?) {
            let docH = Double(scr.documentView?.bounds.height ?? 0)
            let visibleHeight = Double(scr.contentView.bounds.height)
            let topMinY = Double(-scr.contentInsets.top)
            let maxScrollY = max(topMinY, docH - visibleHeight)
            let targetMidY = topMinY + (maxScrollY - topMinY) * 0.5
            tracking?.noteWheelInput(offsetDelta: 120)
            let clip = scr.contentView
            let midTarget = NSRect(
                origin: NSPoint(x: clip.bounds.minX, y: CGFloat(targetMidY)),
                size: clip.bounds.size
            )
            clip.scroll(to: clip.constrainBoundsRect(midTarget).origin)
            scr.reflectScrolledClipView(clip)
        }

        scrollToMiddle(currentScroll, tracking: currentTracking)
        try? await Task.sleep(for: .milliseconds(500))

        if let liveWin = appWindow(), let liveScr = timelineScroll(in: liveWin) {
            currentWindow = liveWin
            currentScroll = liveScr
            currentTracking = timelineTracking(in: liveScr) ?? currentTracking
        }
        let expandedTarget = await prepareExpandedCodeBlock(
            window: currentWindow,
            scroll: currentScroll,
            tracking: currentTracking,
            candidates: codeBlockCandidates
        )

        var expandedStepsTurns: [Int] = []
        if expandSteps, !longActivityTurns.isEmpty {
            if let liveWin = appWindow(), let liveScr = timelineScroll(in: liveWin) {
                currentWindow = liveWin
                currentScroll = liveScr
                currentTracking = timelineTracking(in: liveScr) ?? currentTracking
            }
            scrollToMiddle(currentScroll, tracking: currentTracking)
            try? await Task.sleep(for: .milliseconds(450))
            expandedStepsTurns = await prepareExpandedStepsTurns(
                window: currentWindow,
                scroll: currentScroll,
                tracking: currentTracking,
                candidateTurns: longActivityTurns
            )
        }

        if let liveWin = appWindow(), let liveScr = timelineScroll(in: liveWin) {
            currentWindow = liveWin
            currentScroll = liveScr
            currentTracking = timelineTracking(in: liveScr) ?? currentTracking
        }
        scrollToMiddle(currentScroll, tracking: currentTracking)
        try? await Task.sleep(for: .milliseconds(600))

        var stableChecks = 0
        var prevDocH = Double(currentScroll.documentView?.bounds.height ?? 0)
        var prevClipY = Double(currentScroll.contentView.bounds.minY)
        var lastDocHDelta = 0.0
        var lastClipYDelta = 0.0
        var lastPending = false
        var lastVisibleBlocks = 0
        let settleDeadline = Date.now.addingTimeInterval(6.0)
        while Date.now < settleDeadline, secondsLeft() > 60 {
            if let liveWin = appWindow(), let liveScr = timelineScroll(in: liveWin) {
                currentWindow = liveWin
                currentScroll = liveScr
                currentTracking = timelineTracking(in: liveScr) ?? currentTracking
            }
            let nowDocH = Double(currentScroll.documentView?.bounds.height ?? 0)
            let nowClipY = Double(currentScroll.contentView.bounds.minY)
            let snap = readMidScrollSnapshot(currentScroll, tracking: currentTracking, monoTime: CACurrentMediaTime())
            let pending = currentTracking?.historyLoadPending ?? false
            lastDocHDelta = abs(nowDocH - prevDocH)
            lastClipYDelta = abs(nowClipY - prevClipY)
            lastPending = pending
            lastVisibleBlocks = snap?.visibleBlocks.count ?? 0
            if lastDocHDelta <= 0.5,
               lastClipYDelta <= 0.5,
               !pending,
               lastVisibleBlocks > 0 {
                stableChecks += 1
                if stableChecks >= 4 { break }
            } else {
                stableChecks = 0
            }
            prevDocH = nowDocH
            prevClipY = nowClipY
            try? await Task.sleep(for: .milliseconds(120))
        }
        guard stableChecks >= 4 else {
            let reason = String(
                format: "inconclusive: settle loop timed out before 4 stable samples (stableChecks=%d/4 lastDocHDelta=%.2f lastClipYDelta=%.2f historyLoadPending=%@ visibleBlocks=%d secondsLeft=%.1f)",
                stableChecks,
                lastDocHDelta,
                lastClipYDelta,
                lastPending ? "true" : "false",
                lastVisibleBlocks,
                secondsLeft()
            )
            note("mid-scroll-settle", reason)
            return .inconclusive(reason)
        }
        // Let the 150ms recent-wheel window expire so the timeline starts completely at rest.
        try? await Task.sleep(for: .milliseconds(250))

        guard let settledSnap = readMidScrollSnapshot(currentScroll, tracking: currentTracking, monoTime: CACurrentMediaTime()) else {
            note("mid-scroll-centered", "failed: could not read settled snapshot")
            return .failed
        }
        let stillHasPill = hasEarlierMessagesPill(in: currentScroll)
        let stillPending = currentTracking?.historyLoadPending ?? false
        guard !stillHasPill, !stillPending else {
            note("mid-scroll-centered", "failed: hidden/history not settled (earlierPill=\(stillHasPill) pending=\(stillPending))")
            return .failed
        }
        guard settledSnap.topMargin > settledSnap.viewportHeight * 2,
              settledSnap.bottomMargin > settledSnap.viewportHeight * 2,
              !settledSnap.visibleBlocks.isEmpty else {
            note(
                "mid-scroll-centered",
                String(
                    format: "failed: not centered in loaded region (topMargin=%.1f bottomMargin=%.1f viewport=%.1f visibleBlocks=%d)",
                    settledSnap.topMargin, settledSnap.bottomMargin, settledSnap.viewportHeight, settledSnap.visibleBlocks.count
                )
            )
            return .failed
        }

        await shoot(recorder, stage, "mid-scroll-middle")
        let topTurnText = visibleTopTurn(in: currentScroll).map(String.init) ?? "unknown"
        note(
            "mid-scroll-centered",
            String(
                format: "docHeight=%.1f clipMinY=%.1f topMargin=%.1f bottomMargin=%.1f topTurn=%@ visibleBlocks=%d trackingResolved=%@ expandedTurn=%@ expandedSteps=%@",
                settledSnap.docHeight, settledSnap.clipMinY, settledSnap.topMargin, settledSnap.bottomMargin,
                topTurnText, settledSnap.visibleBlocks.count, currentTracking != nil ? "true" : "false",
                expandedTarget.map { String($0.turn) } ?? "none",
                expandedStepsTurns.isEmpty ? "none" : expandedStepsTurns.map(String.init).joined(separator: ",")
            )
        )
        return .ready(
            window: currentWindow,
            scroll: currentScroll,
            tracking: currentTracking,
            expandedBlock: expandedTarget,
            expandedStepsTurns: expandedStepsTurns
        )
    }

    /// `--mid-scroll-history`: keep earlier history unloaded, unpin from the tail with a short
    /// upward scroll (leaving enough room above bottom for stage 2/5 without hitting bottom, and
    /// positioning close enough to the top of the initial window that stage 1 loads multiple
    /// earlier pages without hitting Turn 1), then settle before publishing readiness.
    private static func prepareHistoryTail(
        window: NSWindow,
        scroll: NSScrollView,
        upSign: Int32,
        recorder: Recorder,
        stage: Stage
    ) async -> MidScrollPrepareResult {
        var currentWindow = window
        var currentScroll = scroll
        var currentTracking = timelineTracking(in: currentScroll)

        let viewportH = Double(max(240, unobstructedViewportRect(in: currentScroll).height))
        let desiredBottomMargin = max(360.0, viewportH * 0.65)
        let safeTopFloor = viewportH * 1.6

        // Step 1: Unpin from bottom through real upward wheel input without triggering a page load yet.
        var unpinAttempts = 0
        while unpinAttempts < 5, secondsLeft() > 75 {
            if let liveWin = appWindow(), let liveScr = timelineScroll(in: liveWin) {
                currentWindow = liveWin
                currentScroll = liveScr
                currentTracking = timelineTracking(in: liveScr) ?? currentTracking
            }
            if let snap = readMidScrollSnapshot(currentScroll, tracking: currentTracking, monoTime: CACurrentMediaTime()) {
                if snap.bottomMargin >= desiredBottomMargin || snap.topMargin <= safeTopFloor {
                    break
                }
            }
            currentTracking?.noteWheelInput(offsetDelta: -160)
            await burst(upSign * 160, times: 3, window: currentWindow, scroll: currentScroll, direct: true)
            unpinAttempts += 1
        }

        // Step 2: If the initial 12-turn tail window is tall (>2.2 viewports above the reader),
        // nudge upward inside the initial window so topMargin sits around 1.8 viewports (still
        // strictly above the 1.0-viewport geometry load trigger so no page loads pre-readiness,
        // while stage 1's 20 upward flicks trigger multiple earlier-history page loads).
        if let liveWin = appWindow(), let liveScr = timelineScroll(in: liveWin) {
            currentWindow = liveWin
            currentScroll = liveScr
            currentTracking = timelineTracking(in: liveScr) ?? currentTracking
        }
        if let snap = readMidScrollSnapshot(currentScroll, tracking: currentTracking, monoTime: CACurrentMediaTime()),
           snap.topMargin > snap.viewportHeight * 2.2 {
            let targetTopMargin = snap.viewportHeight * 1.8
            let targetY = CGFloat(targetTopMargin - snap.topInset)
            let clip = currentScroll.contentView
            let delta = targetY - clip.bounds.minY
            currentTracking?.noteWheelInput(offsetDelta: delta)
            let targetRect = NSRect(origin: NSPoint(x: clip.bounds.minX, y: targetY), size: clip.bounds.size)
            clip.scroll(to: clip.constrainBoundsRect(targetRect).origin)
            currentScroll.reflectScrolledClipView(clip)
            try? await Task.sleep(for: .milliseconds(350))
        }

        // Step 3: Wait for 4 consecutive stable settle samples before writing readiness.
        var stableChecks = 0
        var prevDocH = Double(currentScroll.documentView?.bounds.height ?? 0)
        var prevClipY = Double(currentScroll.contentView.bounds.minY)
        var lastDocHDelta = 0.0
        var lastClipYDelta = 0.0
        var lastPending = false
        var lastVisibleBlocks = 0
        let settleDeadline = Date.now.addingTimeInterval(6.0)
        while Date.now < settleDeadline, secondsLeft() > 60 {
            if let liveWin = appWindow(), let liveScr = timelineScroll(in: liveWin) {
                currentWindow = liveWin
                currentScroll = liveScr
                currentTracking = timelineTracking(in: liveScr) ?? currentTracking
            }
            let nowDocH = Double(currentScroll.documentView?.bounds.height ?? 0)
            let nowClipY = Double(currentScroll.contentView.bounds.minY)
            let snap = readMidScrollSnapshot(currentScroll, tracking: currentTracking, monoTime: CACurrentMediaTime())
            let pending = currentTracking?.historyLoadPending ?? false
            lastDocHDelta = abs(nowDocH - prevDocH)
            lastClipYDelta = abs(nowClipY - prevClipY)
            lastPending = pending
            lastVisibleBlocks = snap?.visibleBlocks.count ?? 0
            if lastDocHDelta <= 0.5,
               lastClipYDelta <= 0.5,
               !pending,
               lastVisibleBlocks > 0 {
                stableChecks += 1
                if stableChecks >= 4 { break }
            } else {
                stableChecks = 0
            }
            prevDocH = nowDocH
            prevClipY = nowClipY
            try? await Task.sleep(for: .milliseconds(120))
        }
        guard stableChecks >= 4 else {
            let reason = String(
                format: "inconclusive: history-tail settle timed out before 4 stable samples (stableChecks=%d/4 lastDocHDelta=%.2f lastClipYDelta=%.2f historyLoadPending=%@ visibleBlocks=%d secondsLeft=%.1f)",
                stableChecks,
                lastDocHDelta,
                lastClipYDelta,
                lastPending ? "true" : "false",
                lastVisibleBlocks,
                secondsLeft()
            )
            note("mid-scroll-settle", reason)
            return .inconclusive(reason)
        }
        // Let the 150ms recent-wheel window expire so the timeline starts completely at rest.
        try? await Task.sleep(for: .milliseconds(250))

        guard let settledSnap = readMidScrollSnapshot(currentScroll, tracking: currentTracking, monoTime: CACurrentMediaTime()) else {
            note("mid-scroll-history-prep", "failed: could not read settled snapshot")
            return .failed
        }
        // Earlier history is still unloaded when Turn 1 is not mounted; there may be no pill.
        let hasPill = hasEarlierMessagesPill(in: currentScroll) || (mountedLowestTurn(in: currentScroll) ?? 1) > 1
        let stillPending = currentTracking?.historyLoadPending ?? false
        guard hasPill, !stillPending, !settledSnap.visibleBlocks.isEmpty, settledSnap.bottomMargin >= 120 else {
            note(
                "mid-scroll-history-prep",
                String(
                    format: "failed: tail not ready for history paging (earlierPill=%@ pending=%@ topMargin=%.1f bottomMargin=%.1f visibleBlocks=%d)",
                    hasPill ? "true" : "false",
                    stillPending ? "true" : "false",
                    settledSnap.topMargin,
                    settledSnap.bottomMargin,
                    settledSnap.visibleBlocks.count
                )
            )
            return .failed
        }

        await shoot(recorder, stage, "mid-scroll-middle")
        let topTurnText = visibleTopTurn(in: currentScroll).map(String.init) ?? "unknown"
        let lowestTurnText = mountedLowestTurn(in: currentScroll).map(String.init) ?? "unknown"
        note(
            "mid-scroll-history-prep",
            String(
                format: "docHeight=%.1f clipMinY=%.1f topMargin=%.1f bottomMargin=%.1f topTurn=%@ lowestTurn=%@ earlierPill=%@ visibleBlocks=%d trackingResolved=%@",
                settledSnap.docHeight, settledSnap.clipMinY, settledSnap.topMargin, settledSnap.bottomMargin,
                topTurnText, lowestTurnText, hasPill ? "true" : "false",
                settledSnap.visibleBlocks.count, currentTracking != nil ? "true" : "false"
            )
        )
        return .ready(
            window: currentWindow,
            scroll: currentScroll,
            tracking: currentTracking,
            expandedBlock: nil,
            expandedStepsTurns: []
        )
    }

    private struct MidScrollMixFixture {
        let name: String
        let path: String
        let aspectLabel: String
    }

    private static func writeMixPNGFixture(
        to url: URL,
        width: Int,
        height: Int,
        r: UInt8,
        g: UInt8,
        b: UInt8
    ) -> Bool {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: width * 4,
            bitsPerPixel: 32
        ), let dataPtr = rep.bitmapData else { return false }
        let rowBytes = rep.bytesPerRow
        for y in 0..<height {
            let stripe = (y / 24) % 2 == 0
            let row = dataPtr.advanced(by: y * rowBytes)
            for x in 0..<width {
                let offset = x * 4
                let accent = stripe && ((x / 32) % 2 == 0)
                row[offset] = accent ? UInt8(min(255, Int(r) + 35)) : r
                row[offset + 1] = accent ? UInt8(min(255, Int(g) + 35)) : g
                row[offset + 2] = accent ? UInt8(min(255, Int(b) + 35)) : b
                row[offset + 3] = 255
            }
        }
        guard let pngData = rep.representation(using: .png, properties: [:]) else { return false }
        do {
            try pngData.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    private static func createMidScrollMixFixtures(in output: URL) -> [MidScrollMixFixture] {
        let dir = output.appendingPathComponent("mix-fixtures", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let specs: [(name: String, width: Int, height: Int, r: UInt8, g: UInt8, b: UInt8, aspect: String)] = [
            ("mix-wide-16x9.png", 640, 360, 46, 98, 168, "16:9"),
            ("mix-square-1x1.png", 420, 420, 62, 138, 110, "1:1"),
            ("mix-portrait-9x16.png", 320, 568, 152, 84, 132, "9:16"),
            ("mix-banner-21x9.png", 840, 360, 174, 118, 52, "21:9"),
        ]
        var fixtures: [MidScrollMixFixture] = []
        for spec in specs {
            let url = dir.appendingPathComponent(spec.name)
            if writeMixPNGFixture(to: url, width: spec.width, height: spec.height, r: spec.r, g: spec.g, b: spec.b) {
                fixtures.append(MidScrollMixFixture(name: spec.name, path: url.path, aspectLabel: spec.aspect))
            }
        }
        return fixtures
    }

    private static func seedMidScroll(
        _ model: AppModel,
        threadID: UUID,
        count: Int,
        scenario: MidScrollScenario,
        output: URL,
        minSecondsLeft: TimeInterval
    ) async -> MidScrollSeedResult {
        let runtime = model.runtime(for: threadID)
        let ready = Date.now.addingTimeInterval(5)
        while runtime.isLoadingHistory, Date.now < ready {
            try? await Task.sleep(for: .milliseconds(40))
        }
        let mixFixtures = scenario.mix ? createMidScrollMixFixtures(in: output) : []
        let compactForHistory = scenario.history
        var seeded = 0
        var legacyTurnEndCount = 0
        var turnRowKinds: [Int: String] = [:]
        var seededRowKinds: [String: Int] = [:]
        var codeBlockCandidates: [MidScrollCodeBlockCandidate] = []
        var longActivityTurns: [Int] = []
        var skippedRowKinds: [String] = []
        if scenario.mix {
            skippedRowKinds.append(
                "persisted-disclosure-preseed: TimelinePresentationStore is private in ThreadTimeline.swift so seeding API cannot pre-populate TimelinePresentation.finished/disclosures (non-history prep toggles up to 2 mounted turns via UI button instead)"
            )
            if mixFixtures.isEmpty {
                skippedRowKinds.append("tool-image-preview: failed to write PNG fixtures in run directory")
            }
        }

        func markLegacyTurnEnd() {
            if let endEntry = runtime.entries.last(where: { $0.kind == .turnEnd }),
               case .turnEnd(var summary) = endEntry.item.content {
                summary.filesChanged = max(1, summary.filesChanged)
                summary.additions = max(3, summary.additions)
                summary.deletions = max(1, summary.deletions)
                summary.changes = nil
                endEntry.item.content = .turnEnd(summary)
                legacyTurnEndCount += 1
            }
        }

        for turn in 1...count {
            guard secondsLeft() > minSecondsLeft else { break }
            if !scenario.mix {
                let rowKind = midScrollDefaultRowKind(turn)
                turnRowKinds[turn] = rowKind
                seededRowKinds[rowKind, default: 0] += 1
                if turn % 6 == 0 {
                    codeBlockCandidates.append(MidScrollCodeBlockCandidate(
                        turn: turn,
                        lineCount: 145,
                        precedingID: "turn-\(turn)-mid",
                        followingID: "turn-\(turn)-closing"
                    ))
                } else if turn % 12 == 5 {
                    codeBlockCandidates.append(MidScrollCodeBlockCandidate(
                        turn: turn,
                        lineCount: 135,
                        precedingID: "turn-\(turn)-intro",
                        followingID: "turn-\(turn)-closing"
                    ))
                }

                let wantsLegacyDiff = turn.isMultiple(of: 6) || turn % 6 == 4
                if wantsLegacyDiff {
                    runtime.rehearseTurn(
                        midScrollQuestion(turn),
                        touchedPaths: ["Tivano/App/Views/Composer/ComposerView.swift"],
                        providerDiff: midScrollSamplePatch
                    )
                    let toolID = "mid-scroll-edit-\(turn)"
                    runtime.rehearse(.toolStarted(
                        id: toolID,
                        call: ToolCall(kind: .edit, title: "Edit", detail: "ComposerView.swift · turn \(turn)")
                    ))
                    runtime.rehearse(.toolUpdated(
                        id: toolID,
                        update: ToolUpdate(
                            status: .completed,
                            edits: [FileEdit(
                                path: "Tivano/App/Views/Composer/ComposerView.swift",
                                diff: midScrollSamplePatch,
                                additions: 3,
                                deletions: 1
                            )]
                        )
                    ))
                    runtime.rehearse(.messageDelta(
                        id: "mid-scroll-\(turn)",
                        text: midScrollAnswer(turn, compactForHistory: compactForHistory)
                    ))
                    await finish(runtime, id: "mid-scroll-\(turn)")
                    markLegacyTurnEnd()
                } else {
                    await speak(
                        runtime,
                        id: "mid-scroll-\(turn)",
                        user: midScrollQuestion(turn),
                        answer: midScrollAnswer(turn, compactForHistory: compactForHistory)
                    )
                }
            } else {
                let slot = turn % 12
                let rowKind: String
                switch slot {
                case 0:
                    rowKind = "tall-table+code+legacy-diff"
                    codeBlockCandidates.append(MidScrollCodeBlockCandidate(
                        turn: turn,
                        lineCount: 145,
                        precedingID: "turn-\(turn)-mid",
                        followingID: "turn-\(turn)-closing"
                    ))
                    runtime.rehearseTurn(
                        midScrollQuestion(turn),
                        touchedPaths: ["Tivano/App/Views/Composer/ComposerView.swift"],
                        providerDiff: midScrollSamplePatch
                    )
                    let toolID = "mid-scroll-edit-\(turn)"
                    runtime.rehearse(.toolStarted(
                        id: toolID,
                        call: ToolCall(kind: .edit, title: "Edit", detail: "ComposerView.swift · turn \(turn)")
                    ))
                    runtime.rehearse(.toolUpdated(
                        id: toolID,
                        update: ToolUpdate(
                            status: .completed,
                            edits: [FileEdit(
                                path: "Tivano/App/Views/Composer/ComposerView.swift",
                                diff: midScrollSamplePatch,
                                additions: 3,
                                deletions: 1
                            )]
                        )
                    ))
                    runtime.rehearse(.messageDelta(
                        id: "mid-scroll-\(turn)",
                        text: midScrollAnswer(turn, compactForHistory: compactForHistory)
                    ))
                    await finish(runtime, id: "mid-scroll-\(turn)")
                    markLegacyTurnEnd()

                case 1:
                    rowKind = "links-favicon+youtube+user-link-bubble"
                    let userText = "Turn \(turn) - question: Compare https://github.com/apple/swift and https://developer.apple.com/documentation/swiftui with https://www.youtube.com/watch?v=jNQXAC9IVRw for checkpoint \(turn)."
                    await speak(
                        runtime,
                        id: "mid-scroll-\(turn)",
                        user: userText,
                        answer: midScrollMixLinksAnswer(turn: turn, compactForHistory: compactForHistory)
                    )

                case 2:
                    rowKind = "wrapping-table"
                    await speak(
                        runtime,
                        id: "mid-scroll-\(turn)",
                        user: midScrollQuestion(turn),
                        answer: midScrollAnswer(turn, compactForHistory: compactForHistory)
                    )

                case 3:
                    rowKind = "tool-image-preview-single"
                    runtime.rehearseTurn("Turn \(turn) - question: Capture the timeline fixture screenshot and summarize layout geometry for checkpoint \(turn).")
                    if !mixFixtures.isEmpty {
                        let fixture = mixFixtures[(turn / 12) % mixFixtures.count]
                        let toolID = "mid-scroll-img-\(turn)"
                        runtime.rehearse(.toolStarted(
                            id: toolID,
                            call: ToolCall(kind: .command, title: "Capture preview", detail: fixture.path)
                        ))
                        runtime.rehearse(.toolUpdated(
                            id: toolID,
                            update: ToolUpdate(
                                output: "Saved \(fixture.aspectLabel) fixture at \(fixture.path)",
                                status: .completed,
                                images: [Attachment(name: fixture.name, path: fixture.path, mimeType: "image/png")]
                            )
                        ))
                    }
                    runtime.rehearse(.messageDelta(
                        id: "mid-scroll-\(turn)",
                        text: [
                            "Turn \(turn) - answer: Single tool image preview checkpoint \(turn). Tool attachments render inline above the reply via `AttachmentStrip` and reload thumbnails asynchronously when remounted.",
                            "",
                            "Turn \(turn) - closing: Verify the preview reserves its aspect height across unmount/remount cycles for checkpoint \(turn).",
                        ].joined(separator: "\n")
                    ))
                    await finish(runtime, id: "mid-scroll-\(turn)")

                case 4:
                    rowKind = "table+legacy-diff"
                    runtime.rehearseTurn(
                        midScrollQuestion(turn),
                        touchedPaths: ["Tivano/App/Views/Composer/ComposerView.swift"],
                        providerDiff: midScrollSamplePatch
                    )
                    let toolID = "mid-scroll-edit-\(turn)"
                    runtime.rehearse(.toolStarted(
                        id: toolID,
                        call: ToolCall(kind: .edit, title: "Edit", detail: "ComposerView.swift · turn \(turn)")
                    ))
                    runtime.rehearse(.toolUpdated(
                        id: toolID,
                        update: ToolUpdate(
                            status: .completed,
                            edits: [FileEdit(
                                path: "Tivano/App/Views/Composer/ComposerView.swift",
                                diff: midScrollSamplePatch,
                                additions: 3,
                                deletions: 1
                            )]
                        )
                    ))
                    runtime.rehearse(.messageDelta(
                        id: "mid-scroll-\(turn)",
                        text: midScrollAnswer(turn, compactForHistory: compactForHistory)
                    ))
                    await finish(runtime, id: "mid-scroll-\(turn)")
                    markLegacyTurnEnd()

                case 5:
                    rowKind = "long-code-135"
                    codeBlockCandidates.append(MidScrollCodeBlockCandidate(
                        turn: turn,
                        lineCount: 135,
                        precedingID: "turn-\(turn)-intro",
                        followingID: "turn-\(turn)-closing"
                    ))
                    await speak(
                        runtime,
                        id: "mid-scroll-\(turn)",
                        user: midScrollQuestion(turn),
                        answer: midScrollAnswer(turn, compactForHistory: compactForHistory)
                    )

                case 6:
                    rowKind = "long-activity-group-66+reasoning"
                    longActivityTurns.append(turn)
                    runtime.rehearseTurn("Turn \(turn) - question: Run the 66-step inspection sweep across timeline modules for checkpoint \(turn).")
                    let reasonID = "mid-scroll-reason-\(turn)"
                    runtime.rehearse(.reasoningDelta(
                        id: reasonID,
                        text: "Checkpoint \(turn): auditing 66 tool steps so ActivityTreeGroup exceeds its 60-step page limit and exposes the earlier-steps paging row."
                    ))
                    runtime.rehearse(.reasoningCompleted(id: reasonID, text: ""))
                    let trailingWorkOrder = ((turn / 12) % 2) == 0
                    if trailingWorkOrder {
                        runtime.rehearse(.messageDelta(
                            id: "mid-scroll-\(turn)",
                            text: [
                                "Turn \(turn) - answer: Completed 66-step activity sweep for checkpoint \(turn) (trailing work group opens directly when this turn's steps are expanded).",
                                "",
                                "Turn \(turn) - closing: Paging row hides the first 6 steps behind `Show 6 earlier steps` at checkpoint \(turn).",
                            ].joined(separator: "\n")
                        ))
                        runtime.rehearse(.messageCompleted(id: "mid-scroll-\(turn)", text: ""))
                    }
                    for step in 1...66 {
                        let toolID = "mid-scroll-step-\(turn)-\(step)"
                        let kind: ToolCall.Kind = step.isMultiple(of: 3) ? .search : (step.isMultiple(of: 2) ? .command : .read)
                        let title = kind == .search ? "Search" : (kind == .command ? "Run check" : "Read")
                        runtime.rehearse(.toolStarted(
                            id: toolID,
                            call: ToolCall(kind: kind, title: title, detail: "Tivano/App/Views/Chat/Module\(step).swift")
                        ))
                        runtime.rehearse(.toolUpdated(
                            id: toolID,
                            update: ToolUpdate(output: "Step \(step)/66 verified for turn \(turn)", status: .completed)
                        ))
                    }
                    if !trailingWorkOrder {
                        runtime.rehearse(.messageDelta(
                            id: "mid-scroll-\(turn)",
                            text: [
                                "Turn \(turn) - answer: Completed 66-step activity sweep for checkpoint \(turn) (work group starts collapsed under the turn disclosure).",
                                "",
                                "Turn \(turn) - closing: Finished 66-step group checkpoint \(turn).",
                            ].joined(separator: "\n")
                        ))
                        await finish(runtime, id: "mid-scroll-\(turn)")
                    } else {
                        runtime.rehearse(.turnCompleted(status: .completed, error: nil))
                        let limit = Date.now.addingTimeInterval(8)
                        while runtime.isRunning, Date.now < limit {
                            try? await Task.sleep(for: .milliseconds(40))
                        }
                    }

                case 7:
                    rowKind = "short+user-link-bubble"
                    let userText = "Turn \(turn) - question: Quick bubble link check https://swift.org and https://www.youtube.com/watch?v=dQw4w9WgXcQ for row \(turn)."
                    await speak(
                        runtime,
                        id: "mid-scroll-\(turn)",
                        user: userText,
                        answer: "Turn \(turn) - answer: Compact reply under a link-bearing user bubble at checkpoint \(turn)."
                    )

                case 8:
                    rowKind = "multi-paragraph+links"
                    await speak(
                        runtime,
                        id: "mid-scroll-\(turn)",
                        user: "Turn \(turn) - question: Write the multi-paragraph architecture notes with reference links for checkpoint \(turn).",
                        answer: midScrollMixParagraphLinksAnswer(turn: turn, compactForHistory: compactForHistory)
                    )

                case 9:
                    rowKind = "tool-image-preview-strip+reasoning"
                    runtime.rehearseTurn("Turn \(turn) - question: Compare the multi-aspect preview strip screenshots for checkpoint \(turn).")
                    let reasonID = "mid-scroll-reason-\(turn)"
                    runtime.rehearse(.reasoningDelta(
                        id: reasonID,
                        text: "Checkpoint \(turn): gathering wide, square, and portrait PNG fixtures into one tool result strip."
                    ))
                    runtime.rehearse(.reasoningCompleted(id: reasonID, text: ""))
                    if !mixFixtures.isEmpty {
                        let stripFixtures = Array(mixFixtures.prefix(3))
                        let attachments = stripFixtures.map {
                            Attachment(name: $0.name, path: $0.path, mimeType: "image/png")
                        }
                        let toolID = "mid-scroll-strip-\(turn)"
                        runtime.rehearse(.toolStarted(
                            id: toolID,
                            call: ToolCall(kind: .mcp, title: "Render screenshots", detail: stripFixtures[0].path)
                        ))
                        runtime.rehearse(.toolUpdated(
                            id: toolID,
                            update: ToolUpdate(
                                output: "Attached \(attachments.count) preview images across aspect ratios",
                                status: .completed,
                                images: attachments
                            )
                        ))
                    }
                    runtime.rehearse(.messageDelta(
                        id: "mid-scroll-\(turn)",
                        text: [
                            "Turn \(turn) - answer: Multi-image tool preview strip checkpoint \(turn) combining wide 16:9, square 1:1, and portrait 9:16 PNG fixtures.",
                            "",
                            "Turn \(turn) - closing: Strip thumbnails stay visible above the folded reply at checkpoint \(turn).",
                        ].joined(separator: "\n")
                    ))
                    await finish(runtime, id: "mid-scroll-\(turn)")

                case 10:
                    rowKind = "folded-multi-step-turn+reasoning"
                    runtime.rehearseTurn("Turn \(turn) - question: Inspect multiple files and deliver a folded multi-reply summary for checkpoint \(turn).")
                    let reasonID = "mid-scroll-reason-\(turn)"
                    runtime.rehearse(.reasoningDelta(
                        id: reasonID,
                        text: "Checkpoint \(turn): collecting tool outputs before merging consecutive assistant replies into a folded finished turn."
                    ))
                    runtime.rehearse(.reasoningCompleted(id: reasonID, text: ""))
                    for step in 1...8 {
                        let toolID = "mid-scroll-fold-step-\(turn)-\(step)"
                        runtime.rehearse(.toolStarted(
                            id: toolID,
                            call: ToolCall(kind: step.isMultiple(of: 2) ? .read : .search, title: step.isMultiple(of: 2) ? "Read" : "Search", detail: "ThreadTimeline.swift · pass \(step)")
                        ))
                        runtime.rehearse(.toolUpdated(
                            id: toolID,
                            update: ToolUpdate(output: "Checked section \(step)", status: .completed)
                        ))
                    }
                    runtime.rehearse(.messageDelta(
                        id: "mid-scroll-\(turn)-a",
                        text: "Turn \(turn) - answer: First folded reply fragment for checkpoint \(turn). Eight intermediate tool calls stay folded behind the turn chevron."
                    ))
                    runtime.rehearse(.messageCompleted(id: "mid-scroll-\(turn)-a", text: ""))
                    runtime.rehearse(.messageDelta(
                        id: "mid-scroll-\(turn)-b",
                        text: "Turn \(turn) - closing: Second folded reply fragment merged via `FoldedAnswerView` for checkpoint \(turn)."
                    ))
                    await finish(runtime, id: "mid-scroll-\(turn)-b")

                default:
                    rowKind = "short"
                    await speak(
                        runtime,
                        id: "mid-scroll-\(turn)",
                        user: midScrollQuestion(turn),
                        answer: "Turn \(turn) - answer: Short row \(turn) stays single-paragraph to keep alternating row heights realistic."
                    )
                }
                turnRowKinds[turn] = rowKind
                seededRowKinds[rowKind, default: 0] += 1
            }
            seeded = turn
        }
        let kindsSummary = seededRowKinds.keys.sorted().map { "\($0)=\(seededRowKinds[$0] ?? 0)" }.joined(separator: ",")
        note(
            "mid-scroll-seed",
            "\(seeded) of \(count) turns on \(threadID.uuidString) legacyTurnEnd=\(legacyTurnEndCount) mix=\(scenario.mix) history=\(scenario.history) kinds=\(kindsSummary) running=\(runtime.isRunning)"
        )
        return MidScrollSeedResult(
            seeded: seeded,
            legacyTurnEndCount: legacyTurnEndCount,
            turnRowKinds: turnRowKinds,
            seededRowKinds: seededRowKinds,
            skippedRowKinds: skippedRowKinds,
            codeBlockCandidates: codeBlockCandidates,
            longActivityTurns: longActivityTurns
        )
    }

    private static func midScrollDefaultRowKind(_ turn: Int) -> String {
        switch turn % 6 {
        case 0: return "tall-table+code+legacy-diff"
        case 1: return "short"
        case 2: return "wrapping-table"
        case 3: return "multi-paragraph"
        case 4: return "table+legacy-diff"
        default: return turn % 12 == 5 ? "long-code-135" : "short"
        }
    }

    private static func midScrollMixLinksAnswer(turn: Int, compactForHistory: Bool) -> String {
        var lines = [
            "Turn \(turn) - answer: Link-heavy prose checkpoint \(turn) exercising async favicon fetches for stable sites and oEmbed title resolution for bare YouTube URLs.",
            "",
            "Reference docs: [Apple](https://apple.com), [GitHub](https://github.com), [Swift.org](https://swift.org), [Mozilla](https://mozilla.org), and [Wikipedia](https://wikipedia.org) alongside bare URLs https://developer.apple.com and https://cloudflare.com.",
            "",
            "Video references (bare URLs trigger `LinkTitles` async title replacement): https://www.youtube.com/watch?v=dQw4w9WgXcQ and https://youtu.be/aqz-KE-bpKQ.",
        ]
        if !compactForHistory {
            lines.append("")
            lines.append("Secondary links paragraph for checkpoint \(turn): https://stripe.com, https://github.com/swiftlang/swift, and https://www.youtube.com/watch?v=jNQXAC9IVRw can wrap onto extra lines once favicons and video titles arrive asynchronously.")
        }
        lines.append("")
        lines.append("Turn \(turn) - closing: Link paragraph checkpoint \(turn) complete.")
        return lines.joined(separator: "\n")
    }

    private static func midScrollMixParagraphLinksAnswer(turn: Int, compactForHistory: Bool) -> String {
        let paragraphCount = compactForHistory ? 3 : 6
        var paragraphs = [
            "Turn \(turn) - answer: Multi-paragraph architecture notes with inline links for checkpoint \(turn).",
            "",
        ]
        for para in 1...paragraphCount {
            paragraphs.append(
                "Paragraph \(para) of checkpoint \(turn) cites https://apple.com and https://github.com plus https://www.youtube.com/watch?v=aqz-KE-bpKQ while explaining how wrapped prose blocks above the viewport must keep stable heights across remounts and async asset fetches."
            )
            paragraphs.append("")
        }
        paragraphs.append("Turn \(turn) - closing: End of linked multi-paragraph reply for checkpoint \(turn).")
        return paragraphs.joined(separator: "\n")
    }

    private static func midScrollRowKind(for blockID: String, turnRowKinds: [Int: String]) -> String {
        if blockID == "unmatched-clip" { return "unmatched-clip" }
        if blockID.hasPrefix("nested-scroll-") { return "nested-scroll" }
        if blockID.hasPrefix("turn-") {
            let afterPrefix = blockID.dropFirst("turn-".count)
            let digits = afterPrefix.prefix { $0.isWholeNumber && $0.isASCII }
            if !digits.isEmpty, let turnNum = Int(digits) {
                let baseKind = turnRowKinds[turnNum] ?? "turn-\(turnNum)"
                let rest = afterPrefix[digits.endIndex...]
                if rest.hasPrefix("-") {
                    let subTag = String(rest.dropFirst())
                    return "\(baseKind)(\(subTag))"
                }
                return baseKind
            }
        }
        return "unknown"
    }

    private static func midScrollQuestion(_ turn: Int) -> String {
        switch turn % 6 {
        case 0:
            return "Turn \(turn) - question: Walk the full table wrapping, long code excerpt, and turn-end diff summary for section \(turn)."
        case 1:
            return "Turn \(turn) - question: Quick check \(turn) — does the short row stay compact?"
        case 2:
            return "Turn \(turn) - question: Show the four-column wrapping comparison table for checkpoint \(turn)."
        case 3:
            return "Turn \(turn) - question: Write out the multi-paragraph architecture notes for checkpoint \(turn)."
        case 4:
            return "Turn \(turn) - question: Update ComposerView.swift insets and summarize the table for checkpoint \(turn)."
        default:
            if turn % 12 == 5 {
                return "Turn \(turn) - question: Include the full >120-line diagnostic script for checkpoint \(turn)."
            }
            return "Turn \(turn) - question: One-line status confirmation for checkpoint \(turn)."
        }
    }

    private static func midScrollWrappingTable(turn: Int, rows: Int) -> String {
        var lines = [
            "| Stage | Timeline behavior under bidirectional scroll | Remount geometry impact | Expected anchor outcome |",
            "| --- | --- | --- | --- |",
        ]
        for row in 1...rows {
            lines.append(
                "| T\(turn).R\(row) | Scrolling past checkpoint \(turn) row \(row) mounts and unmounts blocks outside the active viewport window at column width. | Wrapping multi-word table cells expand vertically when width resolves after initial layout pass \(row). | Visible blocks below this row stay pinned to the reader's wheel motion without vertical lurching. |"
            )
        }
        return lines.joined(separator: "\n")
    }

    private static func midScrollLongCodeBlock(turn: Int, language: String, linesCount: Int) -> String {
        var lines = ["```\(language)"]
        for line in 1...linesCount {
            if language == "swift" {
                lines.append("let rowMetric_\(turn)_\(line) = TimelineRowSample(turn: \(turn), line: \(line), width: 820.0, wrappedHeight: \(18 + (line % 7) * 4), stable: true)")
            } else {
                lines.append("sample_\(turn)_\(line) = dict(turn=\(turn), line=\(line), column_width=820, wrapped_height=\(18 + (line % 5) * 6), anchor_stable=True)")
            }
        }
        lines.append("```")
        return lines.joined(separator: "\n")
    }

    private static func midScrollAnswer(_ turn: Int, compactForHistory: Bool = false) -> String {
        switch turn % 6 {
        case 0:
            // Tall turn (>1 viewport): intro prose + wrapping table + middle prose + >120-line code block + closing prose.
            let tableRows = compactForHistory ? 4 : 10
            return [
                "Turn \(turn) - answer: Comprehensive tall-turn layout check \(turn) combining wrapping Markdown table cells, a 145-line fenced code block, and a turn-end diff summary.",
                "",
                "When the reader flicks upward and downward through the middle of a finished conversation, rows crossing the mounted-window boundary above the viewport must neither change measured height unexpectedly nor shift visible content relative to the trackpad deltas.",
                "",
                midScrollWrappingTable(turn: turn, rows: tableRows),
                "",
                "Turn \(turn) - middle: Following the wrapped table above, the 145-line Swift code excerpt below exceeds the 120-line collapse threshold and stretches this turn well beyond a single viewport height.",
                "",
                midScrollLongCodeBlock(turn: turn, language: "swift", linesCount: 145),
                "",
                "Turn \(turn) - closing: Closing summary for tall turn \(turn). The accompanying turn-end record carries `filesChanged = 1` with `changes == nil` so remounting exercises legacy diff hydration alongside table wrapping.",
            ].joined(separator: "\n")

        case 1:
            return "Turn \(turn) - answer: Short confirmation for row \(turn); keeps compact two-line spacing between taller neighbours."

        case 2:
            let tableRows = compactForHistory ? 4 : 12
            return [
                "Turn \(turn) - answer: Wrapping Markdown table check \(turn). Each row carries four wide prose cells that wrap across multiple lines at the 820pt timeline column width.",
                "",
                midScrollWrappingTable(turn: turn, rows: tableRows),
                "",
                "Turn \(turn) - closing: Table check \(turn) finishes with stable column wrapping once measured width is retained across remounts.",
            ].joined(separator: "\n")

        case 3:
            let paragraphCount = compactForHistory ? 3 : 8
            var paragraphs = [
                "Turn \(turn) - answer: Multi-paragraph architecture reply for checkpoint \(turn), sized to exceed one full viewport of wrapped prose and structured list items.",
                "",
                "### Viewport anchor notes (\(turn))",
                "",
                "- Track each visible block's `minY` in viewport coordinates (`docFrame.minY - clipView.bounds.minY`) rather than `documentHeight - clipMinY`.",
                "- Ignore below-viewport growth when top-anchored in the middle of a completed thread.",
                "- Compare observed `contentMotion` directly against sign-normalized local `.scrollWheel` event deltas.",
                "",
            ]
            for para in 1...paragraphCount {
                paragraphs.append(
                    "Paragraph \(para) of checkpoint \(turn). Bidirectional trackpad scrolling in the interior of a long conversation repeatedly evicts older rows into top spacers and materializes them again on the way back up. If any remounted row above the visible viewport re-wraps a table or asynchronously hydrates a diff summary card without synchronous clip compensation, every block currently on screen lurches downward by the uncompensated height delta."
                )
                paragraphs.append("")
            }
            paragraphs.append("Turn \(turn) - closing: End of multi-paragraph analysis for checkpoint \(turn).")
            return paragraphs.joined(separator: "\n")

        case 4:
            let tableRows = compactForHistory ? 3 : 8
            return [
                "Turn \(turn) - answer: Edit and wrapping-table check \(turn). Applies the `ComposerView.swift` inset diff while leaving `TurnSummary.changes` unset on seed so remounts exercise legacy diff hydration.",
                "",
                midScrollWrappingTable(turn: turn, rows: tableRows),
                "",
                "Turn \(turn) - closing: Finished table and turn-end summary checkpoint \(turn).",
            ].joined(separator: "\n")

        default:
            if turn % 12 == 5 {
                return [
                    "Turn \(turn) - answer: Long code-block checkpoint \(turn) containing 135 lines of Python (over the 120-line threshold).",
                    "",
                    midScrollLongCodeBlock(turn: turn, language: "python", linesCount: 135),
                    "",
                    "Turn \(turn) - closing: Code-block checkpoint \(turn) complete.",
                ].joined(separator: "\n")
            }
            return "Turn \(turn) - answer: Short row \(turn) stays single-paragraph to keep alternating row heights realistic."
        }
    }

    private static func timelineTracking(in scroll: NSScrollView) -> TimelineScrollTracking? {
        guard let document = scroll.documentView else { return nil }
        for view in findAll(NSView.self, in: document) {
            for child in Mirror(reflecting: view).children {
                if child.label == "tracking", let tracking = child.value as? TimelineScrollTracking {
                    return tracking
                }
            }
        }
        return nil
    }

    private static func earlierMessagesPillSuffix() -> String {
        let formatted = String(format: NSLocalizedString("Show %lld earlier messages", comment: ""), Int64(12345))
        if let range = formatted.range(of: "12345") {
            let tail = String(formatted[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            if !tail.isEmpty { return tail }
        }
        return "earlier messages"
    }

    private static func hasEarlierMessagesPill(in scroll: NSScrollView) -> Bool {
        guard let document = scroll.documentView else { return false }
        let suffix = earlierMessagesPillSuffix()
        var queue: [AnyObject] = [document]
        var visited = Set<ObjectIdentifier>()
        var cursor = 0
        while cursor < queue.count, cursor < 512 {
            let node = queue[cursor]
            cursor += 1
            guard visited.insert(ObjectIdentifier(node)).inserted else { continue }
            var texts: [String] = []
            if let view = node as? NSView {
                if let title = view.accessibilityTitle() { texts.append(title) }
                if let label = view.accessibilityLabel() { texts.append(label) }
                if let value = view.accessibilityValue() as? String { texts.append(value) }
                if let children = view.accessibilityChildren() {
                    for child in children { queue.append(child as AnyObject) }
                }
                for subview in view.subviews { queue.append(subview) }
            }
            for text in texts where text.contains("earlier messages") || text.contains(suffix) {
                return true
            }
        }
        return false
    }

    private static func collectTimelineViews(
        in root: NSView,
        excluding outerScroll: NSScrollView,
        textViews: inout [NSTextView],
        nestedScrolls: inout [NSScrollView]
    ) {
        if let text = root as? NSTextView {
            textViews.append(text)
        } else if let nested = root as? NSScrollView, nested !== outerScroll {
            nestedScrolls.append(nested)
        }
        for child in root.subviews {
            collectTimelineViews(in: child, excluding: outerScroll, textViews: &textViews, nestedScrolls: &nestedScrolls)
        }
    }

    private static func midScrollBlockID(for text: String) -> String? {
        var remainder = text[...]
        while let range = remainder.range(of: "Turn ") {
            let afterTurn = remainder[range.upperBound...]
            let digits = afterTurn.prefix { $0.isWholeNumber && $0.isASCII }
            if !digits.isEmpty {
                let afterDigits = afterTurn[digits.endIndex...]
                if afterDigits.hasPrefix(" - "), let turnNumber = Int(digits) {
                    let afterDash = afterDigits.dropFirst(3)
                    let tag: String
                    if afterDash.hasPrefix("answer") {
                        tag = "intro"
                    } else if afterDash.hasPrefix("middle") {
                        tag = "mid"
                    } else if afterDash.hasPrefix("closing") {
                        tag = "closing"
                    } else if afterDash.hasPrefix("question") {
                        tag = "question"
                    } else {
                        tag = "text"
                    }
                    return "turn-\(turnNumber)-\(tag)"
                }
            }
            remainder = afterTurn
        }
        return nil
    }

    private static func showAllLinesLabels(for lineCount: Int) -> [String] {
        let english = "Show all \(lineCount) lines"
        let localized = String(format: NSLocalizedString("Show all %lld lines", comment: ""), Int64(lineCount))
        return localized == english ? [english] : [english, localized]
    }

    private struct MidScrollToggleButtonMatch {
        let node: AnyObject
        let docFrame: NSRect
        let screenFrame: NSRect
        let lineCount: Int
    }

    /// Accessibility getters read through their Objective-C selectors: SwiftUI's nodes are
    /// plain NSObjects, and Swift does not import these as optional protocol methods.
    private static func axValue(_ object: NSObject, _ key: String) -> Any? {
        guard object.responds(to: Selector((key))) else { return nil }
        return object.value(forKey: key)
    }

    private static func axTexts(_ object: NSObject) -> [String] {
        ["accessibilityTitle", "accessibilityLabel", "accessibilityValue"].compactMap { key in
            (axValue(object, key) as? String).flatMap { $0.isEmpty ? nil : $0 }
        }
    }

    private static func findCodeBlockToggleButtons(
        in document: NSView,
        window: NSWindow,
        lineCounts: [Int]
    ) -> [MidScrollToggleButtonMatch] {
        let candidatesByLineCount = lineCounts.map { count in
            (count: count, labels: showAllLinesLabels(for: count))
        }
        var matches: [MidScrollToggleButtonMatch] = []
        var queue: [AnyObject] = [document]
        var visited = Set<ObjectIdentifier>()
        var cursor = 0
        while cursor < queue.count, cursor < 8192 {
            let node = queue[cursor]
            cursor += 1
            guard visited.insert(ObjectIdentifier(node)).inserted else { continue }

            var texts: [String] = []
            var role: NSAccessibility.Role?
            var screenFrame: NSRect = .zero
            if let ax = node as? NSObject {
                texts.append(contentsOf: axTexts(ax))
                role = axValue(ax, "accessibilityRole").flatMap { ($0 as? String).map(NSAccessibility.Role.init(rawValue:)) }
                if let frame = (axValue(ax, "accessibilityFrame") as? NSValue)?.rectValue { screenFrame = frame }
                if let children = axValue(ax, "accessibilityChildren") as? [Any] {
                    for child in children { queue.append(child as AnyObject) }
                }
            }
            if let view = node as? NSView {
                for subview in view.subviews { queue.append(subview) }
            }

            let isButtonLike = (node is NSButton) || role == .button || role == .link
            guard isButtonLike else { continue }

            if texts.isEmpty, let ax = node as? NSObject, let children = axValue(ax, "accessibilityChildren") as? [Any] {
                for child in children {
                    if let childAX = child as? NSObject { texts.append(contentsOf: axTexts(childAX)) }
                }
            }

            var matchedLineCount: Int?
            outer: for entry in candidatesByLineCount {
                for text in texts {
                    for label in entry.labels where text == label || text.contains(label) {
                        matchedLineCount = entry.count
                        break outer
                    }
                }
            }
            guard let matchedLineCount else { continue }

            var resolvedScreenFrame = screenFrame
            if resolvedScreenFrame.width <= 1 || resolvedScreenFrame.height <= 1, let view = node as? NSView {
                let winRect = view.convert(view.bounds, to: nil)
                resolvedScreenFrame = window.convertToScreen(winRect)
            }
            guard resolvedScreenFrame.width > 1, resolvedScreenFrame.height > 1 else { continue }
            let winRect = window.convertFromScreen(resolvedScreenFrame)
            let docFrame = document.convert(winRect, from: nil)
            matches.append(MidScrollToggleButtonMatch(
                node: node,
                docFrame: docFrame,
                screenFrame: resolvedScreenFrame,
                lineCount: matchedLineCount
            ))
        }
        return matches
    }

    private static func findMountedTurnLayout(
        in scroll: NSScrollView
    ) -> (textFrames: [String: NSRect], nestedScrolls: [(scroll: NSScrollView, docFrame: NSRect, docHeight: Double)]) {
        guard let document = scroll.documentView else { return ([:], []) }
        var textViews: [NSTextView] = []
        var nestedScrolls: [NSScrollView] = []
        collectTimelineViews(in: document, excluding: scroll, textViews: &textViews, nestedScrolls: &nestedScrolls)

        var textFrames: [String: NSRect] = [:]
        for view in textViews {
            guard !(view is ComposerNSTextView),
                  !view.isHiddenOrHasHiddenAncestor,
                  view.bounds.width > 1, view.bounds.height > 1,
                  let blockID = midScrollBlockID(for: view.string) else { continue }
            if textFrames[blockID] == nil {
                textFrames[blockID] = view.convert(view.bounds, to: document)
            }
        }

        var nestedFrames: [(scroll: NSScrollView, docFrame: NSRect, docHeight: Double)] = []
        nestedFrames.reserveCapacity(nestedScrolls.count)
        for nested in nestedScrolls {
            guard !(nested.documentView is ComposerNSTextView),
                  !nested.isHiddenOrHasHiddenAncestor,
                  nested.bounds.width > 1, nested.bounds.height > 1 else { continue }
            let docFrame = nested.convert(nested.bounds, to: document)
            let docHeight = Double(nested.documentView?.bounds.height ?? nested.bounds.height)
            nestedFrames.append((nested, docFrame, docHeight))
        }
        return (textFrames, nestedFrames)
    }

    private static func codeBlockHeightBetween(
        precedingID: String,
        followingID: String,
        in scroll: NSScrollView
    ) -> (height: Double, bandMinY: CGFloat, bandMaxY: CGFloat)? {
        let layout = findMountedTurnLayout(in: scroll)
        guard let prevFrame = layout.textFrames[precedingID],
              let nextFrame = layout.textFrames[followingID],
              nextFrame.minY > prevFrame.minY else { return nil }
        let bandMinY = prevFrame.minY
        let bandMaxY = nextFrame.maxY
        let matching = layout.nestedScrolls.filter { item in
            item.docFrame.midY >= bandMinY && item.docFrame.midY <= bandMaxY
        }
        guard let tallest = matching.max(by: { $0.docHeight < $1.docHeight }), tallest.docHeight > 400 else {
            return nil
        }
        return (tallest.docHeight, bandMinY, bandMaxY)
    }

    private static func scrollDocYToViewportCenter(
        _ docY: CGFloat,
        in scroll: NSScrollView,
        tracking: TimelineScrollTracking?
    ) {
        let clip = scroll.contentView
        let viewport = unobstructedViewportRect(in: scroll)
        let targetY = docY - viewport.height * 0.5
        tracking?.noteWheelInput(offsetDelta: 40)
        let rect = NSRect(origin: NSPoint(x: clip.bounds.minX, y: targetY), size: clip.bounds.size)
        clip.scroll(to: clip.constrainBoundsRect(rect).origin)
        scroll.reflectScrolledClipView(clip)
    }

    private static func prepareExpandedCodeBlock(
        window: NSWindow,
        scroll: NSScrollView,
        tracking: TimelineScrollTracking?,
        candidates: [MidScrollCodeBlockCandidate]
    ) async -> MidScrollExpandedBlockTarget? {
        var currentWindow = window
        var currentScroll = scroll
        var currentTracking = tracking
        guard currentScroll.documentView != nil, !candidates.isEmpty else { return nil }

        let lineCounts = Array(Set(candidates.map(\.lineCount))).sorted(by: >)
        let baseClipY = currentScroll.contentView.bounds.minY
        let viewportH = max(240, unobstructedViewportRect(in: currentScroll).height)
        let probeOffsets: [CGFloat] = [0, viewportH * 0.8, -viewportH * 0.8, viewportH * 1.6, -viewportH * 1.6]

        struct Candidate {
            let turn: Int
            let lineCount: Int
            let precedingID: String
            let followingID: String
            let buttonDocMidY: CGFloat
            let distFromBase: CGFloat
        }

        var chosen: Candidate?
        for offset in probeOffsets {
            if offset != 0 {
                let clip = currentScroll.contentView
                currentTracking?.noteWheelInput(offsetDelta: offset)
                let rect = NSRect(origin: NSPoint(x: clip.bounds.minX, y: baseClipY + offset), size: clip.bounds.size)
                clip.scroll(to: clip.constrainBoundsRect(rect).origin)
                currentScroll.reflectScrolledClipView(clip)
                try? await Task.sleep(for: .milliseconds(350))
            }
            if let liveWin = appWindow(), let liveScr = timelineScroll(in: liveWin) {
                currentWindow = liveWin
                currentScroll = liveScr
                currentTracking = timelineTracking(in: liveScr) ?? currentTracking
            }
            guard let document = currentScroll.documentView else { continue }
            let buttons = findCodeBlockToggleButtons(in: document, window: currentWindow, lineCounts: lineCounts)
            guard !buttons.isEmpty else { continue }
            let layout = findMountedTurnLayout(in: currentScroll)
            let centerY = baseClipY + viewportH * 0.5
            for btn in buttons {
                for spec in candidates where btn.lineCount == spec.lineCount {
                    guard let prevFrame = layout.textFrames[spec.precedingID],
                          let nextFrame = layout.textFrames[spec.followingID],
                          btn.docFrame.midY >= prevFrame.minY,
                          btn.docFrame.midY <= nextFrame.maxY + 40 else { continue }
                    let dist = abs(btn.docFrame.midY - centerY)
                    if chosen == nil || dist < chosen!.distFromBase {
                        chosen = Candidate(
                            turn: spec.turn,
                            lineCount: spec.lineCount,
                            precedingID: spec.precedingID,
                            followingID: spec.followingID,
                            buttonDocMidY: btn.docFrame.midY,
                            distFromBase: dist
                        )
                    }
                }
            }
            if chosen != nil { break }
        }

        guard let target = chosen else {
            note("mid-scroll-expand-code", "unavailable: no collapsed >120-line code block button found near middle")
            return nil
        }

        scrollDocYToViewportCenter(target.buttonDocMidY, in: currentScroll, tracking: currentTracking)
        try? await Task.sleep(for: .milliseconds(350))

        if let liveWin = appWindow(), let liveScr = timelineScroll(in: liveWin) {
            currentWindow = liveWin
            currentScroll = liveScr
            currentTracking = timelineTracking(in: liveScr) ?? currentTracking
        }
        guard let document = currentScroll.documentView,
              let beforeMetrics = codeBlockHeightBetween(
                precedingID: target.precedingID,
                followingID: target.followingID,
                in: currentScroll
              ) else {
            note("mid-scroll-expand-code", "unavailable: could not measure collapsed code block height for turn=\(target.turn)")
            return nil
        }

        let freshButtons = findCodeBlockToggleButtons(in: document, window: currentWindow, lineCounts: [target.lineCount])
            .filter { $0.docFrame.midY >= beforeMetrics.bandMinY && $0.docFrame.midY <= beforeMetrics.bandMaxY + 40 }
        guard let buttonMatch = freshButtons.first else {
            note("mid-scroll-expand-code", "unavailable: lost toggle button for turn=\(target.turn) after scrolling to center")
            return nil
        }

        var method = "ax"
        if let nsButton = buttonMatch.node as? NSButton {
            nsButton.performClick(nil)
            method = "nsbutton"
        } else if let ax = buttonMatch.node as? NSObject,
                  ax.responds(to: Selector(("accessibilityPerformPress"))) {
            _ = ax.perform(Selector(("accessibilityPerformPress")))
            method = "ax-press"
        } else {
            method = "ax-unhandled"
        }
        try? await Task.sleep(for: .milliseconds(350))

        var afterHeight = codeBlockHeightBetween(
            precedingID: target.precedingID,
            followingID: target.followingID,
            in: currentScroll
        )?.height ?? beforeMetrics.height

        if afterHeight < beforeMetrics.height + 80 {
            // Fallback: synthetic click on the button frame in window coordinates.
            let retryButtons = findCodeBlockToggleButtons(in: document, window: currentWindow, lineCounts: [target.lineCount])
                .filter { $0.docFrame.midY >= beforeMetrics.bandMinY && $0.docFrame.midY <= beforeMetrics.bandMaxY + 40 }
            let frameToClick = retryButtons.first?.screenFrame ?? buttonMatch.screenFrame
            let clickPoint = currentWindow.convertPoint(
                fromScreen: NSPoint(x: frameToClick.midX, y: frameToClick.midY)
            )
            let now = ProcessInfo.processInfo.systemUptime
            if let down = NSEvent.mouseEvent(
                with: .leftMouseDown,
                location: clickPoint,
                modifierFlags: [],
                timestamp: now,
                windowNumber: currentWindow.windowNumber,
                context: nil,
                eventNumber: 1,
                clickCount: 1,
                pressure: 1
            ), let up = NSEvent.mouseEvent(
                with: .leftMouseUp,
                location: clickPoint,
                modifierFlags: [],
                timestamp: now + 0.02,
                windowNumber: currentWindow.windowNumber,
                context: nil,
                eventNumber: 2,
                clickCount: 1,
                pressure: 0
            ) {
                currentWindow.sendEvent(down)
                try? await Task.sleep(for: .milliseconds(25))
                currentWindow.sendEvent(up)
                method = "synthetic-click"
                try? await Task.sleep(for: .milliseconds(350))
                afterHeight = codeBlockHeightBetween(
                    precedingID: target.precedingID,
                    followingID: target.followingID,
                    in: currentScroll
                )?.height ?? afterHeight
            }
        }

        guard afterHeight >= beforeMetrics.height + 80 else {
            note(
                "mid-scroll-expand-code",
                String(
                    format: "unavailable: press (%@) did not expand turn=%d lines=%d height %.1f->%.1fpt",
                    method, target.turn, target.lineCount, beforeMetrics.height, afterHeight
                )
            )
            return nil
        }

        let updatedMetrics = codeBlockHeightBetween(
            precedingID: target.precedingID,
            followingID: target.followingID,
            in: currentScroll
        )
        let anchorDocY = Double(updatedMetrics?.bandMinY ?? beforeMetrics.bandMinY)
        note(
            "mid-scroll-expand-code",
            String(
                format: "expanded turn=%d lines=%d height %.1f->%.1fpt method=%@",
                target.turn, target.lineCount, beforeMetrics.height, afterHeight, method
            )
        )
        return MidScrollExpandedBlockTarget(
            turn: target.turn,
            lineCount: target.lineCount,
            precedingBlockID: target.precedingID,
            followingBlockID: target.followingID,
            collapsedHeight: beforeMetrics.height,
            expandedHeight: afterHeight,
            anchorDocY: anchorDocY
        )
    }

    private static func showTurnStepsLabels() -> [String] {
        let english = "Show this turn's steps"
        let localized = NSLocalizedString("Show this turn's steps", comment: "")
        return localized == english ? [english] : [english, localized]
    }

    private static func findTurnStepsToggleButtons(
        in document: NSView,
        window: NSWindow
    ) -> [(node: AnyObject, docFrame: NSRect, screenFrame: NSRect)] {
        let labels = showTurnStepsLabels()
        var matches: [(node: AnyObject, docFrame: NSRect, screenFrame: NSRect)] = []
        var queue: [AnyObject] = [document]
        var visited = Set<ObjectIdentifier>()
        var cursor = 0
        while cursor < queue.count, cursor < 8192 {
            let node = queue[cursor]
            cursor += 1
            guard visited.insert(ObjectIdentifier(node)).inserted else { continue }

            var texts: [String] = []
            var role: NSAccessibility.Role?
            var screenFrame: NSRect = .zero
            if let ax = node as? NSObject {
                texts.append(contentsOf: axTexts(ax))
                role = axValue(ax, "accessibilityRole").flatMap { ($0 as? String).map(NSAccessibility.Role.init(rawValue:)) }
                if let frame = (axValue(ax, "accessibilityFrame") as? NSValue)?.rectValue { screenFrame = frame }
                if let children = axValue(ax, "accessibilityChildren") as? [Any] {
                    for child in children { queue.append(child as AnyObject) }
                }
            }
            if let view = node as? NSView {
                for subview in view.subviews { queue.append(subview) }
            }

            let isButtonLike = (node is NSButton) || role == .button || role == .link
            guard isButtonLike else { continue }
            guard texts.contains(where: { text in labels.contains { text == $0 || text.contains($0) } }) else { continue }

            var resolvedScreenFrame = screenFrame
            if resolvedScreenFrame.width <= 1 || resolvedScreenFrame.height <= 1, let view = node as? NSView {
                let winRect = view.convert(view.bounds, to: nil)
                resolvedScreenFrame = window.convertToScreen(winRect)
            }
            guard resolvedScreenFrame.width > 1, resolvedScreenFrame.height > 1 else { continue }
            let winRect = window.convertFromScreen(resolvedScreenFrame)
            let docFrame = document.convert(winRect, from: nil)
            matches.append((node: node, docFrame: docFrame, screenFrame: resolvedScreenFrame))
        }
        return matches
    }

    private static func prepareExpandedStepsTurns(
        window: NSWindow,
        scroll: NSScrollView,
        tracking: TimelineScrollTracking?,
        candidateTurns: [Int],
        maxToExpand: Int = 2
    ) async -> [Int] {
        var currentWindow = window
        var currentScroll = scroll
        var currentTracking = tracking
        guard currentScroll.documentView != nil, !candidateTurns.isEmpty else { return [] }

        let baseClipY = currentScroll.contentView.bounds.minY
        let viewportH = max(240, unobstructedViewportRect(in: currentScroll).height)
        let probeOffsets: [CGFloat] = [0, viewportH * 0.9, -viewportH * 0.9, viewportH * 1.8, -viewportH * 1.8]
        var expandedTurns: [Int] = []

        for offset in probeOffsets {
            if expandedTurns.count >= maxToExpand || secondsLeft() <= 68 { break }
            if offset != 0 {
                let clip = currentScroll.contentView
                currentTracking?.noteWheelInput(offsetDelta: offset)
                let rect = NSRect(origin: NSPoint(x: clip.bounds.minX, y: baseClipY + offset), size: clip.bounds.size)
                clip.scroll(to: clip.constrainBoundsRect(rect).origin)
                currentScroll.reflectScrolledClipView(clip)
                try? await Task.sleep(for: .milliseconds(350))
            }
            if let liveWin = appWindow(), let liveScr = timelineScroll(in: liveWin) {
                currentWindow = liveWin
                currentScroll = liveScr
                currentTracking = timelineTracking(in: liveScr) ?? currentTracking
            }
            guard let document = currentScroll.documentView else { continue }
            let buttons = findTurnStepsToggleButtons(in: document, window: currentWindow)
            guard !buttons.isEmpty else { continue }
            let layout = findMountedTurnLayout(in: currentScroll)

            for turn in candidateTurns where !expandedTurns.contains(turn) {
                if expandedTurns.count >= maxToExpand { break }
                guard let qFrame = layout.textFrames["turn-\(turn)-question"],
                      let aFrame = layout.textFrames["turn-\(turn)-intro"] else { continue }
                guard let match = buttons.first(where: { btn in
                    btn.docFrame.midY >= qFrame.minY && btn.docFrame.midY <= aFrame.maxY
                }) else { continue }

                scrollDocYToViewportCenter(match.docFrame.midY, in: currentScroll, tracking: currentTracking)
                try? await Task.sleep(for: .milliseconds(300))
                if let liveWin = appWindow(), let liveScr = timelineScroll(in: liveWin) {
                    currentWindow = liveWin
                    currentScroll = liveScr
                    currentTracking = timelineTracking(in: liveScr) ?? currentTracking
                }
                guard let freshDoc = currentScroll.documentView else { continue }
                let freshLayout = findMountedTurnLayout(in: currentScroll)
                guard let freshQ = freshLayout.textFrames["turn-\(turn)-question"],
                      let freshA = freshLayout.textFrames["turn-\(turn)-intro"] else { continue }
                let freshButtons = findTurnStepsToggleButtons(in: freshDoc, window: currentWindow)
                guard let freshMatch = freshButtons.first(where: { btn in
                    btn.docFrame.midY >= freshQ.minY && btn.docFrame.midY <= freshA.maxY
                }) else { continue }

                let beforeDocH = Double(freshDoc.bounds.height)
                if let nsButton = freshMatch.node as? NSButton {
                    nsButton.performClick(nil)
                } else if let ax = freshMatch.node as? NSObject,
                          ax.responds(to: Selector(("accessibilityPerformPress"))) {
                    _ = ax.perform(Selector(("accessibilityPerformPress")))
                }
                try? await Task.sleep(for: .milliseconds(350))
                var afterDocH = Double(currentScroll.documentView?.bounds.height ?? 0)
                if afterDocH < beforeDocH + 40 {
                    let clickPoint = currentWindow.convertPoint(
                        fromScreen: NSPoint(x: freshMatch.screenFrame.midX, y: freshMatch.screenFrame.midY)
                    )
                    let now = ProcessInfo.processInfo.systemUptime
                    if let down = NSEvent.mouseEvent(
                        with: .leftMouseDown,
                        location: clickPoint,
                        modifierFlags: [],
                        timestamp: now,
                        windowNumber: currentWindow.windowNumber,
                        context: nil,
                        eventNumber: 1,
                        clickCount: 1,
                        pressure: 1
                    ), let up = NSEvent.mouseEvent(
                        with: .leftMouseUp,
                        location: clickPoint,
                        modifierFlags: [],
                        timestamp: now + 0.02,
                        windowNumber: currentWindow.windowNumber,
                        context: nil,
                        eventNumber: 2,
                        clickCount: 1,
                        pressure: 0
                    ) {
                        currentWindow.sendEvent(down)
                        try? await Task.sleep(for: .milliseconds(25))
                        currentWindow.sendEvent(up)
                        try? await Task.sleep(for: .milliseconds(350))
                        afterDocH = Double(currentScroll.documentView?.bounds.height ?? 0)
                    }
                }
                if afterDocH >= beforeDocH + 40 {
                    expandedTurns.append(turn)
                    note(
                        "mid-scroll-expand-steps",
                        String(format: "expanded turn=%d steps docHeight %.1f->%.1fpt", turn, beforeDocH, afterDocH)
                    )
                }
            }
        }
        return expandedTurns
    }

    private static func verifyExpandedCodeBlock(
        target: MidScrollExpandedBlockTarget,
        samples: [MidScrollSnapshot],
        window: NSWindow,
        scroll: NSScrollView,
        tracking: TimelineScrollTracking?,
        turnCount: Int
    ) async -> MidScrollExpandedBlockResult {
        var currentWindow = window
        var currentScroll = scroll
        var currentTracking = tracking

        var evictedDuringRun = samples.contains { snap in
            snap.mountedBlocks[target.precedingBlockID] == nil && snap.mountedBlocks[target.followingBlockID] == nil
        }

        // Guarantee the target block actually cycled off mountedWindow before checking restoration.
        if !evictedDuringRun {
            let clip = currentScroll.contentView
            let viewportH = max(240, unobstructedViewportRect(in: currentScroll).height)
            let topMinY = -currentScroll.contentInsets.top
            let docH = currentScroll.documentView?.bounds.height ?? 0
            let maxY = max(topMinY, docH - clip.bounds.height)
            let awayY: CGFloat = (clip.bounds.minY - topMinY) > viewportH * 5.5
                ? max(topMinY, clip.bounds.minY - viewportH * 5.0)
                : min(maxY, clip.bounds.minY + viewportH * 5.0)
            currentTracking?.noteWheelInput(offsetDelta: awayY - clip.bounds.minY)
            let awayRect = NSRect(origin: NSPoint(x: clip.bounds.minX, y: awayY), size: clip.bounds.size)
            clip.scroll(to: clip.constrainBoundsRect(awayRect).origin)
            currentScroll.reflectScrolledClipView(clip)
            try? await Task.sleep(for: .milliseconds(450))
            if let snap = readMidScrollSnapshot(currentScroll, tracking: currentTracking, monoTime: CACurrentMediaTime()),
               snap.mountedBlocks[target.precedingBlockID] == nil,
               snap.mountedBlocks[target.followingBlockID] == nil {
                evictedDuringRun = true
            }
        }

        // Scroll back to target turn and let layout settle.
        scrollDocYToViewportCenter(CGFloat(target.anchorDocY), in: currentScroll, tracking: currentTracking)
        try? await Task.sleep(for: .milliseconds(350))

        for _ in 0..<10 {
            if let liveWin = appWindow(), let liveScr = timelineScroll(in: liveWin) {
                currentWindow = liveWin
                currentScroll = liveScr
                currentTracking = timelineTracking(in: liveScr) ?? currentTracking
            }
            if codeBlockHeightBetween(
                precedingID: target.precedingBlockID,
                followingID: target.followingBlockID,
                in: currentScroll
            ) != nil {
                break
            }
            let clip = currentScroll.contentView
            let docH = max(1, currentScroll.documentView?.bounds.height ?? 1)
            let perTurn = max(280, docH / CGFloat(max(1, turnCount)))
            let stepDelta: CGFloat
            if let topTurn = visibleTopTurn(in: currentScroll) {
                stepDelta = CGFloat(target.turn - topTurn) * perTurn
            } else {
                stepDelta = CGFloat(target.anchorDocY) - clip.bounds.minY
            }
            let nextY = clip.bounds.minY + stepDelta
            currentTracking?.noteWheelInput(offsetDelta: stepDelta)
            let rect = NSRect(origin: NSPoint(x: clip.bounds.minX, y: nextY), size: clip.bounds.size)
            clip.scroll(to: clip.constrainBoundsRect(rect).origin)
            currentScroll.reflectScrolledClipView(clip)
            try? await Task.sleep(for: .milliseconds(300))
        }

        try? await Task.sleep(for: .milliseconds(400))
        if let liveWin = appWindow(), let liveScr = timelineScroll(in: liveWin) {
            currentWindow = liveWin
            currentScroll = liveScr
        }
        guard let document = currentScroll.documentView,
              let afterMetrics = codeBlockHeightBetween(
                precedingID: target.precedingBlockID,
                followingID: target.followingBlockID,
                in: currentScroll
              ) else {
            let detail = "unavailable: could not relocate turn=\(target.turn) code block after run"
            note("mid-scroll-expanded-block", detail)
            return MidScrollExpandedBlockResult(
                status: "unavailable",
                turn: target.turn,
                lineCount: target.lineCount,
                collapsedHeight: target.collapsedHeight,
                expandedHeight: target.expandedHeight,
                restoredHeight: nil,
                evictedDuringRun: evictedDuringRun,
                detail: detail
            )
        }

        let collapsedButtons = findCodeBlockToggleButtons(
            in: document,
            window: currentWindow,
            lineCounts: [target.lineCount]
        ).filter { $0.docFrame.midY >= afterMetrics.bandMinY && $0.docFrame.midY <= afterMetrics.bandMaxY + 40 }
        let threshold = target.collapsedHeight + max(80.0, (target.expandedHeight - target.collapsedHeight) * 0.5)
        let isRestored = afterMetrics.height >= threshold && collapsedButtons.isEmpty
        // Restoration means surviving an unmount: without an observed eviction it is unknown.
        let status = !evictedDuringRun ? "unavailable" : (isRestored ? "true" : "false")
        let detail = String(
            format: "restored=%@ turn=%d lines=%d collapsed=%.1fpt expanded=%.1fpt after=%.1fpt threshold=%.1fpt collapsedButton=%@ evicted=%@",
            status,
            target.turn,
            target.lineCount,
            target.collapsedHeight,
            target.expandedHeight,
            afterMetrics.height,
            threshold,
            collapsedButtons.isEmpty ? "false" : "true",
            evictedDuringRun ? "true" : "false"
        )
        note("mid-scroll-expanded-block", detail)
        return MidScrollExpandedBlockResult(
            status: status,
            turn: target.turn,
            lineCount: target.lineCount,
            collapsedHeight: target.collapsedHeight,
            expandedHeight: target.expandedHeight,
            restoredHeight: afterMetrics.height,
            evictedDuringRun: evictedDuringRun,
            detail: detail
        )
    }

    private static func readMidScrollSnapshot(
        _ scroll: NSScrollView,
        tracking: TimelineScrollTracking?,
        monoTime: CFTimeInterval
    ) -> MidScrollSnapshot? {
        guard let document = scroll.documentView else { return nil }
        let clipMinY = Double(scroll.contentView.bounds.minY)
        let docHeight = Double(document.bounds.height)
        let topInset = Double(scroll.contentInsets.top)
        let visibleRect = scroll.documentVisibleRect
        let viewport = unobstructedViewportRect(in: scroll)
        let viewportHeight = Double(max(1, viewport.height))
        let topMargin = clipMinY + topInset
        let bottomMargin = docHeight - Double(visibleRect.maxY)

        var textViews: [NSTextView] = []
        var nestedScrolls: [NSScrollView] = []
        collectTimelineViews(in: document, excluding: scroll, textViews: &textViews, nestedScrolls: &nestedScrolls)

        var visibleBlocks: [String: Double] = [:]
        var visibleTextIDs: Set<String> = []
        var mountedBlocks: [String: Double] = [:]
        var mountedTextIDs: Set<String> = []

        var textItems: [(id: String, docMinY: Double, screenMinY: Double, isVisible: Bool)] = []
        textItems.reserveCapacity(textViews.count)
        for view in textViews {
            guard !(view is ComposerNSTextView),
                  !view.isHiddenOrHasHiddenAncestor,
                  view.bounds.width > 1, view.bounds.height > 1 else { continue }
            guard let baseID = midScrollBlockID(for: view.string) else { continue }
            let docFrame = view.convert(view.bounds, to: document)
            let screenMinY = Double(docFrame.minY) - clipMinY
            let overlap = docFrame.intersection(viewport)
            let isVisible = !overlap.isNull && !overlap.isEmpty && overlap.height > 2 && overlap.width > 2
            textItems.append((baseID, Double(docFrame.minY), screenMinY, isVisible))
        }
        textItems.sort { $0.docMinY < $1.docMinY }

        var seenCounts: [String: Int] = [:]
        for item in textItems {
            let count = seenCounts[item.id, default: 0]
            seenCounts[item.id] = count + 1
            let resolvedID = count == 0 ? item.id : "\(item.id)#\(count)"
            mountedBlocks[resolvedID] = item.screenMinY
            mountedTextIDs.insert(resolvedID)
            if item.isVisible {
                visibleBlocks[resolvedID] = item.screenMinY
                visibleTextIDs.insert(resolvedID)
            }
        }

        for nested in nestedScrolls {
            guard !(nested.documentView is ComposerNSTextView),
                  !nested.isHiddenOrHasHiddenAncestor,
                  nested.bounds.width > 1, nested.bounds.height > 1 else { continue }
            let docFrame = nested.convert(nested.bounds, to: document)
            let screenMinY = Double(docFrame.minY) - clipMinY
            let id = "nested-scroll-\(String(UInt(bitPattern: ObjectIdentifier(nested)), radix: 16))"
            mountedBlocks[id] = screenMinY
            let overlap = docFrame.intersection(viewport)
            if !overlap.isNull, !overlap.isEmpty, overlap.height > 2, overlap.width > 2 {
                visibleBlocks[id] = screenMinY
            }
        }

        return MidScrollSnapshot(
            monoTime: monoTime,
            clipMinY: clipMinY,
            docHeight: docHeight,
            topInset: topInset,
            viewportHeight: viewportHeight,
            topMargin: topMargin,
            bottomMargin: bottomMargin,
            historyLoadPending: tracking?.historyLoadPending ?? false,
            visibleBlocks: visibleBlocks,
            visibleTextIDs: visibleTextIDs,
            mountedBlocks: mountedBlocks,
            mountedTextIDs: mountedTextIDs
        )
    }

    private static func selectCommonMidScrollBlock(
        prev: MidScrollSnapshot,
        curr: MidScrollSnapshot
    ) -> (id: String, prevMinY: Double, currMinY: Double, fallback: Bool)? {
        let targetY = prev.viewportHeight * 0.5

        func best(
            in candidateIDs: [String],
            prevMap: [String: Double],
            currMap: [String: Double]
        ) -> (id: String, prevMinY: Double, currMinY: Double)? {
            var chosen: (id: String, prevMinY: Double, currMinY: Double, dist: Double)?
            for id in candidateIDs {
                guard let py = prevMap[id], let cy = currMap[id] else { continue }
                let dist = abs(py - targetY)
                if let existing = chosen {
                    if dist < existing.dist || (dist == existing.dist && id < existing.id) {
                        chosen = (id, py, cy, dist)
                    }
                } else {
                    chosen = (id, py, cy, dist)
                }
            }
            return chosen.map { ($0.id, $0.prevMinY, $0.currMinY) }
        }

        let commonVisibleText = prev.visibleTextIDs.intersection(curr.visibleTextIDs)
        if let match = best(in: Array(commonVisibleText), prevMap: prev.visibleBlocks, currMap: curr.visibleBlocks) {
            return (match.id, match.prevMinY, match.currMinY, false)
        }

        let commonVisibleAny = Set(prev.visibleBlocks.keys).intersection(curr.visibleBlocks.keys)
        if let match = best(in: Array(commonVisibleAny), prevMap: prev.visibleBlocks, currMap: curr.visibleBlocks) {
            return (match.id, match.prevMinY, match.currMinY, false)
        }

        let prevVisTextCurrMounted = prev.visibleTextIDs.intersection(curr.mountedTextIDs)
        if let match = best(in: Array(prevVisTextCurrMounted), prevMap: prev.visibleBlocks, currMap: curr.mountedBlocks) {
            return (match.id, match.prevMinY, match.currMinY, true)
        }

        let currVisTextPrevMounted = curr.visibleTextIDs.intersection(prev.mountedTextIDs)
        if let match = best(in: Array(currVisTextPrevMounted), prevMap: prev.mountedBlocks, currMap: curr.visibleBlocks) {
            return (match.id, match.prevMinY, match.currMinY, true)
        }

        let prevVisCurrMounted = Set(prev.visibleBlocks.keys).intersection(curr.mountedBlocks.keys)
        if let match = best(in: Array(prevVisCurrMounted), prevMap: prev.visibleBlocks, currMap: curr.mountedBlocks) {
            return (match.id, match.prevMinY, match.currMinY, true)
        }

        let currVisPrevMounted = Set(curr.visibleBlocks.keys).intersection(prev.mountedBlocks.keys)
        if let match = best(in: Array(currVisPrevMounted), prevMap: prev.mountedBlocks, currMap: curr.visibleBlocks) {
            return (match.id, match.prevMinY, match.currMinY, true)
        }

        return nil
    }

    private static func midScrollMomentumSum(quarterViewport: Double, count: Int = 21, ratio: Double = 0.85) -> Int32 {
        guard count > 0, quarterViewport > 0 else { return 0 }
        var weights: [Double] = []
        weights.reserveCapacity(count)
        var current = 1.0
        var weightSum = 0.0
        for _ in 0..<count {
            weights.append(current)
            weightSum += current
            current *= ratio
        }
        var total: Int32 = 0
        var exactAccum = 0.0
        var intAccum = 0
        for weight in weights {
            exactAccum += quarterViewport * (weight / weightSum)
            let nextInt = Int(exactAccum.rounded())
            let step = max(1, nextInt - intAccum)
            total += Int32(step)
            intAccum += step
        }
        return total
    }

    private static func timelineTraceURL() -> URL? {
        let raw = ProcessInfo.processInfo.environment["TIVANO_TIMELINE_TRACE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !raw.isEmpty else { return nil }
        let expanded = (raw as NSString).expandingTildeInPath
        guard !expanded.isEmpty else { return nil }
        return URL(fileURLWithPath: expanded, isDirectory: false)
    }

    private static func currentTimelineTraceLineCount() -> Int {
        guard let url = timelineTraceURL(),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return 0 }
        return text.split(separator: "\n", omittingEmptySubsequences: true).count
    }

    private static func parseTimelineTraceEvents(afterLineOffset baselineLines: Int) -> MidScrollTraceParseResult {
        guard let url = timelineTraceURL() else {
            return MidScrollTraceParseResult(
                enabled: false,
                path: nil,
                traceStartT: nil,
                traceCapped: false,
                compensations: [],
                appliedCount: 0,
                skippedCount: 0,
                skippedReasons: [:],
                totalAppliedMovedY: 0,
                historyLoadCount: 0,
                historyCompensations: [],
                historyAppliedCount: 0,
                historySkippedCount: 0,
                historySkippedReasons: [:],
                historyTotalAppliedMovedY: 0,
                historySyncShiftsAppliedCount: 0,
                historyRestoresAppliedCount: 0
            )
        }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return MidScrollTraceParseResult(
                enabled: true,
                path: url.path,
                traceStartT: nil,
                traceCapped: false,
                compensations: [],
                appliedCount: 0,
                skippedCount: 0,
                skippedReasons: [:],
                totalAppliedMovedY: 0,
                historyLoadCount: 0,
                historyCompensations: [],
                historyAppliedCount: 0,
                historySkippedCount: 0,
                historySkippedReasons: [:],
                historyTotalAppliedMovedY: 0,
                historySyncShiftsAppliedCount: 0,
                historyRestoresAppliedCount: 0
            )
        }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        var traceStartT: Int?
        var traceCapped = false
        for line in lines {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let eventName = obj["event"] as? String else { continue }
            if traceStartT == nil, eventName == "trace.start" {
                traceStartT = (obj["t"] as? NSNumber)?.intValue
            } else if eventName == "trace.capped" {
                traceCapped = true
            }
        }

        func parseOptionalBool(_ raw: Any?) -> Bool? {
            if let boolVal = raw as? Bool { return boolVal }
            if let numVal = raw as? NSNumber { return numVal.boolValue }
            return nil
        }

        let tail = lines.dropFirst(min(baselineLines, lines.count))
        var compensations: [MidScrollCompensationEvent] = []
        var appliedCount = 0
        var skippedCount = 0
        var skippedReasons: [String: Int] = [:]
        var totalAppliedMovedY = 0.0
        var historyLoadCount = 0
        var historyCompensations: [MidScrollCompensationEvent] = []
        var historyAppliedCount = 0
        var historySkippedCount = 0
        var historySkippedReasons: [String: Int] = [:]
        var historyTotalAppliedMovedY = 0.0
        var historySyncShiftsAppliedCount = 0
        var historyRestoresAppliedCount = 0

        for line in tail {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let eventName = obj["event"] as? String else { continue }
            if eventName == "timeline.aboveViewportCompensate" {
                let skipped = parseOptionalBool(obj["skipped"])
                let movedY = (obj["movedY"] as? NSNumber)?.doubleValue
                let reason = obj["reason"] as? String
                compensations.append(MidScrollCompensationEvent(
                    event: eventName,
                    t: (obj["t"] as? NSNumber)?.intValue,
                    alignedTime: nil,
                    seq: (obj["seq"] as? NSNumber)?.intValue,
                    source: obj["source"] as? String,
                    rowID: obj["rowID"] as? String,
                    delta: (obj["delta"] as? NSNumber)?.doubleValue,
                    growth: nil,
                    restoreDelta: nil,
                    historyReaderDelta: nil,
                    beforeY: (obj["beforeY"] as? NSNumber)?.doubleValue,
                    afterY: (obj["afterY"] as? NSNumber)?.doubleValue,
                    movedY: movedY,
                    skipped: skipped,
                    reason: reason
                ))
                if skipped == false {
                    appliedCount += 1
                    totalAppliedMovedY += movedY ?? 0
                } else if skipped == true {
                    skippedCount += 1
                    skippedReasons[reason ?? "unknown", default: 0] += 1
                }
            } else if eventName == "history.syncShift" {
                let skipped = parseOptionalBool(obj["skipped"])
                let movedY = (obj["movedY"] as? NSNumber)?.doubleValue
                let reason = obj["reason"] as? String
                historyCompensations.append(MidScrollCompensationEvent(
                    event: eventName,
                    t: (obj["t"] as? NSNumber)?.intValue,
                    alignedTime: nil,
                    seq: (obj["seq"] as? NSNumber)?.intValue,
                    source: obj["source"] as? String,
                    rowID: nil,
                    delta: nil,
                    growth: (obj["growth"] as? NSNumber)?.doubleValue,
                    restoreDelta: nil,
                    historyReaderDelta: nil,
                    beforeY: (obj["beforeY"] as? NSNumber)?.doubleValue,
                    afterY: (obj["afterY"] as? NSNumber)?.doubleValue,
                    movedY: movedY,
                    skipped: skipped,
                    reason: reason
                ))
                if skipped == false {
                    historyAppliedCount += 1
                    historySyncShiftsAppliedCount += 1
                    historyTotalAppliedMovedY += movedY ?? 0
                } else if skipped == true {
                    historySkippedCount += 1
                    historySkippedReasons["syncShift:\(reason ?? "unknown")", default: 0] += 1
                }
            } else if eventName == "history.restore" {
                let skipped = parseOptionalBool(obj["skipped"])
                let movedY = (obj["movedY"] as? NSNumber)?.doubleValue
                let reason = obj["reason"] as? String
                historyCompensations.append(MidScrollCompensationEvent(
                    event: eventName,
                    t: (obj["t"] as? NSNumber)?.intValue,
                    alignedTime: nil,
                    seq: (obj["seq"] as? NSNumber)?.intValue,
                    source: obj["source"] as? String,
                    rowID: nil,
                    delta: nil,
                    growth: nil,
                    restoreDelta: (obj["restoreDelta"] as? NSNumber)?.doubleValue,
                    historyReaderDelta: (obj["historyReaderDelta"] as? NSNumber)?.doubleValue,
                    beforeY: (obj["beforeY"] as? NSNumber)?.doubleValue,
                    afterY: (obj["afterY"] as? NSNumber)?.doubleValue,
                    movedY: movedY,
                    skipped: skipped,
                    reason: reason
                ))
                if skipped == false {
                    historyAppliedCount += 1
                    historyRestoresAppliedCount += 1
                    historyTotalAppliedMovedY += movedY ?? 0
                } else if skipped == true {
                    historySkippedCount += 1
                    historySkippedReasons["restore:\(reason ?? "unknown")", default: 0] += 1
                }
            } else if eventName == "history.load" {
                historyLoadCount += 1
            }
        }
        return MidScrollTraceParseResult(
            enabled: true,
            path: url.path,
            traceStartT: traceStartT,
            traceCapped: traceCapped,
            compensations: compensations,
            appliedCount: appliedCount,
            skippedCount: skippedCount,
            skippedReasons: skippedReasons,
            totalAppliedMovedY: totalAppliedMovedY,
            historyLoadCount: historyLoadCount,
            historyCompensations: historyCompensations,
            historyAppliedCount: historyAppliedCount,
            historySkippedCount: historySkippedCount,
            historySkippedReasons: historySkippedReasons,
            historyTotalAppliedMovedY: historyTotalAppliedMovedY,
            historySyncShiftsAppliedCount: historySyncShiftsAppliedCount,
            historyRestoresAppliedCount: historyRestoresAppliedCount
        )
    }

    private static func resolveTraceClockAlignment(
        url: URL?,
        traceResult: MidScrollTraceParseResult,
        traceExistedBeforeRun: Bool,
        runStartClock: MidScrollClockPair,
        observedMinT0Mono: CFTimeInterval?
    ) -> MidScrollTraceClockAlignment {
        guard let url, traceResult.enabled else {
            return MidScrollTraceClockAlignment(t0Mono: nil, method: "trace-disabled", birthtimeVsObservedDeltaMs: nil)
        }
        var birthtimeT0Mono: CFTimeInterval?
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let creationDate = attrs[.creationDate] as? Date {
            let birthWall = creationDate.timeIntervalSince1970
            if !traceExistedBeforeRun || birthWall >= runStartClock.wall - 0.5 {
                let pair = captureClockPair()
                birthtimeT0Mono = pair.mono - (pair.wall - birthWall) - Double(traceResult.traceStartT ?? 0) / 1000.0
            }
        }
        let deltaMs: Double?
        if let bt = birthtimeT0Mono, let obs = observedMinT0Mono {
            deltaMs = (obs - bt) * 1000.0
        } else {
            deltaMs = nil
        }
        if let bt = birthtimeT0Mono {
            if let obs = observedMinT0Mono, abs(obs - bt) > 2.0 {
                return MidScrollTraceClockAlignment(
                    t0Mono: obs,
                    method: "cacurrentmediatime+live-trace-tail-min",
                    birthtimeVsObservedDeltaMs: deltaMs
                )
            }
            return MidScrollTraceClockAlignment(
                t0Mono: bt,
                method: "cacurrentmediatime+trace-file-birthtime",
                birthtimeVsObservedDeltaMs: deltaMs
            )
        }
        if let obs = observedMinT0Mono {
            return MidScrollTraceClockAlignment(
                t0Mono: obs,
                method: "cacurrentmediatime+live-trace-tail-min",
                birthtimeVsObservedDeltaMs: nil
            )
        }
        return MidScrollTraceClockAlignment(t0Mono: nil, method: "unavailable", birthtimeVsObservedDeltaMs: nil)
    }

    private static func midScrollGestureIntervals(
        from sortedEvents: [MidScrollObservedBuffer.RawEvent]
    ) -> [(start: CFTimeInterval, end: CFTimeInterval)] {
        guard !sortedEvents.isEmpty else { return [] }
        var intervals: [(start: CFTimeInterval, end: CFTimeInterval)] = []
        var activeStart: CFTimeInterval?
        var lastEventTime: CFTimeInterval?
        for idx in sortedEvents.indices {
            let event = sortedEvents[idx]
            if event.phase.contains(.began) {
                if let start = activeStart, let end = lastEventTime {
                    intervals.append((start, end))
                }
                activeStart = event.monoTime
            } else if activeStart == nil {
                activeStart = event.monoTime
            }
            lastEventTime = event.monoTime
            if event.momentumPhase.contains(.ended) || event.momentumPhase.contains(.cancelled) {
                if let start = activeStart {
                    intervals.append((start, event.monoTime))
                }
                activeStart = nil
            } else if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
                let closesHere: Bool
                if idx + 1 >= sortedEvents.count {
                    closesHere = true
                } else {
                    let next = sortedEvents[idx + 1]
                    closesHere = next.phase.contains(.began)
                        || (next.momentumPhase.isEmpty && next.monoTime - event.monoTime > 0.05)
                }
                if closesHere {
                    if let start = activeStart {
                        intervals.append((start, event.monoTime))
                    }
                    activeStart = nil
                }
            }
        }
        if let start = activeStart {
            intervals.append((start, lastEventTime ?? start))
        }
        return intervals
    }

    private static func evaluateMidScroll(
        samples: [MidScrollSnapshot],
        rawEvents: [MidScrollObservedBuffer.RawEvent],
        upSign: Int32,
        viewport: Double,
        endHasEarlierPill: Bool,
        traceResult: MidScrollTraceParseResult,
        clockAlignment: MidScrollTraceClockAlignment,
        recordingAudit: MidScrollRecordingAudit,
        expandedResult: MidScrollExpandedBlockResult,
        scenario: MidScrollScenario,
        seedResult: MidScrollSeedResult,
        expandedStepsTurns: [Int],
        coldResetMonoTimes: [CFTimeInterval],
        resizeWindows: [MidScrollReflowWindow],
        serifWindows: [MidScrollReflowWindow],
        timedOut: Bool,
        output: URL
    ) -> MidScrollOutcome {
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

        func alignCompensationEvents(_ items: [MidScrollCompensationEvent]) -> [MidScrollCompensationEvent] {
            items.map { comp in
                let alignedTime: Double?
                if let tMs = comp.t, let t0Mono = clockAlignment.t0Mono {
                    alignedTime = (t0Mono + Double(tMs) / 1000.0) - originMono
                } else {
                    alignedTime = nil
                }
                return MidScrollCompensationEvent(
                    event: comp.event,
                    t: comp.t,
                    alignedTime: alignedTime,
                    seq: comp.seq,
                    source: comp.source,
                    rowID: comp.rowID,
                    delta: comp.delta,
                    growth: comp.growth,
                    restoreDelta: comp.restoreDelta,
                    historyReaderDelta: comp.historyReaderDelta,
                    beforeY: comp.beforeY,
                    afterY: comp.afterY,
                    movedY: comp.movedY,
                    skipped: comp.skipped,
                    reason: comp.reason
                )
            }
        }

        let alignedCompensations = alignCompensationEvents(traceResult.compensations)
        let alignedHistoryCompensations = alignCompensationEvents(traceResult.historyCompensations)

        let signFactor = Double(upSign)
        let beganCount = sortedEvents.filter { $0.phase.contains(.began) }.count
        let endedCount = sortedEvents.filter { $0.phase.contains(.ended) }.count
        let momentumEndedCount = sortedEvents.filter { $0.momentumPhase.contains(.ended) }.count
        var observedUpDelta = 0.0
        var observedDownDelta = 0.0
        for event in sortedEvents {
            let signed = signFactor * event.scrollingDeltaY
            if signed > 0 {
                observedUpDelta += signed
            } else if signed < 0 {
                observedDownDelta += -signed
            }
        }

        let fingerStepMag = max(1, Int32((viewport * 0.25 / Double(midScrollFlickChangedSteps)).rounded()))
        let momSumMag = midScrollMomentumSum(quarterViewport: viewport * 0.25, count: midScrollMomentumSteps, ratio: 0.85)
        let perFlickMag = Double(fingerStepMag * Int32(midScrollFlickChangedSteps) + momSumMag)
        let dragCycleSum = Double(midScrollDragStepCycle.reduce(Int32(0), +))
        let perDragMag = dragCycleSum * Double(midScrollDragChangedSteps / midScrollDragStepCycle.count)
        let expectedDirectionDelta = Double(midScrollFlickBatch * 2) * perFlickMag + Double(midScrollDragCount / 2) * perDragMag

        let allEventsArrived = beganCount == midScrollExpectedGestures
            && endedCount == midScrollExpectedGestures
            && momentumEndedCount == midScrollExpectedFlicks
            && observedUpDelta >= expectedDirectionDelta * 0.95
            && observedDownDelta >= expectedDirectionDelta * 0.95

        let gestureIntervals = midScrollGestureIntervals(from: sortedEvents)

        func matchingReflowWindow(prevMono: CFTimeInterval, currMono: CFTimeInterval) -> MidScrollReflowWindow? {
            if let resize = resizeWindows.first(where: { currMono >= $0.startMono && prevMono <= $0.endMono }) {
                return resize
            }
            if let serif = serifWindows.first(where: { currMono >= $0.startMono && prevMono <= $0.endMono }) {
                return serif
            }
            return nil
        }

        var sampleRecords: [MidScrollSampleRecord] = []
        sampleRecords.reserveCapacity(sortedSamples.count)
        var layoutShiftsOver4List: [MidScrollLayoutShiftRecord] = []
        var layoutShiftsOver4pt = 0
        var layoutShiftsOver20pt = 0
        var layoutShiftsOver40pt = 0
        var maxAbsLayoutShift = 0.0
        var resizeWindowPairsCount = 0
        var resizeWindowShiftsOver4List: [MidScrollLayoutShiftRecord] = []
        var resizeWindowShiftsOver4pt = 0
        var resizeWindowShiftsOver20pt = 0
        var resizeWindowShiftsOver40pt = 0
        var resizeWindowMaxAbsShift = 0.0
        var serifWindowPairsCount = 0
        var serifWindowShiftsOver4List: [MidScrollLayoutShiftRecord] = []
        var serifWindowShiftsOver4pt = 0
        var serifWindowShiftsOver20pt = 0
        var serifWindowShiftsOver40pt = 0
        var serifWindowMaxAbsShift = 0.0
        var reflowWindowSampleGaps = 0
        var ambiguousResolvedCount = 0
        var travelPositive = 0.0
        var travelNegative = 0.0
        var sampleGapsDuringInput = 0
        var maxSampleGapDuringInput: CFTimeInterval = 0
        var jumpsOver4List: [MidScrollJumpRecord] = []
        var jumpsOver4pt = 0
        var jumpsOver20pt = 0
        var jumpsOver40pt = 0
        var maxAbsJump = 0.0
        var unmatchedTransitionsCount = 0
        var unmatchedLargeClipDuringGestureCount = 0
        var fallbackTransitionsCount = 0
        var anySampleHistoryLoadPending = false
        var hitTopEnd = false
        var hitBottomEnd = false
        var minTopMargin = Double.infinity
        var minBottomMargin = Double.infinity

        for snap in sortedSamples {
            if snap.historyLoadPending { anySampleHistoryLoadPending = true }
            if snap.isAtTopEnd { hitTopEnd = true }
            if snap.isAtBottomEnd { hitBottomEnd = true }
            if snap.topMargin < minTopMargin { minTopMargin = snap.topMargin }
            if snap.bottomMargin < minBottomMargin { minBottomMargin = snap.bottomMargin }
        }
        if !minTopMargin.isFinite { minTopMargin = 0 }
        if !minBottomMargin.isFinite { minBottomMargin = 0 }

        if let first = sortedSamples.first {
            sampleRecords.append(MidScrollSampleRecord(
                time: first.monoTime - originMono,
                clipMinY: first.clipMinY,
                rawClipDelta: nil,
                docHeight: first.docHeight,
                topMargin: first.topMargin,
                bottomMargin: first.bottomMargin,
                historyLoadPending: first.historyLoadPending,
                blockID: nil,
                prevDocMinY: nil,
                currDocMinY: nil,
                docDelta: nil,
                compensationMovedY: nil,
                layoutShift: nil,
                reflowWindow: nil,
                duringGesture: nil,
                matchedByFallback: nil,
                contentMotion: nil,
                expectedMotion: nil,
                jump: nil,
                visibleBlocks: first.visibleBlocks
            ))
        }

        let pairsCount = max(0, sortedSamples.count - 1)
        if pairsCount > 0 {
            struct PairPrelim {
                let match: (id: String, prevMinY: Double, currMinY: Double, fallback: Bool)?
                let prevDocMinY: Double?
                let currDocMinY: Double?
                let docDelta: Double?
                let rawClipDelta: Double
                let expectedMotion: Double
                let duringGesture: Bool
                let reflowWindow: MidScrollReflowWindow?
            }

            var prelims: [PairPrelim] = []
            prelims.reserveCapacity(pairsCount)
            var eventCursor = 0
            while eventCursor < sortedEvents.count, sortedEvents[eventCursor].monoTime <= sortedSamples[0].monoTime {
                eventCursor += 1
            }
            var gestureCursor = 0

            for pairIdx in 0..<pairsCount {
                let prev = sortedSamples[pairIdx]
                let curr = sortedSamples[pairIdx + 1]
                var intervalObserved = 0.0
                var sawEventInInterval = false
                while eventCursor < sortedEvents.count, sortedEvents[eventCursor].monoTime <= curr.monoTime {
                    if sortedEvents[eventCursor].monoTime > prev.monoTime {
                        intervalObserved += sortedEvents[eventCursor].scrollingDeltaY
                        sawEventInInterval = true
                    }
                    eventCursor += 1
                }
                while gestureCursor < gestureIntervals.count, gestureIntervals[gestureCursor].end < prev.monoTime {
                    gestureCursor += 1
                }
                let overlapsGesture = gestureCursor < gestureIntervals.count
                    && gestureIntervals[gestureCursor].start <= curr.monoTime
                    && gestureIntervals[gestureCursor].end >= prev.monoTime
                let duringGesture = sawEventInInterval || overlapsGesture

                let expectedMotion = signFactor * intervalObserved
                let rawClipDelta = curr.clipMinY - prev.clipMinY
                let match = selectCommonMidScrollBlock(prev: prev, curr: curr)
                let prevDocMinY = match.map { $0.prevMinY + prev.clipMinY }
                let currDocMinY = match.map { $0.currMinY + curr.clipMinY }
                let docDelta: Double?
                if let pDoc = prevDocMinY, let cDoc = currDocMinY {
                    docDelta = cDoc - pDoc
                } else {
                    docDelta = nil
                }
                let reflowWindow = matchingReflowWindow(prevMono: prev.monoTime, currMono: curr.monoTime)
                prelims.append(PairPrelim(
                    match: match,
                    prevDocMinY: prevDocMinY,
                    currDocMinY: currDocMinY,
                    docDelta: docDelta,
                    rawClipDelta: rawClipDelta,
                    expectedMotion: expectedMotion,
                    duringGesture: duringGesture,
                    reflowWindow: reflowWindow
                ))
            }

            // Attribute applied compensation movedY from aligned trace timestamps to sample pairs,
            // resolving +/-5ms sample-boundary rounding ambiguity against adjacent intervals.
            // In `--mid-scroll-history` mode, include applied `history.syncShift` and `history.restore`
            // movements using the exact same timestamp alignment and boundary-group rule.
            let compensationEventsForNetting: [MidScrollCompensationEvent] = scenario.history
                ? (traceResult.compensations + traceResult.historyCompensations)
                : traceResult.compensations
            var pairCompMovedY = Array(repeating: 0.0, count: pairsCount)
            var ambiguousGroups: [[Int]] = []
            if let t0Mono = clockAlignment.t0Mono {
                let firstMono = sortedSamples[0].monoTime
                let lastMono = sortedSamples[pairsCount].monoTime
                let boundaryTolerance: CFTimeInterval = 0.005

                for comp in compensationEventsForNetting {
                    guard comp.skipped == false,
                          let tMs = comp.t,
                          let movedY = comp.movedY,
                          movedY.isFinite, abs(movedY) > 0 else { continue }
                    let cMono = t0Mono + Double(tMs) / 1000.0
                    guard cMono >= firstMono - boundaryTolerance, cMono <= lastMono + boundaryTolerance else { continue }

                    // Assigned by timestamp only, never by which interval it makes look
                    // smoother: a correction must not be able to cancel an unrelated jump.
                    if cMono < firstMono {
                        pairCompMovedY[0] += movedY
                        ambiguousGroups.append([0])
                        continue
                    }
                    if cMono > lastMono {
                        pairCompMovedY[pairsCount - 1] += movedY
                        ambiguousGroups.append([pairsCount - 1])
                        continue
                    }

                    // Binary search for nominal interval where prev.monoTime < cMono <= curr.monoTime.
                    var lo = 0
                    var hi = pairsCount - 1
                    while lo < hi {
                        let mid = (lo + hi) / 2
                        if sortedSamples[mid + 1].monoTime < cMono {
                            lo = mid + 1
                        } else {
                            hi = mid
                        }
                    }
                    let nominal = lo
                    var candidates = [nominal]
                    if nominal > 0, abs(cMono - sortedSamples[nominal].monoTime) <= boundaryTolerance {
                        candidates.append(nominal - 1)
                    }
                    if nominal + 1 < pairsCount, abs(cMono - sortedSamples[nominal + 1].monoTime) <= boundaryTolerance {
                        candidates.append(nominal + 1)
                    }
                    pairCompMovedY[nominal] += movedY
                    if candidates.count > 1 { ambiguousGroups.append(candidates.sorted()) }
                }
            }

            // A correction within the timestamp tolerance of a sample boundary may belong to
            // either neighbouring interval: judge those intervals together, by their summed
            // shift, so boundary rounding neither invents nor hides a jump. Never mix pairs
            // inside and outside a resize/serif reflow window.
            var shiftOverride: [Int: Double] = [:]
            for group in ambiguousGroups {
                let allOutsideReflow = group.allSatisfy { prelims[$0].reflowWindow == nil }
                let allInsideReflow = group.allSatisfy { prelims[$0].reflowWindow != nil }
                guard allOutsideReflow || allInsideReflow else { continue }
                let shifts = group.map { idx in prelims[idx].docDelta.map { $0 - pairCompMovedY[idx] } }
                guard shifts.allSatisfy({ $0 != nil }) else { continue }
                let values = shifts.compactMap { $0 }
                guard values.contains(where: { abs($0) > midScrollLayoutShiftThresholdPt }) else { continue }
                if abs(values.reduce(0, +)) <= midScrollLayoutShiftThresholdPt {
                    for idx in group { shiftOverride[idx] = 0 }
                    ambiguousResolvedCount += 1
                }
            }

            for pairIdx in 0..<pairsCount {
                let prev = sortedSamples[pairIdx]
                let curr = sortedSamples[pairIdx + 1]
                let prelim = prelims[pairIdx]
                let compMovedY = pairCompMovedY[pairIdx]

                let blockID: String
                let contentMotion: Double
                let prevMinY: Double
                let currMinY: Double
                let matchedByFallback: Bool
                let layoutShift: Double?

                if let match = prelim.match,
                   let prevDoc = prelim.prevDocMinY,
                   let currDoc = prelim.currDocMinY,
                   let docDelta = prelim.docDelta {
                    blockID = match.id
                    prevMinY = match.prevMinY
                    currMinY = match.currMinY
                    contentMotion = currMinY - prevMinY
                    matchedByFallback = match.fallback
                    if match.fallback { fallbackTransitionsCount += 1 }
                    let shift = shiftOverride[pairIdx] ?? (docDelta - compMovedY)
                    layoutShift = shift
                    let absShift = abs(shift)
                    let rowKind = midScrollRowKind(for: blockID, turnRowKinds: seedResult.turnRowKinds)
                    if let reflow = prelim.reflowWindow {
                        switch reflow.category {
                        case .resize:
                            resizeWindowPairsCount += 1
                            if absShift > resizeWindowMaxAbsShift { resizeWindowMaxAbsShift = absShift }
                            if absShift > midScrollLayoutShiftThresholdPt {
                                resizeWindowShiftsOver4pt += 1
                                resizeWindowShiftsOver4List.append(MidScrollLayoutShiftRecord(
                                    timestamp: curr.monoTime - originMono,
                                    blockID: blockID,
                                    rowKind: rowKind,
                                    prevDocMinY: prevDoc,
                                    currDocMinY: currDoc,
                                    docDelta: docDelta,
                                    compensationMovedY: compMovedY,
                                    layoutShift: shift,
                                    rawClipDelta: prelim.rawClipDelta,
                                    docHeightPrev: prev.docHeight,
                                    docHeightCurr: curr.docHeight,
                                    matchedByFallback: matchedByFallback
                                ))
                            }
                            if absShift > 20.0 { resizeWindowShiftsOver20pt += 1 }
                            if absShift > 40.0 { resizeWindowShiftsOver40pt += 1 }
                        case .serif:
                            serifWindowPairsCount += 1
                            if absShift > serifWindowMaxAbsShift { serifWindowMaxAbsShift = absShift }
                            if absShift > midScrollLayoutShiftThresholdPt {
                                serifWindowShiftsOver4pt += 1
                                serifWindowShiftsOver4List.append(MidScrollLayoutShiftRecord(
                                    timestamp: curr.monoTime - originMono,
                                    blockID: blockID,
                                    rowKind: rowKind,
                                    prevDocMinY: prevDoc,
                                    currDocMinY: currDoc,
                                    docDelta: docDelta,
                                    compensationMovedY: compMovedY,
                                    layoutShift: shift,
                                    rawClipDelta: prelim.rawClipDelta,
                                    docHeightPrev: prev.docHeight,
                                    docHeightCurr: curr.docHeight,
                                    matchedByFallback: matchedByFallback
                                ))
                            }
                            if absShift > 20.0 { serifWindowShiftsOver20pt += 1 }
                            if absShift > 40.0 { serifWindowShiftsOver40pt += 1 }
                        }
                    } else {
                        if absShift > maxAbsLayoutShift { maxAbsLayoutShift = absShift }
                        if absShift > midScrollLayoutShiftThresholdPt {
                            layoutShiftsOver4pt += 1
                            layoutShiftsOver4List.append(MidScrollLayoutShiftRecord(
                                timestamp: curr.monoTime - originMono,
                                blockID: blockID,
                                rowKind: rowKind,
                                prevDocMinY: prevDoc,
                                currDocMinY: currDoc,
                                docDelta: docDelta,
                                compensationMovedY: compMovedY,
                                layoutShift: shift,
                                rawClipDelta: prelim.rawClipDelta,
                                docHeightPrev: prev.docHeight,
                                docHeightCurr: curr.docHeight,
                                matchedByFallback: matchedByFallback
                            ))
                        }
                        if absShift > 20.0 { layoutShiftsOver20pt += 1 }
                        if absShift > 40.0 { layoutShiftsOver40pt += 1 }
                    }
                } else {
                    unmatchedTransitionsCount += 1
                    if prelim.duringGesture, abs(prelim.rawClipDelta) > viewport * 0.5 {
                        unmatchedLargeClipDuringGestureCount += 1
                    }
                    blockID = "unmatched-clip"
                    prevMinY = -prev.clipMinY
                    currMinY = -curr.clipMinY
                    contentMotion = -prelim.rawClipDelta
                    matchedByFallback = true
                    layoutShift = nil
                }

                if prelim.duringGesture {
                    if prelim.rawClipDelta > 0 { travelPositive += prelim.rawClipDelta } else { travelNegative -= prelim.rawClipDelta }
                    let gap = curr.monoTime - prev.monoTime
                    if gap > maxSampleGapDuringInput { maxSampleGapDuringInput = gap }
                    if gap > midScrollMaxSampleGapSec {
                        if prelim.reflowWindow != nil {
                            reflowWindowSampleGaps += 1
                        } else {
                            sampleGapsDuringInput += 1
                        }
                    }
                }

                // Retain old wheel-event-based jump numbers as informational only.
                let jump = contentMotion - prelim.expectedMotion
                let absJump = abs(jump)
                if absJump > maxAbsJump { maxAbsJump = absJump }
                if absJump > 4.0 {
                    jumpsOver4pt += 1
                    jumpsOver4List.append(MidScrollJumpRecord(
                        timestamp: curr.monoTime - originMono,
                        blockID: blockID,
                        contentMotion: contentMotion,
                        expectedMotion: prelim.expectedMotion,
                        jump: jump,
                        rawClipDelta: prelim.rawClipDelta,
                        prevScreenMinY: prevMinY,
                        currScreenMinY: currMinY,
                        docHeightPrev: prev.docHeight,
                        docHeightCurr: curr.docHeight,
                        matchedByFallback: matchedByFallback
                    ))
                }
                if absJump > 20.0 { jumpsOver20pt += 1 }
                if absJump > 40.0 { jumpsOver40pt += 1 }

                sampleRecords.append(MidScrollSampleRecord(
                    time: curr.monoTime - originMono,
                    clipMinY: curr.clipMinY,
                    rawClipDelta: prelim.rawClipDelta,
                    docHeight: curr.docHeight,
                    topMargin: curr.topMargin,
                    bottomMargin: curr.bottomMargin,
                    historyLoadPending: curr.historyLoadPending,
                    blockID: blockID,
                    prevDocMinY: prelim.prevDocMinY,
                    currDocMinY: prelim.currDocMinY,
                    docDelta: prelim.docDelta,
                    compensationMovedY: compMovedY,
                    layoutShift: layoutShift,
                    reflowWindow: prelim.reflowWindow?.kind,
                    duringGesture: prelim.duringGesture,
                    matchedByFallback: matchedByFallback,
                    contentMotion: contentMotion,
                    expectedMotion: prelim.expectedMotion,
                    jump: jump,
                    visibleBlocks: curr.visibleBlocks
                ))
            }
        }

        if hitTopEnd || hitBottomEnd {
            note(
                "mid-scroll-boundary",
                String(
                    format: "driver reached scroll end: hitTopEnd=%@ hitBottomEnd=%@ minTopMargin=%.1fpt minBottomMargin=%.1fpt",
                    hitTopEnd ? "true" : "false",
                    hitBottomEnd ? "true" : "false",
                    minTopMargin, minBottomMargin
                )
            )
        }

        let topLayoutShifts = Array(layoutShiftsOver4List.sorted { abs($0.layoutShift) > abs($1.layoutShift) }.prefix(20))
        let topResizeWindowShifts = Array(resizeWindowShiftsOver4List.sorted { abs($0.layoutShift) > abs($1.layoutShift) }.prefix(20))
        let topSerifWindowShifts = Array(serifWindowShiftsOver4List.sorted { abs($0.layoutShift) > abs($1.layoutShift) }.prefix(20))
        let topJumps = Array(jumpsOver4List.sorted { abs($0.jump) > abs($1.jump) }.prefix(20))
        let historyLoadHappened = anySampleHistoryLoadPending || endHasEarlierPill || traceResult.historyLoadCount > 0
        let unexpectedHistoryLoad = !scenario.history && historyLoadHappened
        let missingExpectedHistoryLoad = scenario.history && traceResult.enabled && traceResult.historyLoadCount == 0
        if unexpectedHistoryLoad {
            note(
                "mid-scroll-invalid",
                "history load detected during measurement (samplePending=\(anySampleHistoryLoadPending) endEarlierPill=\(endHasEarlierPill) traceHistoryLoads=\(traceResult.historyLoadCount))"
            )
        } else if scenario.history {
            note(
                "mid-scroll-history-loads",
                String(
                    format: "pagesLoaded=%d samplePending=%@ endEarlierPill=%@ syncShiftsApplied=%d restoresApplied=%d historyMovedY=%.1fpt",
                    traceResult.historyLoadCount,
                    anySampleHistoryLoadPending ? "true" : "false",
                    endHasEarlierPill ? "true" : "false",
                    traceResult.historySyncShiftsAppliedCount,
                    traceResult.historyRestoresAppliedCount,
                    traceResult.historyTotalAppliedMovedY
                )
            )
        }

        let mp4URL = output.appendingPathComponent("mid-scroll.mp4")
        let mp4Size = (try? FileManager.default.attributesOfItem(atPath: mp4URL.path)[.size] as? NSNumber)?.int64Value ?? 0
        let recordingExists = FileManager.default.fileExists(atPath: mp4URL.path) && mp4Size > 0

        let recordingRequiredEndOffsetSec: Double?
        let recordingActualEndOffsetSec: Double?
        let recordingCoveredEvents: Bool
        if let recStart = recordingAudit.startMonoTime,
           let recEnd = recordingAudit.endMonoTime,
           let firstEventMono = sortedEvents.first?.monoTime,
           let lastEventMono = sortedEvents.last?.monoTime {
            let requiredEnd = (lastEventMono + 0.5) - recStart
            let actualEnd = recEnd - recStart
            recordingRequiredEndOffsetSec = requiredEnd
            recordingActualEndOffsetSec = actualEnd
            let windowCovered = recStart <= firstEventMono + 0.05 && recEnd >= lastEventMono + 0.5
            // Encoded frames must reach the last gesture; the static tail may encode no frames.
            let minAssetDuration = max(0.0, (lastEventMono - recStart) - 0.05)
            let assetOK = recordingAudit.assetDuration.map { $0.isFinite && $0 > 0 && $0 >= minAssetDuration } ?? false
            recordingCoveredEvents = windowCovered && assetOK
        } else {
            recordingRequiredEndOffsetSec = nil
            recordingActualEndOffsetSec = nil
            recordingCoveredEvents = false
        }
        let recordingComplete = recordingExists && recordingAudit.finishedSuccessfully && recordingCoveredEvents

        let requiredStills = ["mid-scroll-middle", "mid-scroll-start", "mid-scroll-end"]
        let stillsComplete = missingStills.isEmpty && requiredStills.allSatisfy {
            FileManager.default.fileExists(atPath: output.appendingPathComponent("\($0).png").path)
        }

        var verdictReasons: [String] = []
        let unmatchedRatio = pairsCount > 0 ? Double(unmatchedTransitionsCount) / Double(pairsCount) : 1.0
        // A hitch is a pause, not a hidden jump: the anchor's document position across it still
        // shows any net shift. Only frequent or long gaps leave too little to judge.
        let gapsUndermineCoverage = maxSampleGapDuringInput > midScrollMaxHitchSec
            || (pairsCount > 0 && Double(sampleGapsDuringInput) / Double(pairsCount) > 0.01)
        let travelInsufficient = travelPositive < viewport * 2 || travelNegative < viewport * 2
        let coverageFailed = pairsCount == 0
            || unmatchedRatio > midScrollMaxUnmatchedPairRatio
            || unmatchedLargeClipDuringGestureCount > 0
            || travelInsufficient
            || gapsUndermineCoverage
            || !traceResult.enabled
            || missingExpectedHistoryLoad
        if ambiguousResolvedCount > 0 {
            note("mid-scroll-ambiguous", "boundary-ambiguous compensation groups judged together: \(ambiguousResolvedCount)")
        }
        if travelInsufficient {
            verdictReasons.append(String(format: "travelInsufficient(positive=%.0fpt,negative=%.0fpt,need=%.0fpt)", travelPositive, travelNegative, viewport * 2))
        }
        if gapsUndermineCoverage {
            verdictReasons.append(String(format: "sampleGapsDuringInput=%d(max=%.0fms)", sampleGapsDuringInput, maxSampleGapDuringInput * 1000))
        } else if sampleGapsDuringInput > 0 {
            note("mid-scroll-hitches", String(format: "main-thread hitches during input: %d over %.0fms (max %.0fms)", sampleGapsDuringInput, midScrollMaxSampleGapSec * 1000, maxSampleGapDuringInput * 1000))
        }
        if !traceResult.enabled { verdictReasons.append("compensationTraceUnavailable") }
        if missingExpectedHistoryLoad { verdictReasons.append("noHistoryPagesLoaded") }

        if unexpectedHistoryLoad { verdictReasons.append("historyLoadHappened") }
        if timedOut { verdictReasons.append("timedOut") }
        if layoutShiftsOver4pt > 0 {
            verdictReasons.append(String(format: "layoutShiftsOver4pt=%d(max=%.2fpt)", layoutShiftsOver4pt, maxAbsLayoutShift))
        }
        if !allEventsArrived {
            verdictReasons.append("incompleteEvents(\(observedEvents.count)/\(midScrollExpectedEvents),gestures=\(beganCount)/\(midScrollExpectedGestures))")
        }
        if pairsCount == 0 {
            verdictReasons.append("insufficientSamples(\(sortedSamples.count))")
        } else {
            if unmatchedRatio > midScrollMaxUnmatchedPairRatio {
                verdictReasons.append(String(format: "unmatchedRatio=%.4f>%.2f(%d/%d)", unmatchedRatio, midScrollMaxUnmatchedPairRatio, unmatchedTransitionsCount, pairsCount))
            }
            if unmatchedLargeClipDuringGestureCount > 0 {
                verdictReasons.append("unmatchedLargeClipDuringGesture=\(unmatchedLargeClipDuringGestureCount)")
            }
        }
        if !recordingComplete {
            var recDetail: [String] = []
            if !recordingExists { recDetail.append("missingMP4") }
            if !recordingAudit.finishedSuccessfully {
                recDetail.append("recorderError=\(recordingAudit.errorDescription ?? "notFinished")")
            }
            if !recordingCoveredEvents {
                recDetail.append(String(
                    format: "coverage(actual=%.2fs,required=%.2fs,asset=%.2fs)",
                    recordingActualEndOffsetSec ?? -1,
                    recordingRequiredEndOffsetSec ?? -1,
                    recordingAudit.assetDuration ?? -1
                ))
            }
            verdictReasons.append("recordingIncomplete(\(recDetail.joined(separator: ",")))")
        }
        if !stillsComplete { verdictReasons.append("missingStills") }

        let verdict: String
        let outcome: MidScrollOutcome
        if unexpectedHistoryLoad {
            verdict = "INVALID"
            outcome = .failed
        } else if timedOut {
            verdict = "TIMEOUT"
            outcome = .blockedOrOutOfTime
        } else if layoutShiftsOver4pt > 0 {
            verdict = "FAIL"
            outcome = .failed
        } else if !allEventsArrived {
            verdict = "FAIL"
            outcome = .failed
        } else if coverageFailed || !recordingComplete {
            verdict = "INCONCLUSIVE"
            outcome = .inconclusive
        } else if !stillsComplete {
            verdict = "FAIL"
            outcome = .failed
        } else {
            verdict = "PASS"
            outcome = .passed
        }

        let coldMemoryResetTimes = coldResetMonoTimes.map { $0 - originMono }
        let resizeWindowRecords = resizeWindows.map {
            MidScrollReflowWindowRecord(
                category: $0.category.rawValue,
                kind: $0.kind,
                start: $0.startMono - originMono,
                end: $0.endMono - originMono
            )
        }
        let serifWindowRecords = serifWindows.map {
            MidScrollReflowWindowRecord(
                category: $0.category.rawValue,
                kind: $0.kind,
                start: $0.startMono - originMono,
                end: $0.endMono - originMono
            )
        }
        let turnRowKindsMap = Dictionary(uniqueKeysWithValues: seedResult.turnRowKinds.map { ("turn-\($0.key)", $0.value) })
        let skippedReasonsText: String = {
            if traceResult.skippedReasons.isEmpty { return "none" }
            return traceResult.skippedReasons.keys.sorted().map { key in
                "\(key)=\(traceResult.skippedReasons[key] ?? 0)"
            }.joined(separator: ",")
        }()
        let historySkippedReasonsText: String = {
            if traceResult.historySkippedReasons.isEmpty { return "none" }
            return traceResult.historySkippedReasons.keys.sorted().map { key in
                "\(key)=\(traceResult.historySkippedReasons[key] ?? 0)"
            }.joined(separator: ",")
        }()

        func formatShiftList(_ items: [MidScrollLayoutShiftRecord]) -> String {
            if items.isEmpty { return "none" }
            return items.map { item in
                String(
                    format: "t=%.3fs block=%@ kind=%@ docDelta=%.1fpt compMovedY=%.1fpt layoutShift=%.1fpt clip=%.1fpt",
                    item.timestamp, item.blockID, item.rowKind, item.docDelta, item.compensationMovedY, item.layoutShift, item.rawClipDelta
                )
            }.joined(separator: "; ")
        }

        let samplesFile = "mid-scroll-samples.json"
        let samplesReport = MidScrollSamplesReport(
            verdict: verdict,
            verdictReasons: verdictReasons,
            scenarioFlags: scenario.activeFlags,
            coldMode: scenario.cold,
            historyMode: scenario.history,
            mixMode: scenario.mix,
            resizeMode: scenario.resize,
            serifMode: scenario.serif,
            seededTurnCount: seedResult.seeded,
            seededRowKinds: seedResult.seededRowKinds,
            skippedRowKinds: seedResult.skippedRowKinds,
            expandedStepsTurns: expandedStepsTurns,
            turnRowKinds: turnRowKindsMap,
            coldMemoryResetTimes: coldMemoryResetTimes,
            delivery: "hid",
            upSign: upSign,
            viewport: viewport,
            measurementMethod: midScrollMeasurementMethod,
            expectedEventsCount: midScrollExpectedEvents,
            expectedGesturesCount: midScrollExpectedGestures,
            observedEventsCount: observedEvents.count,
            observedGesturesCount: beganCount,
            observedEndedCount: endedCount,
            observedMomentumEndedCount: momentumEndedCount,
            allEventsArrived: allEventsArrived,
            historyLoadHappened: historyLoadHappened,
            historyPagesLoadedCount: traceResult.historyLoadCount,
            hitTopEnd: hitTopEnd,
            hitBottomEnd: hitBottomEnd,
            minTopMarginPt: minTopMargin,
            minBottomMarginPt: minBottomMargin,
            recordingExists: recordingExists,
            recordingFinishedSuccessfully: recordingAudit.finishedSuccessfully,
            recordingCoveredEvents: recordingCoveredEvents,
            recordingDurationSec: recordingAudit.recordedDuration,
            recordingAssetDurationSec: recordingAudit.assetDuration,
            recordingRequiredEndOffsetSec: recordingRequiredEndOffsetSec,
            recordingActualEndOffsetSec: recordingActualEndOffsetSec,
            recordingError: recordingAudit.errorDescription,
            stillsComplete: stillsComplete,
            samplesCount: sortedSamples.count,
            pairsCount: pairsCount,
            unmatchedTransitionsCount: unmatchedTransitionsCount,
            unmatchedTransitionsRatio: unmatchedRatio,
            unmatchedLargeClipDuringGestureCount: unmatchedLargeClipDuringGestureCount,
            fallbackTransitionsCount: fallbackTransitionsCount,
            maxAbsLayoutShift: maxAbsLayoutShift,
            layoutShiftsOver4pt: layoutShiftsOver4pt,
            layoutShiftsOver20pt: layoutShiftsOver20pt,
            layoutShiftsOver40pt: layoutShiftsOver40pt,
            topLayoutShifts: topLayoutShifts,
            resizeWindowTimes: resizeWindowRecords,
            resizeWindowPairsCount: resizeWindowPairsCount,
            resizeWindowShiftsOver4pt: resizeWindowShiftsOver4pt,
            resizeWindowShiftsOver20pt: resizeWindowShiftsOver20pt,
            resizeWindowShiftsOver40pt: resizeWindowShiftsOver40pt,
            resizeWindowMaxAbsShift: resizeWindowMaxAbsShift,
            topResizeWindowShifts: topResizeWindowShifts,
            serifWindowTimes: serifWindowRecords,
            serifWindowPairsCount: serifWindowPairsCount,
            serifWindowShiftsOver4pt: serifWindowShiftsOver4pt,
            serifWindowShiftsOver20pt: serifWindowShiftsOver20pt,
            serifWindowShiftsOver40pt: serifWindowShiftsOver40pt,
            serifWindowMaxAbsShift: serifWindowMaxAbsShift,
            topSerifWindowShifts: topSerifWindowShifts,
            reflowWindowSampleGaps: reflowWindowSampleGaps,
            maxAbsJump: maxAbsJump,
            jumpsOver4pt: jumpsOver4pt,
            jumpsOver20pt: jumpsOver20pt,
            jumpsOver40pt: jumpsOver40pt,
            topJumps: topJumps,
            timelineTraceEnabled: traceResult.enabled,
            timelineTracePath: traceResult.path,
            timelineTraceCapped: traceResult.traceCapped,
            traceClockAlignmentMethod: clockAlignment.method,
            traceClockBirthtimeVsObservedDeltaMs: clockAlignment.birthtimeVsObservedDeltaMs,
            aboveViewportCompensationsCount: traceResult.compensations.count,
            aboveViewportCompensationsAppliedCount: traceResult.appliedCount,
            aboveViewportCompensationsSkippedCount: traceResult.skippedCount,
            aboveViewportCompensationsSkippedReasons: traceResult.skippedReasons,
            aboveViewportCompensationTotalMovedY: traceResult.totalAppliedMovedY,
            aboveViewportCompensations: alignedCompensations,
            historyCompensationsCount: traceResult.historyCompensations.count,
            historyCompensationsAppliedCount: traceResult.historyAppliedCount,
            historyCompensationsSkippedCount: traceResult.historySkippedCount,
            historyCompensationsSkippedReasons: traceResult.historySkippedReasons,
            historyCompensationTotalMovedY: traceResult.historyTotalAppliedMovedY,
            historySyncShiftsAppliedCount: traceResult.historySyncShiftsAppliedCount,
            historyRestoresAppliedCount: traceResult.historyRestoresAppliedCount,
            historyCompensations: alignedHistoryCompensations,
            expandedBlockRestored: expandedResult.status,
            expandedBlockTurn: expandedResult.turn,
            expandedBlockLineCount: expandedResult.lineCount,
            expandedBlockCollapsedHeight: expandedResult.collapsedHeight,
            expandedBlockExpandedHeight: expandedResult.expandedHeight,
            expandedBlockRestoredHeight: expandedResult.restoredHeight,
            expandedBlockEvictedDuringRun: expandedResult.evictedDuringRun,
            samples: sampleRecords,
            observedEvents: observedEvents
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let encoded = try? encoder.encode(samplesReport) {
            try? encoded.write(to: output.appendingPathComponent(samplesFile), options: .atomic)
        }

        let topLayoutShiftsText = formatShiftList(topLayoutShifts)
        let topResizeWindowShiftsText = formatShiftList(topResizeWindowShifts)
        let topSerifWindowShiftsText = formatShiftList(topSerifWindowShifts)

        let topJumpsText: String
        if topJumps.isEmpty {
            topJumpsText = "none"
        } else {
            topJumpsText = topJumps.map { item in
                String(
                    format: "t=%.3fs block=%@ content=%.1fpt expected=%.1fpt jump=%.1fpt clip=%.1fpt",
                    item.timestamp, item.blockID, item.contentMotion, item.expectedMotion, item.jump, item.rawClipDelta
                )
            }.joined(separator: "; ")
        }

        let seededKindsText = seedResult.seededRowKinds.keys.sorted().map {
            "\($0)=\(seedResult.seededRowKinds[$0] ?? 0)"
        }.joined(separator: ",")

        let summaryDetail = String(
            format: "verdict=%@ flags=%@ layoutShiftsOver4pt=%d maxAbsLayoutShift=%.2fpt resizeWinShifts=%d(max=%.2fpt) serifWinShifts=%d(max=%.2fpt) unmatched=%d/%d(%.2f%%) unmatchedLargeClip=%d compensations=%d(applied=%d,skipped=%d,movedY=%.1fpt,skippedReasons=%@) historyPages=%d historyComp=%d(applied=%d,syncShift=%d,restore=%d,movedY=%.1fpt) traceClock=%@ expandedBlockRestored=%@ recordingComplete=%@ allEventsArrived=%@ historyLoadHappened=%@ infoJumpsOver20pt=%d infoMaxAbsJump=%.2fpt observedEvents=%d/%d gestures=%d/%d hitTopEnd=%@ hitBottomEnd=%@ viewport=%dpt",
            verdict,
            scenario.activeFlags.joined(separator: ","),
            layoutShiftsOver4pt,
            maxAbsLayoutShift,
            resizeWindowShiftsOver4pt,
            resizeWindowMaxAbsShift,
            serifWindowShiftsOver4pt,
            serifWindowMaxAbsShift,
            unmatchedTransitionsCount,
            pairsCount,
            unmatchedRatio * 100.0,
            unmatchedLargeClipDuringGestureCount,
            traceResult.compensations.count,
            traceResult.appliedCount,
            traceResult.skippedCount,
            traceResult.totalAppliedMovedY,
            skippedReasonsText,
            traceResult.historyLoadCount,
            traceResult.historyCompensations.count,
            traceResult.historyAppliedCount,
            traceResult.historySyncShiftsAppliedCount,
            traceResult.historyRestoresAppliedCount,
            traceResult.historyTotalAppliedMovedY,
            clockAlignment.method,
            expandedResult.status,
            recordingComplete ? "true" : "false",
            allEventsArrived ? "true" : "false",
            historyLoadHappened ? "true" : "false",
            jumpsOver20pt,
            maxAbsJump,
            observedEvents.count, midScrollExpectedEvents,
            beganCount, midScrollExpectedGestures,
            hitTopEnd ? "true" : "false",
            hitBottomEnd ? "true" : "false",
            Int(viewport.rounded())
        )
        WebsiteCaptures.log("stress mid-scroll-summary: \(summaryDetail)")
        phases.append([
            "name": "mid-scroll-summary",
            "verdict": verdict,
            "verdictReasons": verdictReasons.isEmpty ? "none" : verdictReasons.joined(separator: "; "),
            "scenarioFlags": scenario.activeFlags.joined(separator: " "),
            "coldMode": scenario.cold ? "true" : "false",
            "historyMode": scenario.history ? "true" : "false",
            "mixMode": scenario.mix ? "true" : "false",
            "resizeMode": scenario.resize ? "true" : "false",
            "serifMode": scenario.serif ? "true" : "false",
            "seededTurns": String(seedResult.seeded),
            "seededRowKinds": seededKindsText,
            "skippedRowKinds": seedResult.skippedRowKinds.isEmpty ? "none" : seedResult.skippedRowKinds.joined(separator: "; "),
            "expandedStepsTurns": expandedStepsTurns.isEmpty ? "none" : expandedStepsTurns.map(String.init).joined(separator: ","),
            "detail": summaryDetail,
            "delivery": "hid",
            "measurementMethod": midScrollMeasurementMethod,
            "observedEvents": String(observedEvents.count),
            "expectedEvents": String(midScrollExpectedEvents),
            "observedGestures": String(beganCount),
            "expectedGestures": String(midScrollExpectedGestures),
            "allEventsArrived": allEventsArrived ? "true" : "false",
            "historyLoadHappened": historyLoadHappened ? "true" : "false",
            "historyPagesLoaded": String(traceResult.historyLoadCount),
            "hitTopEnd": hitTopEnd ? "true" : "false",
            "hitBottomEnd": hitBottomEnd ? "true" : "false",
            "minTopMarginPt": String(format: "%.1f", minTopMargin),
            "minBottomMarginPt": String(format: "%.1f", minBottomMargin),
            "recordingExists": recordingExists ? "true" : "false",
            "recordingFinishedSuccessfully": recordingAudit.finishedSuccessfully ? "true" : "false",
            "recordingCoveredEvents": recordingCoveredEvents ? "true" : "false",
            "recordingDurationSec": String(format: "%.2f", recordingAudit.recordedDuration),
            "recordingAssetDurationSec": recordingAudit.assetDuration.map { String(format: "%.2f", $0) } ?? "nil",
            "stillsComplete": stillsComplete ? "true" : "false",
            "samples": String(sortedSamples.count),
            "pairs": String(pairsCount),
            "unmatchedTransitions": String(unmatchedTransitionsCount),
            "unmatchedRatio": String(format: "%.4f", unmatchedRatio),
            "unmatchedLargeClipDuringGesture": String(unmatchedLargeClipDuringGestureCount),
            "fallbackTransitions": String(fallbackTransitionsCount),
            "layoutShiftsOver4pt": String(layoutShiftsOver4pt),
            "layoutShiftsOver20pt": String(layoutShiftsOver20pt),
            "layoutShiftsOver40pt": String(layoutShiftsOver40pt),
            "maxAbsLayoutShiftPt": String(format: "%.2f", maxAbsLayoutShift),
            "topLayoutShifts": topLayoutShiftsText,
            "resizeWindowPairs": String(resizeWindowPairsCount),
            "resizeWindowShiftsOver4pt": String(resizeWindowShiftsOver4pt),
            "resizeWindowShiftsOver20pt": String(resizeWindowShiftsOver20pt),
            "resizeWindowShiftsOver40pt": String(resizeWindowShiftsOver40pt),
            "resizeWindowMaxAbsShiftPt": String(format: "%.2f", resizeWindowMaxAbsShift),
            "topResizeWindowShifts": topResizeWindowShiftsText,
            "serifWindowPairs": String(serifWindowPairsCount),
            "serifWindowShiftsOver4pt": String(serifWindowShiftsOver4pt),
            "serifWindowShiftsOver20pt": String(serifWindowShiftsOver20pt),
            "serifWindowShiftsOver40pt": String(serifWindowShiftsOver40pt),
            "serifWindowMaxAbsShiftPt": String(format: "%.2f", serifWindowMaxAbsShift),
            "topSerifWindowShifts": topSerifWindowShiftsText,
            "reflowWindowSampleGaps": String(reflowWindowSampleGaps),
            "jumpsOver4pt": String(jumpsOver4pt),
            "jumpsOver20pt": String(jumpsOver20pt),
            "jumpsOver40pt": String(jumpsOver40pt),
            "maxAbsJumpPt": String(format: "%.2f", maxAbsJump),
            "topJumps": topJumpsText,
            "timelineTraceEnabled": traceResult.enabled ? "true" : "false",
            "timelineTraceCapped": traceResult.traceCapped ? "true" : "false",
            "traceClockAlignmentMethod": clockAlignment.method,
            "aboveViewportCompensations": String(traceResult.compensations.count),
            "aboveViewportCompensationsApplied": String(traceResult.appliedCount),
            "aboveViewportCompensationsSkipped": String(traceResult.skippedCount),
            "aboveViewportCompensationsSkippedReasons": skippedReasonsText,
            "aboveViewportCompensationTotalMovedY": String(format: "%.2f", traceResult.totalAppliedMovedY),
            "historyCompensations": String(traceResult.historyCompensations.count),
            "historyCompensationsApplied": String(traceResult.historyAppliedCount),
            "historyCompensationsSkipped": String(traceResult.historySkippedCount),
            "historyCompensationsSkippedReasons": historySkippedReasonsText,
            "historyCompensationTotalMovedY": String(format: "%.2f", traceResult.historyTotalAppliedMovedY),
            "historySyncShiftsApplied": String(traceResult.historySyncShiftsAppliedCount),
            "historyRestoresApplied": String(traceResult.historyRestoresAppliedCount),
            "expandedBlockRestored": expandedResult.status,
            "viewportPt": String(Int(viewport.rounded())),
            "samplesFile": samplesFile,
        ])
        saveReport(listFiles: false)
        return outcome
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
        // Outermost only: a tall code block or table nests its own horizontal scroll view,
        // which can outsize the timeline's viewport.
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
        var finishedSuccessfully = false
        var startMonoTime: CFTimeInterval?
        var endMonoTime: CFTimeInterval?
        var recordedDuration: TimeInterval = 0
        var errorDescription: String?
    }

    // Window-only ScreenCaptureKit recording preserves the one-frame motion that
    // the five-second stills miss. It never includes other applications or audio.
    private static func recordWindow(_ name: String, seconds: Double, stop: RecordingStop? = nil) async {
        defer { stop?.started = true }
        guard let window = appWindow(), let output = CaptureRun.outputDirectory else {
            stop?.finishedSuccessfully = false
            stop?.errorDescription = "window or output directory unavailable"
            return
        }
        do {
            let content = try await SCShareableContent.currentProcess
            guard let target = content.windows.first(where: {
                $0.windowID == CGWindowID(window.windowNumber) && $0.owningApplication?.processID == getpid()
            }) else {
                stop?.finishedSuccessfully = false
                stop?.errorDescription = "window not shareable"
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
            let startMono = CACurrentMediaTime()
            stop?.startMonoTime = startMono
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
            let stopMono = CACurrentMediaTime()
            let recordedSeconds = Date.now.timeIntervalSince(recordStart)
            try await stream.stopCapture()
            let end = Date.now.addingTimeInterval(5)
            while !completion.finished, Date.now < end {
                try? await Task.sleep(for: .milliseconds(50))
            }
            stop?.endMonoTime = stopMono
            stop?.recordedDuration = max(0, stopMono - startMono)
            if let error = completion.error {
                stop?.finishedSuccessfully = false
                stop?.errorDescription = error
            } else if completion.finished {
                stop?.finishedSuccessfully = true
                stop?.errorDescription = nil
            } else {
                stop?.finishedSuccessfully = false
                stop?.errorDescription = "recording completion timed out"
            }
            let durationText = stop == nil ? "\(seconds)s" : String(format: "%.1fs", recordedSeconds)
            note(name, completion.error ?? (completion.finished ? "recorded \(durationText)" : "recording completion timed out"))
        } catch {
            stop?.finishedSuccessfully = false
            stop?.errorDescription = error.localizedDescription
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
