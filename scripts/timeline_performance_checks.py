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
'''
swift += "\n@MainActor\n" + declaration("private final class TimelineMeasurements")
swift += r'''
@MainActor
private final class TrackingHarness {
    var columnIsShown = false
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
        t.armBlankWatch()
        t.armViewportRefresh()
        t.noteReturnToFront()
        precondition(t.blankWatch == nil && t.viewportRefreshTask == nil)
        precondition(t.checkRequest == 0 && t.refreshRequest == 0)

        t.setColumnShown(true)
        try? await Task.sleep(for: .milliseconds(380))
        precondition(t.checkRequest == 2 && t.refreshRequest == 1)
        let checked = t.checkRequest
        t.setColumnShown(true)
        precondition(t.checkRequest == checked) // repeated visibility is inert

        // Hide after a refresh has entered its asynchronous wait. Its canceled
        // continuation must not fire or clear the next visible column's task.
        t.isNudging = true
        t.armViewportRefresh()
        t.armBlankWatch()
        try? await Task.sleep(for: .milliseconds(25))
        t.setColumnShown(false)
        let hiddenChecks = t.checkRequest
        let hiddenRefreshes = t.refreshRequest
        t.armBlankWatch()
        t.armViewportRefresh()
        try? await Task.sleep(for: .milliseconds(380))
        precondition(t.checkRequest == hiddenChecks && t.refreshRequest == hiddenRefreshes)
        precondition(!t.refreshPending && t.endedActivity == 1)

        t.setColumnShown(true)
        try? await Task.sleep(for: .milliseconds(25))
        t.setColumnShown(false)
        t.setColumnShown(true)
        let returnChecks = t.checkRequest
        try? await Task.sleep(for: .milliseconds(380))
        precondition(t.refreshRequest == hiddenRefreshes + 1)
        precondition(t.checkRequest == returnChecks + 1)
        precondition(!t.refreshPending)
        t.setColumnShown(false)
        print("PASS: hidden/prebuilt suppression, visible repair, cancellation and rapid return")
    }
}
'''
OUT.mkdir(parents=True, exist_ok=True)
source = OUT / "Checks.swift"
source.write_text(swift)
binary = OUT / "checks"
subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-O", str(source), "-o", str(binary)], check=True, cwd=ROOT)
subprocess.run([str(binary)], check=True, cwd=ROOT)
