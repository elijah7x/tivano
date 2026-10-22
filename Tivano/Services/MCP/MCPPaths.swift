import Foundation

/// Where the config files providers read at launch are written. Each holds every enabled
/// server in that provider's own format; a missing or empty file means no servers.
enum MCPPaths {
    // Provider configs under here carry secrets: the directory and every file in it stay owner-only.
    static let directory: URL = {
        let url = Storage.root.appendingPathComponent("mcp", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // The attributes above only reach a directory this call creates; an existing one is tightened here.
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }()

    /// Kept for the Keychain-free settings: `[MCPConnection]` as JSON.
    static let connectionsURL = Storage.root.appendingPathComponent("mcp.json")
    /// The user's own servers: `[MCPCustomServer]` as JSON (secret values never land here).
    static let customsURL = Storage.root.appendingPathComponent("custom-mcp.json")
    /// `{"mcpServers": {...}}` for `claude --mcp-config`.
    static let claudeConfigURL = directory.appendingPathComponent("claude.json")
    /// `{"mcp_servers": {...}}` for Codex's app-server `config` overrides.
    static let codexConfigURL = directory.appendingPathComponent("codex.json")
    /// `{"mcpServers": {...}}` for `copilot --additional-mcp-config`.
    static let copilotConfigURL = directory.appendingPathComponent("copilot.json")

    /// Atomic write tightened to 0600; a failed write leaves nothing readable behind.
    @discardableResult
    static func writePrivate(_ data: Data, to url: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return true
        } catch {
            try? FileManager.default.removeItem(at: url)
            return false
        }
    }
}
