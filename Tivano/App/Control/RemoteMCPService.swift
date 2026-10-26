import Foundation
import Observation

@MainActor
@Observable
final class RemoteMCPService {
    @ObservationIgnored private weak var app: AppModel?
    private(set) var listening = false
    private(set) var failure: String?
    private(set) var pendingApprovals: [RemoteMCPApprovalRequest] = []
    private(set) var grants: [RemoteMCPGrant] = []
    @ObservationIgnored private var authority: RemoteMCPAuthority!
    @ObservationIgnored private var server: RemoteMCPHTTPServer?
    @ObservationIgnored private var listeningBaseURL: String?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var revision = UUID()

    init(app: AppModel) {
        self.app = app
        authority = RemoteMCPAuthority(
            stateURL: Storage.root.appendingPathComponent("remote-mcp.json"),
            onPendingChanged: { [weak self] requests in
                Task { @MainActor [weak self] in self?.pendingApprovals = requests }
            },
            onGrantsChanged: { [weak self] grants in
                Task { @MainActor [weak self] in self?.grants = grants }
            }
        )
        if app.settings.remoteMCPPort == 0 {
            app.settings.remoteMCPPort = Int(RemoteMCPHTTPServer.pickFreePort())
        }
        let authority = authority!
        refreshTask = Task { [weak self] in
            let grants = await authority.grants()
            self?.grants = grants
        }
    }

    deinit { server?.stop() }

    /// Picked once in init and saved, so the tunnel's target stays put across launches.
    var port: UInt16 { app.flatMap { UInt16(exactly: $0.settings.remoteMCPPort) } ?? 0 }

    var baseURL: String {
        let publicURL = app?.settings.remoteMCPPublicURL ?? ""
        return RemoteMCP.baseURL(publicURL: publicURL.isEmpty ? nil : publicURL, port: port)
    }

    var mcpURL: String { baseURL + RemoteMCP.mcpPath }

    private var shouldListen: Bool {
        guard let app else { return false }
        return app.isLibraryLoaded && app.settings.isRemoteMCPEnabled
            && !CaptureRun.isEnabled && !app.localControl.isShuttingDown
    }

    func refresh() {
        revision = UUID()
        let current = revision
        let enabled = shouldListen
        if !enabled || listeningBaseURL != baseURL {
            server?.stop()
            server = nil
            listening = false
            listeningBaseURL = nil
        }
        let previous = refreshTask
        let authority = authority!
        refreshTask = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            guard enabled else {
                await authority.cancelPending()
                return
            }
            guard self.revision == current else { return }
            guard self.server?.isRunning != true || self.listeningBaseURL != self.baseURL else { return }
            self.server?.stop()
            self.server = nil
            self.listening = false
            for attempt in 0..<2 {
                guard let app = self.app, self.shouldListen, self.revision == current else { return }
                let port = self.port
                let baseURL = self.baseURL
                await authority.setBaseURL(baseURL)
                guard self.shouldListen, self.revision == current else { return }
                let instance = app.localControl.instance
                let endpoint = RemoteMCPEndpoint(instance: instance) { [weak app] command in
                    await Task { @MainActor [weak app] in
                        guard let app else { return ControlResponse(id: nil, error: ControlFailure(code: .unavailable)) }
                        return await app.localControl.handle(ControlRequest(instance: instance, command: command), source: .remote)
                    }.value
                }
                var hosts: Set<String> = ["127.0.0.1:\(port)", "localhost:\(port)"]
                var origins: Set<String> = ["http://127.0.0.1:\(port)", "http://localhost:\(port)"]
                if let components = URLComponents(string: baseURL), let host = components.host, let scheme = components.scheme {
                    hosts.insert(host.lowercased())
                    let authorityHost = host + (components.port.map { ":\($0)" } ?? "")
                    hosts.insert(authorityHost.lowercased())
                    origins.insert("\(scheme)://\(authorityHost)")
                }
                let router = RemoteMCPRouter(config: RemoteMCPRouteConfig(allowedHosts: hosts, allowedOrigins: origins), authority: authority, endpoint: endpoint)
                let server = RemoteMCPHTTPServer(port: port) { request in await router.handle(request) }
                do {
                    guard port != 0 else { throw ControlFailure(code: .unavailable) }
                    try server.start()
                    self.server = server
                    self.listening = true
                    self.listeningBaseURL = baseURL
                    self.failure = nil
                    return
                } catch {
                    server.stop()
                    if attempt == 0 {
                        app.settings.remoteMCPPort = Int(RemoteMCPHTTPServer.pickFreePort())
                    } else {
                        self.failure = "Remote MCP could not start. Retry after freeing the port."
                    }
                }
            }
        }
    }

    func decide(_ request: RemoteMCPApprovalRequest, _ decision: RemoteMCPApprovalDecision) {
        let authority = authority!
        Task { await authority.decide(request.id, decision) }
    }

    func revoke(_ grant: RemoteMCPGrant) {
        let authority = authority!
        Task { await authority.revoke(grantID: grant.id) }
    }

    func revokeAll() {
        let authority = authority!
        Task { await authority.revokeAll() }
    }
}
