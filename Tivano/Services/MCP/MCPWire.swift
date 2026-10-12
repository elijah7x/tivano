import Foundation
import Synchronization

/// The wire pieces MCPHub and MCPProbe share. The HTTP POST returns at the first SSE
/// message with a matching id, so a stream the server holds open doesn't hang it.
enum MCPWire {
    nonisolated static let protocolVersion = "2025-06-18"

    nonisolated static func initializeParams() -> JSONValue {
        .object([
            "protocolVersion": .string(protocolVersion),
            "capabilities": .object([:]),
            "clientInfo": .object(["name": .string("Tivano"), "version": .string("1.0")]),
        ])
    }

    nonisolated static func request(id: Int, method: String, params: JSONValue?) -> JSONValue {
        var object: [String: JSONValue] = [
            "jsonrpc": .string("2.0"),
            "id": .int(id),
            "method": .string(method),
        ]
        if let params { object["params"] = params }
        return .object(object)
    }

    nonisolated static func notification(method: String) -> JSONValue {
        .object(["jsonrpc": .string("2.0"), "method": .string(method)])
    }

    nonisolated static func errorMessage(in value: JSONValue) -> String? {
        guard let error = value["error"], error.object != nil else { return nil }
        return error["message"]?.string ?? String(localized: "The server returned an error without a message.")
    }

    /// Paging for `tools/list`: ten pages at most, each cursor fed back until the server
    /// stops handing one out. The caller owns the request and its error type.
    nonisolated static func listTools(_ page: (JSONValue) async throws -> JSONValue) async throws -> [JSONValue] {
        var tools: [JSONValue] = []
        var cursor: String?
        for _ in 0..<10 {
            var params: [String: JSONValue] = [:]
            if let cursor { params["cursor"] = .string(cursor) }
            let reply = try await page(.object(params))
            guard let list = reply["result"]?.object,
                  let items = list["tools"]?.array else { throw MCPResponseError.invalidToolList }
            for item in items {
                guard item.object != nil, item["name"]?.string != nil,
                      item["inputSchema"]?.object != nil,
                      item["description"] == nil || item["description"]?.string != nil else {
                    throw MCPResponseError.invalidToolList
                }
            }
            tools += items
            guard let next = list["nextCursor"] else { break }
            guard let next = next.string else { throw MCPResponseError.invalidToolList }
            if next.isEmpty { break }
            cursor = next
        }
        return tools
    }

    // MARK: - Streamable HTTP

