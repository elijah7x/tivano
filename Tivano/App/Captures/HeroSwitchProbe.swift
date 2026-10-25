#if DEBUG
import AppKit
import CoreFoundation
import Darwin
import QuartzCore
import Synchronization

@MainActor
enum HeroSwitchProbe {
    static var isColdRequested: Bool { CaptureRun.isEnabled && CommandLine.arguments.contains("--cold-switch-probe") }

    static var isRequested: Bool {
        CaptureRun.isEnabled && (CommandLine.arguments.contains("--hero-switch-probe")
            || CommandLine.arguments.contains("--cold-switch-probe"))
    }

    static let longThreadIDs: [UUID] = [
        UUID(uuidString: "C0000000-0000-4000-8000-000000000001")!,
        UUID(uuidString: "C0000000-0000-4000-8000-000000000002")!,
        UUID(uuidString: "C0000000-0000-4000-8000-000000000003")!,
        UUID(uuidString: "C0000000-0000-4000-8000-000000000004")!,
        UUID(uuidString: "C0000000-0000-4000-8000-000000000005")!,
        UUID(uuidString: "C0000000-0000-4000-8000-000000000006")!,
    ]

    private static var terminationDeadline: DispatchSourceTimer?

    static func run(model: AppModel) async {
        guard isRequested, let output = CaptureRun.outputDirectory else { return }
        let report = ReportStore()
        let destination = output.appendingPathComponent("hero-switch-probe.json")
        report.write(to: destination, timedOut: false)
        let deadline = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        deadline.schedule(wallDeadline: .now() + 120)
        deadline.setEventHandler {
            report.write(to: destination, timedOut: true)
            _exit(124)
        }
        terminationDeadline = deadline
        deadline.resume()

        await model.bootstrap()
        model.settings.hasSeenHydraIntro = true
        let window = WindowManager.shared.makeCaptureWindow(size: NSSize(width: 1100, height: 720))
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if !model.sidebar.isVisible { model.sidebar.toggle() }
        let monitor = HitchMonitor(report: report)
        // NSWindow's display link follows the display containing this window.
        // https://developer.apple.com/documentation/appkit/nswindow/displaylink(target:selector:)
        let displayLink = window.displayLink(target: monitor, selector: #selector(HitchMonitor.tick(_:)))
        displayLink.add(to: .main, forMode: .common)
        try? await Task.sleep(for: .seconds(3))

        let ids = Array(model.threads.filter { !$0.isArchived && !$0.isHydraHead }.prefix(6).map(\.id))
        report.state.withLock { $0.threadIDs = (isColdRequested ? longThreadIDs : ids).map(\.uuidString) }
        if isColdRequested {
            monitor.begin("cold")
            for id in longThreadIDs {
                await measure("cold", action: id.uuidString, report: report) { model.openThread(id) }
                try? await Task.sleep(for: .milliseconds(600))
            }
            monitor.end()
            monitor.begin("warm")
            for id in longThreadIDs {
                await measure("warm", action: id.uuidString, report: report) { model.openThread(id) }
                try? await Task.sleep(for: .milliseconds(600))
            }
            monitor.end()
            displayLink.invalidate()
            report.state.withLock { $0.completed = true }
            report.write(to: destination, timedOut: false)
            exit(0)
        }
        monitor.begin("switch")
        if ids.isEmpty {
            report.state.withLock { $0.error = "No eligible capture threads; switch phase skipped" }
        } else {
            for index in 0..<40 {
                let id = ids[index % ids.count]
                await measure("switch", action: id.uuidString, report: report) { model.openThread(id) }
                try? await Task.sleep(for: .milliseconds(400))
            }
        }
        monitor.end()
        monitor.begin("settings")
        for _ in 0..<10 {
            await measure("settings", action: "open", report: report) { WindowManager.shared.showSettings() }
            try? await Task.sleep(for: .milliseconds(600))
            await measure("settings", action: "close", report: report) { WindowManager.shared.hideSettings() }
            try? await Task.sleep(for: .milliseconds(600))
        }
        monitor.end()
        displayLink.invalidate()
        report.state.withLock { $0.completed = true }
        report.write(to: destination, timedOut: false)
        exit(0)
    }

    private static func measure(_ phase: String, action: String, report: ReportStore, operation: () -> Void) async {
        let start = CACurrentMediaTime()
        operation()
        let sync = (CACurrentMediaTime() - start) * 1000
        report.state.withLock {
            $0.phases[phase, default: Phase()].actions.append(action)
            $0.phases[phase, default: Phase()].syncMilliseconds.append(sync)
        }
        let settled: Double = await withCheckedContinuation { continuation in
            CATransaction.flush()
            // repeats=false invalidates after the first beforeWaiting callback.
            // https://developer.apple.com/documentation/corefoundation/cfrunloopobservercreate
            let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, false, 0) { _, _ in
                continuation.resume(returning: CACurrentMediaTime())
            }
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        }
        report.state.withLock {
            $0.phases[phase, default: Phase()].settleMilliseconds.append((settled - start) * 1000)
        }
    }

