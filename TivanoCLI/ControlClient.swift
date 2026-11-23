import Foundation
import Darwin
import os

/// A synchronous, bounded client for the native CLI (and future adapters). Never
/// opens the App's library, grants permission, or retries a request; `connectLaunching`
/// launches the App only for agent commands.
final class ControlClient: @unchecked Sendable {
    private struct SocketState: Sendable {
        var fd: Int32 = -1
        var interrupted = false
    }

    private let socketState = OSAllocatedUnfairLock(initialState: SocketState())
    private(set) var welcome: ControlWelcome!
    private let timeout: TimeInterval

    private var fd: Int32 { socketState.withLock { $0.fd } }

    init(edition: ControlEdition, expectedInstance: UUID? = nil, directory: URL? = nil, timeout: TimeInterval = 15) throws {
        self.timeout = timeout
        let directory = directory ?? ControlSocket.directory(edition: edition)
        try ControlSocket.checkEndpoint(directory)
        let socketFD = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketFD >= 0 else { throw ControlFailure(code: .unavailable) }
        socketState.withLock { $0.fd = socketFD }
        do {
            try ControlSocket.configure(socketFD, nonblocking: true)
            let deadline = ProcessInfo.processInfo.systemUptime + timeout
            try ControlSocket.withAddress(directory.appendingPathComponent("control.sock").path) { address, size in
                let result = Darwin.connect(socketFD, address, size)
                if result != 0 {
                    guard errno == EINPROGRESS else { throw ControlFailure(code: .unavailable) }
                    try wait(POLLOUT, deadline: deadline)
                    var error: Int32 = 0
                    var length = socklen_t(MemoryLayout.size(ofValue: error))
                    guard getsockopt(socketFD, SOL_SOCKET, SO_ERROR, &error, &length) == 0, error == 0 else { throw ControlFailure(code: .unavailable) }
                }
            }
            try ControlSocket.checkPeer(socketFD)
            let hello = ControlHello(edition: edition, expectedInstance: expectedInstance)
            let response = try exchange(LocalControl.encoder().encode(hello), deadline: deadline)
            if let error = response.error { throw error }
            guard case .welcome(let received) = response.result,
                  received.version == LocalControl.version, received.edition == edition,
                  expectedInstance == nil || received.instance == expectedInstance else { throw ControlFailure(code: .protocolMismatch) }
            welcome = received
        } catch {
            closeSocket()
            throw error
        }
    }

    deinit { closeSocket() }

    private func closeSocket() {
        socketState.withLock { state in
            if state.fd >= 0 {
                Darwin.close(state.fd)
                state.fd = -1
            }
        }
    }

    func interrupt() {
        socketState.withLock { state in
            state.interrupted = true
            if state.fd >= 0 {
                _ = Darwin.shutdown(state.fd, SHUT_RDWR)
            }
        }
    }

    static func connectLaunching(edition: ControlEdition, app: URL?, timeout: TimeInterval = 15) throws -> ControlClient {
        do {
            return try ControlClient(edition: edition)
        } catch let failure as ControlFailure where failure.code == .unavailable {
            // Socket missing or refused; launch the matching edition hidden and retry.
        }
        try launchApp(edition: edition, app: app)
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while true {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else {
                throw ControlFailure(code: .unavailable, detail: "launch_timeout")
            }
            Thread.sleep(forTimeInterval: min(remaining, 0.25))
            let attemptTimeout = max(1, min(timeout, deadline - ProcessInfo.processInfo.systemUptime))
            do {
                return try ControlClient(edition: edition, timeout: attemptTimeout)
            } catch let failure as ControlFailure where failure.code == .unavailable {
                continue
            }
        }
    }

