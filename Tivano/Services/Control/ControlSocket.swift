import Foundation
import Darwin

/// All server state is confined to `queue`. No thread, provider or library is owned here.
/// A connection has one request in flight, bounded buffers and a 30-second deadline.
final class ControlSocketServer: @unchecked Sendable {
    typealias Handler = @Sendable (ControlRequest) async -> ControlResponse
    private let queue = DispatchQueue(label: "dev.tivano.local-control", qos: .utility)
    private let directory: URL
    private let welcome: ControlWelcome
    private let handler: Handler
    private var listener: DispatchSourceRead?
    private var lease: Int32 = -1
    private var socketIdentity: ino_t?
    private var connections: [UUID: Connection] = [:]
    private var generation = UUID()
    private var pendingHandlers = 0

    private final class Connection: @unchecked Sendable {
        let id = UUID()
        let fd: Int32
        var input = Data()
        var output = Data()
        var offset = 0
        var handshaken = false
        var inFlight = false
        var closeAfterWrite = false
        var reader: DispatchSourceRead?
        var writer: DispatchSourceWrite?
        var timer: DispatchSourceTimer?
        init(_ fd: Int32) { self.fd = fd }
    }

    init(directory: URL, welcome: ControlWelcome, handler: @escaping Handler) {
        self.directory = directory
        self.welcome = welcome
        self.handler = handler
    }