    private final class HitchMonitor: NSObject {
        let report: ReportStore
        var phase: String?
        var previous: Double?

        init(report: ReportStore) { self.report = report }

        func begin(_ name: String) {
            phase = name
            previous = CACurrentMediaTime()
            let cpu = processCPUTime()
            report.state.withLock { $0.phases[name, default: Phase()].cpuStartSeconds = cpu }
        }

        func end() {
            guard let phase else { return }
            let cpu = processCPUTime()
            report.state.withLock { $0.phases[phase, default: Phase()].cpuEndSeconds = cpu }
            self.phase = nil
            previous = nil
        }

        @objc func tick(_ link: CADisplayLink) {
            // Callback arrival time includes main-thread stalls, unlike nominal frame duration.
            let now = CACurrentMediaTime()
            defer { previous = now }
            guard let previous else { return }
            let interval = (now - previous) * 1000
            report.state.withLock {
                $0.wholeRunHitches.record(interval)
                if let phase { $0.phases[phase, default: Phase()].hitches.record(interval) }
            }
        }
    }

    private struct Hitches: Codable, Sendable {
        var over25Milliseconds = 0
        var over50Milliseconds = 0
        var over100Milliseconds = 0
        var maxFrameIntervalMilliseconds = 0.0
        var intervals = 0

        mutating func record(_ milliseconds: Double) {
            intervals += 1
            if milliseconds > 25 { over25Milliseconds += 1 }
            if milliseconds > 50 { over50Milliseconds += 1 }
            if milliseconds > 100 { over100Milliseconds += 1 }
            maxFrameIntervalMilliseconds = max(maxFrameIntervalMilliseconds, milliseconds)
        }
    }

    private struct Summary: Codable, Sendable {
        let p50: Double?
        let p90: Double?
        let max: Double?

        init(_ values: [Double]) {
            let sorted = values.sorted()
            p50 = sorted.isEmpty ? nil : sorted[Int(ceil(Double(sorted.count) * 0.5)) - 1]
            p90 = sorted.isEmpty ? nil : sorted[Int(ceil(Double(sorted.count) * 0.9)) - 1]
            max = sorted.last
        }
    }

    private struct Phase: Codable, Sendable {
        var actions: [String] = []
        var syncMilliseconds: [Double] = []
        var settleMilliseconds: [Double] = []
        var syncSummary = Summary([])
        var settleSummary = Summary([])
        var hitches = Hitches()
        var cpuStartSeconds: Double?
        var cpuEndSeconds: Double?
        var cpuSeconds: Double?
    }

    private struct Report: Codable, Sendable {
        var heroOff = CommandLine.arguments.contains("--hero-off")
        var debugAssertConfiguration = _isDebugAssertConfiguration()
        var executablePath = Bundle.main.executableURL?.path ?? CommandLine.arguments[0]
        var timedOut = false
        var completed = false
        var error: String?
        var threadIDs: [String] = []
        var phases: [String: Phase] = ["switch": Phase(), "settings": Phase()]
        var wholeRunHitches = Hitches()
        var measurementScope = "settle is elapsed time from navigation to the next main-run-loop beforeWaiting after CATransaction.flush, not animation completion; frame intervals are display-link callback arrival intervals; CPU is process user+system time including phase waits"
    }

    private final class ReportStore: Sendable {
        let state = Mutex(Report())

        nonisolated func write(to url: URL, timedOut: Bool) {
            var snapshot = state.withLock { $0 }
            snapshot.timedOut = timedOut
            for name in Array(snapshot.phases.keys) {
                guard var phase = snapshot.phases[name] else { continue }
                phase.syncSummary = Summary(phase.syncMilliseconds)
                phase.settleSummary = Summary(phase.settleMilliseconds)
                if let start = phase.cpuStartSeconds {
                    let end = phase.cpuEndSeconds ?? processCPUTime()
                    phase.cpuSeconds = end.map { $0 - start }
                }
                snapshot.phases[name] = phase
            }
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(snapshot).write(to: url, options: .atomic)
            } catch {
                WebsiteCaptures.log("hero-switch-probe report write failed: \(error)")
            }
        }
    }

    nonisolated private static func processCPUTime() -> Double? {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return nil }
        return Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000
            + Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000
    }
}
#endif
