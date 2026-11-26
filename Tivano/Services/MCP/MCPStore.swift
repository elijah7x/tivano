import Foundation
import Observation
import Synchronization

/// The user's MCP connections: which catalog servers are connected, their field values,
/// and what each announced when it was last probed. Persists to `MCPPaths.connectionsURL`
/// (secrets to the Keychain) and, on every change, rewrites the provider config files under
/// `MCPPaths.directory`.
@MainActor
@Observable
final class MCPStore {
    /// Every connection the user has made, connected or not, keyed by catalog id.
    private(set) var connections: [String: MCPConnection] = [:]
    /// Live state per catalog id; a server with no entry here is `.notConnected`.
    private(set) var states: [String: MCPConnectionState] = [:]
    /// Field values the user is typing on a card before connecting, keyed by catalog id then field key.
    var drafts: [String: [String: String]] = [:]
    /// The servers the user defined themselves, in the order they were made.
    private(set) var customs: [MCPCustomServer] = []

    struct ConfigurationLoadError: Error, Sendable {
        let url: URL
        let isReadFailure: Bool
    }

    enum CustomSaveError: Error {
        case configurationBlocked
        case validation(MCPCustomError)

        var message: String {
            switch self {
            case .configurationBlocked: AppText.localized("MCP configuration could not be loaded. Repair the file and retry in Settings before making changes.")
            case .validation(let error): error.message
            }
        }
    }

    private(set) var configurationLoadError: ConfigurationLoadError?
    private(set) var hasLoadedConfiguration = false
    var isConfigurationLoaded: Bool { hasLoadedConfiguration && configurationLoadError == nil }

    @ObservationIgnored private var isLoadingConfiguration = false
    @ObservationIgnored private var readyTask: Task<Void, Never>?
    @ObservationIgnored private let persistence = PersistenceQueue()
    @ObservationIgnored private var probeGeneration = UUID()
    @ObservationIgnored private var probeIDs: [String: UUID] = [:]
    @ObservationIgnored private var probes: [String: Task<Void, Never>] = [:]

    nonisolated private static let latestReadyTask = Mutex<Task<Void, Never>?>(nil)

    init() {
        startLoad()
    }

    /// Waits for the initial off-main configuration load, proxy start and provider config export.
    func ensureReady() async {
        await readyTask?.value
    }

    /// Waits for the active store's initial load and export from service-layer callers without an AppModel reference.
    nonisolated static func waitUntilReady() async {
        let task = latestReadyTask.withLock { $0 }
        await task?.value
    }

    func retryConfigurationLoad() {
        guard hasLoadedConfiguration, configurationLoadError != nil, !isLoadingConfiguration else { return }
        startLoad()
    }

    // MARK: Reading

    func state(for id: String) -> MCPConnectionState {
        states[id] ?? .notConnected
    }

    func connection(for id: String) -> MCPConnection? {
        connections[id]
    }

    /// Connected and enabled servers, resolved with their field values: what providers get.
    var enabledServers: [MCPResolvedServer] {
        guard isConfigurationLoaded else { return [] }
        return connections.values
            .filter { $0.isEnabled && $0.connectedAt != nil }
            .compactMap { connection in
                guard let entry = entry(for: connection.catalogID) else { return nil }
                return entry.resolve(values: storedValues(for: entry))
            }
            .sorted { $0.id < $1.id }
    }

    /// The entry an id names: a custom first, then the catalog.
    func entry(for id: String) -> MCPCatalogEntry? {
        customs.first { $0.id == id }?.catalogEntry() ?? MCPCatalog.entry(id: id)
    }

    /// The value the card shows for a field: the draft, else the stored value (secrets from the Keychain).
    func value(for field: MCPField, of entry: MCPCatalogEntry) -> String {
        if let draft = drafts[entry.id]?[field.key] { return draft }
        if field.kind == .secret {
            if let secret = MCPKeychain.value(server: entry.id, field: field.key) { return secret }
        } else if let stored = connections[entry.id]?.values[field.key] {
            return stored
        }
        return field.defaultValue ?? ""
    }

