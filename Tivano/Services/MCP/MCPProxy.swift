import Foundation
import Network
import OSLog
import Synchronization

final class MCPProxy: @unchecked Sendable {
    private static let log = Logger(subsystem: "dev.tivano.Tivano", category: "mcp-proxy")
    static let shared = MCPProxy()

    /// The proxy's port, kept in the library so the provider configs written on one launch
    /// still point at it on the next. Re-picked when the saved port cannot be bound: the
    /// Dev build runs over a mirror of the release library, so both would otherwise ask for
    /// the same one, and the second to launch would answer nothing.
    static var port: UInt16 { portBox.withLock { $0 } }

    private static let portBox = Mutex<UInt16>(loadPort())
    private static let portFile = MCPPaths.directory.appendingPathComponent("proxy-port")

    private static func loadPort() -> UInt16 {
        if let text = try? String(contentsOf: portFile, encoding: .utf8),
           let saved = UInt16(text.trimmed), saved != 0 {
            return saved
        }
        let picked = pickFreePort()
        MCPPaths.writePrivate(Data("\(picked)".utf8), to: portFile)
        return picked
    }

    /// Moves to a fresh port after the saved one refused to bind, and remembers it.
    private static func repickPort() -> UInt16 {
        let picked = pickFreePort()
        portBox.withLock { $0 = picked }
        MCPPaths.writePrivate(Data("\(picked)".utf8), to: portFile)
        return picked
    }

    static func url(for serverID: String) -> String {
        "http://127.0.0.1:\(port)/mcp/\(serverID)"
    }

    private struct Route: Sendable {
        var upstream: String
        var headers: [String: String]
        var usesOAuth: Bool
    }

    private struct ConnectionBox: @unchecked Sendable {
        let connection: NWConnection
    }

    private static let headLimit = 65_536
    private static let bodyLimit = 32 * 1_024 * 1_024
    private static let responseLimit = 16 * 1024 * 1024
    private static let divider = Data("\r\n\r\n".utf8)
    /// Local connections served at once; one more than this gets a bare 503 and a close.
    /// Hydra heads each hold long-lived streams to several servers, so this stays well above a team's need.
    private static let connectionLimit = 128
    /// Seconds from accept for the whole request — head plus declared body — to arrive.
    private static let requestReadTimeout: TimeInterval = 30

    private let queue = DispatchQueue(label: "MCPProxy")

    /// `reading` stays true only from accept until the request's head and declared body
    /// are all in; the read deadline covers that window alone, never the upstream answer.
    private struct TrackedConnection: @unchecked Sendable {
        let connection: NWConnection
        var task: Task<Void, Never>?
        var reading = true
    }

    private struct State {
        var routes: [String: Route] = [:]
        var listener: NWListener?
        var connections: [ObjectIdentifier: TrackedConnection] = [:]
        var running = false
    }

    private let state = Mutex(State())

    private init() {}

    func register(serverID: String, upstream: String, headers: [String: String], usesOAuth: Bool) {
        state.withLock {
            $0.routes[serverID] = Route(upstream: upstream, headers: headers, usesOAuth: usesOAuth)
        }
    }

    func unregister(serverID: String) {
        state.withLock { _ = $0.routes.removeValue(forKey: serverID) }
    }

    func replaceAll(_ routes: [(serverID: String, upstream: String, headers: [String: String], usesOAuth: Bool)]) {
        state.withLock {
            $0.routes = Dictionary(uniqueKeysWithValues: routes.map { entry in
                (entry.serverID, Route(upstream: entry.upstream, headers: entry.headers, usesOAuth: entry.usesOAuth))
            })
        }
    }

    func start() {
        let alreadyRunning = state.withLock { state -> Bool in
            if state.running { return true }
            state.running = true
            return false
        }
        if alreadyRunning { return }
        listen(on: Self.port, canRepick: true)
    }

