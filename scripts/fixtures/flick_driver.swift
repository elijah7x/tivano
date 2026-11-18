// Standalone HID trackpad-flick driver for TimelineStress `--history-flick`.
// Compile: swiftc -O scripts/fixtures/flick_driver.swift -o flick_driver
// Sign:    codesign --force --sign '<Developer ID Application identity>' --identifier dev.tivano.flick-driver flick_driver
// Usage:   flick_driver <run-dir> [--drift]

import CoreGraphics
import Foundation

struct ReadyPoint: Decodable {
    let x: Double
    let y: Double
}

struct ReadyRect: Decodable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

struct HistoryFlickReady: Decodable {
    let pid: Int32
    let windowNumber: Int
    let point: ReadyPoint
    let windowFrame: ReadyRect
    let upSign: Int32
    let viewport: Double
    let flicks: Int
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

let rawArgs = Array(CommandLine.arguments.dropFirst())
let runDirPath: String
let driftEnabled: Bool
switch rawArgs.count {
case 1 where rawArgs[0] != "--drift":
    runDirPath = rawArgs[0]
    driftEnabled = false
case 2 where rawArgs[1] == "--drift":
    runDirPath = rawArgs[0]
    driftEnabled = true
case 2 where rawArgs[0] == "--drift":
    runDirPath = rawArgs[1]
    driftEnabled = true
default:
    fputs("Usage: flick_driver <run-dir> [--drift]\n", stderr)
    exit(1)
}

guard CGPreflightPostEventAccess() else {
    fail("CGPreflightPostEventAccess() is false; run from a process authorized to post HID events")
}

let runDirURL = URL(fileURLWithPath: runDirPath, isDirectory: true)
let readyURL = runDirURL.appendingPathComponent("history-flick-ready.json")

logStage("wait-ready", "polling \(readyURL.path) up to 120s")
let driverStart = Date()
let waitDeadline = driverStart.addingTimeInterval(120.0)
var decodedReady: HistoryFlickReady?
while Date() < waitDeadline {
    // Ignore stale ready files left by an earlier run.
    if let data = try? Data(contentsOf: readyURL),
       let ready = try? JSONDecoder().decode(HistoryFlickReady.self, from: data),
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
guard ready.viewport > 0, ready.flicks > 0 else {
    fail("invalid viewport=\(ready.viewport) or flicks=\(ready.flicks) in \(readyURL.path)")
}

let timelinePoint = CGPoint(x: ready.point.x, y: ready.point.y)
// `windowFrame` and `point` are both in CG global display coordinates (top-left origin, +y downward),
// so ~40pt above the window's bottom edge sits at maxY - 40 inside the composer area.
let composerY = max(ready.windowFrame.y + 8.0, ready.windowFrame.y + ready.windowFrame.height - 40.0)
let composerPoint = CGPoint(x: ready.point.x, y: composerY)

logStage(
    "ready",
    String(
        format: "pid=%d window=%d point=(%.1f,%.1f) composerPoint=(%.1f,%.1f) upSign=%d viewport=%.1f flicks=%d drift=%@",
        ready.pid, ready.windowNumber,
        timelinePoint.x, timelinePoint.y,
        composerPoint.x, composerPoint.y,
        ready.upSign, ready.viewport, ready.flicks,
        driftEnabled ? "true" : "false"
    )
)

func targetStillUnderPoint(_ checkPoint: CGPoint) -> Bool {
    guard kill(ready.pid, 0) == 0,
          let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
    else { return false }
    // Front-to-back order: the first normal-layer window containing the point receives the event.
    for info in windows {
        guard (info[kCGWindowLayer as String] as? Int) == 0,
              let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: boundsDict),
              bounds.contains(checkPoint) else { continue }
        return (info[kCGWindowNumber as String] as? Int) == Int(ready.windowNumber)
            && (info[kCGWindowOwnerPID as String] as? Int32) == ready.pid
    }
    return false
}

func momentumMagnitudes(quarterViewport: Double, count: Int = 21, ratio: Double = 0.85) -> [Int32] {
    guard count > 0, quarterViewport > 0 else { return [] }
    var weights: [Double] = []
    weights.reserveCapacity(count)
    var current = 1.0
    var weightSum = 0.0
    for _ in 0..<count {
        weights.append(current)
        weightSum += current
        current *= ratio
    }
    var magnitudes: [Int32] = []
    magnitudes.reserveCapacity(count)
    var exactAccum = 0.0
    var intAccum = 0
    for weight in weights {
        exactAccum += quarterViewport * (weight / weightSum)
        let nextInt = Int(exactAccum.rounded())
        let step = max(1, nextInt - intAccum)
        magnitudes.append(Int32(step))
        intAccum += step
    }
    return magnitudes
}

let warpStatus = CGWarpMouseCursorPosition(timelinePoint)
let assocStatus = CGAssociateMouseAndMouseCursorPosition(1)
logStage("warp", "warpStatus=\(warpStatus.rawValue) associateStatus=\(assocStatus.rawValue)")
Thread.sleep(forTimeInterval: 0.3)

guard let eventSource = CGEventSource(stateID: .hidSystemState) else {
    fail("failed to create CGEventSource(.hidSystemState)")
}

func movePointer(to target: CGPoint) {
    guard targetStillUnderPoint(target) else {
        fail("capture window \(ready.windowNumber) of pid \(ready.pid) is no longer under (\(target.x), \(target.y)); stopping")
    }
    if let move = CGEvent(
        mouseEventSource: eventSource,
        mouseType: .mouseMoved,
        mouseCursorPosition: target,
        mouseButton: .left
    ) {
        move.post(tap: .cghidEventTap)
    }
}

@discardableResult
func postFlickWheel(deltaY: Int32, phase: Int64, momentumPhase: Int64, location: CGPoint) -> Bool {
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
    // Set coarse axis first, then pixel point and 16.16 fixed-point fields so continuous deltas stay exact.
    cg.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: Int64(deltaY / 10))
    cg.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(deltaY))
    cg.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: Double(deltaY))
    cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
    cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
    cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentumPhase)
    cg.location = location
    guard targetStillUnderPoint(location) else {
        fail("capture window \(ready.windowNumber) of pid \(ready.pid) is no longer under (\(location.x), \(location.y)); stopping")
    }
    cg.post(tap: .cghidEventTap)
    return true
}

