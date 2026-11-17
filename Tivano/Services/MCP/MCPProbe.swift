import Foundation

enum MCPProbeError: LocalizedError, Sendable {
    case commandMissing(String)
    case exited(code: Int32, stderr: String)
    case timedOut
    case http(status: Int, body: String)
    case unauthorizedOAuth
    /// The sign-in is fine but the server needs a step on its side first (GitLab answers 403
    /// "MCP server disabled", or 404 on GitLab 19.4 and earlier, until the top-level group allows MCP clients).
    case needsSetup(MCPSetupGuide)
    /// A signed-in server answered 404 at its own MCP address: a hiccup on their side.
    case unavailable(host: String)
    case malformed(String)

    var errorDescription: String? {
        switch self {
        case .commandMissing(let name):
            switch name {
            case "npx": return AppText.localized("npx isn't installed. Install Node.js from nodejs.org, then try again.")
            case "uvx": return AppText.localized("uvx isn't installed. Run `brew install uv` in Terminal, then try again.")
            default: return String(format: AppText.localized("%@ isn't installed. Install it, then try again."), name)
            }
        case .exited(let code, let stderr):
            let last = stderr
                .components(separatedBy: .newlines)
                .map { $0.trimmed }
                .last(where: { !$0.isEmpty })
            if let last { return String(format: AppText.localized("The server quit (exit %d). %@"), code, last) }
            return String(format: AppText.localized("The server quit (exit %d)."), code)
        case .timedOut:
            return AppText.localized("The server didn't answer in time.")
        case .http(let status, _):
            switch status {
            case 401, 403: return AppText.localized("That key was refused. Press Try again and paste a new one.")
            case 404: return AppText.localized("Nothing answered at that address. Check the address and try again.")
            default: return String(format: AppText.localized("The server answered %lld."), Int64(status))
            }
        case .unauthorizedOAuth:
            return AppText.localized("Sign-in was rejected. Sign in again in your browser.")
        case .needsSetup(let guide):
            return AppText.localized(guide.reason)
        case .unavailable(let host):
            return String(format: AppText.localized("%@ didn't answer (404). If the address is right, try again in a few minutes."), host)
        case .malformed(let detail):
            return String(format: AppText.localized("The server sent something unexpected: %@"), AppText.localized(detail))
        }
    }
}

enum MCPProbe {
    @concurrent
    static func probe(_ server: MCPResolvedServer) async throws -> MCPProbeResult {
        if server.command != nil {
            return try await probeStdio(server)
        }
        if let url = server.url {
            return try await probeRemote(server, url)
        }
        throw MCPProbeError.malformed("missing command or URL")
    }

    private static func checkReply(_ value: JSONValue) throws {
        if let message = MCPWire.errorMessage(in: value) {
            throw MCPProbeError.malformed(message)
        }
    }

    private static func firstLine(_ text: String?) -> String? {
        guard let text else { return nil }
        let line = text.components(separatedBy: .newlines).first?
            .trimmed ?? ""
        return line.isEmpty ? nil : line
    }

    private static func toolSummary(from tool: JSONValue) -> MCPToolSummary? {
        guard let name = tool["name"]?.string else { return nil }
        return MCPToolSummary(name: name, summary: firstLine(tool["description"]?.string))
    }

    // MARK: - Local servers over stdio

    private static func probeStdio(_ server: MCPResolvedServer) async throws -> MCPProbeResult {
        let command = server.command ?? ""
        guard let executable = LoginEnvironment.which(command, in: LoginEnvironment.current) else {
            throw MCPProbeError.commandMissing(command)
        }
        let isOAuth = server.args.contains("mcp-remote")
        let deadline = Date().addingTimeInterval(isOAuth ? 240 : 90)

        var environment = LoginEnvironment.current
        for (key, value) in server.env { environment[key] = value }

        let connection = try MCPStdioConnection.launch(executable: executable, arguments: server.args, environment: environment)
        defer { connection.stop() }

        func nextReply(_ method: String, _ params: JSONValue?) async throws -> JSONValue {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else {
                throw exitError(code: nil, isOAuth: isOAuth, stderr: connection.errorTail)
            }
            do {
                let reply = try await connection.request(method, params, timeout: remaining)
                try checkReply(reply)
                return reply
            } catch let error as MCPWireError {
                switch error {
                case .exited(let code):
                    throw exitError(code: code, isOAuth: isOAuth, stderr: connection.errorTail)
                case .timedOut:
                    throw exitError(code: nil, isOAuth: isOAuth, stderr: connection.errorTail)
                }
            }
        }

        let initReply = try await nextReply("initialize", MCPWire.initializeParams())
        let initResult = initReply["result"]
        guard initResult?.object != nil else { throw MCPProbeError.malformed("missing result") }
        let serverName = initResult?["serverInfo"]?["name"]?.string
        let serverVersion = initResult?["serverInfo"]?["version"]?.string

        connection.notify("notifications/initialized")

        let items = try await MCPWire.listTools { params in
            try await nextReply("tools/list", params)
        }
        return MCPProbeResult(
            serverName: serverName,
            serverVersion: serverVersion,
            tools: items.compactMap(toolSummary(from:))
        )
    }

