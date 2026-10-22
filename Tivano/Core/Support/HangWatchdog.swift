import Darwin
import Foundation
import os

/// Catches the main thread standing still, and keeps what it was doing.
///
/// A freeze that ends in a force quit leaves nothing behind: the Dock asks spindump for a
/// hang report, spindump declines for a development build, and the crash reporter never
/// sees a process that was killed rather than crashed. So the app watches itself. A thread
/// of its own pings the main thread twice a second; when a ping goes unanswered for
/// `stallThreshold`, it runs `sample` on the process and writes every thread's stack to
/// `~/Library/Logs/Tivano/hang-<date>.txt`. `sample` reads the stacks from outside,
/// so a main thread stuck in a loop or a lock is exactly what it captures. One report per
/// stall; the next stall gets one of its own.
/// SwiftUI can also livelock, keeping the main thread busy while starving user input.
/// A ping alone cannot detect this because the main queue still answers between layout passes.
///
/// This costs a timer on a background thread and a block on the main queue every half
/// second, plus a main-thread CPU time read, so it stays on in every build.
enum HangWatchdog {
    private static let log = Logger(subsystem: "dev.tivano.Tivano", category: "hang")

    /// How long the main thread may go without answering before it counts as stuck. Long
    /// enough that a heavy but finite piece of work (a big diff, a slow layout pass) does
    /// not set off a report, short enough that a real freeze is caught well before the
    /// user reaches for Force Quit.
    private static let stallThreshold: TimeInterval = 4

    /// Minimum main-thread CPU fraction that counts as continuously busy.
    private static let busyFraction = 0.9

    /// How long the main thread must stay busy before a report is written.
    private static let busyThreshold: TimeInterval = 8

    /// How long `sample` watches the process. Short: a stuck thread does not move, and a
    /// long sample only delays the write.
    private static let sampleSeconds = 2

    /// Reports kept before the oldest is dropped, so a machine that freezes often does not
    /// fill its logs folder.
    private static let keptReports = 10

    private static let state = OSAllocatedUnfairLock(initialState: State())

    private struct State {
        /// System uptime, which stands still while the Mac sleeps, so a sleep is never a stall.
        var lastPong = ProcessInfo.processInfo.systemUptime
        var reportedThisStall = false
        var started = false
        var mainThreadPort: thread_act_t = 0
    }

    private struct BusyState {
        var lastCPUTime: TimeInterval?
        var lastWallTime: TimeInterval?
        var busySince: TimeInterval?
        var reportedThisBusy = false
    }

    static func start() {
        dispatchPrecondition(condition: .onQueue(.main))
        let shouldStart = state.withLock { state -> Bool in
            if state.started { return false }
            state.started = true
            state.mainThreadPort = mach_thread_self()
            state.lastPong = ProcessInfo.processInfo.systemUptime
            return true
        }
        guard shouldStart else { return }
        let thread = Thread {
            var busy = BusyState()
            while true {
                Thread.sleep(forTimeInterval: 0.5)
                ping()
                check()
                checkBusy(&busy)
            }
        }
        thread.name = "hang-watchdog"
        thread.qualityOfService = .utility
        thread.start()
    }

    private static func ping() {
        DispatchQueue.main.async {
            state.withLock { state in
                state.lastPong = ProcessInfo.processInfo.systemUptime
                state.reportedThisStall = false
            }
        }
    }

    private static func check() {
        let stalledFor = state.withLock { state -> TimeInterval? in
            let stalled = ProcessInfo.processInfo.systemUptime - state.lastPong
            guard stalled >= stallThreshold, !state.reportedThisStall else { return nil }
            state.reportedThisStall = true
            return stalled
        }
        guard let stalledFor else { return }
        log.error("Main thread unresponsive for \(stalledFor, format: .fixed(precision: 1))s, sampling")
        writeReport(headline: "Tivano main thread unresponsive for \(String(format: "%.1f", stalledFor))s")
    }

    private static func mainThreadCPUTime() -> TimeInterval? {
        let port = state.withLock { $0.mainThreadPort }
        var info = thread_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { pointer in
                thread_info(port, thread_flavor_t(THREAD_BASIC_INFO), pointer, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return TimeInterval(info.user_time.seconds) + TimeInterval(info.system_time.seconds)
            + (TimeInterval(info.user_time.microseconds) + TimeInterval(info.system_time.microseconds)) / 1_000_000
    }

    private static func checkBusy(_ busy: inout BusyState) {
        guard let cpuTime = mainThreadCPUTime() else {
            busy = BusyState()
            return
        }
        let wallTime = ProcessInfo.processInfo.systemUptime
        defer {
            busy.lastCPUTime = cpuTime
            busy.lastWallTime = wallTime
        }
        guard let lastCPUTime = busy.lastCPUTime, let lastWallTime = busy.lastWallTime else { return }
        let elapsed = wallTime - lastWallTime
        guard elapsed > 0 else { return }
        let fraction = (cpuTime - lastCPUTime) / elapsed
        guard fraction >= busyFraction else {
            busy.busySince = nil
            busy.reportedThisBusy = false
            return
        }
        if busy.busySince == nil { busy.busySince = lastWallTime }
        guard let busySince = busy.busySince else { return }
        let busyFor = wallTime - busySince
        guard busyFor >= busyThreshold, !busy.reportedThisBusy else { return }
        busy.reportedThisBusy = true
        log.error("Main thread busy for \(busyFor, format: .fixed(precision: 1))s without a break, sampling")
        writeReport(headline: "Tivano main thread busy for \(String(format: "%.1f", busyFor))s at \(String(format: "%.0f", fraction * 100))% CPU (livelock: the main queue still answers, input does not)")
    }

    /// Runs `sample` against this process and writes what it saw. Runs on the watchdog's
    /// own thread, never the main one, so a stuck main thread cannot stop the report.
    private static func writeReport(headline: String) {
        let folder = reportsFolder()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stamp = ISO8601.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let file = folder.appendingPathComponent("hang-\(stamp).txt")

        var header = "\(headline)\n"
        header += "Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?") (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"))\n"
        header += "Sampled at \(Date())\n\n"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
        process.arguments = [String(ProcessInfo.processInfo.processIdentifier), String(sampleSeconds), "-mayDie"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        var body = ""
        do {
            try process.run()
            DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(sampleSeconds + 30)) {
                if process.isRunning { process.terminate() }
            }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            body = String(decoding: data, as: UTF8.self)
            if process.terminationStatus != 0 {
                body = "sample exited with status \(process.terminationStatus)\n\n" + body
            }
        } catch {
            body = "sample could not run: \(error.localizedDescription)\n"
        }
        try? (header + body).write(to: file, atomically: true, encoding: .utf8)
        log.error("Hang report written to \(file.path, privacy: .public)")
        trimReports(in: folder)
    }

    private static func reportsFolder() -> URL {
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library")
        return library.appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent(AppInfo.libraryName, isDirectory: true)
    }

    private static func trimReports(in folder: URL) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return }
        let reports = names.filter { $0.hasPrefix("hang-") && $0.hasSuffix(".txt") }.sorted()
        guard reports.count > keptReports else { return }
        for name in reports.prefix(reports.count - keptReports) {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
    }
}