let fingerStepMag = max(1, Int32((ready.viewport * 0.25 / 12.0).rounded()))
let fingerDelta = ready.upSign * fingerStepMag
let momMags = momentumMagnitudes(quarterViewport: ready.viewport * 0.25, count: 21, ratio: 0.85)
let momSumMag = momMags.reduce(Int32(0), +)
let perFlickMag = fingerStepMag * 12 + momSumMag

let tickInterval: TimeInterval = 0.008
let interFlickInterval: TimeInterval = 0.120

var totalEventsPosted = 0
var driftedFlicks = 0

for flickIndex in 1...ready.flicks {
    let driftThisFlick = driftEnabled && (flickIndex % 2 == 1)
    let activeLocation = driftThisFlick ? composerPoint : timelinePoint

    guard postFlickWheel(deltaY: 0, phase: 1, momentumPhase: 0, location: timelinePoint) else {
        fail("failed to post began event on flick \(flickIndex)")
    }
    totalEventsPosted += 1
    Thread.sleep(forTimeInterval: tickInterval)

    if driftThisFlick {
        driftedFlicks += 1
        movePointer(to: composerPoint)
    }

    for changedIdx in 1...12 {
        guard postFlickWheel(deltaY: fingerDelta, phase: 2, momentumPhase: 0, location: activeLocation) else {
            fail("failed to post changed #\(changedIdx) on flick \(flickIndex)")
        }
        totalEventsPosted += 1
        Thread.sleep(forTimeInterval: tickInterval)
    }

    guard postFlickWheel(deltaY: 0, phase: 4, momentumPhase: 0, location: activeLocation) else {
        fail("failed to post ended event on flick \(flickIndex)")
    }
    totalEventsPosted += 1
    Thread.sleep(forTimeInterval: tickInterval)

    if let firstMom = momMags.first {
        guard postFlickWheel(deltaY: ready.upSign * firstMom, phase: 0, momentumPhase: 1, location: activeLocation) else {
            fail("failed to post momentum begin on flick \(flickIndex)")
        }
        totalEventsPosted += 1
        Thread.sleep(forTimeInterval: tickInterval)

        for (contOffset, mag) in momMags.dropFirst().enumerated() {
            guard postFlickWheel(deltaY: ready.upSign * mag, phase: 0, momentumPhase: 2, location: activeLocation) else {
                fail("failed to post momentum continue #\(contOffset + 1) on flick \(flickIndex)")
            }
            totalEventsPosted += 1
            Thread.sleep(forTimeInterval: tickInterval)
        }
    }

    guard postFlickWheel(deltaY: 0, phase: 0, momentumPhase: 3, location: activeLocation) else {
        fail("failed to post momentum end on flick \(flickIndex)")
    }
    totalEventsPosted += 1

    if driftThisFlick {
        movePointer(to: timelinePoint)
    }

    if flickIndex < ready.flicks {
        Thread.sleep(forTimeInterval: interFlickInterval)
    }
}

logStage(
    "summary",
    "flicks=\(ready.flicks) driftedFlicks=\(driftedFlicks) eventsPosted=\(totalEventsPosted) fingerDelta=\(fingerDelta)ptx12 momentumDelta=\(ready.upSign * momSumMag)pt perFlick=\(ready.upSign * perFlickMag)pt drift=\(driftEnabled)"
)

exit(0)