    func setDraft(_ value: String, for field: MCPField, of entry: MCPCatalogEntry) {
        guard isConfigurationLoaded else { return }
        drafts[entry.id, default: [:]][field.key] = value
    }

    /// Whether every required field of the entry has a value (draft or stored).
    func canConnect(_ entry: MCPCatalogEntry) -> Bool {
        isConfigurationLoaded && entry.fields.filter { $0.isRequired }.allSatisfy { !value(for: $0, of: entry).isEmpty }
    }

    // MARK: Connecting

    /// Stores the drafts (secrets to the Keychain), probes the server, and on success marks it
    /// connected with its tools; on failure keeps the values and records the message.
    func connect(_ entry: MCPCatalogEntry) {
        guard isConfigurationLoaded else { return }
        probes[entry.id]?.cancel()
        probeIDs[entry.id] = nil
        var connection = connections[entry.id] ?? MCPConnection(catalogID: entry.id)
        connection.isEnabled = true
        // A sign-in belongs to one address: pointing the server elsewhere (another GitLab
        // instance) drops the old token so the browser flow runs against the new one.
        if entry.isOAuth, let draft = drafts[entry.id],
           entry.oauthURL(values: connection.values) != entry.oauthURL(values: connection.values.merging(draft) { $1 }) {
            MCPOAuth.signOut(serverID: entry.id)
            MCPProxy.shared.unregister(serverID: entry.id)
        }
        // A Try again after a rejection must not reuse the rejected token: a failed
        // OAuth entry starts signed out so the browser flow runs afresh.
        if entry.isOAuth, case .failed = states[entry.id] {
            MCPOAuth.signOut(serverID: entry.id)
            MCPProxy.shared.unregister(serverID: entry.id)
        }
        if let draft = drafts[entry.id] {
            for field in entry.fields {
                guard let text = draft[field.key] else { continue }
                if field.kind == .secret {
                    MCPKeychain.set(text, server: entry.id, field: field.key)
                } else {
                    connection.values[field.key] = text
                }
            }
        }
        connections[entry.id] = connection
        drafts[entry.id] = nil
        save()
        states[entry.id] = .connecting
        startProbe(entry)
    }

    /// Forgets the connection, its values and its secrets, and removes it from every provider config.
    func disconnect(_ entry: MCPCatalogEntry) {
        guard isConfigurationLoaded else { return }
        probes[entry.id]?.cancel()
        probeIDs[entry.id] = nil
        probes[entry.id] = nil
        MCPKeychain.deleteAll(server: entry)
        if entry.isOAuth {
            MCPOAuth.signOut(serverID: entry.id)
            MCPProxy.shared.unregister(serverID: entry.id)
        }
        connections[entry.id] = nil
        states[entry.id] = nil
        drafts[entry.id] = nil
        save()
        exportAll()
    }

    /// Re-probes a connected server without changing its values.
    func refresh(_ entry: MCPCatalogEntry) {
        guard isConfigurationLoaded else { return }
        probes[entry.id]?.cancel()
        probeIDs[entry.id] = nil
        states[entry.id] = .connecting
        startProbe(entry)
    }

    func setEnabled(_ enabled: Bool, for entry: MCPCatalogEntry) {
        guard isConfigurationLoaded else { return }
        guard var connection = connections[entry.id] else { return }
        connection.isEnabled = enabled
        connections[entry.id] = connection
        save()
        exportAll()
    }

    // MARK: Custom servers

