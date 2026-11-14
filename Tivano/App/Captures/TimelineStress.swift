#if DEBUG
import AppKit
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
        model.selectedThreadID = threadID
        // Let ThreadTimeline's initial `.task` finish its 250ms open page + 1.6s window settle.
        try? await Task.sleep(for: .milliseconds(2100))

        let settleDeadline = Date.now.addingTimeInterval(3.0)
        var settledChecks = 0
        while Date.now < settleDeadline, secondsLeft() > minSecondsLeft {
            if let window = appWindow(), let scroll = timelineScroll(in: window),
               let docHeight = scroll.documentView?.bounds.height,
               docHeight > scroll.bounds.height * 1.5,
               let gap = bottomGap(scroll), gap <= 8 {
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
        await shoot(recorder, stage, shotName)
        note(noteName, "turns=\(turnsSeeded) offset=\(openOffset) docHeight=\(openHeight) gap=\(openGap) topTurn=\(openTopTurn) lowestTurn=\(openLowestTurn)")
        return (window, scroll)
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

    private static func wheelEvent(window: NSWindow, scroll: NSScrollView, deltaY: Int32) -> NSEvent? {
        guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: deltaY, wheel2: 0, wheel3: 0) else { return nil }
        let bounds = scroll.convert(scroll.bounds, to: nil)
        let point = NSPoint(x: bounds.midX, y: bounds.midY)
        let screenPoint = window.convertToScreen(NSRect(origin: point, size: .zero)).origin
        cg.location = CGPoint(x: screenPoint.x, y: CGDisplayBounds(CGMainDisplayID()).height - screenPoint.y)
        cg.setIntegerValueField(.eventTargetUnixProcessID, value: Int64(getpid()))
        cg.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(window.windowNumber))
        cg.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(window.windowNumber))
        guard let event = NSEvent(cgEvent: cg), event.type == .scrollWheel else { return nil }
        return event
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
