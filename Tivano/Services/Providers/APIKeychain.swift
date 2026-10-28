import Foundation
import Security

/// One Keychain implementation for every native provider's API key. The accounts
/// live in an edition-specific service, one item per provider.
enum APIKeychain {
    /// The stored key for a provider, or `fallback` when nothing is stored.
    /// A capture run reads nothing, so recorded sessions keep working without
    /// touching the user's real credentials.
    static func key(for provider: ProviderKind, fallback: String) -> String {
        guard let account = account(for: provider) else { return fallback }
        guard !CaptureRun.isEnabled else { return "" }
        if let keychain = read(account), !keychain.isEmpty { return keychain }
        return fallback
    }

    /// Stores the key, or removes it for an empty one. Returns whether the Keychain
    /// took it.
    @discardableResult
    static func setKey(_ key: String, for provider: ProviderKind) -> Bool {
        guard let account = account(for: provider) else { return false }
        return set(key, account: account)
    }

    /// Returns the system error description, or nil when the key was stored.
    static func store(_ key: String, for provider: ProviderKind) -> String? {
        let status: OSStatus
        if let account = account(for: provider) {
            status = setStatus(key, account: account)
        } else {
            status = errSecParam
        }
        guard status != errSecSuccess else { return nil }
        return SecCopyErrorMessageString(status, nil) as String? ?? String(status)
    }

    /// Returns the system error description, or nil when the key was stored.
    static func store(_ key: String, account: String) -> String? {
        let status = setStatus(key, account: account)
        guard status != errSecSuccess else { return nil }
        return SecCopyErrorMessageString(status, nil) as String? ?? String(status)
    }

    /// The accounts older builds stored keys under; changing one loses that key.
    private static func account(for provider: ProviderKind) -> String? {
        switch provider {
        case .deepseek: "DeepSeek API Key"
        case .meta: "Meta API Key"
        case .zai: "Z.ai API Key"
        case .commandcode: "Command Code API Key"
        default: nil
        }
    }

    /// Stores the value, or removes it for an empty one.
    @discardableResult
    static func set(_ key: String, account: String, service: String = AppInfo.libraryName) -> Bool {
        setStatus(key, account: account, service: service) == errSecSuccess
    }

    private static func setStatus(_ key: String, account: String, service: String = AppInfo.libraryName) -> OSStatus {
        guard !CaptureRun.isEnabled else { return errSecInteractionNotAllowed }
        let trimmed = key.trimmed
        let data = Data(trimmed.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if trimmed.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            return status == errSecItemNotFound ? errSecSuccess : status
        }
        let updated = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updated == errSecSuccess { return updated }
        guard updated == errSecItemNotFound else { return updated }
        let attributes = query.merging([
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
        ]) { _, new in new }
        return SecItemAdd(attributes as CFDictionary, nil)
    }

    enum ReadResult: Sendable {
        case missing
        case value(String)
        case invalid(Data)
        case unavailable(OSStatus)
    }

    static func read(_ account: String, service: String = AppInfo.libraryName) -> String? {
        guard case .value(let value) = readResult(account, service: service) else { return nil }
        return value.trimmed
    }

    /// Callers doing recovery must distinguish absence from a temporarily locked or
    /// denied item. The optional convenience reader above retains its existing API.
    static func readResult(_ account: String, service: String = AppInfo.libraryName) -> ReadResult {
        guard !CaptureRun.isEnabled else { return .unavailable(errSecInteractionNotAllowed) }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return .missing }
        guard status == errSecSuccess else { return .unavailable(status) }
        guard let data = item as? Data else { return .unavailable(errSecDecode) }
        guard let key = String(data: data, encoding: .utf8), !key.trimmed.isEmpty else { return .invalid(data) }
        // Preserve exact bytes for recovery callers; the optional key reader trims.
        return .value(key)
    }

    static func delete(_ account: String, service: String = AppInfo.libraryName) {
        guard !CaptureRun.isEnabled else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