    /// Adds or replaces a custom server. Validates first; the error, when there is one,
    /// is for the editor to show and nothing is written.
    @discardableResult
    func saveCustom(_ server: MCPCustomServer, replacing oldID: String? = nil) -> CustomSaveError? {
        guard isConfigurationLoaded else { return .configurationBlocked }
        let old = oldID.flatMap { id in customs.first { $0.id == id } }
        var taken = Set(MCPCatalog.entries.map(\.id))
        taken.formUnion(customs.map(\.id))
        if let old { taken.remove(old.id) }
        var server = server
        server.name = server.name.trimmed
        // The id is made once, at creation, from the first name; a rename never moves
        // it, so the connection and the Keychain's secrets stay where they are.
        server.id = old?.id ?? MCPCustomServer.makeID(server.name)
        if let error = MCPCustomError.validate(server, existingIDs: taken) { return .validation(error) }
        probes[server.id]?.cancel()
        probeIDs[server.id] = nil
        probes[server.id] = nil
        drafts[server.id] = nil
        if let index = customs.firstIndex(where: { $0.id == server.id }) {
            customs[index] = server
        } else {
            customs.append(server)
        }
        saveCustoms()
        // The definition changed under any connection it had: the tools and the provider
        // configs still describe the old command, address or variables, so both go now.
        // The server leaves the providers' configs (it is no longer connected) until the
        // editor's re-probe succeeds, and the probe runs after the values are saved.
        if var connection = connections[server.id] {
            connection.connectedAt = nil
            connection.serverVersion = nil
            connection.tools = []
            connections[server.id] = connection
            states[server.id] = .notConnected
            save()
            exportAll()
        }
        return nil
    }

    /// Removes a custom server: its connection and secrets go with it.
    func deleteCustom(_ server: MCPCustomServer) {
        guard isConfigurationLoaded else { return }
        if let entry = customs.first(where: { $0.id == server.id }) {
            disconnect(entry.catalogEntry())
        }
        customs.removeAll { $0.id == server.id }
        saveCustoms()
    }

    /// A variable's stored value, for the editor to prefill: the Keychain's when the
    /// variable is secret, the connection's otherwise.
    func storedValue(server id: String, field: String, secret: Bool) -> String? {
        if secret { return MCPKeychain.value(server: id, field: field) }
        return connections[id]?.values[field]
    }

    /// Saves a custom's variable values where `connect` would put them: plain ones in
    /// the connection (`mcp.json`), secret ones in the Keychain. A variable that moved
    /// between the two keeps its saved value (an unlocked secret is read back from the
    /// Keychain, a locked plain value from the connection) and the stale copy in the
    /// other store is removed. Empty values clear the field; the editor supplies the
    /// stored value for fields the user has not changed.
    @discardableResult
    func saveCustomValues(_ values: [(key: String, value: String, isSecret: Bool)], for id: String, replacingFieldsOf oldEntry: MCPCatalogEntry?) -> Bool {
        guard isConfigurationLoaded else { return false }
        for item in values where item.isSecret {
            guard MCPKeychain.set(item.value, server: id, field: item.key) else { return false }
        }
        let kept = Set(values.map(\.key))
        var connection = connections[id] ?? MCPConnection(catalogID: id)
        // Fields the edit no longer declares: their plain values go, their secrets too.
        for field in oldEntry?.fields ?? [] where !kept.contains(field.key) {
            MCPKeychain.delete(server: id, field: field.key)
        }
        connection.values = connection.values.filter { kept.contains($0.key) }
        for item in values {
            let resolved = item.value
            if item.isSecret {
                connection.values[item.key] = nil
            } else {
                connection.values[item.key] = resolved.isEmpty ? nil : resolved
                MCPKeychain.delete(server: id, field: item.key)
            }
        }
        // A server whose values are all empty needs no connection yet: it gets one on connect.
        if connections[id] != nil || !connection.values.isEmpty {
            connections[id] = connection
            save()
        }
        return true
    }

    // MARK: Persistence

    private enum LoadOutcome: Sendable {
        case loaded(
            customs: [MCPCustomServer],
            connections: [String: MCPConnection],
            states: [String: MCPConnectionState],
            resolvedServers: [MCPResolvedServer]
        )
        case failed(ConfigurationLoadError)
    }