    /// Binds the loopback listener. The port rides in the required local endpoint alone:
    /// naming it a second time through `NWListener(using:on:)` is rejected outright
    /// (EINVAL), which left the proxy silent and every OAuth server unreachable. A port
    /// already taken (another copy of the app) fails only once the listener starts, so
    /// that case moves to a fresh port and tries again, once.
    private func listen(on port: UInt16, canRepick: Bool) {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else { return }
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: endpointPort)
        guard let listener = try? NWListener(using: parameters) else {
            Self.log.error("could not listen on \(port)")
            state.withLock { $0.running = false }
            return
        }
        state.withLock { $0.listener = listener }
        listener.stateUpdateHandler = { [weak self] newState in
            switch newState {
            case .ready:
                Self.log.info("listening on \(port)")
            case .failed(let error):
                Self.log.error("listener on \(port) failed: \(error)")
                guard let self else { return }
                listener.cancel()
                self.state.withLock { state in
                    if state.listener === listener { state.listener = nil }
                }
                if canRepick {
                    self.listen(on: Self.repickPort(), canRepick: false)
                } else {
                    self.state.withLock { $0.running = false }
                }
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
    }

    func stop() {
        let (listener, open) = state.withLock { state -> (NWListener?, [TrackedConnection]) in
            let listener = state.listener
            let open = Array(state.connections.values)
            state.listener = nil
            state.connections.removeAll()
            state.running = false
            return (listener, open)
        }
        listener?.cancel()
        for tracked in open {
            tracked.task?.cancel()
            tracked.connection.cancel()
        }
    }

    /// A loopback port nobody holds, from the kernel: bind port 0, read back what it gave,
    /// let it go. A listener asked for an ephemeral port instead fails with EINVAL on
    /// current macOS, which is how every launch used to end up on the same fallback.
    private static func pickFreePort() -> UInt16 {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socket >= 0 else { return 48123 }
        defer { close(socket) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(socket, $0, length) == 0 && getsockname(socket, $0, &length) == 0 }
        }
        guard bound else { return 48123 }
        let picked = UInt16(bigEndian: address.sin_port)
        return picked == 0 ? 48123 : picked
    }

    private func accept(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        let admitted = state.withLock { state -> Bool in
            guard state.connections.count < Self.connectionLimit else { return false }
            state.connections[id] = TrackedConnection(connection: connection)
            return true
        }
        connection.stateUpdateHandler = { [weak self] newState in
            guard case .failed = newState, let self else { return }
            connection.cancel()
            self.forget(connection)
        }
        connection.start(queue: queue)
        guard admitted else {
            respond(connection: connection, status: 503, body: Self.jsonError("too many connections"))
            return
        }
        queue.asyncAfter(deadline: .now() + Self.requestReadTimeout) { [weak self] in
            guard let self,
                  let tracked = self.state.withLock({ $0.connections[id] }),
                  // An identifier can be reused by a later connection once this one is freed.
                  tracked.connection === connection, tracked.reading else { return }
            self.respond(connection: tracked.connection, status: 408, body: Self.jsonError("request timed out"))
        }
        readHead(connection, Data())
    }

    private func forget(_ connection: NWConnection) {
        let task = state.withLock {
            $0.connections.removeValue(forKey: ObjectIdentifier(connection))?.task
        }
        task?.cancel()
    }

