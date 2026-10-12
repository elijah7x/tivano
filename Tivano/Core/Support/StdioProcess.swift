import Foundation
import Darwin
import Synchronization
import os

/// A child process that exchanges JSON messages over stdio, one per line or
/// behind a `Content-Length` header.
///
/// Reading, parsing and writing happen on private queues. Parsed messages are
/// delivered through `messages`, which finishes once stdout closes or the
/// process exits.
final class StdioProcess: @unchecked Sendable {
    typealias Framing = StdioFramer.Framing

    struct MessageStream: AsyncSequence, Sendable {
        typealias Element = JSONValue
        fileprivate struct Entry: Sendable {
            let value: JSONValue
            let bytes: Int
        }
        struct AsyncIterator: AsyncIteratorProtocol {
            fileprivate var base: AsyncStream<Entry>.Iterator
            fileprivate let consumed: @Sendable (Int) -> Void
            mutating func next(isolation actor: isolated (any Actor)?) async -> JSONValue? {
                guard let entry = await base.next(isolation: actor) else { return nil }
                consumed(entry.bytes)
                return entry.value
            }
            mutating func next() async -> JSONValue? { await next(isolation: #isolation) }
        }
        fileprivate let stream: AsyncStream<Entry>
        fileprivate let consumed: @Sendable (Int) -> Void
        func makeAsyncIterator() -> AsyncIterator {
            AsyncIterator(base: stream.makeAsyncIterator(), consumed: consumed)
        }
    }

    let messages: MessageStream

    private let framing: Framing
    private let continuation: AsyncStream<MessageStream.Entry>.Continuation
    private let process = Process()
    private let stdin = Pipe()
    private let stdout = Pipe()
    private let stderr = Pipe()
    private let writeQueue = DispatchQueue(label: "tivano.stdio.write")
    private let descendants = DescendantTracker()

    private struct State {
        var framer: StdioFramer
        var errorBuffer = Data()
        var failureReason: String?
        var outputFinished = false
        var terminating = false
        var queuedBytes = 0
        var timedWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
        var exitStatus: Int32?
        var exitWaiters: [CheckedContinuation<Int32, Never>] = []
    }

    private let state: Mutex<State>
    /// Bytes delivered but not yet read off `messages`; apart from `state` because the
    /// stream's iterator decrements it and a `Mutex` cannot be captured by a closure.
    private let ingressBytes: OSAllocatedUnfairLock<Int>

    init(executable: URL, arguments: [String], directory: URL, environment: [String: String], framing: Framing = .lines) {
        let stream = AsyncStream.makeStream(of: MessageStream.Entry.self)
        state = Mutex(State(framer: StdioFramer(framing: framing)))
        let ingress = OSAllocatedUnfairLock(initialState: 0)
        ingressBytes = ingress
        messages = MessageStream(stream: stream.stream, consumed: { bytes in
            ingress.withLock { $0 -= bytes }
        })
        continuation = stream.continuation
        self.framing = framing
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.environment = environment
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
    }

    var isRunning: Bool { process.isRunning }
    var processIdentifier: Int32 { process.processIdentifier }

    /// The last few kilobytes written to stderr, used when a provider fails.
    var errorTail: String {
        state.withLock { String(decoding: $0.errorBuffer.suffix(4_000), as: UTF8.self) }
    }

    var failureReason: String? { state.withLock { $0.failureReason } }

    func start() throws {
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else {
                handle.readabilityHandler = nil
                return
            }
            if data.isEmpty {
                handle.readabilityHandler = nil
                self.finishOutput()
            } else {
                self.consume(data)
            }
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self, !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            self.appendError(data)
        }
        process.terminationHandler = { [weak self] process in
            self?.descendants.terminate()
            self?.didExit(process.terminationStatus)
        }
        do {
            try process.run()
            descendants.start(process.processIdentifier)
        } catch {
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            continuation.finish()
            throw error
        }
    }

    func send(_ message: JSONValue, completion: ((Bool) -> Void)? = nil) {
        let body = message.data()
        switch framing {
        case .lines:
            write(body + Data([0x0A]), completion: completion)
        case .contentLength:
            write(Data("Content-Length: \(body.count)\r\n\r\n".utf8) + body, completion: completion)
        }
    }

    /// Writes raw bytes to the process's stdin: a prompt piped to a one-shot CLI.
    func write(_ data: Data, completion: ((Bool) -> Void)? = nil) {
        let accepted = state.withLock { state in
            guard !state.terminating, !state.outputFinished,
                  state.queuedBytes <= 32 * 1024 * 1024 - data.count else { return false }
            state.queuedBytes += data.count
            return true
        }
        guard accepted else {
            fail(AppText.localized("The agent input queue exceeded 32 MB or the connection closed."))
            completion?(false)
            return
        }
        writeQueue.async { [self] in
            defer { state.withLock { $0.queuedBytes -= data.count } }
            guard !state.withLock({ $0.terminating }) else { completion?(false); return }
            do {
                try stdin.fileHandleForWriting.write(contentsOf: data)
                completion?(true)
            } catch {
                fail(String(format: AppText.localized("Writing to the agent failed: %@"), error.localizedDescription))
                completion?(false)
            }
        }
    }

