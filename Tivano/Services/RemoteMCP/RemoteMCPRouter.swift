import Foundation

struct RemoteMCPRouteConfig: Sendable {
    var allowedHosts: Set<String>
    var allowedOrigins: Set<String>
}

struct RemoteMCPRouter: Sendable {
    let config: RemoteMCPRouteConfig
    let authority: RemoteMCPAuthority
    let endpoint: RemoteMCPEndpoint

    func handle(_ request: RemoteHTTPRequest) async -> RemoteHTTPResponse {
        guard let host = request.header("host")?.lowercased(), config.allowedHosts.contains(host) else {
            return .empty(421)
        }
        if let origin = request.header("origin"), !config.allowedOrigins.contains(origin) {
            return .empty(403)
        }
        if request.method == "OPTIONS" { return .empty(204) }
        if let response = await authority.handle(request) { return response }
        guard request.path == RemoteMCP.mcpPath else { return .empty(404) }
        guard let access = await authority.authenticate(request) else {
            return await authority.unauthorizedResponse()
        }
        return await endpoint.handle(request, access: access)
    }
}