    private func readHead(_ connection: NWConnection, _ prefix: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: Self.headLimit) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            var buffer = prefix
            if let data, !data.isEmpty {
                buffer.append(data)
            }
            if let divider = buffer.range(of: Self.divider) {
                guard divider.lowerBound - buffer.startIndex <= Self.headLimit else {
                    self.respond(connection: connection, status: 413, body: Self.jsonError("request head too large"))
                    return
                }
                let head = buffer[buffer.startIndex..<divider.lowerBound]
                let rest = buffer[divider.upperBound..<buffer.endIndex]
                self.handleExchange(connection: connection, head: Data(head), rest: Data(rest))
                return
            }
            if buffer.count > Self.headLimit {
                self.respond(connection: connection, status: 413, body: Self.jsonError("request head too large"))
                return
            }
            if isComplete || error != nil {
                connection.cancel()
                self.forget(connection)
                return
            }
            self.readHead(connection, buffer)
        }
    }

    private static func parseHead(_ head: Data) -> (method: String, path: String, headers: [String: String])? {
        guard let text = String(data: head, encoding: .isoLatin1) else { return nil }
        let lines = text.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count == 3, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if !name.isEmpty {
                if name == "content-length", let existing = headers[name], existing != value {
                    return nil
                }
                headers[name] = value
            }
        }
        return (String(parts[0]), String(parts[1]), headers)
    }

    private func handleExchange(connection: NWConnection, head: Data, rest: Data) {
        guard let (method, path, clientHeaders) = Self.parseHead(head) else {
            respond(connection: connection, status: 400, body: Self.jsonError("bad request"))
            return
        }
        if let transferEncoding = clientHeaders["transfer-encoding"],
           transferEncoding.lowercased().contains("chunked") {
            respond(connection: connection, status: 411, body: Self.jsonError("chunked request bodies are not supported"))
            return
        }
        let contentLength: Int
        if let value = clientHeaders["content-length"] {
            guard !value.isEmpty, value.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
                  let length = Int(value), length >= 0 else {
                respond(connection: connection, status: 400, body: Self.jsonError("invalid content-length"))
                return
            }
            contentLength = length
        } else {
            contentLength = 0
        }
        if contentLength > Self.bodyLimit {
            respond(connection: connection, status: 413, body: Self.jsonError("request body too large"))
            return
        }
        if rest.count >= contentLength {
            routeRequest(connection: connection, method: method, path: path, clientHeaders: clientHeaders, body: Data(rest.prefix(contentLength)))
        } else {
            readBody(connection: connection, method: method, path: path, clientHeaders: clientHeaders, buffer: rest, need: contentLength)
        }
    }

    private func readBody(connection: NWConnection, method: String, path: String, clientHeaders: [String: String], buffer: Data, need: Int) {
        if buffer.count >= need {
            routeRequest(connection: connection, method: method, path: path, clientHeaders: clientHeaders, body: Data(buffer.prefix(need)))
            return
        }
        connection.receive(minimumIncompleteLength: 1, maximumLength: min(need - buffer.count, Self.headLimit)) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            var next = buffer
            if let data, !data.isEmpty {
                next.append(data)
            }
            if next.count >= need {
                self.routeRequest(connection: connection, method: method, path: path, clientHeaders: clientHeaders, body: Data(next.prefix(need)))
            } else if isComplete || error != nil {
                connection.cancel()
                self.forget(connection)
            } else {
                self.readBody(connection: connection, method: method, path: path, clientHeaders: clientHeaders, buffer: next, need: need)
            }
        }
    }

    private func routeRequest(connection: NWConnection, method: String, path: String, clientHeaders: [String: String], body: Data) {
        let id = ObjectIdentifier(connection)
        state.withLock { $0.connections[id]?.reading = false }
        // Loopback alone does not keep browsers out: a cross-site POST from a page
        // arrives either with a Host that is not this loopback port (DNS rebinding)
        // or carrying the page's Origin, which the CLI clients here never send.
        let host = clientHeaders["host"] ?? ""
        guard host == "127.0.0.1:\(Self.port)" || host == "localhost:\(Self.port)",
              clientHeaders["origin"].map(Self.loopbackOrigin) ?? true,
              method.uppercased() != "POST" || Self.jsonContentType(clientHeaders["content-type"])
        else {
            respond(connection: connection, status: 403, body: Self.jsonError("forbidden"))
            return
        }
        let bare = String(path.prefix(upTo: path.firstIndex(of: "?") ?? path.endIndex))
        // A path the proxy holds no route for is a bad gateway, never a 404: the app reads a 404
        // seen through the proxy as the server's own answer (GitLab answers 404 while MCP is off).
        guard bare.hasPrefix("/mcp/") else {
            respond(connection: connection, status: 502, body: Self.jsonError("unknown server"))
            return
        }
        let serverID = String(bare.dropFirst("/mcp/".count))
        guard !serverID.isEmpty, !serverID.contains("/") else {
            respond(connection: connection, status: 502, body: Self.jsonError("unknown server"))
            return
        }
        let route = state.withLock { $0.routes[serverID] }
        guard let route else {
            respond(connection: connection, status: 502, body: Self.jsonError("unknown server"))
            return
        }
        let box = ConnectionBox(connection: connection)
        let task = Task { [weak self] in
            guard let self else {
                box.connection.cancel()
                return
            }
            do {
                try await self.sendUpstream(box: box, serverID: serverID, route: route, method: method, clientHeaders: clientHeaders, body: body)
            } catch let error where error is CancellationError || (error as? URLError)?.code == .cancelled {
                // The local connection went away; nothing left to answer.
            } catch {
                Self.log.error("request to '\(serverID)' failed: \(error.localizedDescription)")
                self.respond(connection: box.connection, status: 502, body: Self.jsonError("upstream request failed"))
            }
        }
        state.withLock { $0.connections[id]?.task = task }
    }

    /// An http(s) origin naming this machine — `null` and every other host are refused.
    private static func loopbackOrigin(_ origin: String) -> Bool {
        guard let url = URL(string: origin),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host else { return false }
        return host == "127.0.0.1" || host == "localhost" || host == "::1"
    }

    /// `application/json` with optional parameters (`; charset=utf-8`).
    private static func jsonContentType(_ contentType: String?) -> Bool {
        guard let mediaType = contentType?.split(separator: ";", maxSplits: 1).first else { return false }
        return mediaType.trimmingCharacters(in: .whitespaces).lowercased() == "application/json"
    }

    private func sendUpstream(box: ConnectionBox, serverID: String, route: Route, method: String, clientHeaders: [String: String], body: Data) async throws {
        guard let upstreamURL = URL(string: route.upstream) else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: upstreamURL)
        request.httpMethod = method
        request.timeoutInterval = 3_600
        let passthrough = [
            ("content-type", "Content-Type"),
            ("accept", "Accept"),
            ("mcp-session-id", "Mcp-Session-Id"),
            ("mcp-protocol-version", "MCP-Protocol-Version"),
            ("last-event-id", "Last-Event-ID"),
        ]
        for (clientName, canonicalName) in passthrough {
            if let value = clientHeaders[clientName] {
                request.setValue(value, forHTTPHeaderField: canonicalName)
            }
        }
        for (name, value) in route.headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        if route.usesOAuth {
            let token: String
            do {
                token = try await MCPOAuth.accessToken(serverID: serverID)
            } catch {
                respond(connection: box.connection, status: 401, body: Self.jsonError(error.localizedDescription))
                return
            }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if !body.isEmpty {
            request.httpBody = body
        }
        var (stream, response) = try await URLSession.shared.bytes(for: request)
        defer { stream.task.cancel() }
        var http = response as? HTTPURLResponse
        if route.usesOAuth, http?.statusCode == 401 {
            if let refreshed = try? await MCPOAuth.accessToken(serverID: serverID) {
                request.setValue("Bearer \(refreshed)", forHTTPHeaderField: "Authorization")
                stream.task.cancel()
                (stream, response) = try await URLSession.shared.bytes(for: request)
                http = response as? HTTPURLResponse
            }
        }
        guard let http else {
            throw URLError(.badServerResponse)
        }
        try await writeBack(box: box, serverID: serverID, response: http, stream: stream)
    }

    private func writeBack(box: ConnectionBox, serverID: String, response: HTTPURLResponse, stream: URLSession.AsyncBytes) async throws {
        let contentType = response.value(forHTTPHeaderField: "Content-Type")
        var headers: [(String, String)] = []
        if let contentType {
            headers.append(("Content-Type", contentType))
        }
        if let sessionID = response.value(forHTTPHeaderField: "Mcp-Session-Id") {
            headers.append(("Mcp-Session-Id", sessionID))
        }
        if let cacheControl = response.value(forHTTPHeaderField: "Cache-Control") {
            headers.append(("Cache-Control", cacheControl))
        }
        let connection = box.connection
        if contentType?.lowercased().contains("text/event-stream") == true {
            headers.append(("Transfer-Encoding", "chunked"))
            headers.append(("Connection", "close"))
            guard await send(connection, Data(Self.statusHead(status: response.statusCode, headers: headers).utf8)) else {
                connection.cancel()
                forget(connection)
                return
            }
            var canSend = true
            do {
                var buffer = Data()
                for try await byte in stream {
                    buffer.append(byte)
                    if byte == UInt8(ascii: "\n") || buffer.count >= 16_384 {
                        canSend = await send(connection, Self.chunk(buffer))
                        buffer.removeAll(keepingCapacity: true)
                        if !canSend { break }
                    }
                }
                if canSend, !buffer.isEmpty {
                    canSend = await send(connection, Self.chunk(buffer))
                }
            } catch {
                // A broken upstream stream gets no terminating chunk: the client must see
                // the connection die, not a clean end of events.
                if !Task.isCancelled {
                    Self.log.error("stream from '\(serverID)' failed mid-response: \(error.localizedDescription)")
                }
                canSend = false
            }
            if canSend {
                await send(connection, Data("0\r\n\r\n".utf8))
            }
            connection.cancel()
            forget(connection)
        } else {
            var payload = Data()
            if response.expectedContentLength > 0 {
                payload.reserveCapacity(Int(min(response.expectedContentLength, Int64(Self.responseLimit))))
            }
            for try await byte in stream {
                guard payload.count < Self.responseLimit else {
                    respond(connection: connection, status: 502, body: Self.jsonError("upstream response too large"))
                    return
                }
                payload.append(byte)
            }
            headers.append(("Content-Length", "\(payload.count)"))
            headers.append(("Connection", "close"))
            var out = Data(Self.statusHead(status: response.statusCode, headers: headers).utf8)
            out.append(payload)
            await send(connection, out)
            connection.cancel()
            forget(connection)
        }
    }

    private static func chunk(_ payload: Data) -> Data {
        var frame = Data((String(payload.count, radix: 16) + "\r\n").utf8)
        frame.append(payload)
        frame.append(Data("\r\n".utf8))
        return frame
    }

    @discardableResult
    private func send(_ connection: NWConnection, _ data: Data) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            connection.send(content: data, completion: .contentProcessed { error in
                continuation.resume(returning: error == nil)
            })
        }
    }

    private func respond(connection: NWConnection, status: Int, body: Data) {
        var out = Data(Self.statusHead(status: status, headers: [
            ("Content-Type", "application/json"),
            ("Content-Length", "\(body.count)"),
            ("Connection", "close"),
        ]).utf8)
        out.append(body)
        connection.send(content: out, completion: .contentProcessed { [weak self] _ in
            connection.cancel()
            self?.forget(connection)
        })
    }

    private static func statusHead(status: Int, headers: [(String, String)]) -> String {
        var head = "HTTP/1.1 \(status) \(reasonPhrase(for: status))\r\n"
        for (name, value) in headers {
            head += "\(name): \(value)\r\n"
        }
        head += "\r\n"
        return head
    }

    private static func reasonPhrase(for status: Int) -> String {
        switch status {
        case 200: "OK"
        case 201: "Created"
        case 202: "Accepted"
        case 204: "No Content"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 408: "Request Timeout"
        case 411: "Length Required"
        case 413: "Content Too Large"
        case 500: "Internal Server Error"
        case 502: "Bad Gateway"
        case 503: "Service Unavailable"
        default:
            if (200..<300).contains(status) { "OK" } else { "Error" }
        }
    }

    private static func jsonError(_ message: String) -> Data {
        let escaped = message
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        return Data("{\"error\":\"\(escaped)\"}".utf8)
    }
}
