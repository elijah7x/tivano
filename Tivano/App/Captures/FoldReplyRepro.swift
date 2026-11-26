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
///         [--fold-repro-scenario all|front|covered|miniaturized|inactive|otherThread|scrolledUp|settings|hydraLead|hydraLeadReal] \
///         [--fold-repro-provider claude|acp] \
///         [--fold-repro-stream-chunks N] [--fold-repro-chunk-gap SECONDS] \
///         [--fold-repro-tail-delay SECONDS] [--fold-repro-reasoning-seconds SECONDS] \
///         [--fold-repro-fresh-thread] \
///         [--fold-repro-count N] [--fold-repro-hold SECONDS] \
///         [--fold-repro-inject-zero] [--fold-repro-no-heal]
///
/// Examples:
///     # Preset matching H8S real timing (stream-chunks 8, chunk-gap 0.4, tail-delay 10, reasoning-seconds 8, fresh-thread):
///     open -n -W "Tivano.app" --args --website-captures /tmp/fold-hydra-real --fold-repro \
///         --fold-repro-scenario hydraLeadReal --fold-repro-count 3
///
///     # Custom composable Hydra lead run (e.g. 30 s reasoning, 8 chunks, 10 s tail delay):
///     open -n -W "Tivano.app" --args --website-captures /tmp/fold-hydra-custom --fold-repro \
///         --fold-repro-scenario hydraLead --fold-repro-stream-chunks 8 --fold-repro-chunk-gap 0.4 \
///         --fold-repro-tail-delay 10 --fold-repro-reasoning-seconds 30 --fold-repro-fresh-thread --fold-repro-count 3
///
///     # Control run of `hydraLeadReal` with Claude-style `.messageCompleted`:
///     open -n -W "Tivano.app" --args --website-captures /tmp/fold-hydra-claude --fold-repro \
///         --fold-repro-scenario hydraLeadReal --fold-repro-provider claude --fold-repro-count 3
///
/// Uses the isolated capture library and rehearsed turns so no provider session or network starts.
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
        /// Hydra lead turn matching the Release 3.0.15 Antigravity ACP bug: long reasoning,
        /// burst ~90-char paragraph + 2-head delegation block, 0 ms `.turnCompleted` (no
        /// `.messageCompleted` under `acp`), real `spawnDelegatedHeads` / `holdSentDelegationBlock`
        /// / sub-agent panel open without launching any provider process.
        case hydraLead
        /// Preset equivalent to `hydraLead` with `--fold-repro-stream-chunks 8`,
        /// `--fold-repro-chunk-gap 0.4`, `--fold-repro-tail-delay 10`,
        /// `--fold-repro-reasoning-seconds 8`, and `--fold-repro-fresh-thread`.
        case hydraLeadReal

        var isHydraLead: Bool {
            self == .hydraLead || self == .hydraLeadReal
        }
    }

    enum ReproProvider: String, CaseIterable, Sendable {
        case claude
        case acp
    }

    private struct HydraLeadConfig: Encodable, Sendable {
        let streamChunks: Int
        let chunkGapSeconds: Double
        let tailDelaySeconds: Double
        let reasoningSeconds: Double
        let freshThread: Bool
    }

    /// Sized dynamically to the requested workload in `run` (reasoning + streaming + tail delay + 10 s sampling + headroom).
    private static var budgetSeconds: TimeInterval = 600
    /// How long a hidden/covered/other-thread scenario stays away after the fold (`--fold-repro-hold`).
    private static var holdSeconds: Double = 3
    private static var injectZero = false
    private static var healDisabled = false
    /// Optional `--fold-repro-provider` override; nil keeps legacy scenarios on `.claude` and Hydra lead scenarios on `.acp`.
    private static var providerOverride: ReproProvider?
    /// Composable Hydra lead CLI overrides (`nil` uses the scenario default: `hydraLead` vs `hydraLeadReal`).
    private static var streamChunksOverride: Int?
    private static var chunkGapOverride: Double?
    private static var tailDelayOverride: Double?
    private static var reasoningSecondsOverride: Double?
    private static var freshThreadFlag = false
    private static let defaultHydraStreamChunks = 1
    private static let defaultHydraChunkGapSeconds = 0.15
    private static let defaultHydraTailDelaySeconds = 0.0
    private static let defaultHydraReasoningSeconds = 2.5
    private static let windowSize = NSSize(width: 890, height: 340)
    /// Wide enough for `SubagentPanelLayout.sitsBesideComposer` (triggers real `ReserveSlide` column narrowing)
    /// and tall enough that the folded header, ~90-char paragraph, and `hydra-sent` card all stay in view.
    private static let hydraWindowSize = NSSize(width: 1040, height: 640)
    /// Sampling instants (seconds after fold, or after restore for hidden/away scenarios),
    /// covering immediate post-fold, `hydra-sent` hold (3.2 s), `hydra-leaving` fade (3.65 s),
    /// and settled persistence out to 10 s.
    private static let sampleOffsetsSeconds: [Double] = [0.3, 1.0, 2.5, 4.0, 6.0, 10.0]
    /// Luminance delta from the crop's median background luminance required to count a pixel as text ink.
    /// Primary text vs. background delta is ~0.60–0.85 in both light and dark themes; 0.25 rejects
    /// wallpaper/glass shading gradients while keeping crisp and anti-aliased glyph strokes.
    private static let inkLuminanceDeltaThreshold: Double = 0.25
    /// Minimum ink pixel ratio for a non-blank paragraph.
    /// A rendered ~90-char CJK or mixed markdown paragraph at 13 pt typically measures ~5%–14% ink pixels
    /// (even a sparse trailing line exceeds ~2%), whereas an unpainted/blank view over a solid or glass
    /// surface measures <0.05%. 0.5% (0.005) sits at ~1/10–1/20 of a normal paragraph's ink ratio,
    /// leaving a wide margin against false positives while cleanly separating blank replies.
    private static let blankInkRatioThreshold: Double = 0.005
    /// Non-executable path set in the isolated capture defaults as defense-in-depth so no provider CLI can launch.
    private static let disabledProviderBinaryPath = "/nonexistent/fold-repro-no-provider"
    private static let interimMessage = "Issue #58 是外部用户反馈，只有一张截图。我在看截图和渲染条件确认原因。"
    private static let interimPrefix = "Issue #58 是外部用户反馈"
    private static let userPrompt = "看下GitHub上的新issue。我有点忘了，在质感模式下是不是不能让用户自己换壁纸的，还是可以。"
    private static let hydraLeadUserPrompt = "这已经是第五次遇到折叠后回复空白的问题了，先派两位子代理并行排查历史修复链路和子代理面板合成层机制，查完汇总给我。"

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

    private struct AbnormalAncestorRecord: Encodable, Sendable {
        let depth: Int
        let className: String
        let isHidden: Bool
        let alphaValue: Double
        let layerIsHidden: Bool?
        let layerOpacity: Double?
        let hasLayerMask: Bool
    }

    private struct SampleRecord: Encodable, Sendable {
        let targetOffsetSeconds: Double
        let actualOffsetSeconds: Double
        let elapsedSinceFoldSeconds: Double
        let markerFound: Bool
        let linkTextViewID: Int?
        let textStorageLength: Int
        let tempForegroundColorPresent: Bool?
        let tempForegroundColorCharCount: Int?
        let tempForegroundColorMinAlpha: Double?
        let storageForegroundColorMinAlpha: Double?
        let bounds: RectRecord?
        let visibleRect: RectRecord?
        let visibleRectInWindow: RectRecord?
        let textContainerWidth: Double?
        let windowOcclusionStateRaw: UInt
        let windowOcclusionVisible: Bool
        let isHiddenOrHasHiddenAncestor: Bool?
        let abnormalAncestors: [AbnormalAncestorRecord]
        let ancestorsAbnormalSummary: String
        let hasLayer: Bool?
        let layerClassName: String?
        let layerContentsIsNil: Bool?
        let layerBounds: RectRecord?
        let layerContentsRedrawPolicyRaw: Int?
        let measuredHeight: Double?
        let stillCaptured: Bool
        let stillFile: String?
        let inkAnalysis: InkAnalysis?
        let offscreenInkRatio: Double?
        let screenInkRatioAfterOffscreen: Double?
        let isBlank: Bool
        let delegationCardState: String?
        let hydraPanelOpen: Bool?
    }

    private struct BlankTimelineSummary: Encodable, Sendable {
        let sampleOffsetsSeconds: [Double]
        let blankSampleCount: Int
        let blankDetected: Bool
        let firstBlankAtSeconds: Double?
        let lastBlankAtSeconds: Double?
        let selfRecovered: Bool?
        let recoveredAtSeconds: Double?
    }

    private struct RepetitionRecord: Encodable, Sendable {
        let scenario: String
        let repetition: Int
        let threadID: String
        let marker: String
        let provider: String
        let sentMessageCompleted: Bool
        let turnDurationSeconds: Double
        let passed: Bool
        let failureReasons: [String]
        let preFoldOcclusionVisible: Bool?
        let scrolledUpDelta: Double?
        let hydraConfig: HydraLeadConfig?
        let titleRewritesCount: Int?
        let hydraSpawnedHeadCount: Int?
        let hydraPanelOpenAfterFold: Bool?
        let delegationMarkedSent: Bool?
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
        let samples: [SampleRecord]
        let blankSummary: BlankTimelineSummary
    }

    private struct ScenarioSummary: Encodable, Sendable {
        let scenario: String
        let total: Int
        let passed: Int
        let failed: Int
        let blankRepetitions: Int
        let totalBlankSamples: Int
        let earliestBlankAtSeconds: Double?
        let selfRecoveredRepetitions: Int
        let unrecoveredBlankRepetitions: Int
    }

    private struct FoldReproReport: Encodable, Sendable {
        let startedAt: String
        let windowSize: SizeRecord
        let hydraWindowSize: SizeRecord
        let scenariosRequested: [String]
        let providerOption: String
        let hydraStreamChunksOption: Int?
        let hydraChunkGapOption: Double?
        let hydraTailDelayOption: Double?
        let hydraReasoningSecondsOption: Double?
        let freshThreadFlag: Bool
        let repetitionsPerScenario: Int
        let budgetSeconds: Int
        let injectZero: Bool
        let healDisabled: Bool
        let sampleOffsetsSeconds: [Double]
        let inkLuminanceDeltaThreshold: Double
        let blankInkRatioThreshold: Double
        let status: String
        let blockedReason: String?
        let totalBlankRepetitions: Int
        let totalBlankSamples: Int
        let earliestBlankAtSeconds: Double?
        let selfRecoveredRepetitions: Int
        let unrecoveredBlankRepetitions: Int
        let scenarioFailCounts: [String: Int]
        let scenarios: [ScenarioSummary]
        let repetitions: [RepetitionRecord]
    }

    @MainActor
    private final class ReportBuilder {
        var startedAt = ISO8601DateFormatter().string(from: .now)
        var scenariosRequested: [String] = []
        var providerOption = "default"
        var repetitionsPerScenario = 10
        var injectZero = false
        var healDisabled = false
        var status = "running"
        var blockedReason: String?
        var scenarioFailCounts: [String: Int] = [:]
        var scenarios: [ScenarioSummary] = []
        var repetitions: [RepetitionRecord] = []

        func reset(
            scenarios: [Scenario],
            count: Int,
            providerOption: String = "default",
            injectZero: Bool = false,
            healDisabled: Bool = false
        ) {
            startedAt = ISO8601DateFormatter().string(from: .now)
            scenariosRequested = scenarios.map(\.rawValue)
            self.providerOption = providerOption
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
            let blankReps = repetitions.filter { $0.blankSummary.blankDetected }
            let totalBlankSamples = repetitions.reduce(0) { $0 + $1.blankSummary.blankSampleCount }
            let earliestBlank = blankReps.compactMap { $0.blankSummary.firstBlankAtSeconds }.min()
            let selfRecovered = blankReps.filter { $0.blankSummary.selfRecovered == true }.count
            let unrecovered = blankReps.filter { $0.blankSummary.selfRecovered == false }.count
            return FoldReproReport(
                startedAt: startedAt,
                windowSize: SizeRecord(width: Double(windowSize.width), height: Double(windowSize.height)),
                hydraWindowSize: SizeRecord(width: Double(hydraWindowSize.width), height: Double(hydraWindowSize.height)),
                scenariosRequested: scenariosRequested,
                providerOption: providerOption,
                hydraStreamChunksOption: streamChunksOverride,
                hydraChunkGapOption: chunkGapOverride,
                hydraTailDelayOption: tailDelayOverride,
                hydraReasoningSecondsOption: reasoningSecondsOverride,
                freshThreadFlag: freshThreadFlag,
                repetitionsPerScenario: repetitionsPerScenario,
                budgetSeconds: Int(budgetSeconds),
                injectZero: injectZero,
                healDisabled: healDisabled,
                sampleOffsetsSeconds: sampleOffsetsSeconds,
                inkLuminanceDeltaThreshold: inkLuminanceDeltaThreshold,
                blankInkRatioThreshold: blankInkRatioThreshold,
                status: status,
                blockedReason: blockedReason,
                totalBlankRepetitions: blankReps.count,
                totalBlankSamples: totalBlankSamples,
                earliestBlankAtSeconds: earliestBlank,
                selfRecoveredRepetitions: selfRecovered,
                unrecoveredBlankRepetitions: unrecovered,
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
        let providerOption = parsed.provider?.rawValue ?? "default"
        streamChunksOverride = parsed.streamChunks
        chunkGapOverride = parsed.chunkGapSeconds
        tailDelayOverride = parsed.tailDelaySeconds
        reasoningSecondsOverride = parsed.reasoningSeconds
        freshThreadFlag = parsed.freshThread

        guard let scenarios = parsed.scenarios, let count = parsed.count else {
            let reason = parsed.error ?? "invalid --fold-repro arguments"
            WebsiteCaptures.log("fold-repro blocked: \(reason)")
            reportState.reset(
                scenarios: [],
                count: 0,
                providerOption: providerOption,
                injectZero: parsed.injectZero,
                healDisabled: parsed.noHeal
            )
            reportState.status = "blocked"
            reportState.blockedReason = reason
            saveReport(to: output)
            emitLine("fold-repro blocked: \(reason)")
            exit(2)
        }

        injectZero = parsed.injectZero
        healDisabled = parsed.noHeal
        providerOverride = parsed.provider
        if healDisabled {
            LinkTextView.debugHeightHealDisabled = true
        }

        let estimatedWorkload = scenarios.reduce(0.0) { total, scenario in
            total + estimatedSecondsPerRepetition(for: scenario) * Double(count)
        }
        budgetSeconds = max(600, estimatedWorkload + 120)
        reportState.reset(
            scenarios: scenarios,
            count: count,
            providerOption: providerOption,
            injectZero: injectZero,
            healDisabled: healDisabled
        )
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
        model.settings.hydraAutoOpensPanels = true
        model.settings.hydraAutoPopsHeads = false
        model.settings.hydraIsolateHeads = false
        model.settings.hydraAutoMerge = false
        // Defense-in-depth in the isolated capture defaults: ensure neither CLI provider can spawn a real process.
        model.settings.setBinaryPath(disabledProviderBinaryPath, for: .antigravity)
        model.settings.setBinaryPath(disabledProviderBinaryPath, for: .claude)

        let scenarioNames = scenarios.map(\.rawValue).joined(separator: ",")
        WebsiteCaptures.log(
            "fold-repro start \(output.path) scenarios=\(scenarioNames) provider=\(providerOption) count=\(count) streamChunks=\(streamChunksOverride.map(String.init) ?? "default") chunkGap=\(chunkGapOverride.map { String(format: "%.2f", $0) } ?? "default") tailDelay=\(tailDelayOverride.map { String(format: "%.2f", $0) } ?? "default") reasoning=\(reasoningSecondsOverride.map { String(format: "%.2f", $0) } ?? "default") freshThread=\(freshThreadFlag) injectZero=\(injectZero) healDisabled=\(healDisabled)"
        )

        let initialWindowSize = scenarios.first?.isHydraLead == true ? hydraWindowSize : windowSize
        let stage = Stage(model: model)
        stage.show(size: initialWindowSize)
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
            var scenarioRecords: [RepetitionRecord] = []
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
                scenarioRecords.append(record)
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

            let blankReps = scenarioRecords.filter { $0.blankSummary.blankDetected }
            let blankSampleCount = scenarioRecords.reduce(0) { $0 + $1.blankSummary.blankSampleCount }
            let earliestBlank = blankReps.compactMap { $0.blankSummary.firstBlankAtSeconds }.min()
            let recoveredReps = blankReps.filter { $0.blankSummary.selfRecovered == true }.count
            let unrecoveredReps = blankReps.filter { $0.blankSummary.selfRecovered == false }.count

            let summary = ScenarioSummary(
                scenario: scenario.rawValue,
                total: count,
                passed: scenarioPassed,
                failed: scenarioFailed,
                blankRepetitions: blankReps.count,
                totalBlankSamples: blankSampleCount,
                earliestBlankAtSeconds: earliestBlank,
                selfRecoveredRepetitions: recoveredReps,
                unrecoveredBlankRepetitions: unrecoveredReps
            )
            reportState.scenarios.append(summary)
            saveReport(to: output)

            let earliestText = earliestBlank.map { "\(formatOffset($0))s" } ?? "none"
            let line = "fold-repro scenario=\(scenario.rawValue) total=\(count) passed=\(scenarioPassed) failed=\(scenarioFailed) blankReps=\(blankReps.count) blankSamples=\(blankSampleCount) earliestBlank=\(earliestText) selfRecovered=\(recoveredReps) unrecovered=\(unrecoveredReps)"
            WebsiteCaptures.log(line)
            emitLine(line)
        }

        reportState.status = totalFailures == 0 ? "passed" : "failed"
        let finalSnapshot = reportState.snapshot()
        saveReport(to: output)
        let overallEarliest = finalSnapshot.earliestBlankAtSeconds.map { "\(formatOffset($0))s" } ?? "none"
        let overallLine = "fold-repro summary status=\(finalSnapshot.status) totalReps=\(finalSnapshot.repetitions.count) failedReps=\(totalFailures) blankReps=\(finalSnapshot.totalBlankRepetitions) blankSamples=\(finalSnapshot.totalBlankSamples) earliestBlank=\(overallEarliest) selfRecovered=\(finalSnapshot.selfRecoveredRepetitions) unrecovered=\(finalSnapshot.unrecoveredBlankRepetitions)"
        WebsiteCaptures.log(overallLine)
        emitLine(overallLine)
        WebsiteCaptures.log("fold-repro done totalFailures=\(totalFailures)")
        exit(totalFailures == 0 ? 0 : 1)
    }

    // MARK: - Single repetition

    private static func effectiveProvider(for scenario: Scenario) -> ReproProvider {
        providerOverride ?? (scenario.isHydraLead ? .acp : .claude)
    }

    private static func effectiveHydraConfig(for scenario: Scenario) -> HydraLeadConfig {
        switch scenario {
        case .hydraLeadReal:
            HydraLeadConfig(
                streamChunks: streamChunksOverride ?? 8,
                chunkGapSeconds: chunkGapOverride ?? 0.4,
                tailDelaySeconds: tailDelayOverride ?? 10.0,
                reasoningSeconds: reasoningSecondsOverride ?? 8.0,
                freshThread: true
            )
        default:
            HydraLeadConfig(
                streamChunks: streamChunksOverride ?? defaultHydraStreamChunks,
                chunkGapSeconds: chunkGapOverride ?? defaultHydraChunkGapSeconds,
                tailDelaySeconds: tailDelayOverride ?? defaultHydraTailDelaySeconds,
                reasoningSeconds: reasoningSecondsOverride ?? defaultHydraReasoningSeconds,
                freshThread: freshThreadFlag
            )
        }
    }

    private static func estimatedSecondsPerRepetition(for scenario: Scenario) -> Double {
        if scenario.isHydraLead {
            let config = effectiveHydraConfig(for: scenario)
            let streamDuration = config.streamChunks > 1
                ? Double(config.streamChunks - 1) * config.chunkGapSeconds
                : 0.3
            return config.reasoningSeconds + streamDuration + config.tailDelaySeconds + 18.0
        }
        return 35.0 + holdSeconds
    }

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
        let isHydra = scenario.isHydraLead
        let hydraConfig = isHydra ? effectiveHydraConfig(for: scenario) : nil
        let targetSize = isHydra ? hydraWindowSize : windowSize
        if abs(window.frame.size.width - targetSize.width) > 1 || abs(window.frame.size.height - targetSize.height) > 1 {
            stage.resize(to: targetSize)
            try? await Task.sleep(for: .milliseconds(150))
        }
        await ensureWindowReady(window: window, stage: stage)

        let reproProvider = effectiveProvider(for: scenario)
        let sendsMessageCompleted = reproProvider == .claude
        let threadProvider: ProviderKind = reproProvider == .acp ? .antigravity : .claude
        let threadModel = reproProvider == .acp ? "gemini-3.8-flash" : "opus"

        model.settings.hydraEnabled = isHydra
        model.settings.hydraAutoOpensPanels = true
        model.settings.hydraAutoPopsHeads = false
        model.settings.hydraIsolateHeads = false
        model.settings.hydraAutoMerge = false

        var thread = ChatThread(
            projectID: project.id,
            provider: threadProvider,
            model: threadModel,
            effort: "high",
            runtimeMode: .supervised
        )
        let usesFreshThread = hydraConfig?.freshThread == true
        if usesFreshThread {
            // Brand-new turn-0 thread: starts untitled with auto-title enabled (`hasCustomTitle = false`).
            thread.title = ChatThread.untitled
            thread.hasCustomTitle = false
            thread.titleRefreshTurn = nil
        } else {
            thread.title = "Fold repro \(scenario.rawValue) #\(repetition)"
            thread.hasCustomTitle = true
        }
        thread.branch = "main"
        if isHydra {
            thread.hydraEnabled = true
            thread.chimeraEnabled = false
        }
        model.insertThread(thread)

        // Open a real v2 Hydra job BEFORE creating `ThreadRuntime` so `ThreadRuntime.init`
        // adopts `hydraJobID` and `hydraJobPacketRequest` through the production path.
        var openJobID: UUID?
        if isHydra {
            openJobID = await model.beginHydraJob(for: thread.id, turnID: UUID(), request: hydraLeadUserPrompt)
        }

        model.selectedThreadID = thread.id
        let runtime = model.runtime(for: thread.id)
        await runtime.ensureLoaded()
        try? await Task.sleep(for: .milliseconds(250))

        let marker = String(format: "FOLDMARK%03d", globalIndex)
        let prefix = "fold-\(scenario.rawValue)-\(repetition)"
        let turnStart = Date.now

        if let hydraConfig {
            WebsiteCaptures.log(
                "fold-repro \(scenario.rawValue) rep=\(repetition) start thread=\(thread.id.uuidString) provider=\(reproProvider.rawValue) sentMsgCompleted=\(sendsMessageCompleted) chunks=\(hydraConfig.streamChunks) chunkGap=\(String(format: "%.2f", hydraConfig.chunkGapSeconds))s tailDelay=\(String(format: "%.2f", hydraConfig.tailDelaySeconds))s reasoning=\(String(format: "%.2f", hydraConfig.reasoningSeconds))s freshThread=\(hydraConfig.freshThread) marker=\(marker)"
            )
        } else {
            WebsiteCaptures.log("fold-repro \(scenario.rawValue) rep=\(repetition) start thread=\(thread.id.uuidString) provider=\(reproProvider.rawValue) sentMsgCompleted=\(sendsMessageCompleted) marker=\(marker)")
        }

        var coverWindow: NSWindow?
        var preFoldOcclusionVisible: Bool?
        var scrolledUpDelta: Double?
        var titleRewritesCount: Int? = usesFreshThread ? 0 : nil

        if isHydra, let hydraConfig {
            runtime.rehearseTurn(hydraLeadUserPrompt)
            if usesFreshThread {
                // Mirror `ThreadRuntime.generateTitle`: initial prompt-based title and `titleRefreshTurn = 1` on turn 0.
                model.updateThread(thread.id) {
                    if !$0.hasCustomTitle {
                        $0.title = TextCleanup.singleLine(hydraLeadUserPrompt, limit: 48)
                        $0.titleRefreshTurn = 1
                    }
                }
            } else {
                runtime.rehearseTitle(hydraLeadUserPrompt)
            }
            let turn = runtime.rehearsalTurnID
            let live = { runtime.isRunning && runtime.rehearsalTurnID == turn }
            try? await Task.sleep(for: .milliseconds(120))

            // Phase 1: configurable long reasoning (`thought-1`). ACP never sends `.reasoningCompleted`.
            let thoughtID = "\(prefix)-thought-1"
            if live() {
                await streamReasoning(
                    runtime,
                    id: thoughtID,
                    text: hydraLeadReasoningText,
                    durationSeconds: hydraConfig.reasoningSeconds,
                    alive: live
                )
                if live(), sendsMessageCompleted {
                    runtime.rehearse(.reasoningCompleted(id: thoughtID, text: ""))
                }
            }

            // Phase 2: ~90-char Chinese paragraph + valid 2-head Hydra block, streamed either as
            // the original burst (`streamChunks == 1`) or as N spaced chunks (`streamChunks > 1`)
            // so `StreamVeil` / `LinkTextVeil` runs live with the delegation opener in the last 1-2 chunks.
            let paragraph = hydraLeadParagraph(marker: marker)
            let delegationBlock = hydraLeadDelegationBlock
            let finalText = paragraph + "\n\n" + delegationBlock
            let finalID = "\(prefix)-message-2"
            let chunks = buildHydraLeadChunks(
                paragraph: paragraph,
                delegationBlock: delegationBlock,
                count: hydraConfig.streamChunks,
                gapSeconds: hydraConfig.chunkGapSeconds
            )
            for (chunkIndex, piece) in chunks.enumerated() {
                guard live() else { break }
                runtime.rehearse(.messageDelta(id: finalID, text: piece.text))
                let isLastChunk = chunkIndex == chunks.count - 1
                if !isLastChunk {
                    if piece.delayMs > 0 {
                        try? await Task.sleep(for: .milliseconds(piece.delayMs))
                    }
                } else if sendsMessageCompleted && hydraConfig.tailDelaySeconds <= 0 && piece.delayMs > 0 {
                    try? await Task.sleep(for: .milliseconds(piece.delayMs))
                }
            }

            // Optional tail delay between final text arrival and `.turnCompleted` (plus pre-fold auto-title rewrite).
            if live() {
                if hydraConfig.tailDelaySeconds > 0 {
                    if usesFreshThread, hydraConfig.tailDelaySeconds > 0.2 {
                        let firstHalf = hydraConfig.tailDelaySeconds / 2.0
                        try? await Task.sleep(for: .seconds(firstHalf))
                        if live() {
                            model.updateThread(thread.id) {
                                if !$0.hasCustomTitle {
                                    $0.title = "排查折叠空白与子代理合成层 #\(repetition)"
                                    $0.titleRefreshTurn = 1
                                }
                            }
                            titleRewritesCount = (titleRewritesCount ?? 0) + 1
                        }
                        try? await Task.sleep(for: .seconds(hydraConfig.tailDelaySeconds - firstHalf))
                    } else {
                        try? await Task.sleep(for: .seconds(hydraConfig.tailDelaySeconds))
                        if live(), usesFreshThread {
                            model.updateThread(thread.id) {
                                if !$0.hasCustomTitle {
                                    $0.title = "排查折叠空白与子代理合成层 #\(repetition)"
                                    $0.titleRefreshTurn = 1
                                }
                            }
                            titleRewritesCount = (titleRewritesCount ?? 0) + 1
                        }
                    }
                } else if usesFreshThread {
                    model.updateThread(thread.id) {
                        if !$0.hasCustomTitle {
                            $0.title = "排查折叠空白与子代理合成层 #\(repetition)"
                            $0.titleRefreshTurn = 1
                        }
                    }
                    titleRewritesCount = (titleRewritesCount ?? 0) + 1
                }
            }

            if live() {
                if sendsMessageCompleted {
                    runtime.rehearse(.messageCompleted(id: finalID, text: finalText))
                }
                if injectZero {
                    ProseRunRepresentable.debugZeroHeightMarker = marker
                    ProseRunRepresentable.debugZeroHeightUntil = Date.now.addingTimeInterval(0.6)
                }
                runtime.rehearse(.turnCompleted(status: .completed, error: nil))
            }
        } else {
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
                if live(), sendsMessageCompleted {
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
            let postChunkTailMs = sendsMessageCompleted ? 100 : 0
            var remainingMs = chunks.reduce(postChunkTailMs) { $0 + $1.delayMs }

            var preFoldTriggered = false
            var scrolledUpTriggered = false

            for (chunkIndex, piece) in chunks.enumerated() {
                guard live() else { break }

                // Fire the 1 s pre-turnCompleted trigger for non-front / non-scrolledUp scenarios.
                if !preFoldTriggered, remainingMs <= 1_000 {
                    switch scenario {
                    case .front, .scrolledUp, .hydraLead, .hydraLeadReal:
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

                let isLastChunk = chunkIndex == chunks.count - 1
                if !isLastChunk || sendsMessageCompleted {
                    try? await Task.sleep(for: .milliseconds(piece.delayMs))
                }
                remainingMs -= piece.delayMs
            }

            // Safety fallback if the final message was shorter than 1 s.
            if !preFoldTriggered {
                switch scenario {
                case .front, .scrolledUp, .hydraLead, .hydraLeadReal:
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

            if live(), postChunkTailMs > 0 {
                try? await Task.sleep(for: .milliseconds(postChunkTailMs))
            }

            if scenario == .covered || scenario == .miniaturized || scenario == .inactive {
                preFoldOcclusionVisible = window.occlusionState.contains(.visible)
            }

            if live() {
                if sendsMessageCompleted {
                    runtime.rehearse(.messageCompleted(id: finalID, text: finalText))
                }
                if injectZero {
                    ProseRunRepresentable.debugZeroHeightMarker = marker
                    ProseRunRepresentable.debugZeroHeightUntil = Date.now.addingTimeInterval(0.6)
                }
                runtime.rehearse(.turnCompleted(status: .completed, error: nil))
            }
        }

        // Yield tightly on MainActor so we catch the immediate turn right after `finalizeTurn`
        // finishes synchronously (before `startTivanoHead`'s async git reads can reach `sendHydraBrief`).
        let finishWait = Date.now.addingTimeInterval(5)
        while runtime.isRunning, Date.now < finishWait {
            await Task.yield()
        }
        let foldCompletedAt = Date.now
        let turnDuration = foldCompletedAt.timeIntervalSince(turnStart)

        var spawnedHeads: [ChatThread] = []
        var hydraSpawnedHeadCount: Int?
        var hydraPanelOpenAfterFold: Bool?
        var delegationMarkedSent: Bool?

        if isHydra {
            spawnedHeads = model.hydraTeam(of: thread.id)
            // Keep spawned heads in a rehearsed running state so `startTivanoHead`'s eventual
            // `sendHydraBrief` exits on `phase != .idle` without launching any provider CLI or network.
            for head in spawnedHeads {
                let headRuntime = model.runtime(for: head.id)
                headRuntime.hydraStartupPending = false
                if !headRuntime.isRunning {
                    headRuntime.rehearseTurn(nil)
                }
                model.updateHydraHead(head.id) {
                    if $0.activity == nil {
                        $0.activity = head.hydra?.task ?? "Investigating"
                    }
                }
            }
            if usesFreshThread {
                // Post-`.turnCompleted` auto-title rewrite on the fresh turn-0 thread.
                model.updateThread(thread.id) {
                    if !$0.hasCustomTitle {
                        $0.title = "Hydra 折叠空白复现与合成排查 #\(repetition)"
                        $0.titleRefreshTurn = 1
                    }
                }
                titleRewritesCount = (titleRewritesCount ?? 0) + 1
            }
            hydraSpawnedHeadCount = spawnedHeads.count
            hydraPanelOpenAfterFold = !runtime.isHydraPanelHidden && spawnedHeads.contains(where: \.isInPanel)
            let cardState = delegationCardState(in: runtime, marker: marker)
            delegationMarkedSent = (cardState == "sent" || cardState == "leaving")
            WebsiteCaptures.log(
                "fold-repro \(scenario.rawValue) rep=\(repetition) post-fold heads=\(spawnedHeads.count) panelOpen=\(hydraPanelOpenAfterFold ?? false) card=\(cardState ?? "nil") titleRewrites=\(titleRewritesCount ?? 0)"
            )
        }

        // Hold & restore per scenario.
        switch scenario {
        case .front, .hydraLead, .hydraLeadReal:
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

        // Sample composited pixels at t = 0.3, 1, 2.5, 4, 6, 10 s relative to fold completion
        // (`turnCompleted` handled) for visible scenarios (or post-restore for away scenarios),
        // without forcing any redraw/scroll.
        let sampleOrigin = (scenario == .front || isHydra || scenario == .scrolledUp) ? foldCompletedAt : Date.now
        var samples: [SampleRecord] = []
        var latestCaptured: (image: CGImage, rect: NSRect)?
        var savedBlankStill = false

        for (sampleIndex, offset) in sampleOffsetsSeconds.enumerated() {
            let isLastSample = sampleIndex == sampleOffsetsSeconds.count - 1
            let targetDate = sampleOrigin.addingTimeInterval(offset)
            let wait = targetDate.timeIntervalSinceNow
            if wait > 0 {
                try? await Task.sleep(for: .seconds(wait))
            }

            let actualOffset = Date.now.timeIntervalSince(sampleOrigin)
            let elapsedSinceFold = Date.now.timeIntervalSince(foldCompletedAt)
            let captured = await captureStillImage(rect: stage.captureRect)
            if let captured { latestCaptured = captured }

            let found = findMarkerViews(marker: marker, in: window)
            let markerView = found.primary
            let primaryScroll = markerView?.enclosingScrollView ?? timelineScroll(in: window)

            let linkTextViewID = markerView.map { ObjectIdentifier($0).hashValue }
            let textStorageLength = markerView?.textStorage?.length ?? 0
            let tempForeground = markerView.map(inspectTemporaryForegroundColor)
            let storageForegroundMinAlpha = markerView.flatMap(inspectStorageForegroundMinAlpha)
            let boundsRect = markerView?.bounds
            let visibleRect = markerView?.visibleRect
            let visibleRectInWindow = markerView.map { $0.convert($0.visibleRect, to: nil) }
            let textContainerWidth = markerView?.textContainer.map { Double($0.containerSize.width) }
            let occlusionState = window.occlusionState
            let occlusionVisible = occlusionState.contains(.visible)
            let isHiddenOrAncestor = markerView?.isHiddenOrHasHiddenAncestor
            let abnormalAncestors = markerView.map { inspectAbnormalAncestors(of: $0, upTo: window.contentView) } ?? []
            let ancestorsAbnormalSummary: String = if markerView == nil {
                "missing"
            } else if abnormalAncestors.isEmpty {
                "none"
            } else {
                abnormalAncestors.map { record in
                    let layerAlpha = record.layerOpacity.map { String(format: "%.2f", $0) } ?? "nil"
                    let layerHidden = record.layerIsHidden.map { $0 ? "1" : "0" } ?? "nil"
                    return "d\(record.depth):\(record.className)(h=\(record.isHidden ? 1 : 0),a=\(String(format: "%.2f", record.alphaValue)),lh=\(layerHidden),lo=\(layerAlpha),m=\(record.hasLayerMask ? 1 : 0))"
                }.joined(separator: ";")
            }
            let hasLayer = markerView.map { $0.layer != nil }
            let layerClassName = markerView?.layer.map { String(describing: type(of: $0)) }
            let layerContentsIsNil = markerView?.layer.map { $0.contents == nil }
            let layerBounds = markerView?.layer.map { RectRecord($0.bounds) }
            let layerContentsRedrawPolicyRaw = markerView.map { $0.layerContentsRedrawPolicy.rawValue }
            let measuredHeight: Double? = markerView.map {
                $0.bounds.width > 0 ? Double($0.height(forWidth: $0.bounds.width)) : 0
            }

            var sampleInk: InkAnalysis?
            if let captured, let markerView {
                sampleInk = analyzeInk(
                    markerView: markerView,
                    scroll: primaryScroll,
                    window: window,
                    image: captured.image,
                    stillScreenRect: captured.rect
                )
            }

            let textNonEmpty = textStorageLength > 0
            let visibleNonEmpty = visibleRect.map {
                !$0.isNull && !$0.isEmpty && $0.width > 1 && $0.height > 1
            } ?? false
            let hasCroppedPixels = (sampleInk?.totalPixels ?? 0) > 0
            let isBlank = (captured != nil)
                && textNonEmpty
                && visibleNonEmpty
                && hasCroppedPixels
                && (sampleInk?.inkRatio ?? 0) < blankInkRatioThreshold

            var sampleStillFile: String?
            if isBlank, !savedBlankStill, let captured {
                let name = String(format: "%@-rep%02d-t%@s-blank.png", scenario.rawValue, repetition, formatOffset(offset))
                if savePNG(captured.image, to: output.appendingPathComponent(name)) {
                    sampleStillFile = name
                    savedBlankStill = true
                }
            }

            let cardState = isHydra ? delegationCardState(in: runtime, marker: marker) : nil
            let panelOpen = isHydra
                ? (!runtime.isHydraPanelHidden && model.hydraTeam(of: thread.id).contains(where: \.isInPanel))
                : nil

            // Offscreen control check: ONLY at the final (10 s) sample, strictly AFTER screen capture
            // and all read-only probes above, because `cacheDisplay` invokes `draw(_:)` and may mutate state.
            var offscreenInkRatio: Double?
            var screenInkRatioAfterOffscreen: Double?
            if isLastSample, let markerView, visibleNonEmpty {
                let backgroundLuminance: CGFloat = if let ink = sampleInk, ink.totalPixels > 0 {
                    CGFloat(ink.medianLuminance)
                } else {
                    resolvedBackgroundLuminance(for: markerView)
                }
                offscreenInkRatio = measureOffscreenInkRatio(
                    for: markerView,
                    opaqueBackgroundLuminance: backgroundLuminance
                )
                // Allow a few display frames for any `cacheDisplay`-induced layer commit before re-capturing screen.
                try? await Task.sleep(for: .milliseconds(100))
                if let afterCaptured = await captureStillImage(rect: stage.captureRect),
                   let afterInk = analyzeInk(
                       markerView: markerView,
                       scroll: markerView.enclosingScrollView ?? primaryScroll,
                       window: window,
                       image: afterCaptured.image,
                       stillScreenRect: afterCaptured.rect
                   ) {
                    screenInkRatioAfterOffscreen = afterInk.inkRatio
                }
            }

            let sample = SampleRecord(
                targetOffsetSeconds: offset,
                actualOffsetSeconds: (actualOffset * 1000).rounded() / 1000,
                elapsedSinceFoldSeconds: (elapsedSinceFold * 1000).rounded() / 1000,
                markerFound: markerView != nil,
                linkTextViewID: linkTextViewID,
                textStorageLength: textStorageLength,
                tempForegroundColorPresent: tempForeground?.present,
                tempForegroundColorCharCount: tempForeground?.coveredChars,
                tempForegroundColorMinAlpha: tempForeground?.minAlpha,
                storageForegroundColorMinAlpha: storageForegroundMinAlpha,
                bounds: boundsRect.map(RectRecord.init),
                visibleRect: visibleRect.map(RectRecord.init),
                visibleRectInWindow: visibleRectInWindow.map(RectRecord.init),
                textContainerWidth: textContainerWidth.map { ($0 * 100).rounded() / 100 },
                windowOcclusionStateRaw: occlusionState.rawValue,
                windowOcclusionVisible: occlusionVisible,
                isHiddenOrHasHiddenAncestor: isHiddenOrAncestor,
                abnormalAncestors: abnormalAncestors,
                ancestorsAbnormalSummary: ancestorsAbnormalSummary,
                hasLayer: hasLayer,
                layerClassName: layerClassName,
                layerContentsIsNil: layerContentsIsNil,
                layerBounds: layerBounds,
                layerContentsRedrawPolicyRaw: layerContentsRedrawPolicyRaw,
                measuredHeight: measuredHeight.map { ($0 * 100).rounded() / 100 },
                stillCaptured: captured != nil,
                stillFile: sampleStillFile,
                inkAnalysis: sampleInk,
                offscreenInkRatio: offscreenInkRatio,
                screenInkRatioAfterOffscreen: screenInkRatioAfterOffscreen,
                isBlank: isBlank,
                delegationCardState: cardState,
                hydraPanelOpen: panelOpen
            )
            samples.append(sample)

            let inkPct = (sampleInk?.inkRatio ?? 0) * 100
            let boundsDesc = boundsRect.map { String(format: "%.1fx%.1f", Double($0.width), Double($0.height)) } ?? "nil"
            let visDesc = visibleRect.map { String(format: "%.1fx%.1f", Double($0.width), Double($0.height)) } ?? "nil"
            let tcWDesc = textContainerWidth.map { String(format: "%.1f", $0) } ?? "nil"
            let viewIDDesc = linkTextViewID.map(String.init) ?? "nil"
            let tempAlphaMinDesc = tempForeground?.minAlpha.map { String(format: "%.3f", $0) } ?? "none"
            let offscreenDesc: String = if let offscreen = offscreenInkRatio {
                String(
                    format: "%.2f%%(after=%@)",
                    offscreen * 100,
                    screenInkRatioAfterOffscreen.map { String(format: "%.2f%%", $0 * 100) } ?? "nil"
                )
            } else {
                "n/a"
            }
            let sampleLine = String(
                format: "fold-repro sample scenario=%@ rep=%d t=%@s(actual=%.2fs,fold=%.2fs) blank=%@ ink=%.2f%%(%d/%d) len=%d viewID=%@ tempAlphaMin=%@ offscreenInk=%@ ancestorsAbnormal=%@ bounds=%@ vis=%@ tcW=%@ occ=%@ hidden=%@ layer=%@ contentsNil=%@ card=%@ panel=%@",
                scenario.rawValue,
                repetition,
                formatOffset(offset),
                actualOffset,
                elapsedSinceFold,
                isBlank ? "true" : "false",
                inkPct,
                sampleInk?.inkPixels ?? 0,
                sampleInk?.totalPixels ?? 0,
                textStorageLength,
                viewIDDesc,
                tempAlphaMinDesc,
                offscreenDesc,
                ancestorsAbnormalSummary,
                boundsDesc,
                visDesc,
                tcWDesc,
                occlusionVisible ? "true" : "false",
                isHiddenOrAncestor.map { $0 ? "true" : "false" } ?? "nil",
                hasLayer.map { $0 ? "true" : "false" } ?? "nil",
                layerContentsIsNil.map { $0 ? "true" : "false" } ?? "nil",
                cardState ?? "n/a",
                panelOpen.map { $0 ? "true" : "false" } ?? "n/a"
            )
            WebsiteCaptures.log(sampleLine)
            emitLine(sampleLine)
        }

        if injectZero {
            ProseRunRepresentable.debugZeroHeightMarker = nil
        }

        // Settled hierarchy inspection after the undisturbed 10 s pixel sampling window.
        let finalFound = findMarkerViews(marker: marker, in: window)
        let matchingViews = finalFound.all
        let primaryMarkerView = finalFound.primary
        let allLinkViews = findAll(LinkTextView.self, in: window.contentView)
        let interimMatchingViews = isHydra
            ? []
            : allLinkViews.filter { ($0.textStorage?.string ?? $0.string).contains(interimPrefix) }

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

        let visibleBeforeRecovery = primaryMarkerView.map {
            isSubstantiallyVisible($0, in: $0.enclosingScrollView ?? primaryScroll)
        } ?? false

        let blankSummary = summarizeBlankTimeline(samples)
        let representativeInk = samples.first(where: \.isBlank)?.inkAnalysis ?? samples.last?.inkAnalysis
        let anyCaptureSucceeded = samples.contains(where: \.stillCaptured)

        // Evaluate pass/fail rules.
        var failureReasons: [String] = []
        if isHydra {
            if hydraSpawnedHeadCount != 2 || delegationMarkedSent != true || hydraPanelOpenAfterFold != true {
                failureReasons.append(
                    "hydra_delegation_not_triggered(heads=\(hydraSpawnedHeadCount ?? 0),sent=\(delegationMarkedSent ?? false),panel=\(hydraPanelOpenAfterFold ?? false))"
                )
            }
        }
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
        // Every scheduled sample must yield a real capture and ink analysis; a failed
        // capture mid-fold could otherwise hide a transient blank.
        let requiredSamples = injectZero ? samples.filter { $0.targetOffsetSeconds >= 4.0 } : samples
        let incompleteSamples = requiredSamples.filter { ($0.inkAnalysis?.totalPixels ?? 0) == 0 }
        if !anyCaptureSucceeded {
            failureReasons.append("still_capture_failed")
        } else if !incompleteSamples.isEmpty {
            failureReasons.append("inconclusive_samples(\(incompleteSamples.count)/\(requiredSamples.count))")
        } else {
            let gatingBlankSamples = injectZero
                ? samples.filter { $0.targetOffsetSeconds >= 4.0 && $0.isBlank }
                : samples.filter(\.isBlank)
            if !gatingBlankSamples.isEmpty {
                let firstStr = gatingBlankSamples.first.map { "\(formatOffset($0.targetOffsetSeconds))s" } ?? "none"
                let recStr = blankSummary.selfRecovered.map { $0 ? "true" : "false" } ?? "false"
                failureReasons.append("blank_pixels(count=\(gatingBlankSamples.count)/\(samples.count),first=\(firstStr),recovered=\(recStr))")
            } else if let finalSample = samples.last, finalSample.markerFound, visibleBeforeRecovery,
                      (finalSample.inkAnalysis?.totalPixels ?? 0) == 0 {
                failureReasons.append("insufficient_ink(no_visible_rect)")
            }
        }

        let passed = failureReasons.isEmpty

        // Save final still for every failure and the first pass of each scenario.
        var stillFile: String?
        let shouldSaveStill = !passed || !savedFirstPass
        if shouldSaveStill, let captured = latestCaptured {
            let tag = passed ? "pass" : "fail"
            let name = String(format: "%@-rep%02d-%@.png", scenario.rawValue, repetition, tag)
            if savePNG(captured.image, to: output.appendingPathComponent(name)) {
                stillFile = name
                if passed { savedFirstPass = true }
            }
        }

        // Clean up rehearsed heads and open job before the next repetition without relaying reports.
        if isHydra {
            for head in spawnedHeads {
                model.updateHydraHead(head.id) {
                    $0.status = .stopped
                    $0.finishedAt = .now
                }
                model.updateThread(head.id) {
                    $0.isInPanel = false
                    $0.lastStatus = .interrupted
                }
                model.existingRuntime(for: head.id)?.rehearse(.turnCompleted(status: .interrupted, error: nil))
            }
            if let openJobID {
                model.updateHydraJob(openJobID, of: thread.id) {
                    $0.ending = .interrupted
                    $0.finishedAt = .now
                }
            }
        }

        let inkPct = (representativeInk?.inkRatio ?? 0) * 100
        let firstProbe = markerProbes.first
        let firstBlankStr = blankSummary.firstBlankAtSeconds.map { "\(formatOffset($0))s" } ?? "none"
        let recoveredStr = blankSummary.selfRecovered.map { $0 ? "true" : "false" } ?? "n/a"
        let repLine = String(
            format: "fold-repro %@ rep=%d provider=%@ sentMsgCompleted=%@ pass=%@ injectZero=%@ healDisabled=%@ found=%d interim=%d h=%.1f/%.1f ink=%.2f%% blanks=%d/%d firstBlank=%@ selfRecovered=%@ occludedVis=%@ reasons=%@",
            scenario.rawValue,
            repetition,
            reproProvider.rawValue,
            sendsMessageCompleted ? "true" : "false",
            passed ? "true" : "false",
            injectZero ? "true" : "false",
            healDisabled ? "true" : "false",
            matchingViews.count,
            interimMatchingViews.count,
            firstProbe?.boundsHeight ?? -1,
            firstProbe?.measuredHeight ?? -1,
            inkPct,
            blankSummary.blankSampleCount,
            samples.count,
            firstBlankStr,
            recoveredStr,
            preFoldOcclusionVisible.map { $0 ? "true" : "false" } ?? "nil",
            failureReasons.isEmpty ? "none" : failureReasons.joined(separator: ",")
        )
        WebsiteCaptures.log(repLine)
        emitLine(repLine)

        return RepetitionRecord(
            scenario: scenario.rawValue,
            repetition: repetition,
            threadID: thread.id.uuidString,
            marker: marker,
            provider: reproProvider.rawValue,
            sentMessageCompleted: sendsMessageCompleted,
            turnDurationSeconds: (turnDuration * 100).rounded() / 100,
            passed: passed,
            failureReasons: failureReasons,
            preFoldOcclusionVisible: preFoldOcclusionVisible,
            scrolledUpDelta: scrolledUpDelta,
            hydraConfig: hydraConfig,
            titleRewritesCount: titleRewritesCount,
            hydraSpawnedHeadCount: hydraSpawnedHeadCount,
            hydraPanelOpenAfterFold: hydraPanelOpenAfterFold,
            delegationMarkedSent: delegationMarkedSent,
            markerFoundCount: matchingViews.count,
            markerViews: markerProbes,
            interimFoundCount: interimMatchingViews.count,
            interimViews: interimProbes,
            scrollState: initialScrollProbe,
            didScrollMarkerIntoView: false,
            scrollStateAfterReveal: nil,
            stillCaptured: anyCaptureSucceeded,
            stillFile: stillFile,
            inkAnalysis: representativeInk,
            samples: samples,
            blankSummary: blankSummary
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

    private static func findMarkerViews(marker: String, in window: NSWindow) -> (all: [LinkTextView], primary: LinkTextView?) {
        let allLinkViews = findAll(LinkTextView.self, in: window.contentView)
        let matching = allLinkViews.filter { ($0.textStorage?.string ?? $0.string).contains(marker) }
        if let mainScroll = timelineScroll(in: window),
           let inMain = matching.first(where: { $0.isDescendant(of: mainScroll) }) {
            return (matching, inMain)
        }
        return (matching, matching.first)
    }

    private static func delegationCardState(in runtime: ThreadRuntime, marker: String) -> String? {
        guard let entry = runtime.entries.last(where: { entry in
            guard case .assistant(let message) = entry.item.content else { return false }
            return message.text.contains(marker)
        }), case .assistant(let message) = entry.item.content else { return nil }
        if HydraPrompts.hasLeavingDelegationBlock(in: message.text) { return "leaving" }
        if HydraPrompts.hasSentDelegationBlock(in: message.text) { return "sent" }
        if HydraPrompts.hasDelegationBlock(in: message.text) { return "raw" }
        return "removed"
    }

    private static func summarizeBlankTimeline(_ samples: [SampleRecord]) -> BlankTimelineSummary {
        let blanks = samples.filter(\.isBlank)
        guard let firstBlank = blanks.first?.targetOffsetSeconds,
              let lastBlank = blanks.last?.targetOffsetSeconds else {
            return BlankTimelineSummary(
                sampleOffsetsSeconds: sampleOffsetsSeconds,
                blankSampleCount: 0,
                blankDetected: false,
                firstBlankAtSeconds: nil,
                lastBlankAtSeconds: nil,
                selfRecovered: nil,
                recoveredAtSeconds: nil
            )
        }
        let validAfterFirst = samples.filter {
            $0.targetOffsetSeconds > firstBlank
                && $0.stillCaptured
                && $0.markerFound
                && $0.textStorageLength > 0
                && ($0.inkAnalysis?.totalPixels ?? 0) > 0
        }
        let selfRecovered = validAfterFirst.last.map { !$0.isBlank } ?? false
        let recoveredAt: Double? = selfRecovered
            ? validAfterFirst.first(where: { $0.targetOffsetSeconds > lastBlank && !$0.isBlank })?.targetOffsetSeconds
            : nil
        return BlankTimelineSummary(
            sampleOffsetsSeconds: sampleOffsetsSeconds,
            blankSampleCount: blanks.count,
            blankDetected: true,
            firstBlankAtSeconds: firstBlank,
            lastBlankAtSeconds: lastBlank,
            selfRecovered: selfRecovered,
            recoveredAtSeconds: recoveredAt
        )
    }

    private static func formatOffset(_ seconds: Double) -> String {
        seconds.rounded() == seconds ? String(format: "%.0f", seconds) : String(format: "%.1f", seconds)
    }

    private static func resolvedAlpha(of color: NSColor, appearance: NSAppearance) -> Double {
        var alpha = 1.0
        appearance.performAsCurrentDrawingAppearance {
            if let rgb = color.usingColorSpace(.sRGB) ?? color.usingColorSpace(.deviceRGB) {
                alpha = Double(rgb.alphaComponent)
            } else {
                alpha = Double(color.cgColor.alpha)
            }
        }
        return (alpha * 10_000).rounded() / 10_000
    }

    private static func resolvedBackgroundLuminance(for view: NSView) -> CGFloat {
        var luminance: CGFloat = 0.95
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            let color = view.window?.backgroundColor ?? NSColor.windowBackgroundColor
            if let rgb = color.usingColorSpace(.sRGB) ?? color.usingColorSpace(.deviceRGB) {
                luminance = 0.2126 * rgb.redComponent + 0.7152 * rgb.greenComponent + 0.0722 * rgb.blueComponent
            }
        }
        return luminance
    }

    private static func inspectTemporaryForegroundColor(in view: LinkTextView) -> (present: Bool, coveredChars: Int, minAlpha: Double?) {
        guard let layoutManager = view.layoutManager,
              let storage = view.textStorage,
              storage.length > 0 else {
            return (false, 0, nil)
        }
        let length = storage.length
        let appearance = view.effectiveAppearance
        var index = 0
        var present = false
        var coveredChars = 0
        var minAlpha: Double?
        while index < length {
            var effectiveRange = NSRange(location: 0, length: 0)
            let attrs = layoutManager.temporaryAttributes(atCharacterIndex: index, effectiveRange: &effectiveRange)
            let stepEnd: Int
            if effectiveRange.length > 0 && effectiveRange.location <= index {
                stepEnd = min(length, effectiveRange.location + effectiveRange.length)
            } else {
                stepEnd = index + 1
            }
            let runLength = max(1, stepEnd - index)
            if let color = attrs[.foregroundColor] as? NSColor {
                present = true
                coveredChars += runLength
                let alpha = resolvedAlpha(of: color, appearance: appearance)
                minAlpha = minAlpha.map { min($0, alpha) } ?? alpha
            }
            index = max(index + 1, stepEnd)
        }
        return (present, coveredChars, minAlpha)
    }

    private static func inspectStorageForegroundMinAlpha(in view: LinkTextView) -> Double? {
        guard let storage = view.textStorage, storage.length > 0 else { return nil }
        let fullRange = NSRange(location: 0, length: storage.length)
        let appearance = view.effectiveAppearance
        var minAlpha: Double?
        storage.enumerateAttribute(.foregroundColor, in: fullRange, options: []) { value, _, _ in
            guard let color = value as? NSColor else { return }
            let alpha = resolvedAlpha(of: color, appearance: appearance)
            minAlpha = minAlpha.map { min($0, alpha) } ?? alpha
        }
        return minAlpha
    }

    private static func inspectAbnormalAncestors(of view: NSView, upTo contentView: NSView?) -> [AbnormalAncestorRecord] {
        var abnormal: [AbnormalAncestorRecord] = []
        var cursor: NSView? = view
        var depth = 0
        while let current = cursor {
            let isHidden = current.isHidden
            let alpha = Double(current.alphaValue)
            let layerIsHidden = current.layer?.isHidden
            let layerOpacity = current.layer.map { Double($0.opacity) }
            let hasLayerMask = current.layer?.mask != nil
            if isHidden || alpha < 0.99 || layerIsHidden == true || (layerOpacity ?? 1.0) < 0.99 {
                abnormal.append(AbnormalAncestorRecord(
                    depth: depth,
                    className: String(describing: type(of: current)),
                    isHidden: isHidden,
                    alphaValue: (alpha * 10_000).rounded() / 10_000,
                    layerIsHidden: layerIsHidden,
                    layerOpacity: layerOpacity.map { ($0 * 10_000).rounded() / 10_000 },
                    hasLayerMask: hasLayerMask
                ))
            }
            if let contentView, current === contentView { break }
            cursor = current.superview
            depth += 1
        }
        return abnormal
    }

    private static func computeInkMetrics(
        from image: CGImage,
        opaqueBackgroundLuminance: CGFloat? = nil
    ) -> (totalPixels: Int, medianLuminance: Double, inkPixels: Int, inkRatio: Double)? {
        let cropW = image.width
        let cropH = image.height
        guard cropW > 0, cropH > 0 else { return nil }

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
            let rect = CGRect(x: 0, y: 0, width: cropW, height: cropH)
            if let bgLum = opaqueBackgroundLuminance,
               let bgColor = CGColor(colorSpace: colorSpace, components: [bgLum, bgLum, bgLum, 1.0]) {
                context.setFillColor(bgColor)
                context.fill(rect)
            }
            context.draw(image, in: rect)
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
            if abs(lum - medianLum) > inkLuminanceDeltaThreshold {
                inkPixels += 1
            }
            offset += 4
        }

        let ratio = totalPixels > 0 ? Double(inkPixels) / Double(totalPixels) : 0
        return (
            totalPixels: totalPixels,
            medianLuminance: (medianLum * 10_000).rounded() / 10_000,
            inkPixels: inkPixels,
            inkRatio: (ratio * 100_000).rounded() / 100_000
        )
    }

    private static func measureOffscreenInkRatio(
        for view: LinkTextView,
        opaqueBackgroundLuminance: CGFloat
    ) -> Double? {
        let rect = view.visibleRect
        guard !rect.isNull, !rect.isEmpty, rect.width > 1, rect.height > 1,
              let rep = view.bitmapImageRepForCachingDisplay(in: rect) else {
            return nil
        }
        view.cacheDisplay(in: rect, to: rep)
        guard let cgImage = rep.cgImage else { return nil }
        return computeInkMetrics(from: cgImage, opaqueBackgroundLuminance: opaqueBackgroundLuminance)?.inkRatio
    }

    private static func analyzeInk(
        markerView: LinkTextView,
        scroll: NSScrollView?,
        window: NSWindow,
        image: CGImage,
        stillScreenRect: NSRect
    ) -> InkAnalysis? {
        let viewVisibleRect = markerView.visibleRect
        guard !viewVisibleRect.isNull, !viewVisibleRect.isEmpty,
              viewVisibleRect.width > 1, viewVisibleRect.height > 1 else {
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
        var visibleWindowRect = markerView.convert(viewVisibleRect, to: nil)
        if let scroll, let document = scroll.documentView {
            let unobstructedInWindow = document.convert(unobstructedViewportRect(in: scroll), to: nil)
            visibleWindowRect = visibleWindowRect.intersection(unobstructedInWindow)
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

        guard let metrics = computeInkMetrics(from: cropped) else { return nil }
        return InkAnalysis(
            visibleRectInWindow: RectRecord(visibleWindowRect),
            cropPixelWidth: cropW,
            cropPixelHeight: cropH,
            totalPixels: metrics.totalPixels,
            medianLuminance: metrics.medianLuminance,
            inkPixels: metrics.inkPixels,
            inkRatio: metrics.inkRatio
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

    private static let hydraLeadReasoningText = """
    先对照 Release 3.0.15 在 Antigravity ACP 下出现的 Hydra lead 故障时间线梳理现场：用户发完消息之后先进入约 30 秒的长思考阶段，这期间时间线一直处在 TurnRunningBlock 状态，还没有创建最终回复段落视图。思考结束后，ACPSession 连续吐出若干个 agent_message_chunk，包含约 90 个汉字的正文段落以及尾部的 Hydra 委派代码块，且 ACP 协议不会补发独立的 messageCompleted 事件，最后一个文本增量之后 0 ms 就直接到达 turnCompleted。紧接着 ThreadRuntime.finalizeTurn 在同一个 MainActor 事务段内连续执行 endStreaming、append(.turnEnd) 触发 TurnRunningBlock 向 TurnFinishedBlock 折叠、将委派块改写为 hydra-sent、调用 spawnDelegatedHeads 打开子代理面板触发布局列宽收缩，并启动 holdSentDelegationBlock：在 t+3.2 秒以 easeOut(0.4) 动画将委派块切换为 hydra-leaving，在 t+3.65 秒禁用动画将其从正文中移除。由于高度正常但像素长期保持空白，且折叠子代理面板或重启后会立刻恢复，我需要把历史修复审计与 AppKit/SwiftUI 合成层机制分成两条只读调查线同时推进，再结合真机像素采样结果做最终收口。
    """

    private static func hydraLeadParagraph(marker: String) -> String {
        "我已经先梳理完折叠渲染链路与子代理面板触发时机，接下来分成两条独立线并行排查：一条核对历史修复与高度测量路径，另一条追查面板切换和图层合成状态，等两位子代理回报后再统一收口方案（标记：\(marker)）。"
    }

    private static let hydraLeadDelegationBlock: String = {
        let fence = "```"
        return """
        \(fence)hydra
        [
          {
            "name": "Otto",
            "task": "审计空白回复修复史与测量绘制路径",
            "files": [],
            "prompt": "只读排查折叠后回复空白的历史修复与 LinkTextView 测量绘制链路，汇报根因与未决点。"
          },
          {
            "name": "Milo",
            "task": "排查合成层与子代理面板布局机制",
            "files": [],
            "prompt": "只读分析 AppKit 与 SwiftUI 合成层在子代理面板展开和折叠时的重绘机制并汇报。"
          }
        ]
        \(fence)
        """
    }()

    private static func splitEvenly(_ text: String, into parts: Int) -> [String] {
        guard parts > 1, text.count > 1 else { return text.isEmpty ? [] : [text] }
        let total = text.count
        let sliceCount = min(parts, total)
        var result: [String] = []
        result.reserveCapacity(sliceCount)
        var start = text.startIndex
        for idx in 0..<sliceCount {
            let currentBoundary = (idx * total) / sliceCount
            let nextBoundary = ((idx + 1) * total) / sliceCount
            let step = idx == sliceCount - 1 ? (total - currentBoundary) : max(1, nextBoundary - currentBoundary)
            let end = text.index(start, offsetBy: step, limitedBy: text.endIndex) ?? text.endIndex
            if start < end {
                result.append(String(text[start..<end]))
            }
            start = end
        }
        return result
    }

    private static func buildHydraLeadChunks(
        paragraph: String,
        delegationBlock: String,
        count: Int,
        gapSeconds: Double
    ) -> [StreamPiece] {
        let fullText = paragraph + "\n\n" + delegationBlock
        if count <= 1 {
            return buildBurstChunks(for: fullText)
        }
        let gapMs = max(0, Int((gapSeconds * 1000).rounded()))
        let fullDelegation = "\n\n" + delegationBlock
        let rawSlices: [String]
        if count == 2 {
            rawSlices = [paragraph, fullDelegation]
        } else {
            let paragraphSlices = splitEvenly(paragraph, into: count - 2)
            let delegationSlices = splitEvenly(fullDelegation, into: 2)
            rawSlices = paragraphSlices + delegationSlices
        }
        return rawSlices.filter { !$0.isEmpty }.map { StreamPiece(text: $0, delayMs: gapMs) }
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

    private static func buildBurstChunks(for text: String) -> [StreamPiece] {
        // Fast post-thought burst (~30-42 chars every 14-18 ms, ~180-220 ms total for ~400 chars).
        let sizes = [32, 38, 34, 42, 36, 40]
        let delays = [15, 18, 14, 17, 16, 15]
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

    private static func streamReasoning(
        _ runtime: ThreadRuntime,
        id: String,
        text: String,
        durationSeconds: Double,
        alive: () -> Bool
    ) async {
        guard !text.isEmpty, alive() else { return }
        if durationSeconds <= 0 {
            runtime.rehearse(.reasoningDelta(id: id, text: text))
            return
        }
        let stepSeconds = min(0.15, max(0.04, durationSeconds / 60.0))
        let totalSteps = max(1, Int((durationSeconds / stepSeconds).rounded()))
        let endTime = Date.now.addingTimeInterval(durationSeconds)
        var cursor = text.startIndex
        var emitted = 0
        let chunkSize = 6
        while alive() && (emitted == 0 || Date.now < endTime) {
            if cursor >= text.endIndex {
                runtime.rehearse(.reasoningDelta(id: id, text: "\n\n"))
                cursor = text.startIndex
            }
            let next = text.index(cursor, offsetBy: chunkSize, limitedBy: text.endIndex) ?? text.endIndex
            runtime.rehearse(.reasoningDelta(id: id, text: String(text[cursor..<next])))
            cursor = next
            emitted += 1
            let remaining = endTime.timeIntervalSinceNow
            if remaining <= 0 || emitted >= totalSteps && remaining < stepSeconds * 0.25 {
                break
            }
            try? await Task.sleep(for: .seconds(min(stepSeconds, remaining)))
        }
    }

    // MARK: - CLI arguments, report & stdout

    private struct ParsedArguments {
        var scenarios: [Scenario]?
        var count: Int?
        var provider: ReproProvider?
        var streamChunks: Int?
        var chunkGapSeconds: Double?
        var tailDelaySeconds: Double?
        var reasoningSeconds: Double?
        var freshThread: Bool
        var injectZero: Bool
        var noHeal: Bool
        var error: String?
    }

    private static func parseArguments() -> ParsedArguments {
        let args = CommandLine.arguments
        var scenarios: [Scenario] = Scenario.allCases
        var count = 10
        var provider: ReproProvider?
        var streamChunks: Int?
        var chunkGapSeconds: Double?
        var tailDelaySeconds: Double?
        var reasoningSeconds: Double?
        let freshThread = args.contains("--fold-repro-fresh-thread")
        let injectZero = args.contains("--fold-repro-inject-zero")
        let noHeal = args.contains("--fold-repro-no-heal")

        func fail(_ message: String) -> ParsedArguments {
            ParsedArguments(
                scenarios: nil,
                count: nil,
                provider: provider,
                streamChunks: streamChunks,
                chunkGapSeconds: chunkGapSeconds,
                tailDelaySeconds: tailDelaySeconds,
                reasoningSeconds: reasoningSeconds,
                freshThread: freshThread,
                injectZero: injectZero,
                noHeal: noHeal,
                error: message
            )
        }

        if let scenarioIndex = args.firstIndex(of: "--fold-repro-scenario") {
            guard args.indices.contains(scenarioIndex + 1) else {
                return fail("missing value after --fold-repro-scenario")
            }
            let raw = args[scenarioIndex + 1]
            if raw == "all" {
                scenarios = Scenario.allCases
            } else if let one = Scenario(rawValue: raw) {
                scenarios = [one]
            } else {
                let valid = (["all"] + Scenario.allCases.map(\.rawValue)).joined(separator: ", ")
                return fail("unknown --fold-repro-scenario '\(raw)'; expected one of: \(valid)")
            }
        }

        if let providerIndex = args.firstIndex(of: "--fold-repro-provider") {
            guard args.indices.contains(providerIndex + 1) else {
                return fail("missing value after --fold-repro-provider")
            }
            let raw = args[providerIndex + 1]
            guard let parsedProvider = ReproProvider(rawValue: raw) else {
                let valid = ReproProvider.allCases.map(\.rawValue).joined(separator: ", ")
                return fail("unknown --fold-repro-provider '\(raw)'; expected one of: \(valid)")
            }
            provider = parsedProvider
        }

        if let chunksIndex = args.firstIndex(of: "--fold-repro-stream-chunks") {
            guard args.indices.contains(chunksIndex + 1),
                  let parsedChunks = Int(args[chunksIndex + 1]),
                  parsedChunks >= 1 else {
                return fail("invalid positive integer after --fold-repro-stream-chunks")
            }
            streamChunks = parsedChunks
        }

        if let gapIndex = args.firstIndex(of: "--fold-repro-chunk-gap") {
            guard args.indices.contains(gapIndex + 1),
                  let parsedGap = Double(args[gapIndex + 1]),
                  parsedGap >= 0 else {
                return fail("invalid number of seconds after --fold-repro-chunk-gap")
            }
            chunkGapSeconds = parsedGap
        }

        if let tailIndex = args.firstIndex(of: "--fold-repro-tail-delay") {
            guard args.indices.contains(tailIndex + 1),
                  let parsedTail = Double(args[tailIndex + 1]),
                  parsedTail >= 0 else {
                return fail("invalid number of seconds after --fold-repro-tail-delay")
            }
            tailDelaySeconds = parsedTail
        }

        if let reasoningIndex = args.firstIndex(of: "--fold-repro-reasoning-seconds") {
            guard args.indices.contains(reasoningIndex + 1),
                  let parsedReasoning = Double(args[reasoningIndex + 1]),
                  parsedReasoning >= 0 else {
                return fail("invalid number of seconds after --fold-repro-reasoning-seconds")
            }
            reasoningSeconds = parsedReasoning
        }

        if let holdIndex = args.firstIndex(of: "--fold-repro-hold") {
            guard args.indices.contains(holdIndex + 1), let hold = Double(args[holdIndex + 1]), hold >= 0 else {
                return fail("invalid number of seconds after --fold-repro-hold")
            }
            holdSeconds = hold
        }

        if let countIndex = args.firstIndex(of: "--fold-repro-count") {
            guard args.indices.contains(countIndex + 1),
                  let parsedCount = Int(args[countIndex + 1]),
                  parsedCount > 0 else {
                return fail("invalid positive integer after --fold-repro-count")
            }
            count = parsedCount
        }

        return ParsedArguments(
            scenarios: scenarios,
            count: count,
            provider: provider,
            streamChunks: streamChunks,
            chunkGapSeconds: chunkGapSeconds,
            tailDelaySeconds: tailDelaySeconds,
            reasoningSeconds: reasoningSeconds,
            freshThread: freshThread,
            injectZero: injectZero,
            noHeal: noHeal,
            error: nil
        )
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
