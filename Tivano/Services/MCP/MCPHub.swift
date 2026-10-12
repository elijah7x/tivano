import Foundation
import Synchronization

enum MCPHubError: LocalizedError, Sendable {
    case unknownTool(String)
    case server(String)

    var errorDescription: String? {
        switch self {
        case .unknownTool(let name):
            return String(format: String(localized: "Unknown tool: %@."), name)
        case .server(let message):
            return message
        }
    }
}

actor MCPHub {
    static let shared = MCPHub()

    /// Every server process started this run, so the app can end them as it quits: a
    /// `Process` child outlives its parent, and an `npx` server left behind would keep
    /// running until the Mac restarts.
    private static let liveProcesses = MCPLiveProcesses()

    nonisolated static func track(_ process: StdioProcess) { liveProcesses.add(process) }

    /// Ends every running server at once. Called from `applicationWillTerminate`, where
    /// nothing asynchronous would get to run.
    nonisolated static func terminateAll() { liveProcesses.terminateAll() }

    nonisolated static var hasLiveProcesses: Bool { liveProcesses.hasLiveProcesses }

    func shutdown() async {
        shuttingDown = true
        generation = UUID()
        let existing = clients
        clients = [:]
        for client in existing.values { await client.stop() }
        await Self.liveProcesses.terminateAndWait()
    }

    struct Tool: Sendable, Hashable {
        let server: String
        let name: String
        let description: String
        let inputSchema: JSONValue

        var callName: String { "mcp__" + server + "__" + name }
    }

    struct Result: Sendable {
        let text: String
        let isError: Bool
    }

    private var specs: [String: MCPServerSpec]?
    private var clients: [String: MCPClient] = [:]
    private var toolCache: [String: [Tool]] = [:]
    private var failed: Set<String> = []
    private var generation = UUID()
    private var shuttingDown = false

    func tools() async -> [Tool] {
        guard !shuttingDown else { return [] }
        if specs == nil { specs = Self.readSpecs() }
        guard let current = specs else { return [] }
        let generation = self.generation
        var all: [Tool] = []
        for id in current.keys.sorted() {
            if let cached = toolCache[id] {
                all += cached
                continue
            }
            if failed.contains(id) { continue }
            guard let spec = current[id] else { continue }
            let client = self.client(for: id, spec: spec)
            do {
                let listed = try await client.listTools()
                guard generation == self.generation else { return [] }
                toolCache[id] = listed
                all += listed
            } catch is CancellationError {
                return all
            } catch {
                guard generation == self.generation else { return [] }
                print("MCPHub: \(id): \(error.localizedDescription)")
                failed.insert(id)
            }
        }
        return all.sorted {
            if $0.server != $1.server { return $0.server < $1.server }
            return $0.name < $1.name
        }
    }

    func call(_ callName: String, arguments: JSONValue) async throws -> Result {
        guard !shuttingDown else { throw CancellationError() }
        let epoch = generation
        if specs == nil { specs = Self.readSpecs() }
        guard let parsed = Self.parse(callName: callName),
              let spec = specs?[parsed.server]
        else { throw MCPHubError.unknownTool(callName) }
        if let cached = toolCache[parsed.server],
           !cached.contains(where: { $0.name == parsed.tool }) {
            throw MCPHubError.unknownTool(callName)
        }
        let client = self.client(for: parsed.server, spec: spec)
        do {
            let result = try await client.callTool(name: parsed.tool, arguments: arguments)
            guard generation == epoch, !shuttingDown else { throw CancellationError() }
            return result
        } catch let error as MCPHubError {
            guard generation == epoch, !shuttingDown else { throw CancellationError() }
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            guard generation == epoch, !shuttingDown else { throw CancellationError() }
            throw MCPHubError.server(error.localizedDescription)
        }
    }

    func reload() {
        guard !shuttingDown else { return }
        generation = UUID()
        let existing = clients
        clients = [:]
        toolCache = [:]
        failed = []
        specs = nil
        for client in existing.values { Task { await client.stop() } }
    }

    nonisolated static func parse(callName: String) -> (server: String, tool: String)? {
        guard callName.hasPrefix("mcp__") else { return nil }
        let rest = callName.dropFirst("mcp__".count)
        guard let separator = rest.range(of: "__") else { return nil }
        let server = String(rest[..<separator.lowerBound])
        let tool = String(rest[separator.upperBound...])
        guard !server.isEmpty, !tool.isEmpty else { return nil }
        return (server, tool)
    }

    private func client(for id: String, spec: MCPServerSpec) -> MCPClient {
        if let existing = clients[id] { return existing }
        let created = MCPClient(id: id, spec: spec)
        clients[id] = created
        return created
    }

    nonisolated private static func readSpecs() -> [String: MCPServerSpec] {
        guard let data = try? Data(contentsOf: MCPPaths.claudeConfigURL),
              let parsed = JSONValue.parse(data),
              let servers = parsed["mcpServers"]?.object
        else { return [:] }
        var out: [String: MCPServerSpec] = [:]
        for (id, entry) in servers {
            if let command = entry["command"]?.string, !command.isEmpty {
                let args = entry["args"]?.array?.compactMap(\.string) ?? []
                var env: [String: String] = [:]
                for (key, value) in entry["env"]?.object ?? [:] {
                    if let string = value.string { env[key] = string }
                }
                out[id] = .stdio(command: command, args: args, env: env)
            } else if let url = entry["url"]?.string, !url.isEmpty {
                var headers: [String: String] = [:]
                for (key, value) in entry["headers"]?.object ?? [:] {
                    if let string = value.string { headers[key] = string }
                }
                out[id] = .http(url: url, headers: headers)
            }
        }
        return out
    }
}