    private static func exitError(code: Int32?, isOAuth: Bool, stderr: String) -> MCPProbeError {
        if isOAuth && (stderr.contains("Unauthorized") || stderr.contains("invalid_grant")) {
            return .unauthorizedOAuth
        }
        if let code { return .exited(code: code, stderr: stderr) }
        return .timedOut
    }

    // MARK: - Remote servers over streamable HTTP

    private static func probeRemote(_ server: MCPResolvedServer, _ urlString: String) async throws -> MCPProbeResult {
        guard let url = URL(string: urlString) else {
            throw MCPProbeError.malformed("invalid URL")
        }
        var sessionID: String?

        func post(_ payload: JSONValue, id: Int?) async throws -> JSONValue? {
            do {
                let posted = try await MCPWire.post(to: url, headers: server.headers, sessionID: sessionID, payload: payload, id: id, timeout: 30)
                sessionID = posted.sessionID ?? sessionID
                return posted.body
            } catch let error as MCPHTTPError where (error.status == 401 || error.status == 403) && server.oauthUpstream != nil {
                let status = error.status, body = error.body
                if status == 403, body.localizedCaseInsensitiveContains("MCP server disabled") {
                    throw MCPProbeError.needsSetup(Self.gitLabServerDisabled(upstream: server.oauthUpstream ?? urlString))
                }
                throw MCPProbeError.unauthorizedOAuth
            } catch let error as MCPHTTPError where error.status == 404 && server.oauthUpstream != nil {
                let upstream = server.oauthUpstream ?? urlString
                // GitLab 19.4 and earlier answer a namespace that does not allow its MCP server with 404
                // instead of 403 'MCP server disabled'; both statuses share every cause, so a 404 from
                // its MCP endpoint is the setup case rather than a hiccup on GitLab's side.
                if Self.isGitLabMCP(upstream) {
                    throw MCPProbeError.needsSetup(Self.gitLabServerDisabled(upstream: upstream))
                }
                throw MCPProbeError.unavailable(host: URL(string: upstream)?.host ?? AppText.localized("The server"))
            } catch let error as MCPHTTPError {
                guard let status = error.status else { throw MCPProbeError.malformed("invalid reply") }
                throw MCPProbeError.http(status: status, body: error.body)
            }
        }

        func nearest(_ value: JSONValue?) throws -> JSONValue {
            guard let body = value else { throw MCPProbeError.malformed("empty reply") }
            try checkReply(body)
            guard body.object != nil else { throw MCPProbeError.malformed("invalid reply") }
            return body
        }

        let initReply = try await nearest(post(MCPWire.request(id: 1, method: "initialize", params: MCPWire.initializeParams()), id: 1))
        let initResult = initReply["result"]
        guard initResult?.object != nil else { throw MCPProbeError.malformed("missing result") }
        let serverName = initResult?["serverInfo"]?["name"]?.string
        let serverVersion = initResult?["serverInfo"]?["version"]?.string

        do {
            _ = try await post(MCPWire.notification(method: "notifications/initialized"), id: nil)
        } catch {
            if error is CancellationError { throw error }
        }

        let items = try await MCPWire.listTools { params in
            try await nearest(post(MCPWire.request(id: 2, method: "tools/list", params: params), id: 2))
        }
        return MCPProbeResult(
            serverName: serverName,
            serverVersion: serverVersion,
            tools: items.compactMap(toolSummary(from:))
        )
    }

    // MARK: - Setup guides

    /// Whether an OAuth upstream is a GitLab instance's MCP endpoint. GitLab.com and a
    /// self-managed instance both answer at <origin>/api/v4/mcp, behind a relative URL root too.
    static func isGitLabMCP(_ upstream: String) -> Bool {
        guard let url = URL(string: upstream) else { return false }
        return url.path.lowercased().hasSuffix("/api/v4/mcp")
    }

    /// GitLab keeps its MCP server off until an Owner allows it on the top-level group.
    static func gitLabServerDisabled(upstream: String) -> MCPSetupGuide {
        let origin: String = {
            guard let url = URL(string: upstream), let host = url.host else { return "https://gitlab.com" }
            return "\(url.scheme ?? "https")://\(host)"
        }()
        return MCPSetupGuide(
            title: "Turn on GitLab's MCP server",
            reason: "You're signed in, but GitLab keeps its MCP server off until a group owner turns it on. Until then, the address answers not found.",
            steps: [
                "Open your groups and pick the top-level group your projects live in",
                "Go to Settings › General and expand Permissions and group features",
                "Under MCP client access, tick Allow connection to GitLab and save",
                "Come back here and press Check again",
            ],
            pageLabel: "Open my groups",
            pageURL: origin + "/dashboard/groups",
            note: "GitLab can take a minute to apply the change."
        )
    }
}