    private static func launchApp(edition: ControlEdition, app: URL?) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        if let app, app.pathExtension == "app" {
            process.arguments = ["-g", "-j", app.path]
        } else {
            let bundleID: String
            switch edition {
            case .release: bundleID = "dev.tivano.Tivano"
            case .dev: bundleID = "dev.tivano.Tivano.dev"
            case .preview: bundleID = "dev.tivano.Tivano.preview"
            }
            process.arguments = ["-g", "-j", "-b", bundleID]
        }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw ControlFailure(code: .unavailable, detail: "launch_failed")
        }
        guard process.terminationStatus == 0 else {
            throw ControlFailure(code: .unavailable, detail: "launch_failed")
        }
    }

    func request(_ command: ControlCommand) throws -> ControlResponse {
        let request = ControlRequest(instance: welcome.instance, command: command)
        let payload = try LocalControl.encoder().encode(request)
        guard payload.count <= LocalControl.maxRequest else { throw ControlFailure(code: .bounds) }
        let response = try exchange(payload, deadline: ProcessInfo.processInfo.systemUptime + timeout)
        guard response.id == request.id else { throw ControlFailure(code: .protocolMismatch) }
        return response
    }

    func stream(_ command: ControlCommand, onFrame: (ControlResponse) throws -> Bool) throws {
        let request = ControlRequest(instance: welcome.instance, command: command)
        let payload = try LocalControl.encoder().encode(request)
        let limit: Int
        if case .agentRun = command { limit = LocalControl.maxFrame } else { limit = LocalControl.maxRequest }
        guard payload.count <= limit else { throw ControlFailure(code: .bounds) }
        try sendFrame(payload, deadline: ProcessInfo.processInfo.systemUptime + timeout)
        var buffer = Data()
        var bytes = [UInt8](repeating: 0, count: 16_384)
        while true {
            while let frame = try ControlSocket.takeFrame(&buffer, limit: LocalControl.maxFrame) {
                let response = try LocalControl.decoder().decode(ControlResponse.self, from: frame)
                guard response.id == request.id else { throw ControlFailure(code: .protocolMismatch) }
                if try !onFrame(response) { return }
            }
            try wait(POLLIN, deadline: nil)
            let count = Darwin.recv(fd, &bytes, bytes.count, 0)
            if count < 0, errno == EINTR || errno == EAGAIN { continue }
            guard count > 0 else { throw ControlFailure(code: .unavailable, detail: "closed") }
            buffer.append(contentsOf: bytes.prefix(count))
            guard buffer.count <= LocalControl.maxFrame + 4 + bytes.count else { throw ControlFailure(code: .bounds) }
        }
    }

    private func sendFrame(_ payload: Data, deadline: TimeInterval) throws {
        let frame = try ControlSocket.frame(payload)
        var offset = 0
        while offset < frame.count {
            try wait(POLLOUT, deadline: deadline)
            let count = frame.withUnsafeBytes { bytes in
                Darwin.send(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, 0)
            }
            if count < 0, errno == EINTR || errno == EAGAIN { continue }
            guard count > 0 else { throw ControlFailure(code: .unavailable) }
            offset += count
        }
    }

    private func exchange(_ payload: Data, deadline: TimeInterval) throws -> ControlResponse {
        try sendFrame(payload, deadline: deadline)
        var buffer = Data()
        var bytes = [UInt8](repeating: 0, count: 16_384)
        while true {
            if let frame = try ControlSocket.takeFrame(&buffer, limit: LocalControl.maxFrame) {
                guard buffer.isEmpty else { throw ControlFailure(code: .protocolMismatch) }
                return try LocalControl.decoder().decode(ControlResponse.self, from: frame)
            }
            try wait(POLLIN, deadline: deadline)
            let count = Darwin.recv(fd, &bytes, bytes.count, 0)
            if count < 0, errno == EINTR || errno == EAGAIN { continue }
            guard count > 0 else { throw ControlFailure(code: .unavailable) }
            buffer.append(contentsOf: bytes.prefix(count))
            guard buffer.count <= LocalControl.maxFrame + 4 else { throw ControlFailure(code: .bounds) }
        }
    }

    private func wait(_ events: Int32, deadline: TimeInterval?) throws {
        while true {
            let state = socketState.withLock { $0 }
            guard !state.interrupted, state.fd >= 0 else {
                throw ControlFailure(code: .unavailable, detail: deadline == nil ? "closed" : nil)
            }
            let pollTimeout: Int32
            if let deadline {
                let remaining = deadline - ProcessInfo.processInfo.systemUptime
                guard remaining > 0 else { throw ControlFailure(code: .unavailable, detail: "timeout_outcome_unknown") }
                pollTimeout = Int32(max(1, min(remaining * 1_000, 30_000)))
            } else {
                pollTimeout = 1_000
            }
            var descriptor = pollfd(fd: state.fd, events: Int16(events), revents: 0)
            let result = Darwin.poll(&descriptor, 1, pollTimeout)
            if result < 0, errno == EINTR { continue }
            if result == 0 { continue }
            guard result > 0 else {
                throw ControlFailure(code: .unavailable, detail: deadline == nil ? "closed" : nil)
            }
            let revents = Int32(descriptor.revents)
            guard revents & (POLLERR | POLLNVAL) == 0 else {
                throw ControlFailure(code: .unavailable, detail: deadline == nil ? "closed" : nil)
            }
            if revents & events != 0 { return }
            if events & POLLIN != 0, revents & POLLHUP != 0 { return }
            throw ControlFailure(code: .unavailable, detail: deadline == nil ? "closed" : nil)
        }
    }
}
