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
            self?.didExit(process.terminationStatus)
        }
        do {
            try process.run()
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

    private struct ProcessIdentity: Sendable {
        let pid: pid_t
        let parent: pid_t
        let seconds: UInt64
        let microseconds: UInt64
    }

    private static func identity(_ pid: pid_t) -> ProcessIdentity? {
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        let size = MemoryLayout<proc_bsdinfo>.size
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(size)) == Int32(size) else { return nil }
        return ProcessIdentity(pid: pid, parent: pid_t(info.pbi_ppid), seconds: info.pbi_start_tvsec, microseconds: info.pbi_start_tvusec)
    }

    private static func processTree(_ root: pid_t) -> [ProcessIdentity] {
        var collected: [ProcessIdentity] = []
        var visited = Set<pid_t>()
        func collect(_ pid: pid_t, parent: pid_t? = nil) {
            guard visited.insert(pid).inserted, let identity = identity(pid),
                  parent == nil || identity.parent == parent else { return }
            collected.append(identity)
            let count = proc_listchildpids(pid, nil, 0)
            guard count > 0 else { return }
            var children = [pid_t](repeating: 0, count: Int(count) / MemoryLayout<pid_t>.size + 32)
            let found = children.withUnsafeMutableBytes { bytes in
                proc_listchildpids(pid, bytes.baseAddress, Int32(bytes.count))
            }
            guard found > 0 else { return }
            // The listing call counts pids, not bytes: dividing again dropped every child of
            // a process with fewer than four, so a stopped agent left its MCP servers behind.
            for child in children.prefix(min(Int(found), children.count)) where child > 0 { collect(child, parent: pid) }
        }
        collect(root)
        return collected.reversed()
    }

    private static func signal(_ tree: [ProcessIdentity], _ signal: Int32) {
        for member in tree {
            guard let current = identity(member.pid), current.seconds == member.seconds,
                  current.microseconds == member.microseconds else { continue }
            kill(member.pid, signal)
        }
    }

    func terminate() {
        let shouldTerminate = state.withLock { state in
            guard !state.terminating else { return false }
            state.terminating = true
            return true
        }
        guard shouldTerminate else { return }
        let tree = process.isRunning ? Self.processTree(process.processIdentifier) : []
        let handle = stdin.fileHandleForWriting
        writeQueue.async { try? handle.close() }
        Self.signal(tree, SIGTERM)
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
            Self.signal(tree, SIGKILL)
        }
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
