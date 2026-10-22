import Foundation

struct GitHubUser: Codable, Equatable, Sendable {
    let id: Int
    let login: String
    let name: String?
    let avatarURL: URL?

    private enum CodingKeys: String, CodingKey {
        case id, login, name
        case avatarURL = "avatar_url"
    }
}

struct GitHubDeviceCode: Equatable, Sendable {
    let deviceCode: String
    let userCode: String
    let verificationURI: URL
    let expiresIn: Int
    let interval: Int
}

enum GitHubTokenSource: String, Codable, Sendable {
    case tivano, githubCLI
}

enum GitHubError: LocalizedError, Equatable {
    case unauthorized, denied, expired, notFound
    case http(Int, String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .unauthorized: AppText.localized("GitHub did not accept the sign-in.")
        case .denied: AppText.localized("The sign-in was cancelled on GitHub.")
        case .expired: AppText.localized("The code expired. Try again.")
        case .notFound: AppText.localized("That repository was not found, or your account cannot see it.")
        case let .http(code, message): String(format: AppText.localized("GitHub answered %lld: %@"), code, message)
        case .invalidResponse: AppText.localized("GitHub sent an answer Tivano could not read.")
        }
    }
}
