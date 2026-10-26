import Foundation

/// Remote MCP (Alpha) exposes local control to cloud agents as a Streamable HTTP MCP
/// server with its own OAuth 2.1 authorization server. Tivano only listens on loopback;
/// the owner's tunnel supplies the public HTTPS address. Approvals stay in the App.
enum RemoteMCP {
    static let protocolVersions = ["2025-11-25", "2025-06-18", "2025-03-26"]
    static let serverName = "tivano"
    static let mcpPath = "/mcp"
    static let maxHead = 32_768
    static let maxBody = 262_144
    static let maxConnections = 32
    static let requestTimeout: TimeInterval = 30
    static let accessTokenLifetime: TimeInterval = 3_600
    static let refreshTokenLifetime: TimeInterval = 30 * 86_400
    static let authorizationCodeLifetime: TimeInterval = 60
    /// How long an authorization waits for the owner's decision in the App.
    static let approvalLifetime: TimeInterval = 300
    static let maxClients = 64
    static let maxPendingApprovals = 4
    static let maxSessions = 64

    /// The base every OAuth and MCP URL derives from: the owner's public HTTPS address
    /// without a trailing slash, or the loopback address when none is set.
    static func baseURL(publicURL: String?, port: UInt16) -> String {
        if let publicURL, let normalized = normalizedPublicURL(publicURL) { return normalized }
        return "http://127.0.0.1:\(port)"
    }

    /// HTTPS with a host and no query or fragment; plain HTTP only for loopback hosts.
    static func normalizedPublicURL(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed), let scheme = components.scheme?.lowercased(),
              let host = components.host, !host.isEmpty, components.query == nil, components.fragment == nil,
              components.user == nil, components.password == nil else { return nil }
        guard scheme == "https" || (scheme == "http" && isLoopback(host)) else { return nil }
        var result = trimmed
        while result.hasSuffix("/") { result.removeLast() }
        return result
    }

    static func isLoopback(_ host: String) -> Bool {
        ["127.0.0.1", "localhost", "::1", "[::1]"].contains(host.lowercased())
    }
}

enum RemoteMCPScope: String, Codable, CaseIterable, Sendable {
    case read = "tivano.read"
    case write = "tivano.write"

    static func parse(_ text: String?) -> Set<RemoteMCPScope> {
        Set((text ?? "").split(separator: " ").compactMap { RemoteMCPScope(rawValue: String($0)) })
    }

    static func string(_ scopes: Set<RemoteMCPScope>) -> String {
        allCases.filter(scopes.contains).map(\.rawValue).joined(separator: " ")
    }
}

/// How a client identified itself: a dynamically registered ID, or an HTTPS URL that
/// serves its client metadata document.
enum RemoteMCPClientSource: String, Codable, Sendable { case registered, metadataDocument }

struct RemoteMCPClient: Codable, Hashable, Sendable {
    var id: String
    var name: String
    var redirectURIs: [String]
    var source: RemoteMCPClientSource
    var createdAt: Date
}

/// One owner approval. Only the refresh token's SHA-256 is stored; access tokens live
/// in memory and are re-issued from the refresh token after a restart.
struct RemoteMCPGrant: Codable, Hashable, Identifiable, Sendable {
    var id: UUID
    var clientID: String
    var clientName: String
    var scopes: Set<RemoteMCPScope>
    var createdAt: Date
    var lastUsedAt: Date?
    var refreshTokenHash: String
    var refreshExpiresAt: Date
}

/// The persisted authorization state, written owner-only to `remote-mcp.json`.
struct RemoteMCPState: Codable, Sendable {
    var clients: [RemoteMCPClient] = []
    var grants: [RemoteMCPGrant] = []
}

/// An authorization waiting for the owner. The code is shown both on the browser page
/// and in the App so the owner can tell their own request from someone else's.
struct RemoteMCPApprovalRequest: Identifiable, Hashable, Sendable {
    var id: UUID
    var clientName: String
    var clientID: String
    var redirectHost: String
    var requestedScopes: Set<RemoteMCPScope>
    var code: String
    var createdAt: Date
}

enum RemoteMCPApprovalDecision: Sendable {
    case allow(Set<RemoteMCPScope>)
    case deny
}

/// What a valid bearer token carries into the MCP endpoint.
struct RemoteMCPAccess: Sendable {
    var grantID: UUID
    var clientName: String
    var scopes: Set<RemoteMCPScope>
}

struct RemoteHTTPRequest: Sendable {
    var method: String
    /// The path without the query, percent-decoded.
    var path: String
    var query: [String: String]
    /// Lowercased names; repeated headers keep the last value.
    var headers: [String: String]
    var body: Data

    func header(_ name: String) -> String? { headers[name.lowercased()] }

    /// `application/x-www-form-urlencoded` body fields, as OAuth token requests send them.
    var form: [String: String] { RemoteHTTPRequest.parseForm(String(decoding: body, as: UTF8.self)) }

    static func parseForm(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for pair in text.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            func decode(_ part: Substring) -> String {
                String(part).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String(part)
            }
            guard let key = parts.first.map(decode), !key.isEmpty else { continue }
            result[key] = parts.count > 1 ? decode(parts[1]) : ""
        }
        return result
    }
}

struct RemoteHTTPResponse: Sendable {
    var status: Int
    var headers: [String: String] = [:]
    var body = Data()

    static func json(_ value: JSONValue, status: Int = 200, headers: [String: String] = [:]) -> RemoteHTTPResponse {
        var merged = headers
        merged["Content-Type"] = "application/json"
        merged["Cache-Control"] = "no-store"
        return RemoteHTTPResponse(status: status, headers: merged, body: value.data())
    }

    static func html(_ text: String, status: Int = 200) -> RemoteHTTPResponse {
        RemoteHTTPResponse(status: status, headers: [
            "Content-Type": "text/html; charset=utf-8",
            "Cache-Control": "no-store",
            "Content-Security-Policy": "default-src 'none'; style-src 'unsafe-inline'",
            "X-Frame-Options": "DENY",
            "Referrer-Policy": "no-referrer"
        ], body: Data(text.utf8))
    }

    static func redirect(_ location: String) -> RemoteHTTPResponse {
        RemoteHTTPResponse(status: 302, headers: ["Location": location, "Cache-Control": "no-store"])
    }

    static func empty(_ status: Int, headers: [String: String] = [:]) -> RemoteHTTPResponse {
        RemoteHTTPResponse(status: status, headers: headers)
    }

    /// RFC 6749 error body for the token and registration endpoints.
    static func oauthError(_ code: String, _ description: String? = nil, status: Int = 400) -> RemoteHTTPResponse {
        var object: [String: JSONValue] = ["error": .string(code)]
        if let description { object["error_description"] = .string(description) }
        return json(.object(object), status: status)
    }
}
