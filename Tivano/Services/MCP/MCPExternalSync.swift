import Foundation

/// One-time cleanup: the connected servers reach the CLIs at launch now
/// (Claude, Codex, Copilot, OpenCode), never through their config files;
/// this only takes back what an earlier build put there.
enum MCPExternalSync {
    static func sync(_ servers: [MCPResolvedServer]) {
        guard !CaptureRun.isEnabled else { return }
        let manager = FileManager.default
        guard manager.fileExists(atPath: managedURL.path) else { return }
        guard let managed = readManaged() else { return }
        let home = URL(fileURLWithPath: LoginEnvironment.homeDirectory, isDirectory: true)
        let cursor = remove(
            ids: managed["cursor"] ?? [],
            at: home.appendingPathComponent(".cursor/mcp.json"),
            rootKey: "mcpServers"
        )
        let opencode = remove(
            ids: managed["opencode"] ?? [],
            at: home.appendingPathComponent(".config/opencode/opencode.json"),
            rootKey: "mcp"
        )
        let gemini = remove(
            ids: managed["gemini"] ?? [],
            at: home.appendingPathComponent(".gemini/settings.json"),
            rootKey: "mcpServers"
        )
        if cursor && opencode && gemini {
            try? manager.removeItem(at: managedURL)
        }
    }

    /// Removes exactly `ids` from the file's `rootKey` object, leaving every
    /// other key alone. Failed cleanup keeps the marker for another launch.
    private static func remove(ids: [String], at url: URL, rootKey: String) -> Bool {
        guard !ids.isEmpty else { return true }
        let target = url.standardizedFileURL.resolvingSymlinksInPath()
        guard let lease = try? SharedLibraryLease(at: SharedResourceLock.url(resource: target.path)) else {
            return false
        }
        return withExtendedLifetime(lease) {
            do {
                let data: Data
                do {
                    data = try Data(contentsOf: target)
                } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                    return true
                }
                guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    return false
                }
                guard let value = root[rootKey] else { return true }
                guard var entries = value as? [String: Any] else { return false }
                var removed = false
                for id in ids where entries[id] != nil {
                    entries.removeValue(forKey: id)
                    removed = true
                }
                guard removed else { return true }
                root[rootKey] = entries
                let out = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
                try out.write(to: target, options: .atomic)
                return true
            } catch {
                return false
            }
        }
    }

    private static let managedURL = MCPPaths.directory.appendingPathComponent("managed.json")

    private static func readManaged() -> [String: [String]]? {
        guard let data = try? Data(contentsOf: managedURL),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        var out: [String: [String]] = [:]
        for key in ["cursor", "opencode", "gemini"] {
            if let value = parsed[key] {
                guard let ids = value as? [String] else { return nil }
                out[key] = ids
            }
        }
        return out
    }
}