private enum MCPServerSpec: Sendable {
    case stdio(command: String, args: [String], env: [String: String])
    case http(url: String, headers: [String: String])
}

private actor MCPClient {
    let id: String
    let spec: MCPServerSpec

    private var stdio: MCPStdioConnection?
    private var nextID = 1
    private var initialized = false
    private var didRestart = false
    private var dead = false
    private var sessionID: String?
    private var generation = UUID()
    private var stopped = false
    private var stdioInitialization: Task<MCPStdioConnection, Error>?
    private var httpInitialization: Task<String?, Error>?
    private var httpRequests: [UUID: Task<MCPHTTPReply, Error>] = [:]

    /// Cancels only this waiter, leaving the shared initialization owned by the client.
    private final class InitializationWaiter<Value: Sendable>: Sendable {
        private struct State {
            var cancelled = false
            var continuation: CheckedContinuation<Value, Error>?
        }
        private let state = Mutex(State())

        func value(of task: Task<Value, Error>) async throws -> Value {
            try await withTaskCancellationHandler {
                try Task.checkCancellation()
                return try await withCheckedThrowingContinuation { continuation in
                    let cancelled = state.withLock { state in
                        guard !state.cancelled else { return true }
                        state.continuation = continuation
                        return false
                    }
                    if cancelled {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    Task {
                        let result = await task.result
                        let waiting = self.state.withLock { state in
                            let waiting = state.continuation
                            state.continuation = nil
                            return waiting
                        }
                        waiting?.resume(with: result)
                    }
                }
            } onCancel: {
                let waiting = self.state.withLock { state in
                    state.cancelled = true
                    let waiting = state.continuation
                    state.continuation = nil
                    return waiting
                }
                waiting?.resume(throwing: CancellationError())
            }
        }
    }

    init(id: String, spec: MCPServerSpec) {
        self.id = id
        self.spec = spec
    }

    func stop() {
        stopped = true
        generation = UUID()
        stdioInitialization?.cancel()
        stdioInitialization = nil
        httpInitialization?.cancel()
        httpInitialization = nil
        for request in httpRequests.values { request.cancel() }
        httpRequests.removeAll()
        stdio?.stop()
        stdio = nil
        initialized = false
        sessionID = nil
    }

    func listTools() async throws -> [MCPHub.Tool] {
        let items = try await MCPWire.listTools { params in
            try await self.rpc(method: "tools/list", params: params, timeout: 60)
        }
        return items.compactMap { item in
            guard let name = item["name"]?.string else { return nil }
            let rawDescription = item["description"]?.string ?? ""
            let schema: JSONValue
            if let found = item["inputSchema"], found.object != nil {
                schema = found
            } else {
                schema = .object(["type": .string("object"), "properties": .object([:])])
            }
            return MCPHub.Tool(
                server: id,
                name: name,
                description: String(rawDescription.prefix(400)),
                inputSchema: schema
            )
        }
    }

    func callTool(name: String, arguments: JSONValue) async throws -> MCPHub.Result {
        let args: JSONValue = arguments.isNull ? .object([:]) : arguments
        let reply = try await rpc(
            method: "tools/call",
            params: .object(["name": .string(name), "arguments": args]),
            timeout: 120
        )
        guard let result = reply["result"]?.object,
              let content = result["content"]?.array,
              result["isError"] == nil || result["isError"]?.bool != nil,
              result["structuredContent"] == nil || result["structuredContent"]?.object != nil else {
            throw MCPResponseError.invalidToolResult
        }
        var lines: [String] = []
        for item in content {
            guard item.object != nil, let type = item["type"]?.string else {
                throw MCPResponseError.invalidToolResult
            }
            switch type {
            case "text":
                guard let text = item["text"]?.string else { throw MCPResponseError.invalidToolResult }
                lines.append(text)
            case "image", "audio":
                guard item["data"]?.string != nil, item["mimeType"]?.string != nil else {
                    throw MCPResponseError.invalidToolResult
                }
                lines.append(type == "image" ? "[image]" : "[audio]")
            case "resource_link":
                guard let uri = item["uri"]?.string, item["name"]?.string != nil else {
                    throw MCPResponseError.invalidToolResult
                }
                lines.append("[resource: \(uri)]")
            case "resource":
                guard let resource = item["resource"]?.object, let uri = resource["uri"]?.string,
                      resource["mimeType"] == nil || resource["mimeType"]?.string != nil else {
                    throw MCPResponseError.invalidToolResult
                }
                if let text = resource["text"] {
                    guard let text = text.string else { throw MCPResponseError.invalidToolResult }
                    lines.append(text)
                } else {
                    guard resource["blob"]?.string != nil else { throw MCPResponseError.invalidToolResult }
                    lines.append("[resource: \(uri)]")
                }
            default:
                throw MCPResponseError.invalidToolResult
            }
        }
        return MCPHub.Result(text: lines.joined(separator: "\n"), isError: result["isError"]?.bool ?? false)
    }

    private func rpc(method: String, params: JSONValue?, timeout: TimeInterval) async throws -> JSONValue {
        switch spec {
        case .stdio(let command, let args, let env):
            return try await stdioRPC(command: command, args: args, env: env, method: method, params: params, timeout: timeout)
        case .http(let url, let headers):
            return try await httpRPC(urlString: url, headers: headers, method: method, params: params, timeout: timeout)
        }
    }

    private func checkReply(_ value: JSONValue) throws {
        if let message = MCPWire.errorMessage(in: value) {
            throw MCPHubError.server(message)
        }
    }

    // MARK: - Local servers over stdio

    private func stdioRPC(command: String, args: [String], env: [String: String], method: String, params: JSONValue?, timeout: TimeInterval) async throws -> JSONValue {
        let connection = try await ensureStdio(command: command, args: args, env: env)
        return try await stdioReply(connection, method: method, params: params, timeout: timeout)
    }

    private func stdioReply(_ connection: MCPStdioConnection, method: String, params: JSONValue?, timeout: TimeInterval) async throws -> JSONValue {
        do {
            let reply = try await connection.request(method, params, timeout: timeout)
            try checkReply(reply)
            return reply
        } catch let error as MCPWireError {
            switch error {
            case .exited(let code):
                throw MCPHubError.server(code.map { String(format: String(localized: "The server quit (exit %d)."), $0) } ?? String(localized: "The server quit."))
            case .timedOut:
                throw MCPHubError.server(String(localized: "The server didn't answer in time."))
            }
        }
    }

    private func ensureStdio(command: String, args: [String], env: [String: String]) async throws -> MCPStdioConnection {
        try Task.checkCancellation()
        if stopped { throw CancellationError() }
        if dead { throw MCPHubError.server(String(localized: "The server quit.")) }
        let task: Task<MCPStdioConnection, Error>
        let epoch: UUID
        if let existing = stdioInitialization {
            task = existing
            epoch = generation
        } else {
            if let connection = stdio, connection.process.isRunning, initialized { return connection }
            if let connection = stdio {
                // Only an actual process exit consumes the one restart allowance.
                if !connection.process.isRunning {
                    if didRestart {
                        dead = true
                        connection.stop()
                        throw MCPHubError.server(String(localized: "The server quit."))
                    }
                    didRestart = true
                }
                connection.stop()
                stdio = nil
            }
            guard let executable = LoginEnvironment.which(command, in: LoginEnvironment.current) else {
                throw MCPHubError.server(String(format: String(localized: "%@ isn't installed."), command))
            }
            var environment = LoginEnvironment.current
            for (key, value) in env { environment[key] = value }
            let connection: MCPStdioConnection
            do {
                connection = try MCPStdioConnection.launch(executable: executable, arguments: args, environment: environment)
            } catch {
                throw MCPHubError.server(error.localizedDescription)
            }
            generation = UUID()
            epoch = generation
            initialized = false
            stdio = connection
            MCPHub.track(connection.process)
            task = Task { try await self.initializeStdio(connection, generation: epoch) }
            stdioInitialization = task
        }
        // An individual caller's cancellation does not cancel the shared handshake.
        let connection = try await InitializationWaiter<MCPStdioConnection>().value(of: task)
        try Task.checkCancellation()
        guard !stopped, generation == epoch, stdio === connection else { throw CancellationError() }
        return connection
    }

    private func initializeStdio(_ connection: MCPStdioConnection, generation epoch: UUID) async throws -> MCPStdioConnection {
        do {
            let reply = try await stdioReply(connection, method: "initialize", params: MCPWire.initializeParams(), timeout: 60)
            try checkInitialization(reply)
            try Task.checkCancellation()
            guard !stopped, generation == epoch, stdio === connection else { throw CancellationError() }
            connection.notify("notifications/initialized")
            initialized = true
            stdioInitialization = nil
            return connection
        } catch {
            if generation == epoch, stdio === connection {
                initialized = false
                stdioInitialization = nil
                // Keep an exited process as the restart marker; discard failed live handshakes.
                if connection.process.isRunning { stdio = nil }
            }
            connection.stop()
            if error is MCPHubError || error is CancellationError { throw error }
            throw MCPHubError.server(error.localizedDescription)
        }
    }

    private func checkInitialization(_ reply: JSONValue) throws {
        guard reply["result"]?.object != nil else {
            throw MCPHubError.server(String(localized: "The server sent something unexpected: missing result."))
        }
        // We advertise only 2025-06-18 and no optional client capabilities.
        guard reply["result"]?["protocolVersion"]?.string == MCPWire.protocolVersion else {
            throw MCPHubError.server(String(localized: "The server sent something unexpected: invalid reply."))
        }
    }

    // MARK: - Remote servers over streamable HTTP

    private func httpRPC(urlString: String, headers: [String: String], method: String, params: JSONValue?, timeout: TimeInterval) async throws -> JSONValue {
        guard let url = URL(string: urlString) else {
            throw MCPHubError.server(String(localized: "The server address is invalid."))
        }
        let session = try await ensureHTTP(url: url, headers: headers)
        try Task.checkCancellation()
        guard !stopped else { throw CancellationError() }
        let epoch = generation
        let id = nextID
        nextID += 1
        let posted = try await post(url: url, headers: headers, sessionID: session, payload: MCPWire.request(id: id, method: method, params: params), id: id, timeout: timeout)
        try Task.checkCancellation()
        guard !stopped, generation == epoch else { throw CancellationError() }
        guard let body = posted.body else {
            throw MCPHubError.server(String(localized: "The server sent something unexpected: empty reply."))
        }
        try checkReply(body)
        return body
    }

    private func ensureHTTP(url: URL, headers: [String: String]) async throws -> String? {
        try Task.checkCancellation()
        if stopped { throw CancellationError() }
        if initialized { return sessionID }
        let task: Task<String?, Error>
        let epoch: UUID
        if let existing = httpInitialization {
            task = existing
            epoch = generation
        } else {
            generation = UUID()
            epoch = generation
            task = Task { try await self.initializeHTTP(url: url, headers: headers, generation: epoch) }
            httpInitialization = task
        }
        let session = try await InitializationWaiter<String?>().value(of: task)
        try Task.checkCancellation()
        guard !stopped, generation == epoch else { throw CancellationError() }
        return session
    }

    private func initializeHTTP(url: URL, headers: [String: String], generation epoch: UUID) async throws -> String? {
        do {
            try Task.checkCancellation()
            guard !stopped, generation == epoch else { throw CancellationError() }
            let id = nextID
            nextID += 1
            let posted = try await post(url: url, headers: headers, sessionID: nil, payload: MCPWire.request(id: id, method: "initialize", params: MCPWire.initializeParams()), id: id, timeout: 60)
            guard let body = posted.body else {
                throw MCPHubError.server(String(localized: "The server sent something unexpected: empty reply."))
            }
            try checkReply(body)
            try checkInitialization(body)
            try Task.checkCancellation()
            guard !stopped, generation == epoch else { throw CancellationError() }
            let session = posted.sessionID
            _ = try await post(url: url, headers: headers, sessionID: session, payload: MCPWire.notification(method: "notifications/initialized"), id: nil, timeout: 30)
            try Task.checkCancellation()
            guard !stopped, generation == epoch else { throw CancellationError() }
            sessionID = session
            initialized = true
            httpInitialization = nil
            return session
        } catch {
            if generation == epoch {
                initialized = false
                sessionID = nil
                httpInitialization = nil
            }
            throw error
        }
    }

    private func post(url: URL, headers: [String: String], sessionID: String?, payload: JSONValue, id: Int?, timeout: TimeInterval) async throws -> MCPHTTPReply {
        try Task.checkCancellation()
        guard !stopped else { throw CancellationError() }
        let epoch = generation
        let token = UUID()
        let task = Task {
            try await MCPWire.post(to: url, headers: headers, sessionID: sessionID, payload: payload, id: id, timeout: timeout)
        }
        httpRequests[token] = task
        defer { httpRequests.removeValue(forKey: token) }
        do {
            let reply = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            try Task.checkCancellation()
            guard !stopped, generation == epoch else { throw CancellationError() }
            return reply
        } catch {
            if Task.isCancelled || stopped || generation != epoch { throw CancellationError() }
            if let error = error as? MCPHTTPError {
                guard let status = error.status else {
                    throw MCPHubError.server(String(localized: "The server sent something unexpected: invalid reply."))
                }
                throw MCPHubError.server(String(format: String(localized: "The server answered %lld."), Int64(status)))
            }
            if let error = error as? MCPWireError, case .timedOut = error {
                throw MCPHubError.server(String(localized: "The server didn't answer in time."))
            }
            throw error
        }
    }

}

/// The server processes alive this run, behind a lock so the quit path can reach them
/// from any thread without an actor hop.
private final class MCPLiveProcesses: Sendable {
    private let state = Mutex<[StdioProcess]>([])

    func add(_ process: StdioProcess) {
        state.withLock { processes in
            // Retain exited roots too: their descendants may still be in TERM grace.
            processes.append(process)
        }
    }

    var hasLiveProcesses: Bool { state.withLock { $0.contains(where: \.isRunning) } }

    func terminateAndWait() async {
        let running = state.withLock { $0 }
        guard !running.isEmpty else { return }
        for process in running { process.terminate() }
        // Wait the full grace even if the root exits before its descendants.
        await withCheckedContinuation { continuation in
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) { continuation.resume() }
        }
        await withTaskGroup(of: Void.self) { group in
            for process in running {
                group.addTask { await process.terminateAndWait(timeout: 0.5) }
            }
        }
        for process in running where process.isRunning {
            let pid = process.processIdentifier
            kill(getpgid(pid) == pid ? -pid : pid, SIGKILL)
        }
    }

    func terminateAll() {
        let running = state.withLock { $0.filter(\.isRunning) }
        for process in running { process.terminate() }
        // The app is quitting, so the delayed SIGKILL in terminate() never fires.
        for process in running where process.isRunning {
            let pid = process.processIdentifier
            kill(getpgid(pid) == pid ? -pid : pid, SIGKILL)
        }
    }
}
