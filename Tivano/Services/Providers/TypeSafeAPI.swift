import Foundation

/// The official endpoint used by Hydra's shadow decisions.
enum TypeSafeAPI {
    static let endpoint = URL(string: "https://api.typesafe.ai/v1/systemone")!
    static let model = "jev-latest"
    static let keyAccount = "TypeSafe API Key"
    static let keyPage = URL(string: "https://typesafe.ai")!

    static func readKey() -> String? {
        guard let key = APIKeychain.read(keyAccount), !key.isEmpty else { return nil }
        return key
    }

    static func storeKey(_ key: String) -> String? {
        APIKeychain.store(key, account: keyAccount)
    }

    struct Evaluation: Sendable {
        var answers: JSONValue
        var model: String?
        var inputTokens: Int?
        var outputTokens: Int?
    }

    enum Failure: String, Error, Sendable {
        case missingKey = "missing_key"
        case authRejected = "auth_rejected"
        case invalidRequest = "invalid_request"
        case rateLimited = "rate_limited"
        case timeout
        case network = "network_error"
        case provider = "provider_error"
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 8
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    static func evaluate(state: JSONValue, questions: [String: JSONValue], key: String) async -> Result<Evaluation, Failure> {
        guard !key.trimmed.isEmpty else { return .failure(.missingKey) }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Tivano", forHTTPHeaderField: "User-Agent")
        request.httpBody = JSONValue.object([
            "model": .string(model), "state": state, "questions": .object(questions),
        ]).data()
        do {
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else { return .failure(.provider) }
            switch response.statusCode {
            case 200..<300: break
            case 401, 403: return .failure(.authRejected)
            case 422: return .failure(.invalidRequest)
            case 429: return .failure(.rateLimited)
            case 408: return .failure(.timeout)
            default: return .failure(.provider)
            }
            guard let body = JSONValue.parse(data), let answers = body["answers"],
                  let values = answers.object,
                  values.values.allSatisfy({ $0.object != nil && $0["type"]?.string != nil }) else {
                return .failure(.provider)
            }
            return .success(Evaluation(
                answers: answers, model: body["model"]?.string,
                inputTokens: body["usage"]?["input_tokens"]?.int,
                outputTokens: body["usage"]?["output_tokens"]?.int
            ))
        } catch let error as URLError {
            return .failure(error.code == .timedOut ? .timeout : .network)
        } catch {
            return .failure(.network)
        }
    }
}
