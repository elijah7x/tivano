import Foundation
import Darwin

/// A synchronous, bounded client for the native CLI (and future adapters). Never
/// launches the App, opens its library, grants permission, or retries a request.
final class ControlClient {
    private var fd: Int32 = -1
    private(set) var welcome: ControlWelcome!
    private let timeout: TimeInterval

    init(edition: ControlEdition, expectedInstance: UUID? = nil, directory: URL? = nil, timeout: TimeInterval = 15) throws {
        self.timeout = timeout
        let directory = directory ?? ControlSocket.directory(edition: edition)
        try ControlSocket.checkEndpoint(directory)
        fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ControlFailure(code: .unavailable) }
        do {
            try ControlSocket.configure(fd, nonblocking: true)
            let deadline = ProcessInfo.processInfo.systemUptime + timeout
            try ControlSocket.withAddress(directory.appendingPathComponent("control.sock").path) { address, size in
                let result = Darwin.connect(fd, address, size)
                if result != 0 {
                    guard errno == EINPROGRESS else { throw ControlFailure(code: .unavailable) }
                    try wait(POLLOUT, deadline: deadline)
                    var error: Int32 = 0
                    var length = socklen_t(MemoryLayout.size(ofValue: error))
                    guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0, error == 0 else { throw ControlFailure(code: .unavailable) }
                }
            }
            try ControlSocket.checkPeer(fd)
            let hello = ControlHello(edition: edition, expectedInstance: expectedInstance)
            let response = try exchange(LocalControl.encoder().encode(hello), deadline: deadline)
            if let error = response.error { throw error }
            guard case .welcome(let received) = response.result,
                  received.version == LocalControl.version, received.edition == edition,
                  expectedInstance == nil || received.instance == expectedInstance else { throw ControlFailure(code: .protocolMismatch) }
            welcome = received
        } catch {
            Darwin.close(fd)
            fd = -1
            throw error
        }
    }

    deinit { if fd >= 0 { Darwin.close(fd) } }

    func request(_ command: ControlCommand) throws -> ControlResponse {
        let request = ControlRequest(instance: welcome.instance, command: command)
        let payload = try LocalControl.encoder().encode(request)
        guard payload.count <= LocalControl.maxRequest else { throw ControlFailure(code: .bounds) }
        let response = try exchange(payload, deadline: ProcessInfo.processInfo.systemUptime + timeout)
        guard response.id == request.id else { throw ControlFailure(code: .protocolMismatch) }
        return response
    }

    private func exchange(_ payload: Data, deadline: TimeInterval) throws -> ControlResponse {
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

    private func wait(_ events: Int32, deadline: TimeInterval) throws {
        while true {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw ControlFailure(code: .unavailable, detail: "timeout_outcome_unknown") }
            var descriptor = pollfd(fd: fd, events: Int16(events), revents: 0)
            let result = Darwin.poll(&descriptor, 1, Int32(min(remaining * 1_000, 30_000)))
            if result < 0, errno == EINTR { continue }
            guard result > 0, Int32(descriptor.revents) & (POLLERR | POLLNVAL) == 0,
                  Int32(descriptor.revents) & events != 0 else { throw ControlFailure(code: .unavailable) }
            return
        }
    }
}