    func start() throws {
        try queue.sync {
            guard listener == nil else { return }
            try ControlSocket.prepareDirectory(directory)
            let lockPath = directory.appendingPathComponent("listener.lock").path
            let lock = Darwin.open(lockPath, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard lock >= 0 else { throw ControlFailure(code: .permission) }
            var lockStat = stat()
            guard fstat(lock, &lockStat) == 0, lockStat.st_uid == getuid(),
                  lockStat.st_mode & S_IFMT == S_IFREG, lockStat.st_mode & 0o077 == 0,
                  flock(lock, LOCK_EX | LOCK_NB) == 0 else {
                Darwin.close(lock)
                throw ControlFailure(code: .busy)
            }
            lease = lock
            do {
                let path = directory.appendingPathComponent("control.sock").path
                var old = stat()
                if lstat(path, &old) == 0 {
                    guard old.st_uid == getuid(), old.st_mode & S_IFMT == S_IFSOCK else { throw ControlFailure(code: .permission) }
                    // Only the holder of the edition's lease may remove a stale endpoint.
                    guard unlink(path) == 0 else { throw ControlFailure(code: .permission) }
                } else if errno != ENOENT { throw ControlFailure(code: .permission) }
                let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
                guard fd >= 0 else { throw ControlFailure(code: .unavailable) }
                var transferred = false
                defer { if !transferred { Darwin.close(fd) } }
                try ControlSocket.configure(fd, nonblocking: true)
                try ControlSocket.withAddress(path) { address, length in
                    guard Darwin.bind(fd, address, length) == 0 else { throw ControlFailure(code: .unavailable) }
                }
                guard chmod(path, 0o600) == 0, Darwin.listen(fd, Int32(LocalControl.maxConnections)) == 0 else {
                    unlink(path)
                    throw ControlFailure(code: .permission)
                }
                var info = stat()
                guard lstat(path, &info) == 0 else { throw ControlFailure(code: .unavailable) }
                socketIdentity = info.st_ino
                generation = UUID()
                let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
                source.setEventHandler { [weak self] in self?.accept(fd) }
                source.setCancelHandler { Darwin.close(fd) }
                listener = source
                transferred = true
                source.resume()
            } catch {
                Darwin.close(lease)
                lease = -1
                throw error
            }
        }
    }

    /// Synchronous revocation: shuts down every accepted FD before returning. Already
    /// accepted App operations are independent of their transport and are not cancelled.
    func stop() {
        queue.sync {
            generation = UUID()
            listener?.cancel()
            listener = nil
            for connection in Array(connections.values) { close(connection) }
            let path = directory.appendingPathComponent("control.sock").path
            var info = stat()
            if let socketIdentity, lstat(path, &info) == 0, info.st_ino == socketIdentity,
               info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFSOCK { unlink(path) }
            socketIdentity = nil
            if lease >= 0 { Darwin.close(lease); lease = -1 }
        }
    }

    private func accept(_ listenerFD: Int32) {
        guard listener != nil else { return }
        // Bound work per dispatch even under an untrusted same-account connection flood.
        for _ in 0..<LocalControl.maxConnections {
            let fd = Darwin.accept(listenerFD, nil, nil)
            if fd < 0 { return }
            guard connections.count < LocalControl.maxConnections,
                  (try? ControlSocket.checkPeer(fd)) != nil,
                  (try? ControlSocket.configure(fd, nonblocking: true)) != nil else {
                Darwin.close(fd)
                continue
            }
            let connection = Connection(fd)
            connections[connection.id] = connection
            let reader = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            reader.setEventHandler { [weak self, weak connection] in
                if let connection { self?.read(connection) }
            }
            reader.setCancelHandler { Darwin.close(fd) }
            connection.reader = reader
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.setEventHandler { [weak self, weak connection] in
                if let connection { self?.close(connection) }
            }
            connection.timer = timer
            armDeadline(connection)
            timer.resume()
            reader.resume()
        }
    }

    private func armDeadline(_ connection: Connection) {
        connection.timer?.schedule(deadline: .now() + 30)
    }

    private func read(_ connection: Connection) {
        guard connections[connection.id] != nil else { return }
        var bytes = [UInt8](repeating: 0, count: 16_384)
        for _ in 0..<10 {
            let count = Darwin.recv(connection.fd, &bytes, bytes.count, 0)
            if count == 0 { close(connection); return }
            if count < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK { break }
                if errno == EINTR { continue }
                close(connection); return
            }
            guard !connection.inFlight, connection.output.isEmpty else { close(connection); return }
            connection.input.append(contentsOf: bytes.prefix(count))
            guard connection.input.count <= LocalControl.maxRequest + 4 else { close(connection); return }
        }
        do {
            guard let payload = try ControlSocket.takeFrame(&connection.input, limit: LocalControl.maxRequest) else { return }
            // Pipelining is deliberately unsupported; reconnect is never an implicit retry.
            guard connection.input.isEmpty else { throw ControlFailure(code: .bounds) }
            if !connection.handshaken {
                let hello = try LocalControl.decoder().decode(ControlHello.self, from: payload)
                guard hello.version == welcome.version else { throw ControlFailure(code: .protocolMismatch) }
                guard hello.edition == welcome.edition else { throw ControlFailure(code: .editionMismatch) }
                guard hello.expectedInstance == nil || hello.expectedInstance == welcome.instance else { throw ControlFailure(code: .instanceMismatch) }
                connection.handshaken = true
                respond(ControlResponse(result: .welcome(welcome)), to: connection)
                return
            }
            let request = try LocalControl.decoder().decode(ControlRequest.self, from: payload)
            guard request.instance == welcome.instance else { throw ControlFailure(code: .instanceMismatch) }
            guard pendingHandlers < LocalControl.maxConnections else { throw ControlFailure(code: .busy) }
            pendingHandlers += 1
            connection.inFlight = true
            let incarnation = generation
            Task { [handler, weak self] in
                let response = await handler(request)
                guard let self else { return }
                self.queue.async { [weak self] in
                    guard let self else { return }
                    self.pendingHandlers -= 1
                    guard self.generation == incarnation, self.connections[connection.id] != nil else { return }
                    connection.inFlight = false
                    self.respond(response, to: connection)
                }
            }
        } catch {
            connection.closeAfterWrite = true
            respond(ControlResponse(error: error as? ControlFailure ?? ControlFailure(code: .invalidRequest)), to: connection)
        }
    }

    private func respond(_ response: ControlResponse, to connection: Connection) {
        do {
            var payload = try LocalControl.encoder().encode(response)
            if payload.count > LocalControl.maxFrame {
                payload = try LocalControl.encoder().encode(ControlResponse(id: response.id, error: ControlFailure(code: .bounds)))
            }
            connection.output = try ControlSocket.frame(payload)
            connection.offset = 0
            write(connection)
        } catch { close(connection) }
    }

