import CryptoKit
import Darwin
import Foundation
import Security
import Synchronization

enum ClaudeCredentialError: LocalizedError {
    case invalidDirectory, invalidCredential, readFile, removeFile
    case readKeychain, writeKeychain, removeKeychain, capture
    case invalidIndex, changedCandidate, missingCredential
    case saveAccount, activationRequired, cleanupRequired

    nonisolated var errorDescription: String? {
        switch self {
        case .saveAccount: AppText.localized("The account changes could not be saved. Try again.")
        case .activationRequired: AppText.localized("Activate this Claude account before using it.")
        case .cleanupRequired: AppText.localized("This Claude account needs local cleanup. Remove it and try again.")
        case .invalidDirectory: AppText.localized("The Claude account directory is not safe to access.")
        case .invalidCredential: AppText.localized("The Claude credentials are damaged or use an unsupported format.")
        case .readFile: AppText.localized("The Claude account file could not be read.")
        case .removeFile: AppText.localized("The Claude credential file could not be removed.")
        case .readKeychain: AppText.localized("The Claude credentials could not be read from Keychain. Unlock it or allow access, then try again.")
        case .writeKeychain: AppText.localized("The Claude credentials could not be saved to Keychain.")
        case .removeKeychain: AppText.localized("The Claude credentials could not be removed from Keychain.")
        case .capture: AppText.localized("Claude account credentials are unavailable during captures.")
        case .invalidIndex: AppText.localized("The CSWAP account index is damaged or uses an unsupported format.")
        case .changedCandidate: AppText.localized("The CSWAP account changed. Refresh the account list and select it again.")
        case .missingCredential: AppText.localized("No saved OAuth credentials were found for this CSWAP account.")
        }
    }
}

enum ClaudeAccountCredentials {
    private nonisolated static let credentialQueue = DispatchQueue(label: "Tivano.ClaudeCredentials", qos: .userInitiated)

    private nonisolated static let unattendedReadInFlight = Mutex(false)

    private final class Request<T: Sendable>: Sendable {
        private nonisolated let continuation: Mutex<CheckedContinuation<T, Error>?>

        nonisolated init(_ continuation: CheckedContinuation<T, Error>) {
            self.continuation = Mutex(continuation)
        }

        nonisolated func finish(_ result: Result<T, Error>) {
            continuation.withLock { pending -> CheckedContinuation<T, Error>? in
                defer { pending = nil }
                return pending
            }?.resume(with: result)
        }
    }