    /// Closes stdin, for a process that reads its input to the end before it starts.
    func closeInput() {
        let handle = stdin.fileHandleForWriting
        writeQueue.async { try? handle.close() }
    }

    fileprivate struct ProcessIdentity: Sendable {
        let pid: pid_t
        let parent: pid_t
        let seconds: UInt64
        let microseconds: UInt64
    }

    fileprivate static func identity(_ pid: pid_t) -> ProcessIdentity? {
        guard pid > 1, pid != getpid() else { return nil }
        var info = proc_bsdinfo()
        let size = MemoryLayout<proc_bsdinfo>.size
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(size)) == Int32(size) else { return nil }
        return ProcessIdentity(pid: pid, parent: pid_t(info.pbi_ppid), seconds: info.pbi_start_tvsec, microseconds: info.pbi_start_tvusec)
    }

    private static func matches(_ member: ProcessIdentity) -> Bool {
        guard let current = identity(member.pid) else { return false }
        return current.seconds == member.seconds && current.microseconds == member.microseconds
    }

    private static func processTree(_ roots: [ProcessIdentity], limit: Int) -> [ProcessIdentity] {
        var collected: [ProcessIdentity] = []
        var visited = Set<pid_t>()
        func collect(_ member: ProcessIdentity, parent: ProcessIdentity? = nil) {
            guard visited.count < limit, !visited.contains(member.pid), matches(member) else { return }
            if let parent {
                guard matches(parent), let current = identity(member.pid), current.parent == parent.pid else { return }
            }
            visited.insert(member.pid)
            // libproc.c returns PID counts; proc_info.c's nil-buffer result is the
            // system-wide nprocs + 20 estimate, not this parent's child count.
            // https://github.com/apple-oss-distributions/xnu/blob/main/libsyscall/wrappers/libproc/libproc.c
            var capacity = min(limit, min(64, max(32, Int(proc_listchildpids(member.pid, nil, 0)))))
            var children: [pid_t] = []
            for _ in 0..<4 {
                var buffer = [pid_t](repeating: 0, count: capacity)
                let found = buffer.withUnsafeMutableBytes { bytes in
                    proc_listchildpids(member.pid, bytes.baseAddress, Int32(bytes.count))
                }
                children = Array(buffer.prefix(max(0, min(Int(found), capacity))))
                guard Int(found) >= capacity, capacity < limit else { break }
                capacity = min(limit, capacity * 2)
            }
            for pid in children where visited.count < limit {
                guard let child = identity(pid) else { continue }
                collect(child, parent: member)
            }
            collected.append(member)
        }
        for root in roots { collect(root) }
        return collected
    }

    private static func signal(_ tree: [ProcessIdentity], _ signal: Int32) {
        for member in tree {
            guard matches(member) else { continue }
            kill(member.pid, signal)
        }
    }

    /// Only observed identities remain attributable after reparenting. An unseen
    /// process that has already detached cannot safely be recovered from a PID scan.
    final class DescendantTracker: @unchecked Sendable {
        private static let limit = 256
        private let queue = DispatchQueue(label: "tivano.process.descendants", qos: .utility)
        private var timer: DispatchSourceTimer?
        private var members: [pid_t: ProcessIdentity] = [:]
        private var terminating = false

        func start(_ pid: pid_t) {
            guard let root = StdioProcess.identity(pid) else { return }
            queue.async { [self] in
                members[root.pid] = root
                observe()
                // Exit/cancellation can enqueue termination before start's work.
                guard !terminating else {
                    StdioProcess.signal(postorder(), SIGTERM)
                    return
                }
                let timer = DispatchSource.makeTimerSource(queue: queue)
                timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(200))
                timer.setEventHandler { [weak self] in
                    guard let self, !self.terminating else { return }
                    self.observe()
                }
                self.timer = timer
                timer.resume()
            }
        }

        private func observe() {
            members = members.filter { StdioProcess.matches($0.value) }
            let roots = members.values.sorted { $0.pid < $1.pid }
            let tree = StdioProcess.processTree(roots, limit: Self.limit)
            for member in tree where members.count < Self.limit || members[member.pid] != nil {
                // Preserve the observed parent for postorder after it exits.
                if members[member.pid] == nil { members[member.pid] = member }
            }
        }

