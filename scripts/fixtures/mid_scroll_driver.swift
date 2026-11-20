// Standalone HID bidirectional scroll driver for TimelineStress `--mid-scroll`.
// Compile: swiftc -O scripts/fixtures/mid_scroll_driver.swift -o mid_scroll_driver
// Sign:    codesign --force --sign '<Developer ID Application identity>' --identifier dev.tivano.mid-scroll-driver mid_scroll_driver
// Usage:   mid_scroll_driver <run-dir>

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

struct MidScrollReady: Decodable {
    let pid: Int32
    let windowNumber: Int
    let point: ReadyPoint
    let windowFrame: ReadyRect?
    let upSign: Int32
    let viewport: Double
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
    fputs("Usage: mid_scroll_driver <run-dir>\n", stderr)
    exit(1)
}

guard CGPreflightPostEventAccess() else {
    fail("CGPreflightPostEventAccess() is false; run from a process authorized to post HID events")
}

let runDirURL = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let readyURL = runDirURL.appendingPathComponent("mid-scroll-ready.json")

logStage("wait-ready", "polling \(readyURL.path) up to 120s")
let driverStart = Date()
let waitDeadline = driverStart.addingTimeInterval(120.0)
var decodedReady: MidScrollReady?
while Date() < waitDeadline {
    // Ignore stale ready files left by an earlier run.
    if let data = try? Data(contentsOf: readyURL),
       let ready = try? JSONDecoder().decode(MidScrollReady.self, from: data),
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
guard ready.viewport > 0 else {
    fail("invalid viewport=\(ready.viewport) in \(readyURL.path)")
}

let timelinePoint = CGPoint(x: ready.point.x, y: ready.point.y)
logStage(
    "ready",
    String(
        format: "pid=%d window=%d point=(%.1f,%.1f) upSign=%d viewport=%.1f",
        ready.pid, ready.windowNumber,
        timelinePoint.x, timelinePoint.y,
        ready.upSign, ready.viewport
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

@discardableResult
func postScrollWheel(deltaY: Int32, phase: Int64, momentumPhase: Int64, location: CGPoint) -> Bool {
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
let momMags = momentumMagnitudes(quarterViewport: ready.viewport * 0.25, count: 21, ratio: 0.85)
let momSumMag = momMags.reduce(Int32(0), +)
let perFlickMag = fingerStepMag * 12 + momSumMag
let dragStepCycle: [Int32] = [6, 7, 8, 9, 10]

let flickTickInterval: TimeInterval = 0.008
let dragTickInterval: TimeInterval = 0.016
let interGestureInterval: TimeInterval = 0.120

var totalEventsPosted = 0
var totalGesturesPosted = 0
var postedUpDelta: Int64 = 0
var postedDownDelta: Int64 = 0

func runFlicks(count: Int, directionSign: Int32, label: String, pauseAfterLast: Bool) {
    let isUp = directionSign == ready.upSign
    logStage("\(label)-start", "count=\(count) direction=\(isUp ? "up" : "down") perFlick=\(directionSign * perFlickMag)pt")
    let fingerDelta = directionSign * fingerStepMag
    for flickIndex in 1...count {
        guard postScrollWheel(deltaY: 0, phase: 1, momentumPhase: 0, location: timelinePoint) else {
            fail("failed to post began on \(label) #\(flickIndex)")
        }
        totalEventsPosted += 1
        totalGesturesPosted += 1
        Thread.sleep(forTimeInterval: flickTickInterval)

        for changedIdx in 1...12 {
            guard postScrollWheel(deltaY: fingerDelta, phase: 2, momentumPhase: 0, location: timelinePoint) else {
                fail("failed to post changed #\(changedIdx) on \(label) #\(flickIndex)")
            }
            totalEventsPosted += 1
            if isUp { postedUpDelta += Int64(fingerStepMag) } else { postedDownDelta += Int64(fingerStepMag) }
            Thread.sleep(forTimeInterval: flickTickInterval)
        }

        guard postScrollWheel(deltaY: 0, phase: 4, momentumPhase: 0, location: timelinePoint) else {
            fail("failed to post ended on \(label) #\(flickIndex)")
        }
        totalEventsPosted += 1
        Thread.sleep(forTimeInterval: flickTickInterval)

        if let firstMom = momMags.first {
            guard postScrollWheel(deltaY: directionSign * firstMom, phase: 0, momentumPhase: 1, location: timelinePoint) else {
                fail("failed to post momentum begin on \(label) #\(flickIndex)")
            }
            totalEventsPosted += 1
            if isUp { postedUpDelta += Int64(firstMom) } else { postedDownDelta += Int64(firstMom) }
            Thread.sleep(forTimeInterval: flickTickInterval)

            for (contOffset, mag) in momMags.dropFirst().enumerated() {
                guard postScrollWheel(deltaY: directionSign * mag, phase: 0, momentumPhase: 2, location: timelinePoint) else {
                    fail("failed to post momentum continue #\(contOffset + 1) on \(label) #\(flickIndex)")
                }
                totalEventsPosted += 1
                if isUp { postedUpDelta += Int64(mag) } else { postedDownDelta += Int64(mag) }
                Thread.sleep(forTimeInterval: flickTickInterval)
            }
        }

        guard postScrollWheel(deltaY: 0, phase: 0, momentumPhase: 3, location: timelinePoint) else {
            fail("failed to post momentum end on \(label) #\(flickIndex)")
        }
        totalEventsPosted += 1

        if flickIndex < count || pauseAfterLast {
            Thread.sleep(forTimeInterval: interGestureInterval)
        }
    }
    logStage("\(label)-end", "eventsPosted=\(totalEventsPosted) gesturesPosted=\(totalGesturesPosted)")
}

func runAlternatingSlowDrags(count: Int, label: String, pauseAfterLast: Bool) {
    logStage("\(label)-start", "count=\(count) steps=60 intervalMs=16 stepRange=6..10pt noMomentum=true")
    for dragIndex in 1...count {
        let isUp = dragIndex % 2 == 1
        let dirSign = isUp ? ready.upSign : -ready.upSign

        guard postScrollWheel(deltaY: 0, phase: 1, momentumPhase: 0, location: timelinePoint) else {
            fail("failed to post began on \(label) #\(dragIndex)")
        }
        totalEventsPosted += 1
        totalGesturesPosted += 1
        Thread.sleep(forTimeInterval: dragTickInterval)

        for changedIdx in 1...60 {
            let mag = dragStepCycle[(changedIdx - 1) % dragStepCycle.count]
            let delta = dirSign * mag
            guard postScrollWheel(deltaY: delta, phase: 2, momentumPhase: 0, location: timelinePoint) else {
                fail("failed to post changed #\(changedIdx) on \(label) #\(dragIndex)")
            }
            totalEventsPosted += 1
            if isUp { postedUpDelta += Int64(mag) } else { postedDownDelta += Int64(mag) }
            Thread.sleep(forTimeInterval: dragTickInterval)
        }

        guard postScrollWheel(deltaY: 0, phase: 4, momentumPhase: 0, location: timelinePoint) else {
            fail("failed to post ended on \(label) #\(dragIndex)")
        }
        totalEventsPosted += 1

        if dragIndex < count || pauseAfterLast {
            Thread.sleep(forTimeInterval: interGestureInterval)
        }
    }
    logStage("\(label)-end", "eventsPosted=\(totalEventsPosted) gesturesPosted=\(totalGesturesPosted)")
}

// Script: 20 flicks up -> 20 flicks down -> 10 alternating slow held drags -> 20 flicks up -> 20 flicks down.
runFlicks(count: 20, directionSign: ready.upSign, label: "stage-1-flicks-up", pauseAfterLast: true)
runFlicks(count: 20, directionSign: -ready.upSign, label: "stage-2-flicks-down", pauseAfterLast: true)
runAlternatingSlowDrags(count: 10, label: "stage-3-held-drags", pauseAfterLast: true)
runFlicks(count: 20, directionSign: ready.upSign, label: "stage-4-flicks-up", pauseAfterLast: true)
runFlicks(count: 20, directionSign: -ready.upSign, label: "stage-5-flicks-down", pauseAfterLast: false)

logStage(
    "summary",
    "gestures=\(totalGesturesPosted) eventsPosted=\(totalEventsPosted) postedUpDelta=\(postedUpDelta)pt postedDownDelta=\(postedDownDelta)pt fingerDelta=\(fingerStepMag)ptx12 momentumDelta=\(momSumMag)pt perFlick=\(perFlickMag)pt"
)

exit(0)
