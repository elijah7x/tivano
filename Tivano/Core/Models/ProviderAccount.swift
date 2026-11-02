import Foundation

struct ProviderAccount: Codable, Identifiable, Equatable, Hashable, Sendable {
    var id: UUID
    var provider: ProviderKind
    /// Nil leaves the CLI's default home in use.
    var home: String?
    var name: String?
    var email: String?
    var plan: String?
    var accountID: String?
    var organizationID: String? = nil
    var organizationName: String? = nil
    var claudeIdentity: ClaudeAccountIdentity? = nil
    var claudeImportPending: Bool? = nil
    var claudeCleanupRequired: Bool? = nil
    var requiresClaudeActivation: Bool { provider == .claude && claudeImportPending == true }
    var requiresClaudeCleanup: Bool { provider == .claude && claudeCleanupRequired == true }
    var addedAt: Date
    var isDefault: Bool { home == nil }
}

struct ProviderAccountBook: Codable, Equatable, Sendable {
    var accounts: [ProviderAccount] = []
    var active: [String: UUID] = [:]
    var switchModes: [String: String] = [:]

    init() {}

    private enum CodingKeys: String, CodingKey { case accounts, active, switchModes }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accounts = ((try? container.decode([LenientAccount].self, forKey: .accounts)) ?? []).compactMap(\.account)
        active = (try? container.decode([String: UUID].self, forKey: .active)) ?? [:]
        switchModes = (try? container.decode([String: String].self, forKey: .switchModes)) ?? [:]
    }

    private struct LenientAccount: Decodable {
        let account: ProviderAccount?
        init(from decoder: Decoder) throws {
            account = try? ProviderAccount(from: decoder)
        }
    }
}

struct CodexIdentity: Equatable, Sendable {
    var email: String?
    var accountID: String?
    var userID: String?
    var plan: String?
}

/// Account and organization recorded by the CLI in an isolated login profile.
struct ClaudeAccountIdentity: Codable, Equatable, Hashable, Sendable {
    var accountID: String
    var organizationID: String
    var email: String

    func matches(_ other: Self) -> Bool {
        accountID == other.accountID && organizationID == other.organizationID
    }
}

enum ClaudeAccountValidationError: LocalizedError {
    case authentication, identityChanged, identityUnavailable, settingsConflict, verificationFailed

    nonisolated var errorDescription: String? {
        switch self {
        case .authentication: AppText.localized("Sign in with a Claude subscription account.")
        case .identityChanged: AppText.localized("The Claude account or organization changed. Restore the original login to continue this chat.")
        case .identityUnavailable: AppText.localized("Claude did not provide a verifiable account and organization identity. No message was sent.")
        case .settingsConflict: AppText.localized("Claude authentication settings conflict with this chat's account. Remove the API key, helper, or provider override before continuing.")
        case .verificationFailed: AppText.localized("Claude account identity could not be verified. Check your connection and sign-in, then try again. No message was sent.")
        }
    }
}
