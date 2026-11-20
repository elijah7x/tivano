import CryptoKit
import Darwin
import Foundation
import Security

enum ClaudeCredentialError: LocalizedError {
    case invalidDirectory, invalidCredential, readFile, removeFile
    case readKeychain, removeKeychain, capture
    case saveAccount, cleanupRequired, duplicateAccount

    nonisolated var errorDescription: String? {
        switch self {
        case .saveAccount: AppText.localized("The account changes could not be saved. Try again.")
        case .cleanupRequired: AppText.localized("This Claude account needs local cleanup. Remove it and try again.")
        case .duplicateAccount: AppText.localized("This Claude account is already added.")
        case .invalidDirectory: AppText.localized("The Claude account directory is not safe to access.")
        case .invalidCredential: AppText.localized("The Claude credentials are damaged or use an unsupported format.")
        case .readFile: AppText.localized("The Claude account file could not be read.")
        case .removeFile: AppText.localized("The Claude credential file could not be removed.")
        case .readKeychain: AppText.localized("The Claude credentials could not be read from Keychain. Unlock it or allow access, then try again.")
        case .removeKeychain: AppText.localized("The Claude credentials could not be removed from Keychain.")
        case .capture: AppText.localized("Claude account credentials are unavailable during captures.")
        }
    }
}

/// Read-only access and local cleanup for Claude Code's native credential storage.
/// Official `claude auth login`, `claude auth logout`, and normal CLI sessions own
/// writing and refreshing credentials so Keychain ACLs remain aligned with `/usr/bin/security`.
enum ClaudeAccountCredentials {
    private nonisolated static let credentialQueue = DispatchQueue(label: "Tivano.ClaudeCredentials", qos: .userInitiated)

