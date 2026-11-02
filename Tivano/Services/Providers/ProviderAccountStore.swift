import Foundation
import Darwin

struct CodexImportCandidate: Identifiable, Equatable, Sendable {
    var id: String
    var source: String
    var authPath: String
    var identity: CodexIdentity
    var label: String?
}

enum ProviderAccountStore {
    nonisolated static var fileURL: URL {
        StoragePaths.root.appendingPathComponent("provider-accounts.json")
    }

    nonisolated static func load() -> ProviderAccountBook {
        guard let data = try? Data(contentsOf: fileURL),
              let book = try? JSONDecoder().decode(ProviderAccountBook.self, from: data) else { return ProviderAccountBook() }
        return book
    }

    @discardableResult
    nonisolated static func save(_ book: ProviderAccountBook) -> Bool {
        do {
            try saveThrowing(book)
            return true
        } catch {
            NSLog("Tivano could not save %@: %@", fileURL.lastPathComponent, error.localizedDescription)
            return false
        }
    }

    nonisolated static func saveThrowing(_ book: ProviderAccountBook) throws {
        try writePrivate(JSONEncoder().encode(book), to: fileURL)
    }

    nonisolated static var accountsRoot: String {
        if let root = CaptureRun.storageRoot { return root.appendingPathComponent("accounts").path }
        return URL(fileURLWithPath: LoginEnvironment.homeDirectory)
            .appendingPathComponent(AppInfo.stateDirectoryName).appendingPathComponent("accounts").path
    }

    nonisolated static func defaultCodexHome(environment: [String: String]) -> String {
        if let configured = environment["CODEX_HOME"], !configured.isEmpty {
            return (configured as NSString).expandingTildeInPath
        }
        return (LoginEnvironment.homeDirectory as NSString).appendingPathComponent(".codex")
    }

