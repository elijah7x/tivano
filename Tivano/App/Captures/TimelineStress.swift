#if DEBUG
import AppKit
import QuartzCore
import ScreenCaptureKit

/// Chat-timeline jitter stress for a `--website-captures` process.
///
///     open -n -W "Tivano.app" --args --website-captures <folder> --timeline-stress
///
/// Uses the real model, chat window and mock threads. Reply text is rehearsed, so no
/// provider session starts. Scroll input is posted as wheel events so the timeline's
/// own monitor can see it. This file does not call the timeline's viewport repair.
@MainActor
enum TimelineStress {
    private static let budgetSeconds: TimeInterval = 300
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
        phase: UInt32
    ) -> (cg: CGEvent, ns: NSEvent)? {
        guard let cg = buildWheelCGEvent(window: window, scroll: scroll, deltaY: deltaY) else { return nil }
        cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase))
        cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: 0)
        cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
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
#endif

@MainActor
private final class HeldDragStreamGate {
    var paused = false
}
