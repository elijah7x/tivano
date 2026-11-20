#if DEBUG
import AppKit
import CoreGraphics
import Darwin
import Foundation
import QuartzCore
import ScreenCaptureKit
import SwiftUI

/// Repro harness for the folded-turn blank-reply bug in a `--website-captures` process.
///
///     open -n -W "Tivano.app" --args --website-captures <folder> --fold-repro \
///         [--fold-repro-scenario all|front|covered|miniaturized|inactive|otherThread|scrolledUp] \
///         [--fold-repro-count N] [--fold-repro-hold SECONDS] \
///         [--fold-repro-inject-zero] [--fold-repro-no-heal]
///
/// Uses the isolated capture library and rehearsed turns so no provider session starts.
@MainActor
enum FoldReplyRepro {
    enum Scenario: String, CaseIterable, Sendable {
        case front
        case covered
        case miniaturized
        case inactive
        case otherThread
        case scrolledUp
        /// Settings open over the chat (the pane hidden under it) while the turn folds.
        case settings
    }

    /// Sized to the requested workload in `run` (about 14 s per repetition plus headroom).
    private static var budgetSeconds: TimeInterval = 600
    /// How long a hidden/covered/other-thread scenario stays away after the fold (`--fold-repro-hold`).
    private static var holdSeconds: Double = 3
    private static var injectZero = false
    private static var healDisabled = false
    private static let windowSize = NSSize(width: 890, height: 340)
    private static let interimMessage = "Issue #58 是外部用户反馈，只有一张截图。我在看截图和渲染条件确认原因。"
    private static let interimPrefix = "Issue #58 是外部用户反馈"
    private static let userPrompt = "看下GitHub上的新issue。我有点忘了，在质感模式下是不是不能让用户自己换壁纸的，还是可以。"

    private static var deadline = Date.now
    private static var reportState = ReportBuilder()

    // MARK: - Report types

    private struct SizeRecord: Encodable, Sendable {
        let width: Double
        let height: Double
    }

    private struct RectRecord: Encodable, Sendable {
        let x: Double
        let y: Double
        let width: Double
        let height: Double

        init(_ rect: NSRect) {
            x = Double(rect.origin.x)
            y = Double(rect.origin.y)
            width = Double(rect.size.width)
            height = Double(rect.size.height)
        }
    }

    private struct AncestorState: Encodable, Sendable {
        let className: String
        let isHidden: Bool
        let alphaValue: Double
        let layerOpacity: Double?
        let layerHidden: Bool?
    }

    private struct TextViewProbe: Encodable, Sendable {
        let frameInWindow: RectRecord
        let boundsWidth: Double
        let boundsHeight: Double
        let measuredHeight: Double
        let heightDelta: Double
        let intersectsDocumentVisibleRect: Bool
        let intersectsUnobstructedViewport: Bool
        let anyAncestorHiddenOrTransparent: Bool
        let ancestors: [AncestorState]
    }

    private struct InterimViewProbe: Encodable, Sendable {
        let frameInWindow: RectRecord
        let boundsWidth: Double
        let boundsHeight: Double
        let measuredHeight: Double
        let sameAsMarkerView: Bool
    }

    private struct ScrollProbe: Encodable, Sendable {
        let clipMinY: Double
        let documentHeight: Double
        let visibleHeight: Double
        let contentInsetTop: Double
        let contentInsetBottom: Double
        let bottomGap: Double
        let isAtBottom: Bool
    }

    private struct InkAnalysis: Encodable, Sendable {
        let visibleRectInWindow: RectRecord
        let cropPixelWidth: Int
        let cropPixelHeight: Int
        let totalPixels: Int
        let medianLuminance: Double
        let inkPixels: Int
        let inkRatio: Double
    }

    private struct RepetitionRecord: Encodable, Sendable {
        let scenario: String
        let repetition: Int
        let threadID: String
        let marker: String
        let turnDurationSeconds: Double
        let passed: Bool
        let failureReasons: [String]
        let preFoldOcclusionVisible: Bool?
        let scrolledUpDelta: Double?
        let markerFoundCount: Int
        let markerViews: [TextViewProbe]
        let interimFoundCount: Int
        let interimViews: [InterimViewProbe]
        let scrollState: ScrollProbe?
        let didScrollMarkerIntoView: Bool
        let scrollStateAfterReveal: ScrollProbe?
        let stillCaptured: Bool
        let stillFile: String?
        let inkAnalysis: InkAnalysis?
    }

    private struct ScenarioSummary: Encodable, Sendable {
        let scenario: String
        let total: Int
        let passed: Int
        let failed: Int
    }

    private struct FoldReproReport: Encodable, Sendable {
        let startedAt: String
        let windowSize: SizeRecord
        let scenariosRequested: [String]
        let repetitionsPerScenario: Int
        let budgetSeconds: Int
        let injectZero: Bool
        let healDisabled: Bool
        let status: String
        let blockedReason: String?
        let scenarioFailCounts: [String: Int]
        let scenarios: [ScenarioSummary]
        let repetitions: [RepetitionRecord]
    }

    @MainActor
    private final class ReportBuilder {
        var startedAt = ISO8601DateFormatter().string(from: .now)
        var scenariosRequested: [String] = []
        var repetitionsPerScenario = 10
        var injectZero = false
        var healDisabled = false
        var status = "running"
        var blockedReason: String?
        var scenarioFailCounts: [String: Int] = [:]
        var scenarios: [ScenarioSummary] = []
        var repetitions: [RepetitionRecord] = []

        func reset(scenarios: [Scenario], count: Int, injectZero: Bool = false, healDisabled: Bool = false) {
            startedAt = ISO8601DateFormatter().string(from: .now)
            scenariosRequested = scenarios.map(\.rawValue)
            repetitionsPerScenario = count
            self.injectZero = injectZero
            self.healDisabled = healDisabled
            status = "running"
            blockedReason = nil
            scenarioFailCounts = Dictionary(uniqueKeysWithValues: scenarios.map { ($0.rawValue, 0) })
            self.scenarios = []
            repetitions = []
        }

        func snapshot() -> FoldReproReport {
            FoldReproReport(
                startedAt: startedAt,
                windowSize: SizeRecord(width: Double(windowSize.width), height: Double(windowSize.height)),
                scenariosRequested: scenariosRequested,
                repetitionsPerScenario: repetitionsPerScenario,
                budgetSeconds: Int(budgetSeconds),
                injectZero: injectZero,
                healDisabled: healDisabled,
                status: status,
                blockedReason: blockedReason,
                scenarioFailCounts: scenarioFailCounts,
                scenarios: scenarios,
                repetitions: repetitions
            )
        }
    }

