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
    /// took it, so the caller knows whether a fallback copy is still needed.
    @discardableResult
    static func setKey(_ key: String, for provider: ProviderKind) -> Bool {
        guard let account = account(for: provider) else { return false }
        return set(key, account: account)
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
        guard !CaptureRun.isEnabled else { return false }
        let trimmed = key.trimmed
        if trimmed.isEmpty {
            delete(account, service: service)
            return true
        }
        let data = Data(trimmed.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let updated = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updated == errSecSuccess { return true }
        guard updated == errSecItemNotFound else { return false }
        let attributes = query.merging([
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
        ]) { _, new in new }
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    static func read(_ account: String, service: String = AppInfo.libraryName) -> String? {
        guard !CaptureRun.isEnabled else { return nil }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let key = String(data: data, encoding: .utf8),
              !key.trimmed.isEmpty else { return nil }
        return key.trimmed
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
