import Darwin
import Foundation
import Network
import Synchronization

/// A loopback-only HTTP server; the owner's tunnel supplies TLS.
final class RemoteMCPHTTPServer: @unchecked Sendable {
    private struct TrackedConnection: @unchecked Sendable {
        let connection: NWConnection
        var task: Task<Void, Never>?
        var reading = true
    }

    private final class Startup: Sendable {
        let semaphore = DispatchSemaphore(value: 0)
        let result = Mutex<Result<Void, Error>?>(nil)

        func finish(_ value: Result<Void, Error>) {
            let first = result.withLock { result in
                guard result == nil else { return false }
                result = value
                return true
            }
            if first { semaphore.signal() }
        }
    }

    private struct State {
        var listener: NWListener?
        var startup: Startup?
        var running = false
        var connections: [ObjectIdentifier: TrackedConnection] = [:]
    }

    private let port: UInt16
    private let handler: @Sendable (RemoteHTTPRequest) async -> RemoteHTTPResponse
    private let queue = DispatchQueue(label: "RemoteMCPHTTPServer")
    private let state = Mutex(State())
    private static let divider = Data("\r\n\r\n".utf8)

    init(port: UInt16, handler: @escaping @Sendable (RemoteHTTPRequest) async -> RemoteHTTPResponse) {
        self.port = port
        self.handler = handler
    }

    var isRunning: Bool { state.withLock { $0.running } }