    private struct ExportTarget: Sendable {
        let entry: MCPCatalogEntry
        let plainValues: [String: String]
    }

    private final class PersistenceQueue: Sendable {
        private struct Generations {
            var connections: UInt64 = 0
            var customs: UInt64 = 0
            var export: UInt64 = 0
        }

        private let queue = DispatchQueue(label: "tivano.mcp.persistence", qos: .utility)
        private let generations = Mutex(Generations())

        func writeConnections(_ list: [MCPConnection]) {
            let generation = generations.withLock { state -> UInt64 in
                state.connections &+= 1
                return state.connections
            }
            queue.async { [self] in
                guard generations.withLock({ $0.connections == generation }) else { return }
                guard let data = try? JSONEncoder.storagePretty.encode(list) else { return }
                try? data.write(to: MCPPaths.connectionsURL, options: .atomic)
            }
        }

        func writeCustoms(_ list: [MCPCustomServer]) {
            let generation = generations.withLock { state -> UInt64 in
                state.customs &+= 1
                return state.customs
            }
            queue.async { [self] in
                guard generations.withLock({ $0.customs == generation }) else { return }
                guard let data = try? JSONEncoder.storagePretty.encode(list) else { return }
                try? data.write(to: MCPPaths.customsURL, options: .atomic)
            }
        }

        func export(_ targets: [ExportTarget], preResolved: [MCPResolvedServer]? = nil, reloadHub: Bool = true) {
            let generation = generations.withLock { state -> UInt64 in
                state.export &+= 1
                return state.export
            }
            queue.async { [self] in
                guard generations.withLock({ $0.export == generation }) else { return }
                let servers = preResolved ?? targets.map { target in
                    MCPStore.resolveServer(target.entry, plainValues: target.plainValues)
                }.sorted { $0.id < $1.id }
                // The proxy's routes follow the enabled list: one per signed-in server.
                MCPProxy.shared.replaceAll(servers.compactMap { server in
                    guard let remote = server.oauthUpstream else { return nil }
                    return (serverID: server.id, upstream: remote, headers: [:], usesOAuth: true)
                })
                MCPProviderConfig.writeAll(servers)
                // The in-app clients (API providers) pick the new list up on their next use.
                if reloadHub {
                    Task { await MCPHub.shared.reload() }
                }
            }
        }

        func waitForIdle() async {
            await withCheckedContinuation { continuation in
                queue.async { continuation.resume() }
            }
        }
    }

    private func startLoad() {
        isLoadingConfiguration = true
        // No callback from the previous snapshot may change the newly loaded one.
        probeGeneration = UUID()
        probes.values.forEach { $0.cancel() }
        probes.removeAll()
        probeIDs.removeAll()
        let task = Task { [weak self] in
            let outcome = await Self.loadConfigurationOffMain()
            guard let self else { return }
            self.isLoadingConfiguration = false
            switch outcome {
            case .loaded(let loadedCustoms, let nextConnections, let nextStates, let resolvedServers):
                self.customs = loadedCustoms
                self.connections = nextConnections
                self.states = nextStates
                self.drafts.removeAll()
                self.configurationLoadError = nil
                self.hasLoadedConfiguration = true
                // Up before anything resolves a route to it: the probe, the hub and every launch
                // reach signed-in servers through the proxy. `MCPProxy.port` was loaded off-main.
                MCPProxy.shared.start()
                self.exportAll(preResolved: resolvedServers, reloadHub: false)
                await self.persistence.waitForIdle()
                await MCPHub.shared.reload()
            case .failed(let error):
                self.configurationLoadError = error
                self.hasLoadedConfiguration = true
            }
        }
        readyTask = task
        Self.latestReadyTask.withLock { $0 = task }
    }

