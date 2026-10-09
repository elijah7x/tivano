import Foundation
import Observation

/// The user's MCP connections: which catalog servers are connected, their field values,
/// and what each announced when it was last probed. Persists to `MCPPaths.connectionsURL`
/// (secrets to the Keychain) and, on every change, rewrites the provider config files under
/// `MCPPaths.directory` and syncs the file-based CLIs (Cursor, OpenCode, Gemini).
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

    @ObservationIgnored private var probes: [String: Task<Void, Never>] = [:]

    init() {
        load()
        // Up before anything resolves a route to it: the probe, the hub and every launch
        // reach signed-in servers through the proxy.
        MCPProxy.shared.start()
        exportAll()
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
        connections.values
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
        drafts[entry.id, default: [:]][field.key] = value
    }

    /// Whether every required field of the entry has a value (draft or stored).
    func canConnect(_ entry: MCPCatalogEntry) -> Bool {
        entry.fields.filter { $0.isRequired }.allSatisfy { !value(for: $0, of: entry).isEmpty }
    }

    // MARK: Connecting

    /// Stores the drafts (secrets to the Keychain), probes the server, and on success marks it
    /// connected with its tools; on failure keeps the values and records the message.
    func connect(_ entry: MCPCatalogEntry) {
        probes[entry.id]?.cancel()
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
        probes[entry.id]?.cancel()
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
        probes[entry.id]?.cancel()
        states[entry.id] = .connecting
        startProbe(entry)
    }

    func setEnabled(_ enabled: Bool, for entry: MCPCatalogEntry) {
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
    func saveCustom(_ server: MCPCustomServer, replacing oldID: String? = nil) -> MCPCustomError? {
        let old = oldID.flatMap { id in customs.first { $0.id == id } }
        var taken = Set(MCPCatalog.entries.map(\.id))
        taken.formUnion(customs.map(\.id))
        if let old { taken.remove(old.id) }
        var server = server
        server.name = server.name.trimmed
        // The id is made once, at creation, from the first name; a rename never moves
        // it, so the connection and the Keychain's secrets stay where they are.
        server.id = old?.id ?? MCPCustomServer.makeID(server.name)
        if let error = MCPCustomError.validate(server, existingIDs: taken) { return error }
        probes[server.id]?.cancel()
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

    private func load() {
        if let data = try? Data(contentsOf: MCPPaths.customsURL),
           let list = try? JSONDecoder().decode([MCPCustomServer].self, from: data) {
            customs = list
        }
        guard let data = try? Data(contentsOf: MCPPaths.connectionsURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let list = try? decoder.decode([MCPConnection].self, from: data) else { return }
        for connection in list {
            connections[connection.catalogID] = connection
            if connection.connectedAt != nil {
                states[connection.catalogID] = .connected(toolCount: connection.tools.count)
            }
        }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let list = connections.values.sorted { $0.catalogID < $1.catalogID }
        guard let data = try? encoder.encode(list) else { return }
        try? data.write(to: MCPPaths.connectionsURL, options: .atomic)
    }

    private func saveCustoms() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(customs) else { return }
        try? data.write(to: MCPPaths.customsURL, options: .atomic)
    }

    /// Rewrites every provider's config from `enabledServers` and runs the one-time external-CLI cleanup.
    private func exportAll() {
        let servers = enabledServers
        // The proxy's routes follow the enabled list: one per signed-in server.
        MCPProxy.shared.replaceAll(servers.compactMap { server in
            guard let remote = server.oauthUpstream else { return nil }
            return (serverID: server.id, upstream: remote, headers: [:], usesOAuth: true)
        })
        MCPProviderConfig.writeAll(servers)
        MCPExternalSync.sync(servers)
        // The in-app clients (API providers) pick the new list up on their next use.
        Task { await MCPHub.shared.reload() }
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

    private func probeOnce(_ entry: MCPCatalogEntry, resolved: MCPResolvedServer) async throws -> MCPProbeResult {
        // A server that signs in: the browser flow first (Tivano's own, with its
        // branded page), then its route on the proxy, and only then the probe, which
        // goes through that route like every provider will.
        if let remote = resolved.oauthUpstream {
            if !MCPOAuth.isSignedIn(serverID: entry.id) {
                try await MCPOAuth.signIn(serverID: entry.id, serverName: entry.name, url: remote)
            }
            MCPProxy.shared.register(serverID: entry.id, upstream: remote, headers: [:], usesOAuth: true)
        }
        return try await MCPProbe.probe(resolved)
    }

    private func startProbe(_ entry: MCPCatalogEntry) {
        probes[entry.id] = Task {
            do {
                let resolved = entry.resolve(values: storedValues(for: entry))
                let result: MCPProbeResult
                do {
                    result = try await probeOnce(entry, resolved: resolved)
                } catch MCPProbeError.unauthorizedOAuth where resolved.oauthUpstream != nil {
                    try Task.checkCancellation()
                    MCPOAuth.signOut(serverID: entry.id)
                    MCPProxy.shared.unregister(serverID: entry.id)
                    result = try await probeOnce(entry, resolved: resolved)
                } catch MCPProbeError.http(let status, _) where resolved.oauthUpstream != nil && (status == 401 || status == 403) {
                    try Task.checkCancellation()
                    MCPOAuth.signOut(serverID: entry.id)
                    MCPProxy.shared.unregister(serverID: entry.id)
                    result = try await probeOnce(entry, resolved: resolved)
                }
                try Task.checkCancellation()
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
                guard !Task.isCancelled else { return }
                // The token is good; the server needs a step on its side. Keep the sign-in so
                // Check again re-probes without another browser round trip.
                states[entry.id] = .needsSetup(guide)
            } catch {
                guard !Task.isCancelled else { return }
                states[entry.id] = .failed(message: error.localizedDescription)
            }
        }
    }
}
