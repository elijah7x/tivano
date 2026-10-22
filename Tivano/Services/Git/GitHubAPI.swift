import Foundation

enum GitHubAPI {
    /// The "Tivano" OAuth App, device flow enabled and token expiry off (nothing here
    /// refreshes tokens). Public by design: device flow needs no client secret.
    static let clientID = "Ov23liVrgDWkR5x3gRn3"
    static let scopes = "repo read:org workflow"

    static func user(token: String) async throws -> GitHubUser {
        try await request(URL(string: "https://api.github.com/user")!, token: token)
    }

    static func startDeviceFlow() async throws -> GitHubDeviceCode {
        let response: DeviceResponse = try await request(
            URL(string: "https://github.com/login/device/code")!,
            form: ["client_id": clientID, "scope": scopes]
        )
        return GitHubDeviceCode(deviceCode: response.device_code, userCode: response.user_code,
                                verificationURI: response.verification_uri, expiresIn: response.expires_in,
                                interval: response.interval)
    }

    static func awaitDeviceToken(_ code: GitHubDeviceCode) async throws -> String {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(code.expiresIn))
        var interval = max(1, code.interval)
        while clock.now < deadline {
            let remaining = clock.now.duration(to: deadline)
            try await Task.sleep(for: min(.seconds(interval), remaining))
            guard clock.now < deadline else { throw GitHubError.expired }
            let response: TokenResponse = try await request(
                URL(string: "https://github.com/login/oauth/access_token")!,
                form: ["client_id": clientID, "device_code": code.deviceCode,
                       "grant_type": "urn:ietf:params:oauth:grant-type:device_code"]
            )
            guard clock.now < deadline else { throw GitHubError.expired }
            if let token = response.access_token, !token.isEmpty { return token }
            switch response.error {
            case "authorization_pending": continue
            case "slow_down": interval += 5
            case "expired_token": throw GitHubError.expired
            case "access_denied": throw GitHubError.denied
            default: throw GitHubError.invalidResponse
            }
        }
        throw GitHubError.expired
    }

    private struct DeviceResponse: Decodable {
        let device_code: String
        let user_code: String
        let verification_uri: URL
        let expires_in: Int
        let interval: Int
    }

    private struct TokenResponse: Decodable {
        let access_token: String?
        let error: String?
    }

    private struct ErrorResponse: Decodable {
        let message: String?
    }

    private static func request<Value: Decodable>(
        _ url: URL, token: String? = nil, form: [String: String]? = nil
    ) async throws -> Value {
        var request = URLRequest(url: url)
        request.setValue("Tivano", forHTTPHeaderField: "User-Agent")
        if url.host == "api.github.com" {
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
            if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        } else {
            request.setValue("application/json", forHTTPHeaderField: "Accept")
        }
        if let form {
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
            let body = form.sorted { $0.key < $1.key }.map { key, value in
                "\(key.addingPercentEncoding(withAllowedCharacters: allowed)!)=\(value.addingPercentEncoding(withAllowedCharacters: allowed)!)"
            }.joined(separator: "&")
            request.httpBody = Data(body.utf8)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw GitHubError.invalidResponse }
        switch response.statusCode {
        case 200..<300: break
        case 401: throw GitHubError.unauthorized
        case 404: throw GitHubError.notFound
        default:
            let message = (try? JSONDecoder().decode(ErrorResponse.self, from: data))?.message
                ?? String(decoding: data, as: UTF8.self)
            throw GitHubError.http(response.statusCode, message)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do { return try decoder.decode(Value.self, from: data) }
        catch { throw GitHubError.invalidResponse }
    }
}

enum GitHubCredentials {
    static let account = "GitHub Token"

    static func storedToken() -> String? {
        CaptureRun.isEnabled ? nil : APIKeychain.read(account)
    }

    @discardableResult
    static func store(_ token: String) -> Bool {
        APIKeychain.set(token, account: account)
    }

    static func remove() {
        APIKeychain.delete(account)
    }

    static func cliToken() async -> String? {
        guard !CaptureRun.isEnabled,
              let result = try? await Shell.run(tool: "gh", ["auth", "token", "--hostname", "github.com"],
                                               in: URL(fileURLWithPath: LoginEnvironment.homeDirectory), timeout: 8),
              result.succeeded, !result.trimmedOutput.isEmpty else { return nil }
        return result.trimmedOutput
    }

    /// Every process Tivano starts inherits this through LoginEnvironment,
    /// so agents can push and run gh with the connected account.
    static func environment(token: String) -> [String: String] {
        [
            "GH_TOKEN": token,
            "GIT_CONFIG_COUNT": "2",
            "GIT_CONFIG_KEY_0": "credential.https://github.com.helper",
            "GIT_CONFIG_VALUE_0": "",
            "GIT_CONFIG_KEY_1": "credential.https://github.com.helper",
            "GIT_CONFIG_VALUE_1": "!f() { test \"$1\" = get || return 0; echo username=x-access-token; echo \"password=$GH_TOKEN\"; }; f",
        ]
    }
}
