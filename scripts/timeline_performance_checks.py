#!/usr/bin/env python3
"""Compile timeline helpers from production source; no app or provider is launched."""
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "Tivano/App/Views/Chat/ThreadTimeline.swift").read_text()
OUT = ROOT / "build.noindex/timeline-performance-checks"


def declaration(marker: str) -> str:
    start = SOURCE.index(marker)
    opening = SOURCE.index("{", start)
    depth = 1
    end = opening + 1
    while depth:
        if SOURCE[end] == "{":
            depth += 1
        elif SOURCE[end] == "}":
            depth -= 1
        end += 1
    return SOURCE[start:end]


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