    nonisolated static func defaultClaudeHome(environment: [String: String]) -> String {
        let path = environment["CLAUDE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : $0 }
            ?? (LoginEnvironment.homeDirectory as NSString).appendingPathComponent(".claude")
        return (path as NSString).expandingTildeInPath
    }

    nonisolated static func writeClaudeIdentity(_ candidate: ClaudeSwapImportCandidate, into home: String) throws {
        guard !CaptureRun.isEnabled else { throw ClaudeCredentialError.capture }
        var identity: [String: String] = ["emailAddress": candidate.email]
        identity["accountUuid"] = candidate.accountID
        identity["organizationUuid"] = candidate.organizationID
        identity["organizationName"] = candidate.organizationName
        let data = try JSONSerialization.data(withJSONObject: ["oauthAccount": identity])
        try writePrivate(data, to: URL(fileURLWithPath: home).appendingPathComponent(".claude.json"))
    }

    nonisolated static func claudeIdentity(home: String, isDefault: Bool = false) -> JSONValue? {
        guard !CaptureRun.isEnabled else { return nil }
        let url = isDefault ? URL(fileURLWithPath: LoginEnvironment.homeDirectory).appendingPathComponent(".claude.json")
            : URL(fileURLWithPath: home).appendingPathComponent(".claude.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return JSONValue.parse(data)?["oauthAccount"]
    }

    nonisolated static func claudeCredentials(environment: [String: String]) async throws -> Data? {
        try await ClaudeAccountCredentials.readUnattended(environment: environment,
            isManaged: environment["CLAUDE_CODE_PROVIDER_MANAGED_BY_HOST"] == "1")
    }

    nonisolated static func makeHome(provider: ProviderKind, id: UUID, linkingFrom source: String) throws -> String {
        if provider == .claude, CaptureRun.isEnabled { throw ClaudeCredentialError.capture }
        let home = URL(fileURLWithPath: accountsRoot).appendingPathComponent(provider.rawValue).appendingPathComponent(id.uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: home.path)
        if provider == .codex { linkShared(home: home.path, source: source) }
        return home.path
    }

    nonisolated static func linkShared(home: String, source: String) {
        let manager = FileManager.default
        let sourceURL = URL(fileURLWithPath: (source as NSString).expandingTildeInPath).standardizedFileURL
        for name in ["sessions", "archived_sessions"] {
            let directory = sourceURL.appendingPathComponent(name)
            if !manager.fileExists(atPath: directory.path) {
                try? manager.createDirectory(at: directory, withIntermediateDirectories: true)
            }
        }
        for entry in (try? manager.contentsOfDirectory(atPath: sourceURL.path)) ?? [] {
            guard entry != "auth.json", !entry.hasPrefix("auth.json.") else { continue }
            let target = URL(fileURLWithPath: home).appendingPathComponent(entry).path
            guard !manager.fileExists(atPath: target),
                  (try? manager.destinationOfSymbolicLink(atPath: target)) == nil else { continue }
            try? manager.createSymbolicLink(atPath: target, withDestinationPath: sourceURL.appendingPathComponent(entry).path)
        }
    }

    nonisolated static func removeHome(_ home: String) {
        let root = URL(fileURLWithPath: accountsRoot).standardizedFileURL.resolvingSymlinksInPath().path
        let target = URL(fileURLWithPath: (home as NSString).expandingTildeInPath).standardizedFileURL
        guard target.resolvingSymlinksInPath().path.hasPrefix(root + "/") else { return }
        try? FileManager.default.removeItem(at: target)
    }

    nonisolated static func removeHomeThrowing(_ home: String) throws {
        guard !CaptureRun.isEnabled else { throw ClaudeCredentialError.capture }
        let root = URL(fileURLWithPath: accountsRoot).standardizedFileURL.resolvingSymlinksInPath().path
        let target = URL(fileURLWithPath: home).standardizedFileURL
        let parent = target.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath().path
        guard parent.hasPrefix(root + "/"), target == target.resolvingSymlinksInPath() else {
            throw ClaudeCredentialError.invalidDirectory
        }
        do { try FileManager.default.removeItem(at: target) }
        catch CocoaError.fileNoSuchFile { return }
    }

    nonisolated static func replaceClaudeMetadata(_ data: Data?, home: String) throws {
        guard !CaptureRun.isEnabled else { throw ClaudeCredentialError.capture }
        // Reuse the credential boundary before writing to a managed profile.
        _ = try ClaudeAccountCredentials.snapshot(configDirectory: home)
        let url = URL(fileURLWithPath: home).appendingPathComponent(".claude.json")
        if let data { try writePrivate(data, to: url) }
        else {
            do { try FileManager.default.removeItem(at: url) }
            catch CocoaError.fileNoSuchFile { return }
        }
    }

    nonisolated static func codexIdentity(home: String) -> CodexIdentity? {
        identity(at: URL(fileURLWithPath: home).appendingPathComponent("auth.json"))
    }

    private nonisolated static func identity(at url: URL) -> CodexIdentity? {
        guard let data = try? Data(contentsOf: url), let root = JSONValue.parse(data) else { return nil }
        if let token = root["tokens"]?["id_token"]?.string {
            let parts = token.split(separator: ".", omittingEmptySubsequences: false)
            if parts.count >= 2 {
                var payload = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
                while !payload.count.isMultiple(of: 4) { payload += "=" }
                if let decoded = Data(base64Encoded: payload), let claims = JSONValue.parse(decoded), claims.object != nil {
                    let auth = claims["https://api.openai.com/auth"]
                    return CodexIdentity(email: claims["email"]?.string, accountID: auth?["chatgpt_account_id"]?.string,
                                         userID: auth?["chatgpt_user_id"]?.string ?? auth?["user_id"]?.string,
                                         plan: auth?["chatgpt_plan_type"]?.string)
                }
            }
        }
        if root["auth_mode"]?.string == "apikey" || (root["OPENAI_API_KEY"]?.string?.isEmpty == false) {
            return CodexIdentity(email: nil, accountID: nil, userID: nil, plan: "API key")
        }
        return nil
    }

    nonisolated static func codexImportCandidates(defaultHome: String) -> [CodexImportCandidate] {
        let manager = FileManager.default
        let switcher = URL(fileURLWithPath: LoginEnvironment.homeDirectory)
            .appendingPathComponent("Library/Application Support/Codex Account Switcher")
        let metadata = (try? Data(contentsOf: switcher.appendingPathComponent("accounts.json"))).flatMap { JSONValue.parse($0) }
        var candidates: [CodexImportCandidate] = []
        let accounts = switcher.appendingPathComponent("accounts")
        for directory in ((try? manager.contentsOfDirectory(atPath: accounts.path)) ?? []).sorted() {
            let auth = accounts.appendingPathComponent(directory).appendingPathComponent("auth.json")
            if let identity = identity(at: auth) {
                candidates.append(CodexImportCandidate(id: auth.path, source: "Codex Account Switcher", authPath: auth.path,
                                                      identity: identity, label: metadata.flatMap { label(in: $0, id: directory) }))
            }
        }
        let legacy = URL(fileURLWithPath: defaultHome).appendingPathComponent("accounts")
        for file in ((try? manager.contentsOfDirectory(atPath: legacy.path)) ?? []).sorted() where file.hasSuffix(".auth.json") {
            let auth = legacy.appendingPathComponent(file)
            if let identity = identity(at: auth) {
                candidates.append(CodexImportCandidate(id: auth.path, source: "codex-auth", authPath: auth.path,
                                                      identity: identity, label: String(file.dropLast(".auth.json".count))))
            }
        }
        var seen = Set<[String]>()
        return candidates.filter { candidate in
            let identity = candidate.identity
            let account = identity.accountID.flatMap { $0.isEmpty ? nil : $0 }
            let email = identity.email.flatMap { $0.isEmpty ? nil : $0 }
            guard account != nil || email != nil else { return false }
            let key = account.map { ["account", $0, identity.userID ?? email ?? ""] } ?? ["email", email ?? ""]
            return seen.insert(key).inserted
        }
    }

    private nonisolated static func label(in value: JSONValue, id: String) -> String? {
        if let object = value.object {
            let record = object[id] ?? object.first(where: { $0.key.lowercased() == id.lowercased() })?.value
            if let record {
                for key in ["name", "label", "email"] {
                    if let text = record[key]?.string, !text.isEmpty { return text }
                }
            }
            if ["id", "uuid", "account_id", "accountId"].contains(where: { object[$0]?.string?.lowercased() == id.lowercased() }) {
                for key in ["name", "label", "email"] {
                    if let text = object[key]?.string, !text.isEmpty { return text }
                }
            }
            for key in object.keys.sorted() {
                if let child = object[key], let result = label(in: child, id: id) { return result }
            }
        } else if let array = value.array {
            for child in array {
                if let result = label(in: child, id: id) { return result }
            }
        }
        return nil
    }

    nonisolated static func importCodexCredential(_ candidate: CodexImportCandidate, into home: String) throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: candidate.authPath))
        try writePrivate(data, to: URL(fileURLWithPath: home).appendingPathComponent("auth.json"))
    }

    /// Stage with private permissions before atomically replacing the destination, including symlinks.
    private nonisolated static func writePrivate(_ data: Data, to url: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let temporary = url.deletingLastPathComponent().appendingPathComponent("auth.json.\(UUID().uuidString).tmp")
        guard manager.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { try? manager.removeItem(at: temporary) }
        try data.write(to: temporary)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        guard rename(temporary.path, url.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}