    // MARK: - Entry point

    static func run(model: AppModel) async {
        guard CaptureRun.isEnabled, let output = CaptureRun.outputDirectory else { return }

        let parsed = parseArguments()
        guard let scenarios = parsed.scenarios, let count = parsed.count else {
            let reason = parsed.error ?? "invalid --fold-repro arguments"
            WebsiteCaptures.log("fold-repro blocked: \(reason)")
            reportState.reset(scenarios: [], count: 0, injectZero: parsed.injectZero, healDisabled: parsed.noHeal)
            reportState.status = "blocked"
            reportState.blockedReason = reason
            saveReport(to: output)
            emitLine("fold-repro blocked: \(reason)")
            exit(2)
        }

        injectZero = parsed.injectZero
        healDisabled = parsed.noHeal
        if healDisabled {
            LinkTextView.debugHeightHealDisabled = true
        }

        budgetSeconds = max(600, TimeInterval(scenarios.count * count) * (25 + holdSeconds) + 120)
        reportState.reset(scenarios: scenarios, count: count, injectZero: injectZero, healDisabled: healDisabled)
        saveReport(to: output)

        await model.bootstrap()
        guard model.isLibraryLoaded, let project = model.projects.first, !model.threads.isEmpty else {
            let reason = "capture library failed to load"
            WebsiteCaptures.log("fold-repro blocked: \(reason)")
            reportState.status = "blocked"
            reportState.blockedReason = reason
            saveReport(to: output)
            emitLine("fold-repro blocked: \(reason)")
            exit(2)
        }

        deadline = Date.now.addingTimeInterval(budgetSeconds)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(budgetSeconds))
            WebsiteCaptures.log("fold-repro out of time (\(Int(budgetSeconds))s), quitting")
            reportState.status = "timeout"
            reportState.blockedReason = "exceeded \(Int(budgetSeconds))s overall timeout"
            saveReport(to: output)
            emitLine("fold-repro timeout after \(Int(budgetSeconds))s")
            exit(2)
        }

        model.settings.hasSeenHydraIntro = true
        model.settings.hydraEnabled = false

        let scenarioNames = scenarios.map(\.rawValue).joined(separator: ",")
        WebsiteCaptures.log("fold-repro start \(output.path) scenarios=\(scenarioNames) count=\(count) injectZero=\(injectZero) healDisabled=\(healDisabled)")

        let stage = Stage(model: model)
        stage.show(size: windowSize)
        await stage.ensureActive()
        guard let window = stage.contentWindow, NSApp.isActive, window.isKeyWindow else {
            let reason = "foreground desktop or main window unavailable"
            WebsiteCaptures.log("fold-repro blocked: \(reason)")
            reportState.status = "blocked"
            reportState.blockedReason = reason
            saveReport(to: output)
            emitLine("fold-repro blocked: \(reason)")
            exit(2)
        }
        guard let content = try? await SCShareableContent.currentProcess, !content.displays.isEmpty else {
            let reason = "no capturable display for this process"
            WebsiteCaptures.log("fold-repro blocked: \(reason)")
            reportState.status = "blocked"
            reportState.blockedReason = reason
            saveReport(to: output)
            emitLine("fold-repro blocked: \(reason)")
            exit(2)
        }

        if model.sidebar.isVisible {
            model.sidebar.toggle()
            try? await Task.sleep(for: .milliseconds(250))
        }

        let otherThreadID = WebsiteCaptures.composerThreadID
        var totalFailures = 0
        var globalIndex = 0

        for scenario in scenarios {
            WebsiteCaptures.log("fold-repro scenario=\(scenario.rawValue) begin count=\(count)")
            var scenarioPassed = 0
            var scenarioFailed = 0
            var savedFirstPass = false

            for rep in 1...count {
                guard deadline.timeIntervalSinceNow > 5 else {
                    WebsiteCaptures.log("fold-repro out of time before \(scenario.rawValue) rep=\(rep)")
                    reportState.status = "timeout"
                    reportState.blockedReason = "exceeded \(Int(budgetSeconds))s overall timeout"
                    saveReport(to: output)
                    emitLine("fold-repro timeout before \(scenario.rawValue) rep=\(rep)")
                    exit(2)
                }

                globalIndex += 1
                let record = await runRepetition(
                    scenario: scenario,
                    repetition: rep,
                    globalIndex: globalIndex,
                    model: model,
                    project: project,
                    otherThreadID: otherThreadID,
                    stage: stage,
                    window: window,
                    output: output,
                    savedFirstPass: &savedFirstPass
                )
                reportState.repetitions.append(record)
                if record.passed {
                    scenarioPassed += 1
                } else {
                    scenarioFailed += 1
                    totalFailures += 1
                    reportState.scenarioFailCounts[scenario.rawValue, default: 0] += 1
                }
                saveReport(to: output)
            }

            let summary = ScenarioSummary(
                scenario: scenario.rawValue,
                total: count,
                passed: scenarioPassed,
                failed: scenarioFailed
            )
            reportState.scenarios.append(summary)
            saveReport(to: output)

            let line = "fold-repro scenario=\(scenario.rawValue) total=\(count) passed=\(scenarioPassed) failed=\(scenarioFailed)"
            WebsiteCaptures.log(line)
            emitLine(line)
        }

        reportState.status = totalFailures == 0 ? "passed" : "failed"
        saveReport(to: output)
        WebsiteCaptures.log("fold-repro done totalFailures=\(totalFailures)")
        exit(totalFailures == 0 ? 0 : 1)
    }

    // MARK: - Single repetition

    private static func runRepetition(
        scenario: Scenario,
        repetition: Int,
        globalIndex: Int,
        model: AppModel,
        project: Project,
        otherThreadID: UUID,
        stage: Stage,
        window: NSWindow,
        output: URL,
        savedFirstPass: inout Bool
    ) async -> RepetitionRecord {
        await ensureWindowReady(window: window, stage: stage)

        var thread = ChatThread(
            projectID: project.id,
            provider: .claude,
            model: "opus",
            effort: "high",
            runtimeMode: .supervised
        )
        thread.title = "Fold repro \(scenario.rawValue) #\(repetition)"
        thread.hasCustomTitle = true
        thread.branch = "main"
        model.insertThread(thread)
        model.selectedThreadID = thread.id

        let runtime = model.runtime(for: thread.id)
        await runtime.ensureLoaded()
        try? await Task.sleep(for: .milliseconds(250))

        let marker = String(format: "FOLDMARK%03d", globalIndex)
        let prefix = "fold-\(scenario.rawValue)-\(repetition)"
        let turnStart = Date.now

        WebsiteCaptures.log("fold-repro \(scenario.rawValue) rep=\(repetition) start thread=\(thread.id.uuidString) marker=\(marker)")

        runtime.rehearseTurn(userPrompt)
        runtime.rehearseTitle(userPrompt)
        let turn = runtime.rehearsalTurnID
        let live = { runtime.isRunning && runtime.rehearsalTurnID == turn }
        try? await Task.sleep(for: .milliseconds(150))

        // 5 command tool calls, each with a few hundred chars of output.
        for toolIndex in 1...5 {
            guard live() else { break }
            let toolID = "\(prefix)-cmd-\(toolIndex)"
            let spec = initialCommandTools[toolIndex - 1]
            runtime.rehearse(.toolStarted(id: toolID, call: ToolCall(kind: .command, title: spec.title, detail: spec.detail)))
            try? await Task.sleep(for: .milliseconds(640))
            guard live() else { break }
            runtime.rehearse(.toolUpdated(id: toolID, update: ToolUpdate(output: spec.output, status: .completed, exitCode: 0)))
            try? await Task.sleep(for: .milliseconds(120))
        }

        // Intermediate ~52-char assistant message streamed then completed.
        if live() {
            let interimID = "\(prefix)-m1"
            await streamFixed(runtime, id: interimID, text: interimMessage, chunkSize: 6, delayMs: 25, alive: live)
            if live() {
                runtime.rehearse(.messageCompleted(id: interimID, text: interimMessage))
                try? await Task.sleep(for: .milliseconds(180))
            }
        }

        // 3 more tools including one `.read` of a PNG path.
        for (index, spec) in followUpTools.enumerated() {
            guard live() else { break }
            let toolID = "\(prefix)-extra-\(index + 1)"
            runtime.rehearse(.toolStarted(id: toolID, call: ToolCall(kind: spec.kind, title: spec.title, detail: spec.detail)))
            try? await Task.sleep(for: .milliseconds(720))
            guard live() else { break }
            runtime.rehearse(.toolUpdated(id: toolID, update: ToolUpdate(output: spec.output, status: .completed, exitCode: spec.kind == .command ? 0 : nil)))
            try? await Task.sleep(for: .milliseconds(120))
        }

        // Final ~770-char assistant message streamed in deltas of 20-40 chars every 16-30 ms.
        let finalText = finalMarkdown(marker: marker)
        let finalID = "\(prefix)-m2"
        let chunks = buildChunks(for: finalText)
        let postChunkTailMs = 100
        var remainingMs = chunks.reduce(postChunkTailMs) { $0 + $1.delayMs }

        var coverWindow: NSWindow?
        var preFoldTriggered = false
        var preFoldOcclusionVisible: Bool?
        var scrolledUpTriggered = false
        var scrolledUpDelta: Double?

        for (chunkIndex, piece) in chunks.enumerated() {
            guard live() else { break }

            // Fire the 1 s pre-turnCompleted trigger for non-front / non-scrolledUp scenarios.
            if !preFoldTriggered, remainingMs <= 1_000 {
                switch scenario {
                case .front, .scrolledUp:
                    break
                case .covered:
                    preFoldTriggered = true
                    coverWindow = orderCoverWindow(above: window)
                case .miniaturized:
                    preFoldTriggered = true
                    window.miniaturize(nil)
                case .inactive:
                    preFoldTriggered = true
                    NSApp.hide(nil)
                case .otherThread:
                    preFoldTriggered = true
                    model.selectedThreadID = otherThreadID
                case .settings:
                    preFoldTriggered = true
                    SettingsNavigation.shared.present(page: .appearance)
                }
            }

            runtime.rehearse(.messageDelta(id: finalID, text: piece.text))

            // In scrolledUp, scroll up 60 pt (unpinning) once enough text is streaming.
            if scenario == .scrolledUp, !scrolledUpTriggered, chunkIndex >= chunks.count / 3 {
                if let moved = scrollUpBy60AndUnpin(in: window) {
                    scrolledUpDelta = moved
                    if abs(moved) >= 1.0 || chunkIndex >= (chunks.count * 2) / 3 {
                        scrolledUpTriggered = true
                    }
                }
            }

            try? await Task.sleep(for: .milliseconds(piece.delayMs))
            remainingMs -= piece.delayMs
        }

        // Safety fallback if the final message was shorter than 1 s.
        if !preFoldTriggered {
            switch scenario {
            case .front, .scrolledUp:
                break
            case .covered:
                preFoldTriggered = true
                coverWindow = orderCoverWindow(above: window)
            case .miniaturized:
                preFoldTriggered = true
                window.miniaturize(nil)
            case .inactive:
                preFoldTriggered = true
                NSApp.hide(nil)
            case .otherThread:
                preFoldTriggered = true
                model.selectedThreadID = otherThreadID
            case .settings:
                preFoldTriggered = true
                SettingsNavigation.shared.present(page: .appearance)
            }
        }

        if scenario == .scrolledUp, !scrolledUpTriggered {
            scrolledUpDelta = scrollUpBy60AndUnpin(in: window)
        }

        if live() {
            try? await Task.sleep(for: .milliseconds(postChunkTailMs))
        }

        if scenario == .covered || scenario == .miniaturized || scenario == .inactive {
            preFoldOcclusionVisible = window.occlusionState.contains(.visible)
        }

        if live() {
            runtime.rehearse(.messageCompleted(id: finalID, text: finalText))
            if injectZero {
                ProseRunRepresentable.debugZeroHeightMarker = marker
                ProseRunRepresentable.debugZeroHeightUntil = Date.now.addingTimeInterval(0.6)
            }
            runtime.rehearse(.turnCompleted(status: .completed, error: nil))
        }

        let finishWait = Date.now.addingTimeInterval(5)
        while runtime.isRunning, Date.now < finishWait {
            try? await Task.sleep(for: .milliseconds(40))
        }
        let turnDuration = Date.now.timeIntervalSince(turnStart)

        // Hold & restore per scenario.
        switch scenario {
        case .front:
            break
        case .covered:
            try? await Task.sleep(for: .seconds(holdSeconds))
            if let cover = coverWindow {
                cover.orderOut(nil)
                cover.close()
                coverWindow = nil
            }
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        case .miniaturized:
            try? await Task.sleep(for: .seconds(holdSeconds))
            window.deminiaturize(nil)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            let deminiDeadline = Date.now.addingTimeInterval(1.5)
            while window.isMiniaturized, Date.now < deminiDeadline {
                try? await Task.sleep(for: .milliseconds(50))
            }
        case .inactive:
            try? await Task.sleep(for: .seconds(holdSeconds))
            NSApp.unhide(nil)
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        case .otherThread:
            try? await Task.sleep(for: .seconds(holdSeconds))
            model.selectedThreadID = thread.id
        case .settings:
            try? await Task.sleep(for: .seconds(holdSeconds))
            SettingsNavigation.shared.dismiss()
        case .scrolledUp:
            try? await Task.sleep(for: .milliseconds(250))
            scrollToBottomProgrammatically(in: window)
        }

        // Wait 1.5 s after the restore step (or after turnCompleted for `front`),
        // or 4.5 s when injecting zero height so the heal backoff (1 s, 3 s) can run.
        try? await Task.sleep(for: .milliseconds(injectZero ? 4_500 : 1_500))

        // Inspect hierarchy before scrolling into view.
        let allLinkViews = findAll(LinkTextView.self, in: window.contentView)
        let matchingViews = allLinkViews.filter { ($0.textStorage?.string ?? $0.string).contains(marker) }
        let primaryMarkerView = matchingViews.first
        let interimMatchingViews = allLinkViews.filter { ($0.textStorage?.string ?? $0.string).contains(interimPrefix) }

        let primaryScroll = primaryMarkerView?.enclosingScrollView ?? timelineScroll(in: window)
        let initialScrollProbe = primaryScroll.flatMap(measureScroll)

        let markerProbes = matchingViews.map { probeMarkerView($0, scroll: $0.enclosingScrollView ?? primaryScroll) }
        let interimProbes = interimMatchingViews.map { view -> InterimViewProbe in
            let frameInWindow = view.convert(view.bounds, to: nil)
            let measured = view.bounds.width > 0 ? view.height(forWidth: view.bounds.width) : 0
            return InterimViewProbe(
                frameInWindow: RectRecord(frameInWindow),
                boundsWidth: Double(view.bounds.width),
                boundsHeight: Double(view.bounds.height),
                measuredHeight: Double(measured),
                sameAsMarkerView: primaryMarkerView != nil && (view === primaryMarkerView)
            )
        }

        // Scroll marker view into view if not visible, then wait 300 ms.
        var didScrollMarkerIntoView = false
        var scrollProbeAfterReveal: ScrollProbe?
        // Judged before any recovery scroll: a reply the timeline failed to show must not
        // pass because the harness scrolled (and so redrew) it.
        var visibleBeforeRecovery = false
        if let markerView = primaryMarkerView {
            let scroll = markerView.enclosingScrollView ?? primaryScroll
            let visibleBefore = isSubstantiallyVisible(markerView, in: scroll)
            visibleBeforeRecovery = visibleBefore
            if !visibleBefore {
                didScrollMarkerIntoView = true
                _ = markerView.scrollToVisible(markerView.bounds)
                if let scroll {
                    scroll.reflectScrolledClipView(scroll.contentView)
                }
                try? await Task.sleep(for: .milliseconds(300))

                // If `scrollToVisible` stopped behind `contentInsets.bottom` (composer), align into unobstructed viewport.
                if let scroll, !isSubstantiallyVisible(markerView, in: scroll), let document = scroll.documentView {
                    let rectInDoc = markerView.convert(markerView.bounds, to: document)
                    let clip = scroll.contentView
                    let targetY = rectInDoc.minY - scroll.contentInsets.top
                    let rect = NSRect(origin: NSPoint(x: clip.bounds.minX, y: targetY), size: clip.bounds.size)
                    clip.scroll(to: clip.constrainBoundsRect(rect).origin)
                    scroll.reflectScrolledClipView(clip)
                    try? await Task.sleep(for: .milliseconds(300))
                }
                scrollProbeAfterReveal = scroll.flatMap(measureScroll)
            }
        }

        // Capture a still of the window using the same method as other capture runs.
        await stage.ensureActive()
        let captured = await captureStillImage(rect: stage.captureRect)

        var inkAnalysis: InkAnalysis?
        if let captured, let markerView = primaryMarkerView {
            inkAnalysis = analyzeInk(
                markerView: markerView,
                scroll: markerView.enclosingScrollView ?? primaryScroll,
                window: window,
                image: captured.image,
                stillScreenRect: captured.rect
            )
        }

        if injectZero {
            ProseRunRepresentable.debugZeroHeightMarker = nil
        }

        // Evaluate pass/fail rules.
        var failureReasons: [String] = []
        if matchingViews.isEmpty {
            failureReasons.append("marker_view_missing")
        } else if !visibleBeforeRecovery {
            failureReasons.append("not_in_view_before_recovery")
        }
        if scenario == .scrolledUp, abs(scrolledUpDelta ?? 0) < 30 {
            failureReasons.append(String(format: "scroll_up_not_applied(delta=%.1f)", scrolledUpDelta ?? 0))
        }
        if let probe = markerProbes.first {
            if probe.boundsWidth <= 0 || probe.boundsHeight < probe.measuredHeight - 1.0 {
                failureReasons.append(String(format: "height_too_small(bounds=%.1f,measured=%.1f)", probe.boundsHeight, probe.measuredHeight))
            }
            if probe.anyAncestorHiddenOrTransparent {
                failureReasons.append("ancestor_hidden_or_transparent")
            }
        }
        if captured == nil {
            failureReasons.append("still_capture_failed")
        } else if let ink = inkAnalysis {
            if ink.totalPixels == 0 || ink.inkRatio < 0.005 {
                failureReasons.append(String(format: "insufficient_ink(ratio=%.4f,pixels=%d/%d)", ink.inkRatio, ink.inkPixels, ink.totalPixels))
            }
        } else if primaryMarkerView != nil {
            failureReasons.append("insufficient_ink(no_visible_rect)")
        }

        let passed = failureReasons.isEmpty

        // Save still for every failure and the first pass of each scenario.
        var stillFile: String?
        let shouldSaveStill = !passed || !savedFirstPass
        if shouldSaveStill, let captured {
            let tag = passed ? "pass" : "fail"
            let name = String(format: "%@-rep%02d-%@.png", scenario.rawValue, repetition, tag)
            if savePNG(captured.image, to: output.appendingPathComponent(name)) {
                stillFile = name
                if passed { savedFirstPass = true }
            }
        }

        let inkPct = (inkAnalysis?.inkRatio ?? 0) * 100
        let firstProbe = markerProbes.first
        WebsiteCaptures.log(
            String(
                format: "fold-repro %@ rep=%d pass=%@ injectZero=%@ healDisabled=%@ found=%d interim=%d h=%.1f/%.1f ink=%.2f%% occludedVis=%@ reasons=%@",
                scenario.rawValue,
                repetition,
                passed ? "true" : "false",
                injectZero ? "true" : "false",
                healDisabled ? "true" : "false",
                matchingViews.count,
                interimMatchingViews.count,
                firstProbe?.boundsHeight ?? -1,
                firstProbe?.measuredHeight ?? -1,
                inkPct,
                preFoldOcclusionVisible.map { $0 ? "true" : "false" } ?? "nil",
                failureReasons.isEmpty ? "none" : failureReasons.joined(separator: ",")
            )
        )

        return RepetitionRecord(
            scenario: scenario.rawValue,
            repetition: repetition,
            threadID: thread.id.uuidString,
            marker: marker,
            turnDurationSeconds: (turnDuration * 100).rounded() / 100,
            passed: passed,
            failureReasons: failureReasons,
            preFoldOcclusionVisible: preFoldOcclusionVisible,
            scrolledUpDelta: scrolledUpDelta,
            markerFoundCount: matchingViews.count,
            markerViews: markerProbes,
            interimFoundCount: interimMatchingViews.count,
            interimViews: interimProbes,
            scrollState: initialScrollProbe,
            didScrollMarkerIntoView: didScrollMarkerIntoView,
            scrollStateAfterReveal: scrollProbeAfterReveal,
            stillCaptured: captured != nil,
            stillFile: stillFile,
            inkAnalysis: inkAnalysis
        )
    }

    // MARK: - Window, scroll & inspection helpers

    private static func ensureWindowReady(window: NSWindow, stage: Stage) async {
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        NSApp.unhide(nil)
        await stage.ensureActive()
        window.makeKeyAndOrderFront(nil)
    }

    private static func orderCoverWindow(above window: NSWindow) -> NSWindow {
        let frame = window.frame.insetBy(dx: -40, dy: -40)
        let cover = NSWindow(
            contentRect: frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        cover.isOpaque = true
        cover.backgroundColor = .windowBackgroundColor
        cover.hasShadow = false
        cover.level = .normal
        cover.isReleasedWhenClosed = false
        cover.order(.above, relativeTo: window.windowNumber)
        return cover
    }

    private static func findAll<View: NSView>(_ type: View.Type, in root: NSView?) -> [View] {
        guard let root else { return [] }
        var found: [View] = []
        if let match = root as? View { found.append(match) }
        for child in root.subviews { found.append(contentsOf: findAll(type, in: child)) }
        return found
    }

    private static func timelineScroll(in window: NSWindow) -> NSScrollView? {
        findAll(NSScrollView.self, in: window.contentView)
            .filter {
                !$0.isHiddenOrHasHiddenAncestor
                    && $0.enclosingScrollView == nil
                    && !($0.documentView is ComposerNSTextView)
                    && $0.bounds.height > 60
                    && $0.bounds.width > 200
            }
            .max { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }
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

    private static func unobstructedViewportRect(in scroll: NSScrollView) -> NSRect {
        let visible = scroll.documentVisibleRect
        let insets = scroll.contentInsets
        let height = visible.height - insets.top - insets.bottom
        guard height > 24 else { return visible }
        return NSRect(x: visible.minX, y: visible.minY + insets.top, width: visible.width, height: height)
    }

    private static func scrollUpBy60AndUnpin(in window: NSWindow) -> Double? {
        guard let scroll = timelineScroll(in: window), scroll.documentView != nil else { return nil }
        let clip = scroll.contentView
        let beforeY = clip.bounds.minY
        let targetY = clip.isFlipped ? (beforeY - 60) : (beforeY + 60)
        timelineTracking(in: scroll)?.noteWheelInput(offsetDelta: -60)
        let rect = NSRect(origin: NSPoint(x: clip.bounds.minX, y: targetY), size: clip.bounds.size)
        clip.scroll(to: clip.constrainBoundsRect(rect).origin)
        scroll.reflectScrolledClipView(clip)
        return Double(clip.bounds.minY - beforeY)
    }

    private static func scrollToBottomProgrammatically(in window: NSWindow) {
        guard let scroll = timelineScroll(in: window), let document = scroll.documentView else { return }
        let clip = scroll.contentView
        let bottomY = clip.isFlipped ? document.bounds.maxY : document.bounds.minY
        let rect = NSRect(origin: NSPoint(x: clip.bounds.minX, y: bottomY), size: clip.bounds.size)
        clip.scroll(to: clip.constrainBoundsRect(rect).origin)
        scroll.reflectScrolledClipView(clip)
    }

    private static func measureScroll(_ scroll: NSScrollView) -> ScrollProbe {
        let clip = scroll.contentView
        let docHeight = Double(scroll.documentView?.bounds.height ?? 0)
        let viewport = unobstructedViewportRect(in: scroll)
        let gap: Double
        if let document = scroll.documentView {
            if document.isFlipped {
                gap = Double(document.bounds.height - viewport.maxY)
            } else {
                gap = Double(viewport.minY)
            }
        } else {
            gap = 0
        }
        return ScrollProbe(
            clipMinY: Double(clip.bounds.minY),
            documentHeight: docHeight,
            visibleHeight: Double(viewport.height),
            contentInsetTop: Double(scroll.contentInsets.top),
            contentInsetBottom: Double(scroll.contentInsets.bottom),
            bottomGap: gap,
            isAtBottom: gap <= 8.0
        )
    }

    private static func probeMarkerView(_ view: LinkTextView, scroll: NSScrollView?) -> TextViewProbe {
        let frameInWindow = view.convert(view.bounds, to: nil)
        let boundsWidth = view.bounds.width
        let boundsHeight = view.bounds.height
        let measured = boundsWidth > 0 ? view.height(forWidth: boundsWidth) : 0

        var ancestors: [AncestorState] = []
        var anyHiddenOrTransparent = false
        var cursor: NSView? = view
        while let current = cursor {
            let layerOpacity = current.layer.map { Double($0.opacity) }
            let layerHidden = current.layer.map { $0.isHidden }
            if current.isHidden || current.alphaValue < 0.05 || (layerOpacity ?? 1.0) < 0.05 || layerHidden == true {
                anyHiddenOrTransparent = true
            }
            ancestors.append(AncestorState(
                className: String(describing: type(of: current)),
                isHidden: current.isHidden,
                alphaValue: Double(current.alphaValue),
                layerOpacity: layerOpacity,
                layerHidden: layerHidden
            ))
            cursor = current.superview
        }

        var intersectsDocVisible = false
        var intersectsUnobstructed = false
        if let scroll, let document = scroll.documentView {
            let rectInDoc = view.convert(view.bounds, to: document)
            let docOverlap = rectInDoc.intersection(scroll.documentVisibleRect)
            intersectsDocVisible = !docOverlap.isNull && !docOverlap.isEmpty && docOverlap.width > 1 && docOverlap.height > 1
            let unobstructedOverlap = rectInDoc.intersection(unobstructedViewportRect(in: scroll))
            intersectsUnobstructed = !unobstructedOverlap.isNull && !unobstructedOverlap.isEmpty && unobstructedOverlap.width > 1 && unobstructedOverlap.height > 1
        }

        return TextViewProbe(
            frameInWindow: RectRecord(frameInWindow),
            boundsWidth: Double(boundsWidth),
            boundsHeight: Double(boundsHeight),
            measuredHeight: Double(measured),
            heightDelta: Double(boundsHeight - measured),
            intersectsDocumentVisibleRect: intersectsDocVisible,
            intersectsUnobstructedViewport: intersectsUnobstructed,
            anyAncestorHiddenOrTransparent: anyHiddenOrTransparent,
            ancestors: ancestors
        )
    }

    private static func isSubstantiallyVisible(_ view: LinkTextView, in scroll: NSScrollView?) -> Bool {
        guard let scroll, let document = scroll.documentView else { return false }
        let rectInDoc = view.convert(view.bounds, to: document)
        let overlap = rectInDoc.intersection(unobstructedViewportRect(in: scroll))
        return !overlap.isNull && !overlap.isEmpty && overlap.width > 8 && overlap.height >= min(16, view.bounds.height)
    }

    // MARK: - Still capture & ink analysis

    private static func captureStillImage(rect rawRect: NSRect) async -> (image: CGImage, rect: NSRect)? {
        guard let screen = NSScreen.main else { return nil }
        let rect = rawRect.intersection(screen.visibleFrame)
        guard !rect.isEmpty else { return nil }
        guard let filter = await Recorder.filter() else {
            WebsiteCaptures.log("fold-repro still: no ScreenCaptureKit filter")
            return nil
        }
        let configuration = Recorder.configuration(for: rect)
        configuration.captureResolution = .best
        do {
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            return (image, rect)
        } catch {
            WebsiteCaptures.log("fold-repro still failed: \(error.localizedDescription)")
            return nil
        }
    }

    private static func savePNG(_ image: CGImage, to url: URL) -> Bool {
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        do {
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            WebsiteCaptures.log("fold-repro failed to save \(url.lastPathComponent): \(error.localizedDescription)")
            return false
        }
    }

    private static func analyzeInk(
        markerView: LinkTextView,
        scroll: NSScrollView?,
        window: NSWindow,
        image: CGImage,
        stillScreenRect: NSRect
    ) -> InkAnalysis? {
        var visibleWindowRect = markerView.convert(markerView.bounds, to: nil)
        if let scroll, let document = scroll.documentView {
            let rectInDoc = markerView.convert(markerView.bounds, to: document)
            let clippedDoc = rectInDoc.intersection(unobstructedViewportRect(in: scroll))
            if clippedDoc.isNull || clippedDoc.isEmpty {
                return InkAnalysis(
                    visibleRectInWindow: RectRecord(.zero),
                    cropPixelWidth: 0,
                    cropPixelHeight: 0,
                    totalPixels: 0,
                    medianLuminance: 0,
                    inkPixels: 0,
                    inkRatio: 0
                )
            }
            visibleWindowRect = document.convert(clippedDoc, to: nil)
        }
        if let contentView = window.contentView {
            visibleWindowRect = visibleWindowRect.intersection(contentView.convert(contentView.bounds, to: nil))
        }
        guard !visibleWindowRect.isNull, !visibleWindowRect.isEmpty else {
            return InkAnalysis(
                visibleRectInWindow: RectRecord(.zero),
                cropPixelWidth: 0,
                cropPixelHeight: 0,
                totalPixels: 0,
                medianLuminance: 0,
                inkPixels: 0,
                inkRatio: 0
            )
        }

        let screenRect = window.convertToScreen(visibleWindowRect)
        let clippedScreen = screenRect.intersection(stillScreenRect)
        guard !clippedScreen.isNull, !clippedScreen.isEmpty, stillScreenRect.width > 0, stillScreenRect.height > 0 else {
            return InkAnalysis(
                visibleRectInWindow: RectRecord(visibleWindowRect),
                cropPixelWidth: 0,
                cropPixelHeight: 0,
                totalPixels: 0,
                medianLuminance: 0,
                inkPixels: 0,
                inkRatio: 0
            )
        }

        let scaleX = CGFloat(image.width) / stillScreenRect.width
        let scaleY = CGFloat(image.height) / stillScreenRect.height
        let pxMinX = max(0, min(image.width, Int(((clippedScreen.minX - stillScreenRect.minX) * scaleX).rounded(.up))))
        let pxMaxX = max(0, min(image.width, Int(((clippedScreen.maxX - stillScreenRect.minX) * scaleX).rounded(.down))))
        // CGImage origin is top-left while AppKit screen Y increases upward.
        let pxMinY = max(0, min(image.height, Int(((stillScreenRect.maxY - clippedScreen.maxY) * scaleY).rounded(.up))))
        let pxMaxY = max(0, min(image.height, Int(((stillScreenRect.maxY - clippedScreen.minY) * scaleY).rounded(.down))))

        let cropW = pxMaxX - pxMinX
        let cropH = pxMaxY - pxMinY
        guard cropW > 0, cropH > 0,
              let cropped = image.cropping(to: CGRect(x: pxMinX, y: pxMinY, width: cropW, height: cropH)) else {
            return InkAnalysis(
                visibleRectInWindow: RectRecord(visibleWindowRect),
                cropPixelWidth: max(0, cropW),
                cropPixelHeight: max(0, cropH),
                totalPixels: 0,
                medianLuminance: 0,
                inkPixels: 0,
                inkRatio: 0
            )
        }

        let bytesPerRow = cropW * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * cropH)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        let drew: Bool = pixels.withUnsafeMutableBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress,
                  let context = CGContext(
                    data: baseAddress,
                    width: cropW,
                    height: cropH,
                    bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow,
                    space: colorSpace,
                    bitmapInfo: bitmapInfo
                  ) else { return false }
            context.draw(cropped, in: CGRect(x: 0, y: 0, width: cropW, height: cropH))
            return true
        }
        guard drew else { return nil }

        let totalPixels = cropW * cropH
        let bins = 4096
        let maxBin = bins - 1
        var histogram = [Int](repeating: 0, count: bins)

        var offset = 0
        while offset < pixels.count {
            let r = Double(pixels[offset])
            let g = Double(pixels[offset + 1])
            let b = Double(pixels[offset + 2])
            let lum = (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255.0
            let bin = min(maxBin, max(0, Int((lum * Double(maxBin)).rounded())))
            histogram[bin] += 1
            offset += 4
        }

        var cumulative = 0
        let half = (totalPixels + 1) / 2
        var medianBin = 0
        for (bin, count) in histogram.enumerated() {
            cumulative += count
            if cumulative >= half {
                medianBin = bin
                break
            }
        }
        let medianLum = Double(medianBin) / Double(maxBin)

        var inkPixels = 0
        offset = 0
        while offset < pixels.count {
            let r = Double(pixels[offset])
            let g = Double(pixels[offset + 1])
            let b = Double(pixels[offset + 2])
            let lum = (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255.0
            if abs(lum - medianLum) > 0.25 {
                inkPixels += 1
            }
            offset += 4
        }

        let ratio = totalPixels > 0 ? Double(inkPixels) / Double(totalPixels) : 0
        return InkAnalysis(
            visibleRectInWindow: RectRecord(visibleWindowRect),
            cropPixelWidth: cropW,
            cropPixelHeight: cropH,
            totalPixels: totalPixels,
            medianLuminance: (medianLum * 10_000).rounded() / 10_000,
            inkPixels: inkPixels,
            inkRatio: (ratio * 100_000).rounded() / 100_000
        )
    }

    // MARK: - Streaming & mock turn content

    private struct StreamPiece {
        let text: String
        let delayMs: Int
    }

    private struct ToolSpec {
        let kind: ToolCall.Kind
        let title: String
        let detail: String?
        let output: String
    }

    private static let initialCommandTools: [ToolSpec] = [
        ToolSpec(
            kind: .command,
            title: "gh issue list --limit 10 --state open",
            detail: "Inspect open GitHub issues",
            output: """
            #58  质感模式下壁纸设置没有生效  bug,ui  2026-11-19T14:22:10Z
            #57  Sidebar collapsed width jumps when switching threads  2026-11-17T08:11:04Z
            #55  Add keyboard shortcut hint on Worktree review card  enhancement  2026-11-15T19:40:28Z
            #52  Markdown table horizontal scroll indicator contrast in light theme  2026-11-12T10:05:51Z
            """
        ),
        ToolSpec(
            kind: .command,
            title: "gh issue view 58 --json title,body,comments,author",
            detail: "Read issue #58 details",
            output: """
            {
              "author": { "login": "external-reporter" },
              "title": "质感模式下壁纸设置没有生效",
              "body": "升级后在外观里开启质感模式，感觉壁纸换了之后界面上还是看不出变化，附一张当前窗口截图。",
              "comments": [],
              "attachments": ["https://github.com/user-attachments/assets/issue-58-screenshot.png"]
            }
            """
        ),
        ToolSpec(
            kind: .command,
            title: "grep -rn 'wallpaper\\|质感\\|glass' Tivano/App/Views/Settings",
            detail: "Search appearance settings for wallpaper gating",
            output: """
            Tivano/App/Views/Settings/AppearanceSettingsPage.swift:28:    private var allowsCustomWallpaper: Bool {
            Tivano/App/Views/Settings/AppearanceSettingsPage.swift:31:        model.settings.appTheme != .creation
            Tivano/App/Views/Settings/AppearanceSettingsPage.swift:84:    ChromeRow("Wallpaper") {
            Tivano/App/Views/Settings/AppearanceSettingsPage.swift:92:        .disabled(!allowsCustomWallpaper)
            Tivano/App/Views/Settings/AppearanceSettingsPage.swift:114:   Slider(value: $model.settings.glassOpacity, in: 0.15...0.95)
            """
        ),
        ToolSpec(
            kind: .command,
            title: "grep -rn 'ThemeWallpaperPolicy\\|WindowWallpaperView' Tivano",
            detail: "Locate wallpaper policy and window backdrop layer",
            output: """
            Tivano/UI/Theme/ThemeWallpaperPolicy.swift:42:    static func supportsCustomWallpaper(theme: AppTheme, material: SurfaceMaterial) -> Bool {
            Tivano/UI/Theme/ThemeWallpaperPolicy.swift:48:        guard theme != .creation else { return false }
            Tivano/UI/Theme/ThemeWallpaperPolicy.swift:49:        return true
            Tivano/App/Views/Chrome/WindowWallpaperView.swift:64:    if ThemeWallpaperPolicy.supportsCustomWallpaper(theme: theme, material: material) {
            """
        ),
        ToolSpec(
            kind: .command,
            title: "curl -sL -o /tmp/issue-58-screenshot.png https://github.com/user-attachments/assets/issue-58-screenshot.png",
            detail: "Download issue #58 screenshot",
            output: """
            Saved /tmp/issue-58-screenshot.png (184260 bytes, image/png, 1780x680)
            SHA256: 9f41e8c20d7a3b14578196cf0c2d4a5b6e87101f23c8d45a6b9e0123456789ab
            HTTP/2 200 content-type: image/png cache-control: public, max-age=31536000
            """
        ),
    ]

    private static let followUpTools: [ToolSpec] = [
        ToolSpec(
            kind: .read,
            title: "Read",
            detail: "/tmp/issue-58-screenshot.png",
            output: """
            Image loaded: /tmp/issue-58-screenshot.png (1780x680 px, sRGB PNG).
            Observed UI state: glass material enabled, light appearance, top translucent backdrop visible,
            wallpaper picker row active in Appearance settings, glass opacity slider near high opacity end.
            """
        ),
        ToolSpec(
            kind: .read,
            title: "Read",
            detail: "Tivano/App/Views/Settings/AppearanceSettingsPage.swift",
            output: """
            26: struct AppearanceSettingsPage: View {
            28:     private var allowsCustomWallpaper: Bool {
            31:         model.settings.appTheme != .creation
            32:     }
            34:     private var showsWallpaperPicker: Bool {
            35:         allowsCustomWallpaper && model.settings.surfaceMaterial == .glass
            36:     }
            """
        ),
        ToolSpec(
            kind: .command,
            title: "grep -rn 'wallpaperBookmark\\|creation' Tivano/App/Settings Tivano/App/Views/Chrome",
            detail: "Verify bookmark persistence and creation-theme fallback",
            output: """
            Tivano/App/Settings/AppearanceSettingsStore.swift:109:    func resolvedWallpaperURL(for theme: AppTheme) -> URL? {
            Tivano/App/Settings/AppearanceSettingsStore.swift:112:        guard theme != .creation else { return nil }
            Tivano/App/Settings/AppearanceSettingsStore.swift:118:        return try? URL(resolvingBookmarkData: wallpaperBookmark, options: .withSecurityScope)
            Tivano/App/Views/Chrome/WindowWallpaperView.swift:71:        WallpaperLayer(url: url, opacity: 1.0 - glassOpacity)
            """
        ),
    ]

    private static func finalMarkdown(marker: String) -> String {
        """
        结论：**质感模式下可以换壁纸**，只有「创作」主题不行。

        **代码依据**

        - `Tivano/App/Views/Settings/AppearanceSettingsPage.swift:31` 在外观设置页中统一判断当前主题是否允许切换壁纸，仅当主题为「创作」时禁用壁纸选择器，其余质感模式主题入口均保持可用。
        - `Tivano/UI/Theme/ThemeWallpaperPolicy.swift:48` 将质感模式（glass）的自定义壁纸能力显式标记为开启，并允许用户按主题独立指定本地图片路径与模糊强度参数。
        - `Tivano/App/Views/Chrome/WindowWallpaperView.swift:64` 在主窗口背景层按当前质感透明度与材质权重合成自定义壁纸图层，不会因为开启质感外观而强制隐藏用户选择的底图。
        - `Tivano/App/Settings/AppearanceSettingsStore.swift:112` 负责持久化安全范围壁纸书签并在下次启动或切换主题后自动恢复，仅在显式切入「创作」主题时回退到默认纯色画布。

        **用户截图里看起来没生效的常见原因**

        - 顶部质感透明度滑块拉得偏高时，浅色毛玻璃遮罩会把底图压得很淡，在低对比度壁纸下容易被误判为壁纸没有生效。
        - 如果当前选中的是「创作」主题，即便处于质感模式，壁纸入口也会被策略锁定并回退到纯色背景，看起来像是无法换图。
        - 旧版本保存的本地壁纸安全书签在文件移动或改名后失效时，渲染层会静默回退到系统默认渐变，需要重新选取一次图片文件。

        以上结论已经对照外部用户提交的截图与本地渲染条件逐项核对完毕，我会先不直接回复该 issue，等你进一步确认透明度滑块位置与复现路径后再决定最终回复内容。标记：\(marker)
        """
    }

    private static func buildChunks(for text: String) -> [StreamPiece] {
        // 20-40 chars per delta every 16-30 ms (~1.05-1.15 s total for ~770 chars).
        let sizes = [20, 23, 21, 24, 22, 25, 20, 23]
        let delays = [28, 30, 27, 29, 30, 28, 30, 29]
        var pieces: [StreamPiece] = []
        var index = text.startIndex
        var step = 0
        while index < text.endIndex {
            let chunkSize = sizes[step % sizes.count]
            let delayMs = delays[step % delays.count]
            let end = text.index(index, offsetBy: chunkSize, limitedBy: text.endIndex) ?? text.endIndex
            pieces.append(StreamPiece(text: String(text[index..<end]), delayMs: delayMs))
            index = end
            step += 1
        }
        return pieces
    }

    private static func streamFixed(
        _ runtime: ThreadRuntime,
        id: String,
        text: String,
        chunkSize: Int,
        delayMs: Int,
        alive: () -> Bool
    ) async {
        var index = text.startIndex
        while index < text.endIndex {
            guard alive() else { return }
            let end = text.index(index, offsetBy: chunkSize, limitedBy: text.endIndex) ?? text.endIndex
            runtime.rehearse(.messageDelta(id: id, text: String(text[index..<end])))
            index = end
            try? await Task.sleep(for: .milliseconds(delayMs))
        }
    }

    // MARK: - CLI arguments, report & stdout

    private static func parseArguments() -> (scenarios: [Scenario]?, count: Int?, injectZero: Bool, noHeal: Bool, error: String?) {
        let args = CommandLine.arguments
        var scenarios: [Scenario] = Scenario.allCases
        var count = 10
        let injectZero = args.contains("--fold-repro-inject-zero")
        let noHeal = args.contains("--fold-repro-no-heal")

        if let scenarioIndex = args.firstIndex(of: "--fold-repro-scenario") {
            guard args.indices.contains(scenarioIndex + 1) else {
                return (nil, nil, injectZero, noHeal, "missing value after --fold-repro-scenario")
            }
            let raw = args[scenarioIndex + 1]
            if raw == "all" {
                scenarios = Scenario.allCases
            } else if let one = Scenario(rawValue: raw) {
                scenarios = [one]
            } else {
                let valid = (["all"] + Scenario.allCases.map(\.rawValue)).joined(separator: ", ")
                return (nil, nil, injectZero, noHeal, "unknown --fold-repro-scenario '\(raw)'; expected one of: \(valid)")
            }
        }

        if let holdIndex = args.firstIndex(of: "--fold-repro-hold") {
            guard args.indices.contains(holdIndex + 1), let hold = Double(args[holdIndex + 1]), hold >= 0 else {
                return (nil, nil, injectZero, noHeal, "invalid number of seconds after --fold-repro-hold")
            }
            holdSeconds = hold
        }

        if let countIndex = args.firstIndex(of: "--fold-repro-count") {
            guard args.indices.contains(countIndex + 1),
                  let parsedCount = Int(args[countIndex + 1]),
                  parsedCount > 0 else {
                return (nil, nil, injectZero, noHeal, "invalid positive integer after --fold-repro-count")
            }
            count = parsedCount
        }

        return (scenarios, count, injectZero, noHeal, nil)
    }

    private static func saveReport(to output: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(reportState.snapshot()) else { return }
        try? data.write(to: output.appendingPathComponent("fold-repro.json"), options: .atomic)
    }

    private static func emitLine(_ line: String) {
        print(line)
        fflush(stdout)
    }
}
#endif