    // Keychain calls can wait on a macOS access prompt with no upper bound. Without a
    // timeout, work runs in order on one queue. A timed read gets its own worker instead:
    // one stuck past its timeout must not hold up imports, sign-ins or removals, and only
    // one may be in flight, so later timed reads fail at once rather than stack prompts.
    nonisolated static func offMain<T: Sendable>(timeout: TimeInterval? = nil, _ work: @escaping @Sendable () throws -> T) async throws -> T {
        guard let timeout else {
            return try await withCheckedThrowingContinuation { continuation in
                credentialQueue.async { continuation.resume(with: Result { try work() }) }
            }
        }
        let claimed = unattendedReadInFlight.withLock { busy -> Bool in
            guard !busy else { return false }
            busy = true
            return true
        }
        guard claimed else { throw ClaudeCredentialError.readKeychain }
        return try await withCheckedThrowingContinuation { continuation in
            let request = Request<T>(continuation)
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                request.finish(.failure(ClaudeCredentialError.readKeychain))
            }
            DispatchQueue.global(qos: .userInitiated).async {
                let result = Result { try work() }
                unattendedReadInFlight.withLock { $0 = false }
                request.finish(result)
            }
        }
    }

    // Verified against Claude Code 2.1.314's embedded macOsKeychainHelpers and
    // plainTextStorage: NFC(raw env value), SHA-256 prefix, and USER validation.
    // https://code.claude.com/docs/en/env-vars documents CLAUDE_CONFIG_DIR.
    // Prefer the environment overload when the caller has a launch snapshot.
    // This compatibility entry point can only infer selectors from the login
    // environment; a path alone cannot distinguish an unset selector from an
    // explicit selector naming that same directory.
    nonisolated static func read(configDirectory: String, isDefault: Bool) throws -> Data? {
        var environment = LoginEnvironment.current
        if !isDefault {
            environment["CLAUDE_CONFIG_DIR"] = configDirectory
            environment["CLAUDE_SECURESTORAGE_CONFIG_DIR"] = configDirectory
        } else if environment["CLAUDE_SECURESTORAGE_CONFIG_DIR"] == nil {
            let configured = environment["CLAUDE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : $0 }
            let inferred = configured ?? defaultDirectory(environment: environment)
            guard URL(fileURLWithPath: inferred).standardizedFileURL.resolvingSymlinksInPath()
                == URL(fileURLWithPath: configDirectory).standardizedFileURL.resolvingSymlinksInPath()
            else { throw ClaudeCredentialError.invalidDirectory }
        }
        return try read(environment: environment, isManaged: !isDefault)
    }

    /// Pass the complete environment used to launch this Claude process,
    /// including HOME/USER and preserving absent versus empty selectors.
    /// Managed launches must set both selectors to the same absolute string.
    /// Keep USER aligned with LoginEnvironment.current for write/remove.
    nonisolated static func read(environment: [String: String], isManaged: Bool) throws -> Data? {
        try requireAccess()
        let directory: String
        let service: String
        if isManaged {
            guard let configured = environment["CLAUDE_CONFIG_DIR"], !configured.isEmpty,
                  environment["CLAUDE_SECURESTORAGE_CONFIG_DIR"] == configured else {
                throw ClaudeCredentialError.invalidDirectory
            }
            try requireManagedDirectory(configured, protecting: [:])
            directory = configured
            service = serviceName(configured)
        } else {
            let store = try defaultStore(environment: environment)
            directory = store.directory
            service = store.service
        }
        if let data = try readKeychain(service: service, account: username(environment: environment)) {
            return try validated(data)
        }
        guard let data = try readFile(directory: directory, name: ".credentials.json") else { return nil }
        return try validated(data)
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

    /// Background usage reads; never on the main actor and never longer than `timeout`.
    nonisolated static func readUnattended(environment: [String: String], isManaged: Bool, timeout: TimeInterval = 5) async throws -> Data? {
        try requireAccess()
        if isManaged {
            return try await offMain(timeout: timeout) { try read(environment: environment, isManaged: true) }
        }
        let store = try defaultStore(environment: environment)
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
        guard let data = try await offMain(timeout: timeout, { try readFile(directory: store.directory, name: ".credentials.json") }) else { return nil }
        return try validated(data)
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

    nonisolated static func write(_ data: Data, configDirectory: String) throws {
        try requireAccess()
        try requireManagedDirectory(configDirectory)
        _ = try validated(data)
        let query = keychainQuery(service: serviceName(configDirectory), account: username(environment: LoginEnvironment.current))
        let updated = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updated == errSecSuccess { return }
        guard updated == errSecItemNotFound else { throw ClaudeCredentialError.writeKeychain }
        var attributes = query
        attributes[kSecValueData as String] = data
        // Use the login Keychain, matching the CLI's security command, rather
        // than a data-protection Keychain item the CLI cannot discover.
        // Keep the default ACL: CLI access through /usr/bin/security may need
        // user approval. Do not grant all applications access to avoid a prompt.
        guard SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess else {
            throw ClaudeCredentialError.writeKeychain
        }
    }

    nonisolated static func remove(configDirectory: String) throws {
        try requireAccess()
        try requireManagedDirectory(configDirectory)
        // Remove a stale file first: a failed Keychain delete then leaves the
        // current credential intact instead of exposing an old file fallback.
        let fd = open(configDirectory, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if fd >= 0 {
            defer { close(fd) }
            if unlinkat(fd, ".credentials.json", 0) != 0, errno != ENOENT {
                throw ClaudeCredentialError.removeFile
            }
        } else if errno != ENOENT {
            throw ClaudeCredentialError.removeFile
        }
        let status = SecItemDelete(keychainQuery(service: serviceName(configDirectory), account: username(environment: LoginEnvironment.current)) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ClaudeCredentialError.removeKeychain
        }
    }

    // Claude Code 2.1.314 stores claude.ai OAuth and device trust separately from
    // MCP, design and cloud-session grants. Only this login crosses profiles.
    nonisolated static func sanitizedImport(_ data: Data) throws -> Data {
        _ = try validated(data)
        let source = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        var login: [String: Any] = ["claudeAiOauth": source["claudeAiOauth"]!]
        if let trust = source["trustedDeviceToken"] {
            guard trust is String || trust is NSNull else { throw ClaudeCredentialError.invalidCredential }
            login["trustedDeviceToken"] = trust
        }
        return try JSONSerialization.data(withJSONObject: login, options: [.sortedKeys])
    }

    struct Snapshot: Sendable {
        let keychain: Data?
        let file: Data?
        var credential: Data? { keychain ?? file }
    }

    nonisolated static func snapshot(configDirectory: String) throws -> Snapshot {
        try requireAccess()
        try requireManagedDirectory(configDirectory)
        return try Snapshot(
            keychain: readKeychain(service: serviceName(configDirectory), account: username(environment: LoginEnvironment.current)),
            file: readFile(directory: configDirectory, name: ".credentials.json"))
    }

    nonisolated static func restore(_ snapshot: Snapshot, configDirectory: String) throws {
        try requireAccess()
        try requireManagedDirectory(configDirectory)
        let query = keychainQuery(service: serviceName(configDirectory), account: username(environment: LoginEnvironment.current))
        if let data = snapshot.keychain {
            let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            if status == errSecItemNotFound {
                var attributes = query
                attributes[kSecValueData as String] = data
                guard SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess else { throw ClaudeCredentialError.writeKeychain }
            } else if status != errSecSuccess { throw ClaudeCredentialError.writeKeychain }
        } else {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw ClaudeCredentialError.removeKeychain }
        }
        let file = URL(fileURLWithPath: configDirectory).appendingPathComponent(".credentials.json")
        if let data = snapshot.file {
            let temporary = file.deletingLastPathComponent().appendingPathComponent(".credentials-" + UUID().uuidString + ".tmp")
            guard FileManager.default.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw ClaudeCredentialError.writeKeychain
            }
            defer { try? FileManager.default.removeItem(at: temporary) }
            try data.write(to: temporary)
            guard rename(temporary.path, file.path) == 0 else { throw ClaudeCredentialError.removeFile }
        } else {
            do { try FileManager.default.removeItem(at: file) }
            catch CocoaError.fileNoSuchFile { return }
        }
    }

    nonisolated static func replacingLogin(_ login: Data, in original: Data?) throws -> Data {
        let incoming = try JSONSerialization.jsonObject(with: sanitizedImport(login)) as! [String: Any]
        var root = try original.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        root["claudeAiOauth"] = incoming["claudeAiOauth"]
        root["trustedDeviceToken"] = incoming["trustedDeviceToken"]
        return try JSONSerialization.data(withJSONObject: root)
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
        // Keep the original bytes, including trustedDeviceToken and other CLI
        // fields; reconstructing only access/refresh tokens loses login state.
        return data
    }

    nonisolated static func readKeychain(service: String, account: String) throws -> Data? {
        try requireAccess()
        var query = keychainQuery(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        // Apple SecItem.h: only errSecItemNotFound means no matching item;
        // authorization/interaction failures must not select another store.
        guard status != errSecItemNotFound else { return nil }
        guard status == errSecSuccess, let data = value as? Data else {
            throw ClaudeCredentialError.readKeychain
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