    @concurrent
    nonisolated private static func loadConfigurationOffMain() async -> LoadOutcome {
        do {
            let loadedCustoms = try readConfiguration([MCPCustomServer].self, at: MCPPaths.customsURL, decoder: .storage) ?? []
            let loadedConnections = try readConfiguration([MCPConnection].self, at: MCPPaths.connectionsURL, decoder: .storage) ?? []
            var nextConnections: [String: MCPConnection] = [:]
            var nextStates: [String: MCPConnectionState] = [:]
            for connection in loadedConnections {
                nextConnections[connection.catalogID] = connection
                if connection.connectedAt != nil {
                    nextStates[connection.catalogID] = .connected(toolCount: connection.tools.count)
                }
            }
            // Warm the proxy port (reads/writes `proxy-port`) off-main before resolving OAuth routes.
            _ = MCPProxy.port
            let resolvedServers: [MCPResolvedServer] = nextConnections.values
                .filter { $0.isEnabled && $0.connectedAt != nil }
                .compactMap { connection in
                    let entry = loadedCustoms.first { $0.id == connection.catalogID }?.catalogEntry()
                        ?? MCPCatalog.entry(id: connection.catalogID)
                    guard let entry else { return nil }
                    return resolveServer(entry, plainValues: connection.values)
                }
                .sorted { $0.id < $1.id }
            return .loaded(
                customs: loadedCustoms,
                connections: nextConnections,
                states: nextStates,
                resolvedServers: resolvedServers
            )
        } catch let error as ConfigurationLoadError {
            return .failed(error)
        } catch {
            return .failed(ConfigurationLoadError(url: MCPPaths.connectionsURL, isReadFailure: true))
        }
    }