        private func postorder() -> [ProcessIdentity] {
            var visited = Set<pid_t>()
            var result: [ProcessIdentity] = []
            let children = Dictionary(grouping: members.values, by: \.parent)
            func visit(_ member: ProcessIdentity) {
                guard visited.insert(member.pid).inserted else { return }
                for child in children[member.pid] ?? [] { visit(child) }
                result.append(member)
            }
            for member in members.values { visit(member) }
            return result
        }

        func terminate() {
            queue.async { [self] in
                guard !terminating else { return }
                terminating = true
                timer?.cancel()
                timer = nil
                observe()
                StdioProcess.signal(postorder(), SIGTERM)
                queue.asyncAfter(deadline: .now() + 3) { [self] in
                    observe()
                    StdioProcess.signal(postorder(), SIGKILL)
                    members.removeAll()
                }
            }
        }

        deinit { timer?.cancel() }
    }

    func terminate() {
        let shouldTerminate = state.withLock { state in
            guard !state.terminating else { return false }
            state.terminating = true
            return true
        }
        guard shouldTerminate else { return }
        let handle = stdin.fileHandleForWriting
        writeQueue.async { try? handle.close() }
        descendants.terminate()
    }

    func terminateAndWait(timeout: TimeInterval) async {
        terminate()
        let id = UUID()
        await withCheckedContinuation { continuation in
            let exited = state.withLock { state in
                guard state.exitStatus == nil else { return true }
                state.timedWaiters[id] = continuation
                return false
            }
            if exited { continuation.resume(); return }
            DispatchQueue.global().asyncAfter(deadline: .now() + max(0, timeout)) { [self] in
                state.withLock { $0.timedWaiters.removeValue(forKey: id) }?.resume()
            }
        }
    }

    private func fail(_ reason: String) {
        let first = state.withLock { state in
            guard state.failureReason == nil else { return false }
            state.failureReason = reason
            return true
        }
        guard first else { return }
        NSLog("StdioProcess: %@", reason)
        terminate()
        stdout.fileHandleForReading.readabilityHandler = nil
        finishOutput()
    }

    func waitForExit() async -> Int32 {
        await withCheckedContinuation { continuation in
            let exited = state.withLock { state -> Int32? in
                if let exitStatus = state.exitStatus { return exitStatus }
                state.exitWaiters.append(continuation)
                return nil
            }
            if let exited { continuation.resume(returning: exited) }
        }
    }

    private func consume(_ data: Data) {
        do {
            let messages = try state.withLock { state in
                guard !state.outputFinished else { return [Data]() }
                return try state.framer.append(data)
            }
            for message in messages { deliver(message) }
        } catch { fail(error.localizedDescription) }
    }

    private func deliver(_ line: Data) {
        var line = line
        while let last = line.last, last == 0x0D || last == 0x20 { line.removeLast() }
        guard !line.isEmpty, let message = JSONValue.parse(line) else { return }
        guard !state.withLock({ $0.outputFinished }) else { return }
        let size = line.count
        let accepted = ingressBytes.withLock { queued in
            guard queued <= 256 * 1024 * 1024 - size else { return false }
            queued += size
            return true
        }
        guard accepted else {
            if !state.withLock({ $0.outputFinished }) { fail(AppText.localized("The agent output backlog exceeded 256 MB.")) }
            return
        }
        if case .terminated = continuation.yield(MessageStream.Entry(value: message, bytes: size)) {
            ingressBytes.withLock { $0 -= size }
        }
    }

    private func finishOutput() {
        let remainder = state.withLock { state -> Data? in
            guard !state.outputFinished else { return nil }
            return state.framer.finish()
        }
        if failureReason == nil, let remainder { deliver(remainder) }
        state.withLock { $0.outputFinished = true }
        continuation.finish()
    }

    private func appendError(_ data: Data) {
        state.withLock { state in
            state.errorBuffer.append(data)
            if state.errorBuffer.count > 64_000 {
                state.errorBuffer = Data(state.errorBuffer.suffix(16_000))
            }
        }
    }

    private func didExit(_ status: Int32) {
        let waiters = state.withLock { state in
            state.exitStatus = status
            let waiters = state.exitWaiters
            state.exitWaiters.removeAll()
            return waiters
        }
        for waiter in waiters { waiter.resume(returning: status) }
        let timed = state.withLock { state in
            let waiting = Array(state.timedWaiters.values)
            state.timedWaiters.removeAll()
            return waiting
        }
        for waiter in timed { waiter.resume() }

        // A grandchild can inherit stdout and keep it open after the provider exits.
        let handle = stdout.fileHandleForReading
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) { [weak self] in
            handle.readabilityHandler = nil
            self?.finishOutput()
        }
    }
}