    func start() throws {
        guard port != 0, let endpointPort = NWEndpoint.Port(rawValue: port) else {
            throw NWError.posix(.EINVAL)
        }
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: endpointPort)
        let listener = try NWListener(using: parameters)
        let startup = Startup()
        listener.stateUpdateHandler = { [weak self, weak listener] newState in
            guard let self, let listener else {
                startup.finish(.failure(CancellationError()))
                return
            }
            switch newState {
            case .ready:
                let active = self.state.withLock { state in
                    guard state.listener === listener else { return false }
                    state.running = true
                    return true
                }
                startup.finish(active ? .success(()) : .failure(CancellationError()))
            case .failed(let error), .waiting(let error):
                startup.finish(.failure(error))
                self.stop(listener: listener)
            case .cancelled:
                self.stop(listener: listener)
                startup.finish(.failure(CancellationError()))
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self, weak listener] connection in
            guard let self, let listener else { connection.cancel(); return }
            self.accept(connection, listener: listener)
        }
        let launched = try state.withLock { state in
            if state.running { return false }
            guard state.listener == nil else { throw NWError.posix(.EALREADY) }
            state.listener = listener
            state.startup = startup
            listener.start(queue: queue)
            return true
        }
        guard launched else { listener.cancel(); return }
        // NWListener reports a successful bind through .ready, after start(queue:).
        // https://developer.apple.com/documentation/network/nwlistener/state-swift.enum
        startup.semaphore.wait()
        try startup.result.withLock { try $0!.get() }
    }

    func stop() { stop(listener: nil) }

    private func stop(listener expected: NWListener?) {
        let stopped = state.withLock { state -> (NWListener?, Startup?, [TrackedConnection]) in
            if let expected, state.listener !== expected { return (nil, nil, []) }
            let result = (state.listener, state.startup, Array(state.connections.values))
            state = State()
            return result
        }
        stopped.1?.finish(.failure(CancellationError()))
        stopped.0?.cancel()
        for tracked in stopped.2 {
            tracked.task?.cancel()
            tracked.connection.cancel()
        }
    }

    static func pickFreePort() -> UInt16 {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socket >= 0 else { return 0 }
        defer { Darwin.close(socket) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(socket, $0, length) == 0 && getsockname(socket, $0, &length) == 0
            }
        }
        return bound ? UInt16(bigEndian: address.sin_port) : 0
    }

    private func accept(_ connection: NWConnection, listener: NWListener) {
        let id = ObjectIdentifier(connection)
        let admission = state.withLock { state -> Int in
            guard state.listener === listener, state.running else { return 0 }
            guard state.connections.count < RemoteMCP.maxConnections else { return 503 }
            state.connections[id] = TrackedConnection(connection: connection)
            return 200
        }
        guard admission != 0 else { connection.cancel(); return }
        connection.stateUpdateHandler = { [weak self] newState in
            switch newState {
            case .failed, .cancelled: self?.close(connection)
            default: break
            }
        }
        connection.start(queue: queue)
        guard admission == 200 else {
            write(.empty(503), to: connection)
            return
        }
        queue.asyncAfter(deadline: .now() + RemoteMCP.requestTimeout) { [weak self] in
            guard let self else { return }
            let expired = self.state.withLock { state -> TrackedConnection? in
                guard let tracked = state.connections[id], tracked.connection === connection,
                      tracked.reading else { return nil }
                return state.connections.removeValue(forKey: id)
            }
            expired?.task?.cancel()
            expired?.connection.cancel()
        }
        readHead(connection, prefix: Data())
    }

    private func close(_ connection: NWConnection) {
        let tracked = state.withLock { $0.connections.removeValue(forKey: ObjectIdentifier(connection)) }
        tracked?.task?.cancel()
        connection.cancel()
    }

    private func isReading(_ connection: NWConnection) -> Bool {
        state.withLock { $0.connections[ObjectIdentifier(connection)]?.reading == true }
    }

    private func readHead(_ connection: NWConnection, prefix: Data) {
        guard isReading(connection) else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: RemoteMCP.maxHead + 4 - prefix.count) { [weak self] data, _, complete, error in
            guard let self else { connection.cancel(); return }
            guard self.isReading(connection) else { return }
            var buffer = prefix
            if let data { buffer.append(data) }
            if let divider = buffer.range(of: Self.divider) {
                guard divider.lowerBound <= RemoteMCP.maxHead else {
                    self.reject(431, connection: connection)
                    return
                }
                self.readRequest(connection, head: Data(buffer[..<divider.lowerBound]), rest: Data(buffer[divider.upperBound...]))
            } else if buffer.count >= RemoteMCP.maxHead + 4 {
                self.reject(431, connection: connection)
            } else if error != nil {
                self.close(connection)
            } else if complete {
                self.reject(400, connection: connection)
            } else {
                self.readHead(connection, prefix: buffer)
            }
        }
    }

    private static func isToken(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0)
                || "!#$%&'*+-.^_`|~".utf8.contains($0)
        }
    }

    private static func parseHead(_ data: Data) -> RemoteHTTPRequest? {
        guard let text = String(data: data, encoding: .isoLatin1) else { return nil }
        let lines = text.components(separatedBy: "\r\n")
        guard let first = lines.first else { return nil }
        let parts = first.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3, isToken(String(parts[0])), parts[2] == "HTTP/1.1",
              parts[1].hasPrefix("/"), !parts[1].contains("#"),
              parts[1].utf8.allSatisfy({ $0 > 32 && $0 < 127 }) else { return nil }
        let target = parts[1].split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        guard let path = String(target[0]).removingPercentEncoding else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { return nil }
            let name = String(line[..<colon])
            let value = String(line[line.index(after: colon)...])
            guard isToken(name), value.utf8.allSatisfy({ $0 == 9 || ($0 >= 32 && $0 != 127) }) else { return nil }
            headers[name.lowercased()] = value.trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
        }
        return RemoteHTTPRequest(method: String(parts[0]), path: path,
                                 query: target.count == 2 ? RemoteHTTPRequest.parseForm(String(target[1])) : [:],
                                 headers: headers, body: Data())
    }

    private func readRequest(_ connection: NWConnection, head: Data, rest: Data) {
        guard let request = Self.parseHead(head) else { reject(400, connection: connection); return }
        guard request.headers["transfer-encoding"] == nil else { reject(501, connection: connection); return }
        let length: Int
        if let value = request.headers["content-length"] {
            guard !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }) else {
                reject(400, connection: connection)
                return
            }
            guard let parsed = Int(value), parsed <= RemoteMCP.maxBody else {
                reject(413, connection: connection)
                return
            }
            length = parsed
        } else {
            length = 0
        }
        readBody(connection, request: request, buffer: rest, length: length)
    }

    private func readBody(_ connection: NWConnection, request: RemoteHTTPRequest, buffer: Data, length: Int) {
        guard isReading(connection) else { return }
        if buffer.count >= length {
            var complete = request
            complete.body = Data(buffer.prefix(length))
            dispatch(complete, connection: connection)
            return
        }
        connection.receive(minimumIncompleteLength: 1, maximumLength: length - buffer.count) { [weak self] data, _, complete, error in
            guard let self else { connection.cancel(); return }
            guard self.isReading(connection) else { return }
            var next = buffer
            if let data { next.append(data) }
            if next.count >= length {
                self.readBody(connection, request: request, buffer: next, length: length)
            } else if error != nil {
                self.close(connection)
            } else if complete {
                self.reject(400, connection: connection)
            } else {
                self.readBody(connection, request: request, buffer: next, length: length)
            }
        }
    }

    private func dispatch(_ request: RemoteHTTPRequest, connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        state.withLock { state in
            guard state.connections[id]?.reading == true else { return }
            state.connections[id]?.reading = false
            state.connections[id]?.task = Task { [weak self] in
                guard let self, !Task.isCancelled,
                      self.state.withLock({ $0.connections[id] != nil }) else { return }
                let response = await self.handler(request)
                guard !Task.isCancelled else { return }
                self.queue.async { [weak self] in
                    guard let self, self.state.withLock({ $0.connections[id] != nil }) else { return }
                    self.write(response, to: connection)
                }
            }
        }
    }

    private func reject(_ status: Int, connection: NWConnection) {
        let active = state.withLock { state in
            let id = ObjectIdentifier(connection)
            guard state.connections[id]?.reading == true else { return false }
            state.connections[id]?.reading = false
            return true
        }
        if active { write(.empty(status), to: connection) }
    }

    private func write(_ response: RemoteHTTPResponse, to connection: NWConnection) {
        var head = "HTTP/1.1 \(response.status) \(Self.reasonPhrase(response.status))\r\n"
        for (name, value) in response.headers {
            guard !["content-length", "connection", "transfer-encoding"].contains(name.lowercased()),
                  Self.isToken(name), !value.contains("\r"), !value.contains("\n") else { continue }
            head += "\(name): \(value)\r\n"
        }
        head += "Content-Length: \(response.body.count)\r\nConnection: close\r\n\r\n"
        var output = Data(head.utf8)
        output.append(response.body)
        connection.send(content: output, completion: .contentProcessed { [weak self] _ in
            connection.cancel()
            self?.close(connection)
        })
    }

    private static func reasonPhrase(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 201: "Created"
        case 202: "Accepted"
        case 204: "No Content"
        case 301: "Moved Permanently"
        case 302: "Found"
        case 303: "See Other"
        case 304: "Not Modified"
        case 307: "Temporary Redirect"
        case 308: "Permanent Redirect"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 406: "Not Acceptable"
        case 408: "Request Timeout"
        case 409: "Conflict"
        case 410: "Gone"
        case 411: "Length Required"
        case 413: "Content Too Large"
        case 414: "URI Too Long"
        case 415: "Unsupported Media Type"
        case 422: "Unprocessable Content"
        case 429: "Too Many Requests"
        case 431: "Request Header Fields Too Large"
        case 500: "Internal Server Error"
        case 501: "Not Implemented"
        case 502: "Bad Gateway"
        case 503: "Service Unavailable"
        case 504: "Gateway Timeout"
        default: HTTPURLResponse.localizedString(forStatusCode: status)
        }
    }
}
