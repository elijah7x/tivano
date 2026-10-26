import CryptoKit
import Darwin
import Foundation
import Security

private final class RemoteMCPMetadataDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

actor RemoteMCPAuthority {
    private struct Pending {
        var approval: RemoteMCPApprovalRequest
        var client: RemoteMCPClient
        var redirect: String
        var state: String?
        var challenge: String
        var resource: String
        var issuer: String
        var decision: RemoteMCPApprovalDecision?
    }

    private struct Code {
        var pending: Pending
        var scopes: Set<RemoteMCPScope>
        var expiresAt: Date
    }

    private struct AccessToken {
        var grantID: UUID
        var scopes: Set<RemoteMCPScope>
        var resource: String
        var expiresAt: Date
    }

    private let stateURL: URL
    private let onPendingChanged: @Sendable ([RemoteMCPApprovalRequest]) -> Void
    private let onGrantsChanged: @Sendable ([RemoteMCPGrant]) -> Void
    private var state: RemoteMCPState
    private var base = ""
    private var resource: String { base + RemoteMCP.mcpPath }
    private var pending: [UUID: Pending] = [:]
    private var codes: [String: Code] = [:]
    private var accessTokens: [String: AccessToken] = [:]
    private var metadataCache: [String: (client: RemoteMCPClient, expiresAt: Date)] = [:]
    private var lastUsagePersisted = Date.distantPast

    init(stateURL: URL,
         onPendingChanged: @escaping @Sendable ([RemoteMCPApprovalRequest]) -> Void,
         onGrantsChanged: @escaping @Sendable ([RemoteMCPGrant]) -> Void) {
        self.stateURL = stateURL
        self.onPendingChanged = onPendingChanged
        self.onGrantsChanged = onGrantsChanged
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: stateURL) {
            if let loaded = try? decoder.decode(RemoteMCPState.self, from: data) {
                state = loaded
            } else {
                var quarantine = stateURL.appendingPathExtension("corrupt")
                if FileManager.default.fileExists(atPath: quarantine.path) {
                    quarantine = stateURL.appendingPathExtension(UUID().uuidString + ".corrupt")
                }
                try? FileManager.default.moveItem(at: stateURL, to: quarantine)
                state = RemoteMCPState()
            }
        } else {
            state = RemoteMCPState()
        }
    }

    func setBaseURL(_ base: String) { self.base = base }

    func handle(_ request: RemoteHTTPRequest) async -> RemoteHTTPResponse? {
        switch request.path {
        case "/.well-known/oauth-protected-resource", "/.well-known/oauth-protected-resource/mcp":
            guard request.method == "GET" else { return .empty(405, headers: ["Allow": "GET"]) }
            return .json(.object([
                "resource": .string(resource), "authorization_servers": strings([base]),
                "scopes_supported": strings(RemoteMCPScope.allCases.map(\.rawValue)),
                "bearer_methods_supported": strings(["header"]), "resource_name": .string("Tivano")
            ]))
        case "/.well-known/oauth-authorization-server", "/.well-known/oauth-authorization-server/mcp", "/.well-known/openid-configuration":
            guard request.method == "GET" else { return .empty(405, headers: ["Allow": "GET"]) }
            return .json(.object([
                "issuer": .string(base), "authorization_endpoint": .string(base + "/oauth/authorize"),
                "token_endpoint": .string(base + "/oauth/token"), "registration_endpoint": .string(base + "/oauth/register"),
                "revocation_endpoint": .string(base + "/oauth/revoke"), "response_types_supported": strings(["code"]),
                "grant_types_supported": strings(["authorization_code", "refresh_token"]),
                "code_challenge_methods_supported": strings(["S256"]), "token_endpoint_auth_methods_supported": strings(["none"]),
                "scopes_supported": strings(RemoteMCPScope.allCases.map(\.rawValue)),
                "client_id_metadata_document_supported": .bool(true), "authorization_response_iss_parameter_supported": .bool(true)
            ]))
        case "/oauth/register":
            guard request.method == "POST" else { return .empty(405, headers: ["Allow": "POST"]) }
            return register(request)
        case "/oauth/authorize":
            guard request.method == "GET" else { return .empty(405, headers: ["Allow": "GET"]) }
            return await authorize(request)
        case "/oauth/authorize/pending":
            guard request.method == "GET" else { return .empty(405, headers: ["Allow": "GET"]) }
            return poll(request)
        case "/oauth/token":
            guard request.method == "POST" else { return .empty(405, headers: ["Allow": "POST"]) }
            return token(request.form)
        case "/oauth/revoke":
            guard request.method == "POST" else { return .empty(405, headers: ["Allow": "POST"]) }
            if let token = request.form["token"] {
                let hash = Self.hash(token)
                if let grant = state.grants.first(where: { $0.refreshTokenHash == hash }) { revoke(grantID: grant.id) }
                else { accessTokens.removeValue(forKey: hash) }
            }
            return .empty(200)
        default: return nil
        }
    }

    func authenticate(_ request: RemoteHTTPRequest) -> RemoteMCPAccess? {
        guard let header = request.header("Authorization") else { return nil }
        let parts = header.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard parts.count == 2, parts[0].lowercased() == "bearer" else { return nil }
        let hash = Self.hash(String(parts[1]))
        guard let token = accessTokens[hash], token.expiresAt > Date(), token.resource == resource,
              let index = state.grants.firstIndex(where: { $0.id == token.grantID }) else { return nil }
        let now = Date()
        state.grants[index].lastUsedAt = now
        if now.timeIntervalSince(lastUsagePersisted) >= 60 {
            persist()
            lastUsagePersisted = now
            onGrantsChanged(state.grants)
        }
        return RemoteMCPAccess(grantID: token.grantID, clientName: state.grants[index].clientName, scopes: token.scopes)
    }

    func unauthorizedResponse() -> RemoteHTTPResponse {
        .json(.object(["error": .string("invalid_token")]), status: 401, headers: [
            "WWW-Authenticate": "Bearer resource_metadata=\"\(base)/.well-known/oauth-protected-resource/mcp\", scope=\"tivano.read tivano.write\""
        ])
    }

    func decide(_ id: UUID, _ decision: RemoteMCPApprovalDecision) {
        expirePending()
        guard var entry = pending[id], entry.decision == nil else { return }
        entry.decision = decision
        pending[id] = entry
        notifyPending()
    }

    func grants() -> [RemoteMCPGrant] { state.grants }

    func revoke(grantID: UUID) {
        state.grants.removeAll { $0.id == grantID }
        accessTokens = accessTokens.filter { $0.value.grantID != grantID }
        grantsChanged()
    }

    func revokeAll() {
        state.grants.removeAll()
        accessTokens.removeAll()
        codes.removeAll()
        cancelPending()
        grantsChanged()
    }

    func cancelPending() {
        for id in Array(pending.keys) where pending[id]?.decision == nil { pending[id]?.decision = .deny }
        notifyPending()
    }

    private func register(_ request: RemoteHTTPRequest) -> RemoteHTTPResponse {
        guard let object = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
              let redirects = object["redirect_uris"] as? [String], !redirects.isEmpty,
              redirects.allSatisfy(Self.validRedirect) else { return .oauthError("invalid_client_metadata") }
        guard let bytes = Self.random(16) else { return .oauthError("invalid_request", status: 500) }
        if state.clients.count >= RemoteMCP.maxClients {
            guard let oldest = state.clients.filter({ client in !state.grants.contains { $0.clientID == client.id } })
                .min(by: { $0.createdAt < $1.createdAt }) else { return .oauthError("invalid_client_metadata") }
            state.clients.removeAll { $0.id == oldest.id }
        }
        let client = RemoteMCPClient(id: "tvn_" + Self.hex(bytes), name: Self.clientName(object["client_name"] as? String),
                                     redirectURIs: redirects, source: .registered, createdAt: Date())
        state.clients.append(client)
        persist()
        return .json(.object([
            "client_id": .string(client.id), "client_id_issued_at": .int(Int(client.createdAt.timeIntervalSince1970)),
            "client_name": .string(client.name), "redirect_uris": strings(redirects),
            "token_endpoint_auth_method": .string("none"), "grant_types": strings(["authorization_code", "refresh_token"]),
            "response_types": strings(["code"])
        ]), status: 201)
    }

    private func authorize(_ request: RemoteHTTPRequest) async -> RemoteHTTPResponse {
        let query = request.query
        guard let id = query["client_id"], let client = await client(id),
              let redirect = query["redirect_uri"], client.redirectURIs.contains(redirect) else { return invalidPage() }
        func error(_ code: String) -> RemoteHTTPResponse {
            redirectResponse(redirect, parameters: ["error": code], state: query["state"], issuer: base)
        }
        guard query["response_type"] == "code", let challenge = query["code_challenge"],
              challenge.utf8.count == 43, challenge.utf8.allSatisfy(Self.isBase64URL),
              query["code_challenge_method"] == "S256" else { return error("invalid_request") }
        guard query["resource"] == nil || query["resource"] == resource else { return error("invalid_target") }
        expirePending()
        guard pending.values.filter({ $0.decision == nil }).count < RemoteMCP.maxPendingApprovals else {
            return .html(RemoteMCPPages.message(title: "Too many requests waiting", body: "Approve or deny the requests already waiting in Tivano, then try again."), status: 429)
        }
        guard let bytes = Self.random(6) else { return .oauthError("invalid_request", status: 500) }
        let alphabet = Array("ABCDEFGHJKMNPQRSTUVWXYZ23456789")
        let text = String(bytes.map { alphabet[Int($0) % alphabet.count] })
        let code = String(text.prefix(3)) + "-" + String(text.suffix(3))
        let scopes = query["scope"].map { RemoteMCPScope.parse($0) } ?? Set(RemoteMCPScope.allCases)
        let components = URLComponents(string: redirect)
        let approval = RemoteMCPApprovalRequest(id: UUID(), clientName: client.name, clientID: client.id,
            redirectHost: components?.host ?? components?.scheme ?? "", requestedScopes: scopes.union([.read]), code: code, createdAt: Date())
        pending[approval.id] = Pending(approval: approval, client: client, redirect: redirect, state: query["state"],
                                       challenge: challenge, resource: resource, issuer: base)
        notifyPending()
        return .redirect(base + "/oauth/authorize/pending?request=" + approval.id.uuidString)
    }

    private func poll(_ request: RemoteHTTPRequest) -> RemoteHTTPResponse {
        expirePending()
        guard let text = request.query["request"], let id = UUID(uuidString: text), let entry = pending[id] else {
            return .html(RemoteMCPPages.message(title: "Request expired", body: "Start the connection again from your agent."), status: 404)
        }
        guard let decision = entry.decision else { return .html(RemoteMCPPages.waiting(clientName: entry.client.name, code: entry.approval.code)) }
        switch decision {
        case .deny:
            pending.removeValue(forKey: id)
            notifyPending()
            return redirectResponse(entry.redirect, parameters: ["error": "access_denied"], state: entry.state, issuer: entry.issuer)
        case .allow(let allowed):
            guard let bytes = Self.random(32) else { return .oauthError("invalid_request", status: 500) }
            let code = Self.base64URL(bytes)
            codes = codes.filter { $0.value.expiresAt > Date() }
            codes[Self.hash(code)] = Code(pending: entry, scopes: allowed.intersection(entry.approval.requestedScopes).union([.read]),
                                          expiresAt: Date().addingTimeInterval(RemoteMCP.authorizationCodeLifetime))
            pending.removeValue(forKey: id)
            notifyPending()
            return redirectResponse(entry.redirect, parameters: ["code": code], state: entry.state, issuer: entry.issuer)
        }
    }

    private func token(_ form: [String: String]) -> RemoteHTTPResponse {
        switch form["grant_type"] {
        case "authorization_code":
            // Consume before validating anything else, including required fields.
            let code = form["code"].flatMap { codes.removeValue(forKey: Self.hash($0)) }
            guard let clientID = form["client_id"], let redirect = form["redirect_uri"], let verifier = form["code_verifier"], form["code"] != nil else {
                return .oauthError("invalid_request")
            }
            guard let code, code.expiresAt > Date(), code.pending.client.id == clientID,
                  code.pending.redirect == redirect, code.pending.resource == resource,
                  form["resource"] == nil || form["resource"] == code.pending.resource,
                  (43...128).contains(verifier.utf8.count), verifier.utf8.allSatisfy(Self.isVerifierCharacter),
                  Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8)))) == code.pending.challenge else { return .oauthError("invalid_grant") }
            guard let access = Self.random(32), let refresh = Self.random(32) else { return .oauthError("invalid_request", status: 500) }
            let refreshText = Self.base64URL(refresh)
            let grant = RemoteMCPGrant(id: UUID(), clientID: clientID, clientName: code.pending.client.name, scopes: code.scopes,
                createdAt: Date(), lastUsedAt: nil, refreshTokenHash: Self.hash(refreshText),
                refreshExpiresAt: Date().addingTimeInterval(RemoteMCP.refreshTokenLifetime))
            state.grants.append(grant)
            grantsChanged()
            return tokenResponse(access: access, refresh: refreshText, grant: grant)
        case "refresh_token":
            guard let refresh = form["refresh_token"], let clientID = form["client_id"] else { return .oauthError("invalid_request") }
            guard let index = state.grants.firstIndex(where: { $0.refreshTokenHash == Self.hash(refresh) && $0.clientID == clientID }) else {
                return .oauthError("invalid_grant")
            }
            guard state.grants[index].refreshExpiresAt > Date() else {
                revoke(grantID: state.grants[index].id)
                return .oauthError("invalid_grant")
            }
            if let target = form["resource"], target != resource { return .oauthError("invalid_grant") }
            var grant = state.grants[index]
            if let scope = form["scope"] {
                let requested = RemoteMCPScope.parse(scope)
                guard Set(scope.split(separator: " ").map(String.init)).isSubset(of: Set(grant.scopes.map(\.rawValue))) else {
                    return .oauthError("invalid_request")
                }
                grant.scopes = requested
            }
            guard let access = Self.random(32), let refreshBytes = Self.random(32) else { return .oauthError("invalid_request", status: 500) }
            let refreshText = Self.base64URL(refreshBytes)
            grant.refreshTokenHash = Self.hash(refreshText)
            grant.refreshExpiresAt = Date().addingTimeInterval(RemoteMCP.refreshTokenLifetime)
            grant.lastUsedAt = Date()
            state.grants[index] = grant
            grantsChanged()
            return tokenResponse(access: access, refresh: refreshText, grant: grant)
        case nil: return .oauthError("invalid_request")
        default: return .oauthError("unsupported_grant_type")
        }
    }

    private func tokenResponse(access: Data, refresh: String, grant: RemoteMCPGrant) -> RemoteHTTPResponse {
        let text = Self.base64URL(access)
        accessTokens = accessTokens.filter { $0.value.expiresAt > Date() }
        accessTokens[Self.hash(text)] = AccessToken(grantID: grant.id, scopes: grant.scopes, resource: resource,
                                                   expiresAt: Date().addingTimeInterval(RemoteMCP.accessTokenLifetime))
        return .json(.object(["access_token": .string(text), "token_type": .string("Bearer"),
            "expires_in": .int(Int(RemoteMCP.accessTokenLifetime)), "refresh_token": .string(refresh),
            "scope": .string(RemoteMCPScope.string(grant.scopes))]))
    }

    private func client(_ id: String) async -> RemoteMCPClient? {
        if let registered = state.clients.first(where: { $0.id == id }) { return registered }
        if let cached = metadataCache[id], cached.expiresAt > Date() { return cached.client }
        guard let components = URLComponents(string: id), components.scheme?.lowercased() == "https",
              let host = components.host, !components.path.isEmpty, components.fragment == nil,
              components.user == nil, components.password == nil, Self.publicMetadataHost(host), let url = components.url else { return nil }
        // The host text alone says nothing about where a name resolves: every address it
        // resolves to must be public too, so a name pointing into the private network is
        // refused before any request goes out. A rebinding between this lookup and the
        // connection is not covered.
        guard await Self.resolvesOnlyToPublicAddresses(host) else { return nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 5
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration, delegate: RemoteMCPMetadataDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            let (bytes, response) = try await session.bytes(from: url)
            guard let response = response as? HTTPURLResponse, response.statusCode == 200,
                  response.expectedContentLength <= 65_536 else { return nil }
            var data = Data()
            for try await byte in bytes {
                guard data.count < 65_536 else { return nil }
                data.append(byte)
            }
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["client_id"] as? String == id, let redirects = object["redirect_uris"] as? [String],
                  !redirects.isEmpty, redirects.allSatisfy(Self.validRedirect) else { return nil }
            let client = RemoteMCPClient(id: id, name: Self.clientName(object["client_name"] as? String),
                                         redirectURIs: redirects, source: .metadataDocument, createdAt: Date())
            metadataCache = metadataCache.filter { $0.value.expiresAt > Date() }
            metadataCache[id] = (client, Date().addingTimeInterval(600))
            return client
        } catch { return nil }
    }

    private static func publicMetadataHost(_ raw: String) -> Bool {
        let host = raw.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        guard !RemoteMCP.isLoopback(host), host != "localhost", !host.hasSuffix(".localhost"), !host.hasSuffix(".local"), !host.hasSuffix(".") else { return false }
        var ipv4 = in_addr()
        if inet_aton(host, &ipv4) == 1 {
            let value = UInt32(bigEndian: ipv4.s_addr)
            let first = value >> 24
            let second = (value >> 16) & 255
            return !(first == 0 || first == 10 || first == 127 || first >= 224 ||
                     (first == 169 && second == 254) || (first == 172 && (16...31).contains(second)) ||
                     (first == 192 && second == 168) || (first == 100 && (64...127).contains(second)))
        }
        var ipv6 = in6_addr()
        if inet_pton(AF_INET6, host, &ipv6) == 1 {
            let bytes = withUnsafeBytes(of: &ipv6) { Array($0) }
            if bytes.prefix(10).allSatisfy({ $0 == 0 }), bytes[10] == 255, bytes[11] == 255 {
                return publicMetadataHost(bytes.suffix(4).map(String.init).joined(separator: "."))
            }
            return bytes[0] & 0xe0 == 0x20
        }
        return !host.contains(":") && !host.contains("%")
    }

    /// Resolves a host name off the caller's thread; false when it does not resolve or
    /// any of its addresses fails `publicMetadataHost`.
    private static func resolvesOnlyToPublicAddresses(_ host: String) async -> Bool {
        await Task.detached(priority: .utility) {
            var hints = addrinfo()
            hints.ai_socktype = SOCK_STREAM
            var list: UnsafeMutablePointer<addrinfo>?
            guard getaddrinfo(host, "443", &hints, &list) == 0, let first = list else { return false }
            defer { freeaddrinfo(first) }
            var any = false
            var cursor: UnsafeMutablePointer<addrinfo>? = first
            while let info = cursor {
                var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                guard getnameinfo(info.pointee.ai_addr, info.pointee.ai_addrlen, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 else { return false }
                let address = String(cString: buffer)
                guard publicMetadataHost(address) else { return false }
                any = true
                cursor = info.pointee.ai_next
            }
            return any
        }.value
    }

    private static func validRedirect(_ text: String) -> Bool {
        guard let uri = URLComponents(string: text), uri.url != nil, let scheme = uri.scheme?.lowercased(),
              uri.fragment == nil, uri.user == nil, uri.password == nil else { return false }
        if scheme == "https" { return !(uri.host ?? "").isEmpty }
        if scheme == "http" { return uri.host.map(RemoteMCP.isLoopback) ?? false }
        return !["javascript", "data", "file"].contains(scheme)
    }

    private func redirectResponse(_ uri: String, parameters: [String: String], state: String?, issuer: String) -> RemoteHTTPResponse {
        guard var components = URLComponents(string: uri) else { return invalidPage() }
        var items = components.queryItems ?? []
        items += parameters.sorted(by: { $0.key < $1.key }).map { URLQueryItem(name: $0.key, value: $0.value) }
        if let state { items.append(URLQueryItem(name: "state", value: state)) }
        items.append(URLQueryItem(name: "iss", value: issuer))
        components.queryItems = items
        guard let location = components.string else { return invalidPage() }
        return .redirect(location)
    }

    private func invalidPage() -> RemoteHTTPResponse {
        .html(RemoteMCPPages.message(title: "Connection request not valid", body: "This client or its return address is not registered with Tivano."), status: 400)
    }

    private func expirePending() {
        let count = pending.count
        pending = pending.filter { Date().timeIntervalSince($0.value.approval.createdAt) <= RemoteMCP.approvalLifetime }
        if pending.count != count { notifyPending() }
    }

    private func notifyPending() {
        onPendingChanged(pending.values.filter { $0.decision == nil }.map(\.approval).sorted { $0.createdAt < $1.createdAt })
    }

    private func grantsChanged() {
        persist()
        onGrantsChanged(state.grants)
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(state) { MCPPaths.writePrivate(data, to: stateURL) }
    }

    private func strings(_ values: [String]) -> JSONValue { .array(values.map(JSONValue.string)) }

    private static func clientName(_ name: String?) -> String {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "MCP client" : String(trimmed.prefix(100))
    }

    private static func random(_ count: Int) -> Data? {
        var bytes = [UInt8](repeating: 0, count: count)
        guard SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess else { return nil }
        return Data(bytes)
    }

    private static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
    private static func hash(_ value: String) -> String { hex(Data(SHA256.hash(data: Data(value.utf8)))) }
    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    private static func isBase64URL(_ byte: UInt8) -> Bool {
        (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte) || byte == 45 || byte == 95
    }
    private static func isVerifierCharacter(_ byte: UInt8) -> Bool { isBase64URL(byte) || byte == 46 || byte == 126 }
}