    nonisolated static func offMain<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            credentialQueue.async { continuation.resume(with: Result { try work() }) }
        }
    }

    // Verified against Claude Code 2.1.314's embedded macOsKeychainHelpers and
    // plainTextStorage: NFC(raw env value), SHA-256 prefix, and USER validation.
    // https://code.claude.com/docs/en/env-vars documents CLAUDE_CONFIG_DIR.
    private nonisolated static func storeLocation(environment: [String: String], isManaged: Bool) throws -> (directory: String, service: String) {
        if isManaged {
            guard let configured = environment["CLAUDE_CONFIG_DIR"], !configured.isEmpty,
                  environment["CLAUDE_SECURESTORAGE_CONFIG_DIR"] == configured else {
                throw ClaudeCredentialError.invalidDirectory
            }
            try requireManagedDirectory(configured, protecting: [:])
            return (configured, serviceName(configured))
        }
        return try defaultStore(environment: environment)
    }

    private nonisolated static func defaultStore(environment: [String: String]) throws -> (directory: String, service: String) {
        // A defined-but-empty secure selector overrides a custom config
        // directory and selects HOME/.claude plus the unsuffixed service.
        let selector = environment["CLAUDE_SECURESTORAGE_CONFIG_DIR"]
            ?? environment["CLAUDE_CONFIG_DIR"] ?? ""
        let directory = selector.isEmpty ? defaultDirectory(environment: environment)
            : selector.precomposedStringWithCanonicalMapping
        let service = selector.isEmpty ? "Claude Code-credentials" : serviceName(selector)
        try requireAbsoluteDirectory(directory)
        return (directory, service)
    }

    /// Background usage reads; uses `/usr/bin/security` for both default and managed
    /// profiles (matching Claude Code CLI's own Keychain ownership) and never blocks longer than `timeout`.
    nonisolated static func readUnattended(environment: [String: String], isManaged: Bool, timeout: TimeInterval = 5) async throws -> Data? {
        try requireAccess()
        let store = try storeLocation(environment: environment, isManaged: isManaged)
        let result: ShellResult
        do {
            result = try await Shell.run(URL(fileURLWithPath: "/usr/bin/security"),
                ["find-generic-password", "-s", store.service, "-a", username(environment: environment), "-w"],
                environment: environment, timeout: timeout)
        } catch {
            throw ClaudeCredentialError.readKeychain
        }
        guard !result.timedOut else { throw ClaudeCredentialError.readKeychain }
        if result.status == 0 {
            let text = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            let data = text.hasPrefix("{") ? Data(text.utf8) : (hexDecoded(text) ?? Data(text.utf8))
            return try validated(data)
        }
        // security exits with 44 for errSecItemNotFound; other failures must not select the file store.
        guard result.status == 44 else { throw ClaudeCredentialError.readKeychain }
        guard let data = try await offMain({ try readFile(directory: store.directory, name: ".credentials.json") }) else { return nil }
        return try validated(data)
    }

    /// Removes local credentials for a managed profile. Tries `/usr/bin/security` first
    /// (for CLI-created items) and falls back to the login Keychain API for legacy Tivano-created items.
    nonisolated static func remove(configDirectory: String, environment: [String: String] = LoginEnvironment.current, timeout: TimeInterval = 15) async throws {
        try requireAccess()
        try requireManagedDirectory(configDirectory)
        // Remove a stale file first: a failed Keychain delete then leaves the
        // current credential intact instead of exposing an old file fallback.
        try await offMain {
            let fd = open(configDirectory, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if fd >= 0 {
                defer { close(fd) }
                if unlinkat(fd, ".credentials.json", 0) != 0, errno != ENOENT {
                    throw ClaudeCredentialError.removeFile
                }
            } else if errno != ENOENT {
                throw ClaudeCredentialError.removeFile
            }
        }
        let service = serviceName(configDirectory)
        let account = username(environment: environment)
        let securityResult = try? await Shell.run(URL(fileURLWithPath: "/usr/bin/security"),
            ["delete-generic-password", "-s", service, "-a", account],
            environment: environment, timeout: timeout)
        if let securityResult, !securityResult.timedOut,
           securityResult.status == 0 || securityResult.status == 44 {
            return
        }
        // Fallback for legacy Keychain entries previously added by Tivano directly.
        try await offMain {
            let status = SecItemDelete(keychainQuery(service: service, account: account) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw ClaudeCredentialError.removeKeychain
            }
        }
    }

    private nonisolated static func hexDecoded(_ text: String) -> Data? {
        guard text.count.isMultiple(of: 2), text.allSatisfy(\.isHexDigit) else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(text.count / 2)
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            guard let byte = UInt8(text[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return Data(bytes)
    }

    nonisolated static func validated(_ data: Data) throws -> Data {
        guard data.count <= 4 * 1024 * 1024,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else {
            throw ClaudeCredentialError.invalidCredential
        }
        if let refresh = oauth["refreshToken"], !(refresh is NSNull), !(refresh is String) {
            throw ClaudeCredentialError.invalidCredential
        }
        if let scopes = oauth["scopes"], !(scopes is [String]) {
            throw ClaudeCredentialError.invalidCredential
        }
        for key in ["expiresAt", "refreshTokenExpiresAt"] {
            if let value = oauth[key], !(value is NSNull) {
                guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                      number.doubleValue.isFinite else { throw ClaudeCredentialError.invalidCredential }
            }
        }
        return data
    }

    nonisolated static func readFile(directory: String, name: String) throws -> Data? {
        try requireAccess()
        try requireAbsoluteDirectory(directory)
        guard !name.isEmpty, name != ".", name != "..",
              !name.contains("/"), !name.contains("\\"), !name.contains("\0") else {
            throw ClaudeCredentialError.invalidDirectory
        }
        let folder = open(directory, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard folder >= 0 else {
            if errno == ENOENT { return nil }
            throw ClaudeCredentialError.readFile
        }
        defer { close(folder) }
        let fd = openat(folder, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else {
            if errno == ENOENT { return nil }
            throw ClaudeCredentialError.readFile
        }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size >= 0, info.st_size <= 4 * 1024 * 1024 else {
            throw ClaudeCredentialError.readFile
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count < 0 {
                if errno == EINTR { continue }
                throw ClaudeCredentialError.readFile
            }
            if count == 0 { return data }
            guard data.count + count <= 4 * 1024 * 1024 else { throw ClaudeCredentialError.readFile }
            data.append(contentsOf: buffer.prefix(count))
        }
    }

    private nonisolated static func requireAccess() throws {
        guard !CaptureRun.isEnabled else { throw ClaudeCredentialError.capture }
    }

    private nonisolated static func requireAbsoluteDirectory(_ path: String) throws {
        guard path.hasPrefix("/"), !path.contains("\0"), !path.split(separator: "/").contains("..") else {
            throw ClaudeCredentialError.invalidDirectory
        }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard url == url.resolvingSymlinksInPath() else { throw ClaudeCredentialError.invalidDirectory }
    }

    private nonisolated static func requireManagedDirectory(
        _ path: String, protecting environment: [String: String] = LoginEnvironment.current
    ) throws {
        try requireAbsoluteDirectory(path)
        let root = URL(fileURLWithPath: ProviderAccountStore.accountsRoot)
            .appendingPathComponent("claude").standardizedFileURL.resolvingSymlinksInPath().path
        let targetURL = URL(fileURLWithPath: path)
        let parent = targetURL.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath().path
        let target = parent + "/" + targetURL.lastPathComponent
        let defaultDirectory = LoginEnvironment.homeDirectory + "/.claude"
        let protectedDirectories = [defaultDirectory,
                                    environment["CLAUDE_CONFIG_DIR"],
                                    environment["CLAUDE_SECURESTORAGE_CONFIG_DIR"]]
            .compactMap { $0 }.filter { !$0.isEmpty }
            .map { URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath().path }
        guard parent == root, !protectedDirectories.contains(target) else {
            throw ClaudeCredentialError.invalidDirectory
        }
    }

    private nonisolated static func serviceName(_ directory: String) -> String {
        let digest = SHA256.hash(data: Data(directory.precomposedStringWithCanonicalMapping.utf8))
        let suffix = digest.prefix(4).map { String(format: "%02x", $0) }.joined()
        return "Claude Code-credentials-" + suffix
    }

    private nonisolated static func defaultDirectory(environment: [String: String]) -> String {
        // os.homedir() on POSIX honors HOME when defined:
        // https://nodejs.org/api/os.html#oshomedir
        let home = environment["HOME"] ?? LoginEnvironment.homeDirectory
        return (home as NSString).appendingPathComponent(".claude").precomposedStringWithCanonicalMapping
    }

    private nonisolated static func username(environment: [String: String]) -> String {
        let user = environment["USER"].flatMap { $0.isEmpty ? nil : $0 } ?? NSUserName()
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        return !user.isEmpty && user.unicodeScalars.allSatisfy(allowed.contains) ? user : "claude-code-user"
    }

    private nonisolated static func keychainQuery(service: String, account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }
}