    nonisolated private static func readConfiguration<Value: Decodable>(_ type: Value.Type, at url: URL, decoder: JSONDecoder) throws -> Value? {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            let error = error as NSError
            // Only an explicit missing-file error is a normal empty first launch.
            if error.domain == NSCocoaErrorDomain,
               error.code == NSFileReadNoSuchFileError || error.code == NSFileNoSuchFileError {
                return nil
            }
            throw ConfigurationLoadError(url: url, isReadFailure: true)
        }
        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw ConfigurationLoadError(url: url, isReadFailure: false)
        }
    }

    nonisolated private static func resolveServer(_ entry: MCPCatalogEntry, plainValues: [String: String]) -> MCPResolvedServer {
        var values = plainValues
        for field in entry.fields where field.kind == .secret {
            if let secret = MCPKeychain.value(server: entry.id, field: field.key) {
                values[field.key] = secret
            }
        }
        return entry.resolve(values: values)
    }

    @concurrent
    nonisolated private static func resolveServerOffMain(_ entry: MCPCatalogEntry, plainValues: [String: String]) async -> MCPResolvedServer {
        resolveServer(entry, plainValues: plainValues)
    }

    private func save() {
        guard isConfigurationLoaded else { return }
        let list = connections.values.sorted { $0.catalogID < $1.catalogID }
        persistence.writeConnections(list)
    }

    private func saveCustoms() {
        guard isConfigurationLoaded else { return }
        persistence.writeCustoms(customs)
    }

    /// Rewrites every provider's config from the current enabled servers on the background writer queue.
    private func exportAll(preResolved: [MCPResolvedServer]? = nil, reloadHub: Bool = true) {
        guard isConfigurationLoaded else { return }
        let targets: [ExportTarget]
        if preResolved != nil {
            targets = []
        } else {
            targets = connections.values
                .filter { $0.isEnabled && $0.connectedAt != nil }
                .compactMap { connection in
                    guard let entry = entry(for: connection.catalogID) else { return nil }
                    return ExportTarget(entry: entry, plainValues: connection.values)
                }
        }
        persistence.export(targets, preResolved: preResolved, reloadHub: reloadHub)
    }

    /// Non-secret values from the connection, overlaid with the Keychain's secrets.
    private func storedValues(for entry: MCPCatalogEntry) -> [String: String] {
        var values = connections[entry.id]?.values ?? [:]
        for field in entry.fields where field.kind == .secret {
            if let secret = MCPKeychain.value(server: entry.id, field: field.key) {
                values[field.key] = secret
            }
        }
        return values
    }

    private func probeOnce(_ entry: MCPCatalogEntry, resolved: MCPResolvedServer, generation: UUID, probeID: UUID) async throws -> MCPProbeResult {
        try requireCurrentProbe(entry.id, generation: generation, probeID: probeID)
        // A server that signs in: the browser flow first (Tivano's own, with its
        // branded page), then its route on the proxy, and only then the probe, which
        // goes through that route like every provider will.
        if let remote = resolved.oauthUpstream {
            if !MCPOAuth.isSignedIn(serverID: entry.id) {
                try await MCPOAuth.signIn(serverID: entry.id, serverName: entry.name, url: remote)
            }
            try requireCurrentProbe(entry.id, generation: generation, probeID: probeID)
            MCPProxy.shared.register(serverID: entry.id, upstream: remote, headers: [:], usesOAuth: true)
        }
        try requireCurrentProbe(entry.id, generation: generation, probeID: probeID)
        return try await MCPProbe.probe(resolved)
    }

    private func requireCurrentProbe(_ id: String, generation: UUID, probeID: UUID) throws {
        try Task.checkCancellation()
        guard isConfigurationLoaded, probeGeneration == generation, probeIDs[id] == probeID else {
            throw CancellationError()
        }
    }

    private func startProbe(_ entry: MCPCatalogEntry) {
        guard isConfigurationLoaded else { return }
        let generation = probeGeneration
        let probeID = UUID()
        probeIDs[entry.id] = probeID
        let plainValues = connections[entry.id]?.values ?? [:]
        probes[entry.id] = Task {
            do {
                try requireCurrentProbe(entry.id, generation: generation, probeID: probeID)
                let resolved = await Self.resolveServerOffMain(entry, plainValues: plainValues)
                let result: MCPProbeResult
                do {
                    result = try await probeOnce(entry, resolved: resolved, generation: generation, probeID: probeID)
                } catch MCPProbeError.unauthorizedOAuth where resolved.oauthUpstream != nil {
                    try requireCurrentProbe(entry.id, generation: generation, probeID: probeID)
                    MCPOAuth.signOut(serverID: entry.id)
                    MCPProxy.shared.unregister(serverID: entry.id)
                    result = try await probeOnce(entry, resolved: resolved, generation: generation, probeID: probeID)
                } catch MCPProbeError.http(let status, _) where resolved.oauthUpstream != nil && (status == 401 || status == 403) {
                    try requireCurrentProbe(entry.id, generation: generation, probeID: probeID)
                    MCPOAuth.signOut(serverID: entry.id)
                    MCPProxy.shared.unregister(serverID: entry.id)
                    result = try await probeOnce(entry, resolved: resolved, generation: generation, probeID: probeID)
                }
                try requireCurrentProbe(entry.id, generation: generation, probeID: probeID)
                if var connection = connections[entry.id] {
                    connection.connectedAt = .now
                    connection.serverVersion = result.serverVersion
                    connection.tools = result.tools
                    connections[entry.id] = connection
                }
                states[entry.id] = .connected(toolCount: result.tools.count)
                save()
                exportAll()
            } catch is CancellationError {
            } catch MCPProbeError.needsSetup(let guide) {
                guard !Task.isCancelled, isConfigurationLoaded,
                      probeGeneration == generation, probeIDs[entry.id] == probeID else { return }
                // The token is good; the server needs a step on its side. Keep the sign-in so
                // Check again re-probes without another browser round trip.
                states[entry.id] = .needsSetup(guide)
            } catch {
                guard !Task.isCancelled, isConfigurationLoaded,
                      probeGeneration == generation, probeIDs[entry.id] == probeID else { return }
                states[entry.id] = .failed(message: error.localizedDescription)
            }
        }
    }
}
