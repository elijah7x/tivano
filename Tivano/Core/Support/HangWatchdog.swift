import Darwin
import Foundation
import os

/// Catches the main thread standing still, and keeps what it was doing.
///
/// A freeze that ends in a force quit leaves nothing behind: the Dock asks spindump for a
/// hang report, spindump declines for a development build, and the crash reporter never
/// sees a process that was killed rather than crashed. So the app watches itself. A thread
/// of its own checks the main thread twice a second; when an outstanding ping goes
/// unanswered for `stallThreshold` from when it was sent, it runs `sample` on the process
/// and writes every thread's stack to `~/Library/Logs/Tivano/hang-<date>.txt`.
/// `sample` reads the stacks from outside,
/// so a main thread stuck in a loop or a lock is exactly what it captures. One report per
/// stall, with reports rate-limited to at most one per `minReportInterval` after the last
/// report finishes.
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

    /// Caps how often `sample` can run against the app.
    private static let minReportInterval: TimeInterval = 60

    /// Reports kept before the oldest is dropped, so a machine that freezes often does not
    /// fill its logs folder.
    private static let keptReports = 10
    private static let reportByteLimit: Int64 = 20 * 1_024 * 1_024
    private static let reportMaxAge: TimeInterval = 30 * 24 * 60 * 60
    // Disk work never holds the ping lock, and sampling never holds this lock.
    private static let reportsLock = NSLock()

    private static let state = OSAllocatedUnfairLock(initialState: State())

    private struct State {
        /// System uptime, which stands still while the Mac sleeps, so a sleep is never a stall.
        var pingSentAt: TimeInterval?
        var reportedThisStall = false
        var nextReportAllowed: TimeInterval = 0
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
            return true
        }
        guard shouldStart else { return }
        let thread = Thread {
            maintainReports()
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
        state.withLock { state in
            guard state.pingSentAt == nil else { return }
            state.pingSentAt = ProcessInfo.processInfo.systemUptime
            DispatchQueue.main.async {
                self.state.withLock { state in
                    state.pingSentAt = nil
                    state.reportedThisStall = false
                }
            }
        }
    }

    private static func check() {
        let stalledFor = state.withLock { state -> TimeInterval? in
            guard let pingSentAt = state.pingSentAt else { return nil }
            let now = ProcessInfo.processInfo.systemUptime
            let stalled = now - pingSentAt
            guard stalled >= stallThreshold, !state.reportedThisStall else { return nil }
            guard now >= state.nextReportAllowed else { return nil }
            state.reportedThisStall = true
            return stalled
        }
        guard let stalledFor else { return }
        log.error("Main thread unresponsive for \(stalledFor, format: .fixed(precision: 1))s, sampling")
        writeReport(headline: "Tivano main thread unresponsive for \(String(format: "%.1f", stalledFor))s")
        state.withLock { $0.nextReportAllowed = ProcessInfo.processInfo.systemUptime + minReportInterval }
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
        var baselineCPUTime: TimeInterval? = cpuTime
        var wallTime = ProcessInfo.processInfo.systemUptime
        defer {
            busy.lastCPUTime = baselineCPUTime
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
        let measuredAt = wallTime
        guard state.withLock({ measuredAt >= $0.nextReportAllowed }) else { return }
        busy.reportedThisBusy = true
        log.error("Main thread busy for \(busyFor, format: .fixed(precision: 1))s without a break, sampling")
        writeReport(headline: "Tivano main thread busy for \(String(format: "%.1f", busyFor))s at \(String(format: "%.0f", fraction * 100))% CPU (livelock: the main queue still answers, input does not)")
        state.withLock { $0.nextReportAllowed = ProcessInfo.processInfo.systemUptime + minReportInterval }
        baselineCPUTime = mainThreadCPUTime()
        wallTime = ProcessInfo.processInfo.systemUptime
    }

    /// Runs `sample` against this process and writes what it saw. Runs on the watchdog's
    /// own thread, never the main one, so a stuck main thread cannot stop the report.
    private static func writeReport(headline: String) {
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
        do {
            try reportsLock.withLock {
                guard let directory = try DiagnosticDirectory.open(reportsFolder(), create: true) else { return }
                let stamp = ISO8601.string(from: Date()).replacingOccurrences(of: ":", with: "-")
                let name = "hang-\(stamp).txt"
                let temporary = ".hang-\(UUID().uuidString).tmp"
                // Only a closed, fully written report becomes a cleanup candidate.
                try directory.writeNew(temporary, data: Data((header + body).utf8))
                guard let file = try directory.file(temporary) else { throw DiagnosticDirectory.failure(ENOENT) }
                do { try directory.move(file, to: name) }
                catch {
                    try? directory.remove(file)
                    throw error
                }
                log.error("Hang report written to \(reportsFolder().appendingPathComponent(name).path, privacy: .public)")
                try trimReports(in: directory)
            }
        } catch {
            log.error("Could not save or retain hang reports: \(error.localizedDescription, privacy: .public)")
        }
    }

    static func measureDiagnostics() throws -> RuntimeStorageUsage {
        try reportsLock.withLock {
            guard let directory = try DiagnosticDirectory.open(reportsFolder()) else { return RuntimeStorageUsage() }
            let reports = try completedReports(in: directory)
            return RuntimeStorageUsage(totalBytes: try DiagnosticDirectory.totalBytes(reports),
                                       cleanableBytes: try DiagnosticDirectory.totalBytes(Array(reports.dropFirst())))
        }
    }

    static func clearDiagnostics() throws {
        try reportsLock.withLock {
            guard let directory = try DiagnosticDirectory.open(reportsFolder()) else { return }
            for report in try completedReports(in: directory).dropFirst() {
                try directory.remove(report)
            }
        }
    }

    private static func reportsFolder() -> URL {
        if let root = CaptureRun.storageRoot {
            return root.appendingPathComponent("logs", isDirectory: true)
        }
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library")
        return library.appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent(AppInfo.libraryName, isDirectory: true)
    }

    private static func completedReports(in directory: DiagnosticDirectory) throws -> [DiagnosticDirectory.File] {
        var reports: [DiagnosticDirectory.File] = []
        for name in try directory.names() {
            guard name.hasPrefix("hang-"), name.hasSuffix(".txt") else { continue }
            let stamp = String(name.dropFirst(5).dropLast(4))
            let parts = stamp.split(separator: "T")
            guard parts.count == 2,
                  let date = ISO8601.date(from: String(parts[0]) + "T" + String(parts[1]).replacingOccurrences(of: "-", with: ":")),
                  ISO8601.string(from: date).replacingOccurrences(of: ":", with: "-") == stamp else { continue }
            if let file = try directory.file(name, skipNonRegular: true) { reports.append(file) }
        }
        return reports.sorted { $0.modified == $1.modified ? $0.name > $1.name : $0.modified > $1.modified }
    }

    private static func maintainReports() {
        do {
            try reportsLock.withLock {
                guard let directory = try DiagnosticDirectory.open(reportsFolder()) else { return }
                try trimReports(in: directory)
            }
        } catch {
            log.error("Could not retain hang reports: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func trimReports(in directory: DiagnosticDirectory) throws {
        let reports = try completedReports(in: directory)
        var bytes = try DiagnosticDirectory.totalBytes(reports)
        var count = reports.count
        let cutoff = Date().addingTimeInterval(-reportMaxAge)
        for report in reports.reversed() {
            if report.modified < cutoff || count > keptReports || bytes > reportByteLimit {
                try directory.remove(report)
                bytes -= report.size
                count -= 1
            }
        }
    }
}

/// Descriptor-relative I/O keeps diagnostic maintenance out of symlinked ancestors.
/// Callers serialize access; this never enumerates or removes a directory recursively.
final class DiagnosticDirectory {
    struct File: Equatable {
        let name: String
        let size: Int64
        let modified: Date
        let device: dev_t
        let inode: ino_t
    }

    private let descriptor: Int32

    private init(_ descriptor: Int32) { self.descriptor = descriptor }
    deinit { Darwin.close(descriptor) }

    static func failure(_ code: Int32 = errno) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code))
    }

    static func open(_ url: URL, create: Bool = false) throws -> DiagnosticDirectory? {
        var current = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard current >= 0 else { throw failure() }
        defer { if current >= 0 { Darwin.close(current) } }
        for component in url.pathComponents.dropFirst() {
            guard component != ".", component != "..", !component.utf8.contains(0) else { throw failure(EINVAL) }
            var next = Darwin.openat(current, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if next < 0, errno == ENOENT {
                guard create else { return nil }
                guard Darwin.mkdirat(current, component, mode_t(0o700)) == 0 || errno == EEXIST else { throw failure() }
                next = Darwin.openat(current, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard next >= 0 else { throw failure() }
            Darwin.close(current)
            current = next
        }
        let result = DiagnosticDirectory(current)
        current = -1
        return result
    }

    private func validateName(_ name: String) throws {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.utf8.contains(0) else {
            throw Self.failure(EINVAL)
        }
    }

    func names() throws -> [String] {
        let copy = Darwin.openat(descriptor, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard copy >= 0 else { throw Self.failure() }
        guard let directory = Darwin.fdopendir(copy) else {
            let error = Self.failure()
            Darwin.close(copy)
            throw error
        }
        defer { Darwin.closedir(directory) }
        var names: [String] = []
        while true {
            errno = 0
            guard let entry = Darwin.readdir(directory) else {
                guard errno == 0 else { throw Self.failure() }
                return names
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            if name != ".", name != ".." { names.append(name) }
        }
    }

    func file(_ name: String, skipNonRegular: Bool = false) throws -> File? {
        try validateName(name)
        var info = stat()
        guard Darwin.fstatat(descriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT { return nil }
            throw Self.failure()
        }
        // A hard link is not evidence that these bytes belong only to diagnostics.
        guard info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else {
            if skipNonRegular { return nil }
            throw Self.failure(EINVAL)
        }
        guard info.st_size >= 0 else { throw Self.failure(EIO) }
        return File(name: name, size: info.st_size,
                    modified: Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1_000_000_000),
                    device: info.st_dev, inode: info.st_ino)
    }

    func remove(_ expected: File) throws {
        guard let current = try file(expected.name) else { return }
        guard current == expected else { throw Self.failure(ESTALE) }
        guard Darwin.unlinkat(descriptor, expected.name, 0) == 0 else { throw Self.failure() }
    }

    func move(_ expected: File, to name: String) throws {
        guard try file(expected.name) == expected else { throw Self.failure(ESTALE) }
        guard try file(name) == nil else { throw Self.failure(EEXIST) }
        guard Darwin.renameat(descriptor, expected.name, descriptor, name) == 0 else { throw Self.failure() }
    }

    func writeNew(_ name: String, data: Data) throws {
        try validateName(name)
        let fd = Darwin.openat(descriptor, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard fd >= 0 else { throw Self.failure() }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            try handle.close()
        } catch {
            try? handle.close()
            Darwin.unlinkat(descriptor, name, 0)
            throw error
        }
    }

    func append(_ name: String, data: Data, limit: Int64) throws {
        try validateName(name)
        let fd = Darwin.openat(descriptor, name, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, mode_t(0o600))
        guard fd >= 0 else { throw Self.failure() }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard Darwin.fstat(fd, &info) == 0 else { throw Self.failure() }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1, info.st_size >= 0 else { throw Self.failure(EINVAL) }
        guard Int64(data.count) <= limit, info.st_size <= limit - Int64(data.count) else { throw Self.failure(EFBIG) }
        do { try handle.write(contentsOf: data) }
        catch {
            // A short write must not leave half a JSONL record before the next append.
            try handle.truncate(atOffset: UInt64(info.st_size))
            throw error
        }
    }

    static func totalBytes(_ files: [File]) throws -> Int64 {
        try files.reduce(Int64(0)) { total, file in
            let (sum, overflow) = total.addingReportingOverflow(file.size)
            guard !overflow else { throw failure(EOVERFLOW) }
            return sum
        }
    }
}
