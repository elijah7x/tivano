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
