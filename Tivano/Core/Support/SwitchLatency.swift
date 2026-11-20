import Foundation
import os

/// Logs how long the main thread stays busy after a thread is selected, in the Dev and Preview apps:
/// the span from the selection to the run loop's next sleep (what the click waits on), then
/// the busy total over the following second. Archiving a thread opens a window too, folding
/// any neighbor switch inside it into the same label. Read with
/// `log stream --predicate 'subsystem == "dev.tivano.Tivano" && category == "switch"'`.
/// Each switch or archive is also a point of interest, so an Instruments trace can be cut at it.
@MainActor
enum SwitchLatency {
    private static let log = Logger(subsystem: "dev.tivano.Tivano", category: "switch")
    private static let pointsOfInterest = OSLog(subsystem: "dev.tivano.Tivano", category: .pointsOfInterest)
    private static var switchStart: CFAbsoluteTime = 0
    private static var busySince: CFAbsoluteTime = 0
    private static var firstSpan: Double?
    private static var busyTotal: Double = 0
    private static var label = ""
    private static var actionOpen = false
    private static var observer: CFRunLoopObserver?

    static var isActive: Bool { observer != nil }

    static func ms(_ duration: Duration) -> String {
        let components = duration.components
        let value = Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15
        return String(format: "%.1f", value)
    }

    static func start() {
        guard AppInfo.isDevelopment || AppInfo.isPreview, observer == nil else { return }
        let activities = CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue
        observer = CFRunLoopObserverCreateWithHandler(nil, activities, true, 0) { _, activity in
            let now = CFAbsoluteTimeGetCurrent()
            if activity == .afterWaiting {
                busySince = now
                return
            }
            guard switchStart > 0 else { return }
            let span = (now - max(busySince, switchStart)) * 1000
            if firstSpan == nil { firstSpan = span }
            busyTotal += span
            if now - switchStart >= 1 {
                log.notice("switch to \(label, privacy: .public): blocked \(Int(firstSpan ?? 0)) ms, busy \(Int(busyTotal)) ms in 1 s")
                switchStart = 0
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }

    /// A line beside the switch timings, in the dev app only.
    static func note(_ message: String) {
        guard observer != nil else { return }
        log.notice("\(message, privacy: .public)")
    }

    /// The selection just changed: the next spans are its cost.
    static func noteSwitch(to title: String) {
        guard observer != nil else { return }
        if actionOpen {
            label = String((label + " → " + title.prefix(24)).prefix(64))
            return
        }
        if switchStart > 0 { log.notice("switch to \(label, privacy: .public): blocked \(Int(firstSpan ?? 0)) ms, busy \(Int(busyTotal)) ms before the next switch") }
        os_signpost(.event, log: pointsOfInterest, name: "switch", "%{public}s", title)
        switchStart = CFAbsoluteTimeGetCurrent()
        busySince = switchStart
        firstSpan = nil
        busyTotal = 0
        label = String(title.prefix(24))
    }

    static func beginAction(_ label: String) {
        guard observer != nil else { return }
        if switchStart > 0 { log.notice("switch to \(Self.label, privacy: .public): blocked \(Int(firstSpan ?? 0)) ms, busy \(Int(busyTotal)) ms before the next switch") }
        os_signpost(.event, log: pointsOfInterest, name: "archive", "%{public}s", label)
        switchStart = CFAbsoluteTimeGetCurrent()
        busySince = switchStart
        firstSpan = nil
        busyTotal = 0
        Self.label = String(label.prefix(40))
        actionOpen = true
    }

    static func endAction() {
        actionOpen = false
    }
}