    nonisolated static func post(
        to url: URL,
        headers: [String: String],
        sessionID: String?,
        payload: JSONValue,
        id: Int?,
        timeout: TimeInterval
    ) async throws -> MCPHTTPReply {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.httpBody = payload.data()
        for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue(protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
        if let sessionID { request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }

        // A dedicated session gives cancellation ownership even before headers arrive.
        let postRequest = request
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        return try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: MCPHTTPReply.self) { group in
                group.addTask { try await readPost(postRequest, session: session, id: id) }
                group.addTask {
                    try await Task.sleep(for: .seconds(timeout))
                    session.invalidateAndCancel()
                    throw MCPWireError.timedOut
                }
                defer { group.cancelAll() }
                guard let reply = try await group.next() else { throw CancellationError() }
                try Task.checkCancellation()
                return reply
            }
        } onCancel: {
            session.invalidateAndCancel()
        }
    }

    nonisolated private static let responseLimit = 16 * 1024 * 1024

    nonisolated private static func readPost(_ request: URLRequest, session: URLSession, id: Int?) async throws -> MCPHTTPReply {
        let (bytes, response) = try await session.bytes(for: request)
        // AsyncBytes.task owns the transfer; cancel also on early SSE success or error.
        defer { bytes.task.cancel() }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse else {
                throw MCPHTTPError(status: nil, body: "")
            }
            let sessionID = http.value(forHTTPHeaderField: "Mcp-Session-Id")
            guard (200..<300).contains(http.statusCode) else {
                var data = Data()
                for try await byte in bytes {
                    try Task.checkCancellation()
                    data.append(byte)
                    if data.count >= 2_000 { break }
                }
                throw MCPHTTPError(status: http.statusCode, body: String(decoding: data, as: UTF8.self).trimmed)
            }
            let contentType = http.value(forHTTPHeaderField: "Content-Type") ?? ""
            guard contentType.lowercased().contains("text/event-stream") else {
                var data = Data()
                for try await byte in bytes {
                    try Task.checkCancellation()
                    guard data.count < responseLimit else {
                        bytes.task.cancel()
                        throw MCPResponseError.responseTooLarge
                    }
                    data.append(byte)
                }
                guard !data.isEmpty else { return MCPHTTPReply(sessionID: sessionID, body: nil) }
                let body = JSONValue.parse(data)
                if let id {
                    guard let body, isReply(body, to: id) else {
                        throw MCPHTTPError(status: nil, body: "")
                    }
                }
                return MCPHTTPReply(sessionID: sessionID, body: body)
            }
            guard let id else { return MCPHTTPReply(sessionID: sessionID, body: nil) }
            var event = SSEEvent()
            for try await byte in bytes {
                try Task.checkCancellation()
                if let text = try event.append(byte),
                   let value = JSONValue.parse(text), isReply(value, to: id) {
                    return MCPHTTPReply(sessionID: sessionID, body: value)
                }
            }
            return MCPHTTPReply(sessionID: sessionID, body: nil)
        } onCancel: {
            bytes.task.cancel()
        }
    }

    /// Limits raw event bytes, including ignored fields and an unterminated line.
    private struct SSEEvent {
        var line = Data()
        var data = Data()
        var size = 0
        var afterCR = false
        var firstLine = true

        mutating func append(_ byte: UInt8) throws -> String? {
            if afterCR {
                afterCR = false
                if byte == 0x0A {
                    if size > 0 {
                        guard size < MCPWire.responseLimit else { throw MCPResponseError.eventTooLarge }
                        size += 1
                    }
                    return nil
                }
            }
            guard size < MCPWire.responseLimit else { throw MCPResponseError.eventTooLarge }
            size += 1
            if byte != 0x0A && byte != 0x0D {
                line.append(byte)
                return nil
            }
            afterCR = byte == 0x0D
            if firstLine {
                firstLine = false
                if line.starts(with: [0xEF, 0xBB, 0xBF]) { line.removeFirst(3) }
            }
            defer { line.removeAll(keepingCapacity: true) }
            if line.isEmpty {
                size = 0
                guard !data.isEmpty else { return nil }
                data.removeLast() // SSE removes the final newline after joining data fields.
                let text = String(decoding: data, as: UTF8.self)
                data.removeAll(keepingCapacity: true)
                return text
            }
            let colon = line.firstIndex(of: 0x3A) ?? line.endIndex
            guard line[..<colon].elementsEqual("data".utf8) else { return nil }
            var value = colon == line.endIndex ? line.endIndex : line.index(after: colon)
            if value < line.endIndex, line[value] == 0x20 { value = line.index(after: value) }
            data.append(contentsOf: line[value...])
            data.append(0x0A)
            return nil
        }
    }

    nonisolated private static func isReply(_ value: JSONValue, to id: Int) -> Bool {
        guard let object = value.object, object["jsonrpc"]?.string == "2.0",
              object["method"] == nil, object["id"] == .int(id) else { return false }
        return (object["result"] != nil) != (object["error"] != nil)
    }
}

struct MCPHTTPReply: Sendable {
    let sessionID: String?
    let body: JSONValue?
}

struct MCPHTTPError: Error, Sendable {
    let status: Int?
    let body: String
}

enum MCPResponseError: LocalizedError, Sendable {
    case responseTooLarge
    case eventTooLarge
    case invalidToolList
    case invalidToolResult

    var errorDescription: String? {
        switch self {
        case .responseTooLarge: String(localized: "The MCP response exceeded 16 MiB.")
        case .eventTooLarge: String(localized: "The MCP event exceeded 16 MiB.")
        case .invalidToolList: String(localized: "The server sent an invalid tool list.")
        case .invalidToolResult: String(localized: "The server sent an invalid tool result.")
        }
    }
}

enum MCPWireError: Error, Sendable {
    case exited(Int32?)
    case timedOut
}

/// A stdio MCP server; each request waits on a continuation for the reply with its id.
final class MCPStdioConnection: Sendable {
    let process: StdioProcess

    private struct State {
        var nextID = 1
        var pending: [RPCID: CheckedContinuation<JSONValue, Error>] = [:]
        var outstanding: Set<RPCID> = []
        var buffered: [RPCID: JSONValue] = [:]
        var exitStatus: Int32?
        var closed = false
    }

    private let state = Mutex(State())

    init(process: StdioProcess) {
        self.process = process
    }

    static func launch(executable: URL, arguments: [String], environment: [String: String]) throws -> MCPStdioConnection {
        let process = StdioProcess(
            executable: executable,
            arguments: arguments,
            directory: FileManager.default.homeDirectoryForCurrentUser,
            environment: environment
        )
        let connection = MCPStdioConnection(process: process)
        try process.start()
        connection.read()
        return connection
    }

