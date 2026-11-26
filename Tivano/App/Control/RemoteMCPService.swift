import Foundation
import Observation

@MainActor
@Observable
final class RemoteMCPService {
    @ObservationIgnored private weak var app: AppModel?
    private(set) var listening = false
    private(set) var failure: String?
    private(set) var pendingApprovals: [RemoteMCPApprovalRequest] = []
    private var storedGrants: [RemoteMCPGrant] = []
    @ObservationIgnored private var authority: RemoteMCPAuthority?
    @ObservationIgnored private var server: RemoteMCPHTTPServer?
    @ObservationIgnored private var listeningBaseURL: String?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var portPickTask: Task<UInt16, Never>?
    @ObservationIgnored private var didRequestGrantsLoad = false
    @ObservationIgnored private var didReceiveGrantsUpdate = false
    @ObservationIgnored private var revision = UUID()

    /// Lazily reads grants on first Settings or service access so disabled launches avoid disk I/O.
    var grants: [RemoteMCPGrant] {
        loadGrantsIfNeeded()
        return storedGrants
    }

    init(app: AppModel) {
        self.app = app
    }

    deinit { server?.stop() }

    private func ensureAuthority() -> RemoteMCPAuthority {
        if let authority { return authority }
        let created = RemoteMCPAuthority(
            stateURL: Storage.root.appendingPathComponent("remote-mcp.json"),
            onPendingChanged: { [weak self] requests in
                Task { @MainActor [weak self] in self?.pendingApprovals = requests }
            },
            onGrantsChanged: { [weak self] grants in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.didReceiveGrantsUpdate = true
                    self.storedGrants = grants
                }
            }
        )
        authority = created
        return created
    }

    private func loadGrantsIfNeeded() {
        guard !didRequestGrantsLoad else { return }
        didRequestGrantsLoad = true
        let authority = ensureAuthority()
        Task { [weak self] in
            let loaded = await authority.grants()
            guard let self, !self.didReceiveGrantsUpdate else { return }
            self.storedGrants = loaded
        }
    }

    @discardableResult
    private func pickAndStorePortIfNeeded() -> Task<UInt16, Never>? {
        if let task = portPickTask { return task }
        guard let app, app.settings.remoteMCPPort == 0 else { return nil }
        let task = Task { [weak self] in
            let picked = await Task.detached(priority: .userInitiated) {
                RemoteMCPHTTPServer.pickFreePort()
            }.value
            guard let self else { return UInt16(0) }
            self.portPickTask = nil
            if let app = self.app, app.settings.remoteMCPPort == 0, picked != 0 {
                app.settings.remoteMCPPort = Int(picked)
            }
            return picked
        }
        portPickTask = task
        return task
    }

    /// Picked lazily on first Settings view or enable and saved, so the tunnel's target stays put across launches.
    var port: UInt16 {
        guard let app else { return 0 }
        if let existing = UInt16(exactly: app.settings.remoteMCPPort), existing != 0 {
            return existing
        }
        pickAndStorePortIfNeeded()
        return 0
    }

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
        if !enabled {
            server?.stop()
            server = nil
            listening = false
            listeningBaseURL = nil
            // When disabled and never initialized, avoid reading state or binding a port.
            guard authority != nil || refreshTask != nil else { return }
        } else if listeningBaseURL != baseURL {
            server?.stop()
            server = nil
            listening = false
            listeningBaseURL = nil
        }
        let previous = refreshTask
        previous?.cancel()
        let authority = enabled ? ensureAuthority() : self.authority
        if enabled { loadGrantsIfNeeded() }
        refreshTask = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            guard enabled else {
                await authority?.cancelPending()
                return
            }
            guard let authority, self.revision == current else { return }
            if let pickTask = self.pickAndStorePortIfNeeded() {
                _ = await pickTask.value
            }
            guard self.shouldListen, self.revision == current else { return }
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
                    try await server.start()
                    guard self.shouldListen, self.revision == current else {
                        server.stop()
                        return
                    }
                    self.server = server
                    self.listening = true
                    self.listeningBaseURL = baseURL
                    self.failure = nil
                    return
                } catch {
                    server.stop()
                    guard self.shouldListen, self.revision == current else { return }
                    if attempt == 0 {
                        let picked = await Task.detached(priority: .userInitiated) {
                            RemoteMCPHTTPServer.pickFreePort()
                        }.value
                        guard self.shouldListen, self.revision == current else { return }
                        app.settings.remoteMCPPort = Int(picked)
                    } else {
                        self.failure = "Remote MCP could not start. Retry after freeing the port."
                    }
                }
            }
        }
    }

    func decide(_ request: RemoteMCPApprovalRequest, _ decision: RemoteMCPApprovalDecision) {
        guard let authority else { return }
        Task { await authority.decide(request.id, decision) }
    }

    func revoke(_ grant: RemoteMCPGrant) {
        let authority = ensureAuthority()
        Task { await authority.revoke(grantID: grant.id) }
    }

    func revokeAll() {
        let authority = ensureAuthority()
        Task { await authority.revokeAll() }
    }
}
