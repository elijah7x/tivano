import Foundation

actor RemoteMCPEndpoint {
    private let instance: UUID
    private let control: @Sendable (ControlCommand) async -> ControlResponse
    private var sessions: [(id: String, grantID: UUID)] = []

    init(instance: UUID, control: @escaping @Sendable (ControlCommand) async -> ControlResponse) {
        self.instance = instance
        self.control = control
    }

    func handle(_ request: RemoteHTTPRequest, access: RemoteMCPAccess) async -> RemoteHTTPResponse {
        if request.method == "GET" {
            return .empty(405, headers: ["Allow": "POST, DELETE"])
        }
        guard request.method == "POST" || request.method == "DELETE" else {
            return .empty(405, headers: ["Allow": "POST, DELETE"])
        }
        let sessionID = request.header("mcp-session-id")
        if let sessionID, !sessions.contains(where: { $0.id == sessionID && $0.grantID == access.grantID }) {
            return .empty(404)
        }
        if request.method == "DELETE" {
            if let sessionID { sessions.removeAll { $0.id == sessionID } }
            return .empty(204)
        }
        guard let message = JSONValue.parse(request.body) else {
            return rpcError(-32700, "Parse error")
        }
        guard let object = message.object, object["jsonrpc"]?.string == "2.0",
              let method = object["method"]?.string else {
            return rpcError(-32600, "Invalid Request; batching is unsupported")
        }
        if let id = object["id"] {
            switch id {
            case .string, .int, .double, .null: break
            default: return rpcError(-32600, "Invalid request id")
            }
        }
        guard let id = object["id"] else { return .empty(202) }
        if let params = object["params"], params.object == nil {
            return rpcError(-32602, "Expected object params", id: id)
        }
        let params = object["params"]?.object ?? [:]
        switch method {
        case "initialize":
            let session = UUID().uuidString
            sessions.append((session, access.grantID))
            if sessions.count > RemoteMCP.maxSessions { sessions.removeFirst(sessions.count - RemoteMCP.maxSessions) }
            let requested = params["protocolVersion"]?.string ?? ""
            let version = RemoteMCP.protocolVersions.contains(requested) ? requested : RemoteMCP.protocolVersions[0]
            return reply([
                "protocolVersion": .string(version),
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": .string(RemoteMCP.serverName), "title": "Tivano",
                               "version": .string(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0")],
                "instructions": .string(Self.instructions)
            ], id: id, headers: ["Mcp-Session-Id": session])
        case "ping":
            return reply([:], id: id)
        case "tools/list":
            return reply(["tools": .array(Self.tools.filter { access.scopes.contains($0.scope) }.map(\.json))], id: id)
        case "tools/call":
            guard let name = params["name"]?.string, let tool = Self.tools.first(where: { $0.name == name }) else {
                return rpcError(-32602, "Unknown tool name", id: id)
            }
            guard access.scopes.contains(tool.scope) else {
                return reply(Self.toolError("permission", "This connection was approved read-only.", prefix: false), id: id)
            }
            do {
                let arguments: [String: JSONValue]
                if let value = params["arguments"] {
                    guard let object = value.object else { throw ArgumentError(detail: "arguments must be an object") }
                    arguments = object
                } else {
                    arguments = [:]
                }
                try tool.validate(arguments)
                let command = try command(name, arguments)
                let response = await control(command)
                if let failure = response.error {
                    return reply(Self.toolError(failure.code.rawValue, failure.errorDescription ?? failure.code.message), id: id)
                }
                guard let result = response.result else {
                    return reply(Self.toolError("internalError", "Local control returned no result."), id: id)
                }
                let payload = try Self.payload(result)
                let structured: JSONValue
                if case .array = payload { structured = ["items": payload] } else { structured = payload }
                return reply(["content": [["type": "text", "text": .string(structured.compactString)]],
                              "structuredContent": structured, "isError": false], id: id)
            } catch let error as ArgumentError {
                return reply(Self.toolError("invalidRequest", error.detail), id: id)
            } catch {
                return reply(Self.toolError("internalError", "Could not encode the local control result."), id: id)
            }
        default:
            return rpcError(-32601, "Method not found", id: id)
        }
    }

    private func command(_ name: String, _ args: [String: JSONValue]) throws -> ControlCommand {
        func uuid(_ key: String) throws -> UUID {
            guard let text = args[key]?.string, let value = UUID(uuidString: text) else {
                throw ArgumentError(detail: "\(key) must be a UUID")
            }
            return value
        }
        func page(_ limit: Int = 50) -> ControlPage {
            ControlPage(limit: args["limit"]?.int ?? limit, cursor: args["cursor"]?.string)
        }
        switch name {
        case "tivano_info": return .info
        case "list_providers": return .providers
        case "list_projects": return .projects(page())
        case "list_threads":
            return .threads(ControlThreadQuery(
                page: page(), archive: ControlArchiveFilter(rawValue: args["archive"]?.string ?? "active")!,
                role: ControlRoleFilter(rawValue: args["role"]?.string ?? "normal")!,
                affiliation: ControlAffiliationFilter(rawValue: args["affiliation"]?.string ?? "all")!,
                projectID: try args["project_id"].map { _ in try uuid("project_id") }, search: args["search"]?.string))
        case "get_thread": return .thread(try uuid("thread_id"))
        case "get_history": return .history(ControlHistoryQuery(threadID: try uuid("thread_id"), page: page(25)))
        case "get_operation":
            guard let ticket = ControlTicket(args["ticket"]?.string ?? "") else {
                throw ArgumentError(detail: "ticket must be an operation ticket returned by a write")
            }
            return .operation(ticket)
        case "create_thread":
            return .create(ControlCreate(ticket: ControlTicket(instance: instance),
                projectID: try args["project_id"].map { _ in try uuid("project_id") },
                workspace: ControlWorkspaceMode(rawValue: args["workspace"]!.string!)!,
                provider: args["provider"]!.string!, model: args["model"]?.string))
        case "send_message":
            let text = args["text"]!.string!
            guard text.utf8.count <= LocalControl.maxText else {
                throw ArgumentError(detail: "text exceeds \(LocalControl.maxText) UTF-8 bytes")
            }
            return .submit(ControlSubmit(ticket: ControlTicket(instance: instance), threadID: try uuid("thread_id"),
                text: text, continuation: ControlContinuation(rawValue: args["continuation"]?.string ?? "automatic")!))
        case "interrupt_turn":
            return .interrupt(ControlInterrupt(ticket: ControlTicket(instance: instance),
                threadID: try uuid("thread_id"), turnID: try uuid("turn_id")))
        default: throw ArgumentError(detail: "Unknown tool")
        }
    }

    private static func payload(_ result: ControlResult) throws -> JSONValue {
        func encode<T: Encodable>(_ value: T) throws -> JSONValue {
            guard let json = JSONValue.parse(try LocalControl.encoder().encode(value)) else {
                throw ArgumentError(detail: "Invalid encoded result")
            }
            return json
        }
        switch result {
        case .info(let value), .welcome(let value):
            var object = try encode(value).object ?? [:]
            object.removeValue(forKey: "settings")
            object["methods"] = .array(value.methods.filter { $0 != "settingsGet" && $0 != "settingsSet" }.map(JSONValue.string))
            return .object(object)
        case .providers(let value): return try encode(value)
        case .projects(let value): return try encode(value)
        case .threads(let value): return try encode(value)
        case .thread(let value): return try encode(value)
        case .history(let value): return try encode(value)
        case .operation(let value):
            var object = try encode(value).object ?? [:]
            object.removeValue(forKey: "setting")
            // The wire form get_operation accepts, so an agent can poll without assembling it.
            object["ticket"] = .string(value.ticket.string)
            return .object(object)
        case .settings:
            throw ArgumentError(detail: "Settings are not exposed through Remote MCP")
        }
    }

    private func reply(_ result: JSONValue, id: JSONValue, headers: [String: String] = [:]) -> RemoteHTTPResponse {
        .json(["jsonrpc": "2.0", "id": id, "result": result], headers: headers)
    }

    private func rpcError(_ code: Int, _ message: String, id: JSONValue = .null) -> RemoteHTTPResponse {
        .json(["jsonrpc": "2.0", "id": id, "error": ["code": .int(code), "message": .string(message)]])
    }

    private static func toolError(_ code: String, _ detail: String, prefix: Bool = true) -> JSONValue {
        ["content": [["type": "text", "text": .string(prefix ? "\(code): \(detail)" : detail)]],
         "structuredContent": ["error": .string(code), "detail": .string(detail)], "isError": true]
    }

    private struct ArgumentError: Error { var detail: String }

    private struct Tool: Sendable {
        var name: String
        var description: String
        var scope: RemoteMCPScope = .read
        var properties: [String: JSONValue] = [:]
        var required: [String] = []

        var json: JSONValue {
            ["name": .string(name), "description": .string(description),
             "inputSchema": ["type": "object", "properties": .object(properties),
                             "required": .array(required.map(JSONValue.string)), "additionalProperties": false],
             "annotations": ["readOnlyHint": .bool(scope == .read), "destructiveHint": false,
                             "idempotentHint": .bool(scope == .read), "openWorldHint": false]]
        }

        func validate(_ args: [String: JSONValue]) throws {
            for key in required where args[key] == nil { throw ArgumentError(detail: "Missing \(key)") }
            for (key, value) in args {
                guard let schema = properties[key] else { throw ArgumentError(detail: "Unknown argument: \(key)") }
                if schema["type"]?.string == "integer" {
                    let integer: Int?
                    switch value {
                    case .int(let number): integer = number
                    case .double(let number): integer = Int(exactly: number)
                    default: integer = nil
                    }
                    guard let integer, integer >= (schema["minimum"]?.int ?? 1),
                          integer <= (schema["maximum"]?.int ?? 100) else {
                        throw ArgumentError(detail: "\(key) must be an integer in the allowed range")
                    }
                } else {
                    guard let string = value.string else { throw ArgumentError(detail: "\(key) must be a string") }
                    if let values = schema["enum"]?.array, !values.contains(.string(string)) {
                        throw ArgumentError(detail: "Invalid \(key)")
                    }
                    if schema["format"]?.string == "uuid", UUID(uuidString: string) == nil {
                        throw ArgumentError(detail: "\(key) must be a UUID")
                    }
                }
            }
        }
    }

    private static let instructions = "Approvals and questions wait in the Tivano app; the owner may let threads created here run in Full access without approvals. When get_thread shows waitingForUI, the owner must act in Tivano. Writes return an operation ticket to poll with get_operation and get_history. 'completed' means the provider reported completion, not that the task is correct. Standalone means no project. Do not blindly retry writes after a disconnect."

    private static let tools: [Tool] = {
        let string: JSONValue = ["type": "string"]
        let uuid: JSONValue = ["type": "string", "format": "uuid"]
        func choice(_ values: [String], _ initial: String? = nil) -> JSONValue {
            var schema: [String: JSONValue] = ["type": "string", "enum": .array(values.map(JSONValue.string))]
            if let initial { schema["default"] = .string(initial) }
            return .object(schema)
        }
        func limit(_ maximum: Int, _ initial: Int) -> JSONValue {
            ["type": "integer", "minimum": 1, "maximum": .int(maximum), "default": .int(initial)]
        }
        return [
            Tool(name: "tivano_info", description: "Read Tivano instance and control limits. " + instructions),
            Tool(name: "list_providers", description: "List cached provider availability and supported models; does not refresh or log in."),
            Tool(name: "list_projects", description: "List projects with cursor pagination.",
                 properties: ["limit": limit(100, 50), "cursor": string]),
            Tool(name: "list_threads", description: "List thread metadata. Search matches titles only. Standalone means no project.", properties: [
                "archive": choice(["active", "archived", "all"], "active"),
                "role": choice(["normal", "helper", "head", "all"], "normal"),
                "affiliation": choice(["all", "standalone", "project", "missing_project"], "all"),
                "project_id": uuid, "search": string, "limit": limit(100, 50), "cursor": string]),
            Tool(name: "get_thread", description: "Read a thread's metadata, workspace and current status.",
                 properties: ["thread_id": uuid], required: ["thread_id"]),
            Tool(name: "get_history", description: "Read persisted history excerpts. 'completed' means the provider reported completion, not that the task is correct.",
                 properties: ["thread_id": uuid, "limit": limit(50, 25), "cursor": string], required: ["thread_id"]),
            Tool(name: "get_operation", description: "Poll a write's operation ticket. Approvals and questions wait in the Tivano app. 'completed' means the provider reported completion, not that the task is correct.",
                 properties: ["ticket": string], required: ["ticket"]),
            Tool(name: "create_thread", description: "Create a supervised thread. Omit project_id for standalone (no project). " + instructions,
                 scope: .write, properties: ["project_id": uuid, "workspace": choice(["local", "worktree"]), "provider": string, "model": string],
                 required: ["workspace", "provider"]),
            Tool(name: "send_message", description: "Send text to an eligible idle thread; no attachments or slash commands. " + instructions,
                 scope: .write, properties: ["thread_id": uuid,
                    "text": ["type": "string", "description": .string("At most \(LocalControl.maxText) UTF-8 bytes.")],
                    "continuation": choice(["automatic", "fresh", "providerSession", "transcript"], "automatic")], required: ["thread_id", "text"]),
            Tool(name: "interrupt_turn", description: "Request interruption of the exact turn. Acceptance does not mean the provider stopped. " + instructions,
                 scope: .write, properties: ["thread_id": uuid, "turn_id": uuid], required: ["thread_id", "turn_id"])
        ]
    }()
}
