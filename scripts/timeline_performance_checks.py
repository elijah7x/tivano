#!/usr/bin/env python3
"""Compile timeline helpers from production source; no app or provider is launched."""
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "Tivano/App/Views/Chat/ThreadTimeline.swift").read_text()
OUT = ROOT / "build.noindex/timeline-performance-checks"


def declaration(marker: str) -> str:
    try:
        start = SOURCE.index(marker)
        opening = SOURCE.index("{", start)
    except ValueError:
        raise SystemExit(f"FAIL: missing extraction marker {marker!r}") from None
    depth = 1
    end = opening + 1
    while depth:
        if end >= len(SOURCE):
            raise SystemExit(f"FAIL: unterminated declaration at {marker!r}")
        if SOURCE[end] == "{":
            depth += 1
        elif SOURCE[end] == "}":
            depth -= 1
        end += 1
    return SOURCE[start:end]


def scroll_geometry_source() -> str:
    return declaration("        .onScrollGeometryChange(for: ScrollMetrics.self, of: ScrollMetrics.init(geometry:)) {")


def require_source(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(f"FAIL: {message}")


wheel = declaration("    func noteWheelInput(")
navigation = declaration("    func noteUserNavigation(")
cancels_navigation = declaration("        if !preservingHistory {")
require_source("if !preservingHistory" in navigation, "navigation must distinguish continuous scrolling from explicit jumps")
require_source(
    "historyReaderDelta += offsetDelta" in wheel and "historyReaderDelta +=" not in scroll_geometry_source(),
    "a history load must take the reader's movement from wheel input, never from offset changes an anchor may have made",
)
require_source(
    "noteUserNavigation(preservingHistory: historyLoadPending)" in wheel,
    "wheel input must preserve an in-flight history request",
)
for marker in ("navigationGeneration += 1", "navigationAction()"):
    require_source(marker in cancels_navigation, f"wheel-preservable navigation must contain {marker!r} only in its cancellation branch")
for marker in ("placementTask?.cancel()", "placementToken = nil"):
    require_source(marker not in cancels_navigation and marker in navigation,
                   f"reader input must always cancel placement corrections ({marker!r})")
load_earlier = declaration("    private func loadEarlier(")
cancel_history = declaration("    private func cancelHistoryRequest() {")
settle_measurements = declaration("    private func settleMeasurements(")
scroll_geometry = declaration("        .onScrollGeometryChange(for: ScrollMetrics.self, of: ScrollMetrics.init(geometry:)) {")
scroll_view_probe = declaration("private struct ScrollViewProbe: NSViewRepresentable {")
probe_view = declaration("    fileprivate final class ProbeView: NSView {")
history_anchor_math = declaration("enum HistoryAnchorMath {")
for marker in (
    "let anchorBlock =",
    "measurements.viewportFrame",
    "anchorID: anchor?.id",
    "anchorOffset: anchor?.offset ?? 0",
    "historyReaderDelta = 0",
    "historySyncShift = 0",
):
    require_source(marker in load_earlier, f"loadEarlier must record the reader anchor ({marker!r})")
require_source("historyReaderDelta = 0" in cancel_history, "cancelHistoryRequest must reset historyReaderDelta")
require_source("historySyncShift = 0" in cancel_history, "cancelHistoryRequest must reset historySyncShift")
for forbidden in ("lastReaderMovement <= request.requestedAt", "lastReaderMovement", "keepAnchor("):
    require_source(
        forbidden not in settle_measurements,
        f"settleMeasurements must not gate or delegate history restoration through {forbidden!r}",
    )
for marker in (
    "historyRequest?.anchorRestored = true",
    "DispatchQueue.main.async",
    "HistoryAnchorMath.restoreDelta",
    "isRestoringHistory = true",
    "clip.scroll(",
    "reflectScrolledClipView",
    "resetDrift()",
    "historyLoadPending = false",
    "historyReaderDelta = 0",
    "historySyncShift = 0",
    "updateMountedWindow(",
):
    require_source(marker in settle_measurements, f"history measurement must restore its anchor once ({marker!r})")
require_source(
    settle_measurements.index("clip.scroll(") < settle_measurements.index("historyLoadPending = false"),
    "historyLoadPending = false must run after clip.scroll restores the anchor",
)
for marker in (
    "postsFrameChangedNotifications",
    "NSView.frameDidChangeNotification",
    "removeDocumentObserver()",
    "guard !isSyncShifting",
    "guard let tracking, tracking.historyLoadPending else { return }",
    "HistoryAnchorMath.syncShift(",
    "readerMovement: readerMovement",
    "isSyncShifting = true",
    "isSyncShiftingHistory = true",
    "clip.scroll(",
    "reflectScrolledClipView",
    "historySyncShift +=",
):
    require_source(marker in probe_view, f"ProbeView must synchronously compensate unanchored history growth ({marker!r})")
require_source(
    "removeDocumentObserver()" in scroll_view_probe,
    "ScrollViewProbe.dismantleNSView must remove the document frame observer",
)
for marker in (
    "HistoryAnchorMath.readerDelta(",
    "isSyncShiftingHistory",
    "new.offset < old.offset || tracking.isUserScrolling || tracking.isCoasting",
    "warmMarkdown(for: blocks[target..<hidden])",
):
    require_source(marker in scroll_geometry, f"scroll geometry handler must preserve history tracking ({marker!r})")
print("PASS: wheel preserves history loading; history pages record and restore one reader anchor")


# Only unrelated dependencies are stubbed. The measured-height implementation and
# asynchronous visibility/repair methods below are the actual production code.
swift = r'''
import Foundation
import QuartzCore

struct DisplayBlock { let id: String }
enum Chrome { static let contentTopInset: CGFloat = 16 }
enum TimelineMetrics { static let rowSpacing: CGFloat = 12 }

/// Counts what the production tracking reports; the runtime's flush pacing reads the count.
@MainActor
final class ThreadRuntime {
    var shownTimelines = 0
    func noteTimeline(shown: Bool) { shownTimelines += shown ? 1 : -1 }
}
'''
swift += "\n" + history_anchor_math
swift += "\n@MainActor\n" + declaration("private final class TimelineMeasurements")
swift += r'''
@MainActor
private final class TrackingHarness {
    var columnIsShown = false
    weak var shownRuntime: ThreadRuntime?
    var blankWatch: Task<Void, Never>?
    var viewportRefreshTask: Task<Void, Never>?
    var refreshPending = false
    var refreshesInBurst = 0
    var burstStartedAt: CFTimeInterval = 0
    var drift: CGFloat = 0
    var blankRepairs = 0
    var checkRequest = 0
    var refreshRequest = 0
    var showsNothing = true
    var isNudging = false
    var endedActivity = 0
    func endActivity() { endedActivity += 1 }
    func trace(_ name: StaticString, _ source: StaticString, disposition: String = "") {}
'''
for name in ("setColumnShown", "armBlankWatch", "noteReturnToFront", "armViewportRefresh"):
    swift += "\n" + declaration(f"    func {name}(")
swift += "\n}\n"
swift += r'''
@main
struct Checks {
    /// The refresh fires after production's 300 ms wait; a fixed sleep with a small margin
    /// fails on a loaded host, so wait for the expected state (up to 5 s) instead.
    @MainActor static func eventually(_ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() && ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
    }

    @MainActor static func main() async {
        let deltaH: CGFloat = 480
        precondition(HistoryAnchorMath.readerDelta(offsetChange: 0, growth: deltaH, anchorsBottom: true) == 0,
                     "uncompensated insertion frame must not count as reader movement")
        precondition(HistoryAnchorMath.readerDelta(offsetChange: deltaH, growth: deltaH, anchorsBottom: true) == 0,
                     "bottom-anchored insertion frame must subtract growth")
        precondition(HistoryAnchorMath.readerDelta(offsetChange: deltaH - 90, growth: deltaH, anchorsBottom: true) == -90,
                     "bottom-anchored insertion frame must preserve simultaneous upward reader scroll")
        precondition(HistoryAnchorMath.readerDelta(offsetChange: -90, growth: deltaH, anchorsBottom: true) == -90,
                     "uncompensated insertion frame must preserve simultaneous upward reader scroll")
        precondition(HistoryAnchorMath.readerDelta(offsetChange: -64, growth: 0, anchorsBottom: true) == -64,
                     "pure upward scroll frame must return offsetChange unchanged")
        precondition(HistoryAnchorMath.readerDelta(offsetChange: 42, growth: 0, anchorsBottom: false) == 42,
                     "pure downward scroll frame must return offsetChange unchanged")
        precondition(HistoryAnchorMath.readerDelta(offsetChange: -64, growth: deltaH, anchorsBottom: false) == -64,
                     "top-anchored frame must return offsetChange unchanged")

        let anchorMeasure = TimelineMeasurements()
        anchorMeasure.restoreFrames(["anchor": CGRect(x: 0, y: 200, width: 720, height: 120)])
        let initialOffset: CGFloat = 150
        let anchorOffset = anchorMeasure.viewportFrame("anchor", offset: initialOffset)!.minY
        anchorMeasure.restoreFrames(["anchor": CGRect(x: 0, y: 200 + deltaH, width: 720, height: 120)])

        let stationaryMinY = anchorMeasure.viewportFrame("anchor", offset: initialOffset)!.minY
        let stationaryRestore = HistoryAnchorMath.restoreDelta(
            anchorMinY: stationaryMinY,
            anchorOffset: anchorOffset,
            readerDelta: 0
        )
        precondition(stationaryRestore == deltaH,
                     "stationary restoreDelta must equal inserted height deltaH, got \(stationaryRestore)")
        precondition(anchorMeasure.viewportFrame("anchor", offset: initialOffset + stationaryRestore)!.minY == anchorOffset,
                     "stationary restore must keep anchor at its original viewport minY")

        let upwardScroll: CGFloat = -120
        let uncompensatedOffset = initialOffset + upwardScroll
        let uncompensatedMinY = anchorMeasure.viewportFrame("anchor", offset: uncompensatedOffset)!.minY
        let movingRestore = HistoryAnchorMath.restoreDelta(
            anchorMinY: uncompensatedMinY,
            anchorOffset: anchorOffset,
            readerDelta: upwardScroll
        )
        precondition(movingRestore == deltaH,
                     "upward-scrolling restoreDelta must compensate only deltaH without pulling reader back, got \(movingRestore)")
        let restoredOffset = uncompensatedOffset + movingRestore
        precondition(restoredOffset == initialOffset + deltaH + upwardScroll,
                     "restored offset must preserve upward reader scroll")
        precondition(anchorMeasure.viewportFrame("anchor", offset: restoredOffset)!.minY == anchorOffset - upwardScroll,
                     "upward reader scroll must move anchor down in viewport rather than yanking reader back")

        let compensatedOffset = initialOffset + deltaH + upwardScroll
        let compensatedMinY = anchorMeasure.viewportFrame("anchor", offset: compensatedOffset)!.minY
        precondition(HistoryAnchorMath.restoreDelta(
            anchorMinY: compensatedMinY,
            anchorOffset: anchorOffset,
            readerDelta: upwardScroll
        ) == 0, "already-compensated upward scroll must have zero restoreDelta")

        precondition(HistoryAnchorMath.syncShift(
            historyLoadPending: true,
            isRestoringHistory: false,
            isNudging: false,
            isPinnedToBottom: false,
            growth: deltaH,
            clipMinYChange: 0
        ) == deltaH, "unanchored history growth must synchronously shift by growth")
        precondition(HistoryAnchorMath.syncShift(
            historyLoadPending: true,
            isRestoringHistory: false,
            isNudging: false,
            isPinnedToBottom: false,
            growth: deltaH,
            clipMinYChange: -90
        ) == deltaH, "unanchored history growth with upward reader scroll must still shift by growth")
        precondition(HistoryAnchorMath.syncShift(
            historyLoadPending: true,
            isRestoringHistory: false,
            isNudging: false,
            isPinnedToBottom: false,
            growth: deltaH,
            clipMinYChange: deltaH
        ) == 0, "bottom-anchored history growth must not double-shift")
        precondition(HistoryAnchorMath.syncShift(
            historyLoadPending: true,
            isRestoringHistory: false,
            isNudging: false,
            isPinnedToBottom: false,
            growth: deltaH,
            clipMinYChange: deltaH - 90
        ) == 0, "bottom-anchored history growth with upward reader scroll must not double-shift")
        precondition(HistoryAnchorMath.syncShift(
            historyLoadPending: true,
            isRestoringHistory: false,
            isNudging: false,
            isPinnedToBottom: false,
            growth: 100,
            clipMinYChange: 20,
            readerMovement: -80
        ) == 0, "an anchor move hidden by coalesced upward wheel movement must not shift again")
        precondition(HistoryAnchorMath.syncShift(
            historyLoadPending: true,
            isRestoringHistory: false,
            isNudging: false,
            isPinnedToBottom: false,
            growth: 100,
            clipMinYChange: -80,
            readerMovement: -80
        ) == 100, "upward wheel movement without an anchor move must still shift by growth")
        precondition(HistoryAnchorMath.syncShift(
            historyLoadPending: false,
            isRestoringHistory: false,
            isNudging: false,
            isPinnedToBottom: false,
            growth: deltaH,
            clipMinYChange: 0
        ) == 0, "non-history growth must never trigger sync shift")
        precondition(HistoryAnchorMath.syncShift(
            historyLoadPending: true,
            isRestoringHistory: true,
            isNudging: false,
            isPinnedToBottom: false,
            growth: deltaH,
            clipMinYChange: 0
        ) == 0, "sync shift must not run while async restore is active")
        precondition(HistoryAnchorMath.syncShift(
            historyLoadPending: true,
            isRestoringHistory: false,
            isNudging: true,
            isPinnedToBottom: false,
            growth: deltaH,
            clipMinYChange: 0
        ) == 0, "sync shift must not run while nudging")
        precondition(HistoryAnchorMath.syncShift(
            historyLoadPending: true,
            isRestoringHistory: false,
            isNudging: false,
            isPinnedToBottom: true,
            growth: deltaH,
            clipMinYChange: 0
        ) == 0, "sync shift must not run when pinned to bottom")
        precondition(HistoryAnchorMath.syncShift(
            historyLoadPending: true,
            isRestoringHistory: false,
            isNudging: false,
            isPinnedToBottom: false,
            growth: 1,
            clipMinYChange: 0
        ) == 0, "sync shift must ignore growth <= 1")
        print("PASS: HistoryAnchorMath filters anchor growth and preserves upward reader scroll")

        let m = TimelineMeasurements()
        var reference: [String: CGRect] = [:]
        var fallback: CGFloat = 160
        func estimate() -> CGFloat {
            let heights = reference.values.map(\.height).filter { $0.isFinite && $0 > 0 }
            return heights.isEmpty ? fallback : min(1600, max(48, heights.reduce(0, +) / CGFloat(heights.count)))
        }
        func checkEstimate() {
            precondition(abs(m.rowHeight("unknown") - estimate()) < 0.000001)
        }
        checkEstimate()
        // Repeated streaming growth, replacement, origin-only changes, zero and
        // non-finite values must agree with the original full-scan calculation.
        for index in 0..<20_000 {
            let id = "row-\(index % 173)"
            let height: CGFloat = index % 101 == 0 ? .infinity : (index % 79 == 0 ? 0 : CGFloat((index * 37) % 5000) / 4)
            let frame = CGRect(x: 0, y: CGFloat(index), width: 400, height: height)
            let expectedChange = reference[id]?.height != frame.height
            precondition(m.record(id, frame: frame, generation: m.generation) == expectedChange)
            reference[id] = frame
            checkEstimate()
        }
        let previousGeneration = m.generation
        fallback = estimate()
        m.invalidate(width: 720)
        reference.removeAll()
        checkEstimate()
        precondition(!m.record("stale", frame: CGRect(x: 0, y: 0, width: 400, height: 900), generation: previousGeneration))
        precondition(m.frames.isEmpty)
        reference = ["restored": CGRect(x: 0, y: 120, width: 720, height: 400)]
        m.restoreFrames(reference)
        checkEstimate()
        let moved = CGRect(x: 0, y: 240, width: 720, height: 400)
        precondition(!m.record("restored", frame: moved, generation: m.generation))
        reference["restored"] = moved
        checkEstimate()
        precondition(m.viewportFrame("restored", offset: 30)?.minY == 226)
        m.restoreFrames([:])
        reference.removeAll()
        checkEstimate()
        print("PASS: 20,000 height updates, restoration, invalidation and stale generations")

        let t = TrackingHarness()
        let r = ThreadRuntime()
        t.armBlankWatch()
        t.armViewportRefresh()
        t.noteReturnToFront()
        precondition(t.blankWatch == nil && t.viewportRefreshTask == nil)
        precondition(t.checkRequest == 0 && t.refreshRequest == 0)

        t.setColumnShown(true, on: r)
        await eventually { t.checkRequest >= 2 && t.refreshRequest >= 1 }
        try? await Task.sleep(for: .milliseconds(380)) // no extra requests may follow
        precondition(t.checkRequest == 2 && t.refreshRequest == 1, "visible column: expected 2 checks and 1 refresh, got \(t.checkRequest)/\(t.refreshRequest)")
        let checked = t.checkRequest
        t.setColumnShown(true, on: r)
        precondition(t.checkRequest == checked, "repeated visibility must be inert") // repeated visibility is inert

        // Hide after a refresh has entered its asynchronous wait. Its canceled
        // continuation must not fire or clear the next visible column's task.
        t.isNudging = true
        t.armViewportRefresh()
        t.armBlankWatch()
        try? await Task.sleep(for: .milliseconds(25))
        t.setColumnShown(false, on: r)
        let hiddenChecks = t.checkRequest
        let hiddenRefreshes = t.refreshRequest
        t.armBlankWatch()
        t.armViewportRefresh()
        try? await Task.sleep(for: .milliseconds(380))
        precondition(t.checkRequest == hiddenChecks && t.refreshRequest == hiddenRefreshes, "hidden column must not check or refresh")
        await eventually { !t.refreshPending && t.endedActivity == 1 }
        precondition(!t.refreshPending && t.endedActivity == 1, "hiding must end the pending refresh once, got pending=\(t.refreshPending) ended=\(t.endedActivity)")

        t.setColumnShown(true, on: r)
        try? await Task.sleep(for: .milliseconds(25))
        t.setColumnShown(false, on: r)
        t.setColumnShown(true, on: r)
        let returnChecks = t.checkRequest
        await eventually { t.refreshRequest >= hiddenRefreshes + 1 && t.checkRequest >= returnChecks + 1 && !t.refreshPending }
        try? await Task.sleep(for: .milliseconds(380)) // no extra requests may follow
        precondition(t.refreshRequest == hiddenRefreshes + 1, "rapid return: expected exactly one refresh, got \(t.refreshRequest - hiddenRefreshes)")
        precondition(t.checkRequest == returnChecks + 1, "rapid return: expected exactly one check, got \(t.checkRequest - returnChecks)")
        precondition(!t.refreshPending, "rapid return left a refresh pending")
        t.setColumnShown(false, on: r)
        precondition(r.shownTimelines == 0, "hidden column must leave no visible count, got \(r.shownTimelines)")
        print("PASS: hidden/prebuilt suppression, visible repair, cancellation and rapid return")

        // The runtime's visible count: one per shown timeline, inert on repeats, moved
        // with a runtime swapped under a shown timeline, and never left behind on hide.
        let u = TrackingHarness()
        let first = ThreadRuntime()
        let second = ThreadRuntime()
        u.setColumnShown(true, on: first)
        u.setColumnShown(true, on: first)
        precondition(first.shownTimelines == 1, "repeated show must count once, got \(first.shownTimelines)")
        u.setColumnShown(true, on: second)
        precondition(first.shownTimelines == 0 && second.shownTimelines == 1, "swap must move the count, got \(first.shownTimelines)/\(second.shownTimelines)")
        u.setColumnShown(false, on: second)
        u.setColumnShown(false, on: second)
        precondition(second.shownTimelines == 0, "hide must take the count back once, got \(second.shownTimelines)")
        print("PASS: visible-timeline count pairs show and hide across runtime swaps")
    }
}
'''
OUT.mkdir(parents=True, exist_ok=True)
source = OUT / "Checks.swift"
source.write_text(swift)
binary = OUT / "checks"
subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-O", str(source), "-o", str(binary)], check=True, cwd=ROOT)
subprocess.run([str(binary)], check=True, cwd=ROOT)