    private func write(_ connection: Connection) {
        guard connections[connection.id] != nil else { return }
        while connection.offset < connection.output.count {
            let count = connection.output.withUnsafeBytes { bytes in
                Darwin.send(connection.fd, bytes.baseAddress!.advanced(by: connection.offset), bytes.count - connection.offset, 0)
            }
            if count < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    if connection.writer == nil {
                        let source = DispatchSource.makeWriteSource(fileDescriptor: connection.fd, queue: queue)
                        source.setEventHandler { [weak self, weak connection] in
                            if let connection { self?.write(connection) }
                        }
                        connection.writer = source
                        source.resume()
                    }
                    return
                }
                close(connection); return
            }
            guard count > 0 else { close(connection); return }
            connection.offset += count
        }
        connection.writer?.cancel()
        connection.writer = nil
        connection.output.removeAll(keepingCapacity: false)
        connection.offset = 0
        if connection.closeAfterWrite { close(connection) } else { armDeadline(connection) }
    }

    private func close(_ connection: Connection) {
        guard connections.removeValue(forKey: connection.id) != nil else { return }
        Darwin.shutdown(connection.fd, SHUT_RDWR)
        connection.writer?.cancel()
        connection.timer?.cancel()
        connection.reader?.cancel()
        connection.writer = nil
        connection.reader = nil
        connection.timer = nil
    }
}

enum ControlSocket {
    /// Short enough for Darwin's sockaddr_un even with a long home directory. Each
    /// component below /private/tmp is checked without following a symbolic link.
    static func directory(edition: ControlEdition) -> URL {
        URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("tivano-control-\(getuid())", isDirectory: true)
            .appendingPathComponent(edition.rawValue, isDirectory: true)
    }

    static func prepareDirectory(_ directory: URL) throws {
        // Tests may supply an isolated parent; production always uses directory(edition:).
        try ensurePrivateDirectory(directory.deletingLastPathComponent(), create: true)
        try ensurePrivateDirectory(directory, create: true)
    }

    static func ensurePrivateDirectory(_ directory: URL, create: Bool) throws {
        if create, mkdir(directory.path, 0o700) != 0, errno != EEXIST { throw ControlFailure(code: .permission) }
        var info = stat()
        guard lstat(directory.path, &info) == 0 else { throw ControlFailure(code: errno == ENOENT ? .unavailable : .permission) }
        guard info.st_uid == getuid(),
              info.st_mode & S_IFMT == S_IFDIR, info.st_mode & 0o077 == 0 else { throw ControlFailure(code: .permission) }
    }

    static func checkEndpoint(_ directory: URL) throws {
        try ensurePrivateDirectory(directory.deletingLastPathComponent(), create: false)
        try ensurePrivateDirectory(directory, create: false)
        var info = stat()
        let path = directory.appendingPathComponent("control.sock").path
        guard lstat(path, &info) == 0 else { throw ControlFailure(code: .unavailable) }
        guard info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFSOCK, info.st_mode & 0o077 == 0 else { throw ControlFailure(code: .permission) }
    }

    static func checkPeer(_ fd: Int32, expectedUID: uid_t = getuid()) throws {
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == expectedUID else { throw ControlFailure(code: .permission) }
    }

    static func configure(_ fd: Int32, nonblocking: Bool) throws {
        var yes: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout.size(ofValue: yes))) == 0,
              fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else { throw ControlFailure(code: .unavailable) }
        if nonblocking, fcntl(fd, F_SETFL, O_NONBLOCK) != 0 { throw ControlFailure(code: .unavailable) }
    }

    static func withAddress<T>(_ path: String, _ operation: (UnsafePointer<sockaddr>, socklen_t) throws -> T) throws -> T {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw ControlFailure(code: .bounds) }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in buffer.copyBytes(from: bytes) }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return try withUnsafePointer(to: &address) {
            try $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { try operation($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
    }

    static func frame(_ data: Data) throws -> Data {
        guard !data.isEmpty, data.count <= LocalControl.maxFrame else { throw ControlFailure(code: .bounds) }
        var size = UInt32(data.count).bigEndian
        var framed = withUnsafeBytes(of: &size) { Data($0) }
        framed.append(data)
        return framed
    }

    static func takeFrame(_ buffer: inout Data, limit: Int) throws -> Data? {
        guard buffer.count >= 4 else { return nil }
        let size = buffer.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
        guard size > 0, size <= limit else { throw ControlFailure(code: .bounds) }
        guard buffer.count >= size + 4 else { return nil }
        let payload = Data(buffer.dropFirst(4).prefix(size))
        buffer.removeFirst(size + 4)
        return payload
    }
}
