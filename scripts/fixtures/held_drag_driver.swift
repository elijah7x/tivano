// Standalone HID scroll-wheel driver for TimelineStress `--held-drag` / `--held-drag-hid`.
// Compile: swiftc -O held_drag_driver.swift -o held_drag_driver
// Usage:   held_drag_driver <run-dir>

import CoreGraphics
import Foundation

struct ReadyPoint: Decodable {
    let x: Double
    let y: Double
}

struct HeldDragReady: Decodable {
    let pid: Int32
    let windowNumber: Int
    let point: ReadyPoint
    let upSign: Int32
    let readyAt: Double?
    let readyAtWallClock: Double?
}

private func wallTimestamp() -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: Date())
}

private func logStage(_ stage: String, _ detail: String = "") {
    let suffix = detail.isEmpty ? "" : " \(detail)"
    print("[\(wallTimestamp())] \(stage)\(suffix)")
    fflush(stdout)
}

private func fail(_ message: String) -> Never {
    fputs("[\(wallTimestamp())] ERROR: \(message)\n", stderr)
    fflush(stderr)
    exit(1)
}

guard CommandLine.arguments.count == 2 else {
    fputs("Usage: held_drag_driver <run-dir>\n", stderr)
    exit(1)
}

guard CGPreflightPostEventAccess() else {
    fail("CGPreflightPostEventAccess() is false; run from a process authorized to post HID events")
}

let runDirURL = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let readyURL = runDirURL.appendingPathComponent("held-drag-ready.json")

logStage("wait-ready", "polling \(readyURL.path) up to 120s")
let driverStart = Date()
let waitDeadline = driverStart.addingTimeInterval(120.0)
var decodedReady: HeldDragReady?
while Date() < waitDeadline {
    // A ready file left by an earlier run is ignored: its app is gone and the point may now
    // belong to another app.
    if let data = try? Data(contentsOf: readyURL),
       let ready = try? JSONDecoder().decode(HeldDragReady.self, from: data),
       let wallClock = ready.readyAtWallClock,
       wallClock >= driverStart.timeIntervalSince1970 - 30 {
        decodedReady = ready
        break
    }
    Thread.sleep(forTimeInterval: 0.05)
}

guard let ready = decodedReady else {
    fail("timed out after 120s waiting for \(readyURL.path)")
}
guard ready.upSign == 1 || ready.upSign == -1 else {
    fail("invalid upSign=\(ready.upSign) in \(readyURL.path)")
}

let point = CGPoint(x: ready.point.x, y: ready.point.y)
logStage(
    "ready",
    String(
        format: "pid=%d window=%d point=(%.1f,%.1f) upSign=%d",
        ready.pid, ready.windowNumber, point.x, point.y, ready.upSign
    )
)

func targetStillUnderPoint() -> Bool {
    guard kill(ready.pid, 0) == 0,
          let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
    else { return false }
    // Front-to-back order: the first normal-layer window containing the point receives the event.
    for info in windows {
        guard (info[kCGWindowLayer as String] as? Int) == 0,
              let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: boundsDict),
              bounds.contains(point) else { continue }
        return (info[kCGWindowNumber as String] as? Int) == Int(ready.windowNumber)
            && (info[kCGWindowOwnerPID as String] as? Int32) == ready.pid
    }
    return false
}

let warpStatus = CGWarpMouseCursorPosition(point)
let assocStatus = CGAssociateMouseAndMouseCursorPosition(1)
logStage("warp", "warpStatus=\(warpStatus.rawValue) associateStatus=\(assocStatus.rawValue)")
Thread.sleep(forTimeInterval: 0.3)

guard let eventSource = CGEventSource(stateID: .hidSystemState) else {
    fail("failed to create CGEventSource(.hidSystemState)")
}

@discardableResult
func postPhasedWheel(deltaY: Int32, phase: Int64) -> Bool {
    guard let cg = CGEvent(
        scrollWheelEvent2Source: eventSource,
        units: .pixel,
        wheelCount: 1,
        wheel1: deltaY,
        wheel2: 0,
        wheel3: 0
    ) else {
        return false
    }
    cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
    cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: 0)
    cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
    cg.location = point
    // HID events go to whatever window is under the point: post only while the capture
    // app's window is still the frontmost one there.
    guard targetStillUnderPoint() else { fail("capture window \(ready.windowNumber) of pid \(ready.pid) is no longer under the point; stopping") }
    cg.post(tap: .cghidEventTap)
    return true
}

guard postPhasedWheel(deltaY: 0, phase: 128) else {
    fail("failed to build/post mayBegin scrollWheel event")
}
logStage("mayBegin", "phase=128 deltaY=0")
Thread.sleep(forTimeInterval: 0.016)

guard postPhasedWheel(deltaY: 0, phase: 1) else {
    fail("failed to build/post began scrollWheel event")
}
logStage("began", "phase=1 deltaY=0")
Thread.sleep(forTimeInterval: 0.016)

let dragDelta = ready.upSign * 1
// HELD_DRAG_INTERVAL_MS slows the drag; ~120ms keeps a whole hold under 48pt, the slow
// press-and-drag that used to stay inside the old follow band.
let dragInterval = (ProcessInfo.processInfo.environment["HELD_DRAG_INTERVAL_MS"].flatMap(Double.init) ?? 16) / 1000

logStage("drag1-start", "phase=2 deltaY=\(dragDelta) duration=1.5s interval=\(Int(dragInterval * 1000))ms")
var drag1Count = 0
let drag1End = Date().addingTimeInterval(1.5)
while Date() < drag1End {
    guard postPhasedWheel(deltaY: dragDelta, phase: 2) else {
        fail("failed to build/post drag1 changed scrollWheel event")
    }
    drag1Count += 1
    Thread.sleep(forTimeInterval: dragInterval)
}
logStage("drag1-end", "events=\(drag1Count)")

logStage("pause-start", "duration=3.0s no-events")
Thread.sleep(forTimeInterval: 3.0)
logStage("pause-end")

logStage("drag2-start", "phase=2 deltaY=\(dragDelta) duration=1.5s interval=\(Int(dragInterval * 1000))ms")
var drag2Count = 0
let drag2End = Date().addingTimeInterval(1.5)
while Date() < drag2End {
    guard postPhasedWheel(deltaY: dragDelta, phase: 2) else {
        fail("failed to build/post drag2 changed scrollWheel event")
    }
    drag2Count += 1
    Thread.sleep(forTimeInterval: dragInterval)
}
logStage("drag2-end", "events=\(drag2Count)")

guard postPhasedWheel(deltaY: 0, phase: 4) else {
    fail("failed to build/post ended scrollWheel event")
}
logStage("ended", "phase=4 deltaY=0")

exit(0)