    func stop() {
        close(status: nil)
        process.terminate()
    }

    var errorTail: String { process.errorTail }

    func notify(_ method: String) {
        state.withLock { state in
            guard !state.closed else { return }
            process.send(MCPWire.notification(method: method))
        }
    }

    func request(_ method: String, _ params: JSONValue?, timeout: TimeInterval) async throws -> JSONValue {
        try Task.checkCancellation()
        try state.withLock { state in
            if state.closed { throw MCPWireError.exited(state.exitStatus) }
        }
        guard process.isRunning else { throw MCPWireError.exited(await process.waitForExit()) }
        let id = try state.withLock { state -> Int in
            guard !state.closed else { throw MCPWireError.exited(state.exitStatus) }
            let id = state.nextID
            state.nextID += 1
            state.outstanding.insert(.int(id))
            // Register before enqueueing the write: a reply can beat awaitReply.
            process.send(MCPWire.request(id: id, method: method, params: params))
            return id
        }
        let key = RPCID.int(id)
        return try await withThrowingTaskGroup(of: JSONValue.self) { group in
            group.addTask { try await self.awaitReply(key) }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw MCPWireError.timedOut
            }
            do {
                guard let value = try await group.next() else { throw MCPWireError.timedOut }
                group.cancelAll()
                return value
            } catch {
                group.cancelAll()
                self.abandon(key)
                throw error
            }
        }
    }

    private func read() {
        let messages = process.messages
        Task {
            for await message in messages { self.handle(message) }
            let status = await self.process.waitForExit()
            self.close(status: status)
        }
    }

    private func awaitReply(_ id: RPCID) async throws -> JSONValue {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let immediate = self.state.withLock { state -> Result<JSONValue, Error>? in
                    if state.closed { return .failure(MCPWireError.exited(state.exitStatus)) }
                    guard !Task.isCancelled, state.outstanding.contains(id) else { return .failure(CancellationError()) }
                    if let value = state.buffered.removeValue(forKey: id) {
                        state.outstanding.remove(id)
                        return .success(value)
                    }
                    state.pending[id] = continuation
                    return nil
                }
                switch immediate {
                case .success(let value): continuation.resume(returning: value)
                case .failure(let error): continuation.resume(throwing: error)
                case nil: break
                }
            }
        } onCancel: {
            self.abandon(id)
        }
    }

    private func handle(_ message: JSONValue) {
        guard let object = message.object, object["jsonrpc"]?.string == "2.0" else { return }
        if let methodValue = object["method"] {
            guard let method = methodValue.string,
                  let rawID = object["id"] else { return }
            switch rawID {
            case .int, .string: break
            case .double(let number):
                guard number.isFinite else { return }
            default: return
            }
            // Server request ids are independent of our outstanding request ids.
            let reply: JSONValue = .object([
                "jsonrpc": .string("2.0"), "id": rawID,
                method == "ping" ? "result" : "error": method == "ping" ? .object([:]) : .object([
                    "code": .int(-32601), "message": .string("Method not found"),
                ]),
            ])
            state.withLock { state in
                guard !state.closed else { return }
                process.send(reply)
            }
            return
        }
        guard (object["result"] != nil) != (object["error"] != nil),
              let rawID = object["id"] else { return }
        let id: RPCID
        switch rawID {
        case .int(let number): id = .int(number)
        case .string(let string): id = .string(string)
        case .double(let number):
            guard let number = Int(exactly: number) else { return }
            id = .int(number)
        default: return
        }
        let continuation = state.withLock { state -> CheckedContinuation<JSONValue, Error>? in
            guard !state.closed, state.outstanding.contains(id), state.buffered[id] == nil else { return nil }
            if let continuation = state.pending.removeValue(forKey: id) {
                state.outstanding.remove(id)
                return continuation
            }
            state.buffered[id] = message
            return nil
        }
        continuation?.resume(returning: message)
    }

    private func abandon(_ id: RPCID) {
        let continuation = state.withLock { state in
            state.outstanding.remove(id)
            state.buffered.removeValue(forKey: id)
            return state.pending.removeValue(forKey: id)
        }
        continuation?.resume(throwing: CancellationError())
    }

    private func close(status: Int32?) {
        let pending = state.withLock { state -> [CheckedContinuation<JSONValue, Error>] in
            guard !state.closed else { return [] }
            state.closed = true
            state.exitStatus = status
            let pending = Array(state.pending.values)
            state.pending.removeAll()
            state.outstanding.removeAll()
            state.buffered.removeAll()
            return pending
        }
        for continuation in pending { continuation.resume(throwing: MCPWireError.exited(status)) }
    }
}
