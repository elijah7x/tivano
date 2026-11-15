import Foundation

/// Minimal OpenAI-compatible HTTP client for api.meta.ai.
/// Chat streaming itself lives in MetaSession; this covers the
/// lightweight calls (key validation, model catalog) the registry needs.
///
/// Reference: https://dev.meta.ai/docs/api-reference/
/// Base URL `https://api.meta.ai/v1`, bearer auth with `MODEL_API_KEY`.
/// Endpoints used here:
/// - `GET /v1/models` — list available models (also validates the key)
/// - `POST /v1/chat/completions` — OpenAI-compatible messages-array endpoint (see MetaSession)
/// The Responses API (`POST /v1/responses`) carries reasoning across turns via
/// encrypted replay, but Chat Completions keeps the agent loop OpenAI-compatible
/// and matches the rest of Tivano's native providers.
enum MetaAPI {
    static let baseURL = URL(string: "https://api.meta.ai/v1")!
    static let chatURL = URL(string: "https://api.meta.ai/v1/chat/completions")!
    static let modelsURL = URL(string: "https://api.meta.ai/v1/models")!

    /// Muse Spark context window per https://dev.meta.ai/docs/models
    static let contextWindow = 1_048_576
    static let maxOutputTokens = 131_072

    /// True when the key lists models successfully.
    static func validate(apiKey: String) async -> Bool {
        await OpenAICompatibleAPI.validate(modelsURL: modelsURL, key: apiKey)
    }

    static func listModels(apiKey: String) async throws -> [ModelOption] {
        try await OpenAICompatibleAPI.listModels(modelsURL: modelsURL, key: apiKey, option: Self.option(for:))
    }

    /// Probed live 2026-09-13: among Spark models only `muse-spark-1.3` accepts "max"
    /// (other Spark checkpoints, including `muse-spark-1.3-contributor`, reject it with
    /// a bare "The request contains invalid parameters" 400). Wonder and Ember models
    /// also support and default to "max".
    static let maxEfforts = ["minimal", "low", "medium", "high", "xhigh", "max"]
    static let standardEfforts = ["minimal", "low", "medium", "high", "xhigh"]

    private static let chatModelPrefixes = ["muse-spark", "muse-wonder", "muse-ember"]

    private static func hasChatPrefix(_ id: String) -> Bool {
        let lower = id.lowercased()
        return chatModelPrefixes.contains { lower.hasPrefix($0) }
    }

    private static func supportsMaxEffort(_ id: String) -> Bool {
        let lower = id.lowercased()
        return lower == "muse-spark-1.3" || lower.hasPrefix("muse-wonder") || lower.hasPrefix("muse-ember")
    }

    static func efforts(for id: String) -> [String] {
        supportsMaxEffort(id) ? maxEfforts : standardEfforts
    }

    static func option(for id: String) -> ModelOption? {
        let efforts = efforts(for: id)
        switch id {
        case "muse-spark-1.3":
            return ModelOption(id: id, name: "Spark 1.3", detail: "Latest Muse Spark · best agentic coding · 1M context", efforts: efforts, defaultEffort: "high", isDefault: true)
        case "muse-spark-1.3-contributor":
            return ModelOption(id: id, name: "Spark 1.3 Contributor", detail: "Cheaper 1.3 · Meta may train on your chats · no max effort", efforts: efforts, defaultEffort: "high")
        case "muse-spark-1.2":
            return ModelOption(id: id, name: "Spark 1.2", detail: "Previous checkpoint · Standard tier · 1M context", efforts: efforts, defaultEffort: "high")
        case "muse-spark-1.2-contributor":
            return ModelOption(id: id, name: "Spark 1.2 Contributor", detail: "Cheaper 1.2 · Meta may train on your chats", efforts: efforts, defaultEffort: "high")
        case "muse-spark-1.1":
            return ModelOption(id: id, name: "Spark 1.1", detail: "Original checkpoint · Standard tier · 1M context", efforts: efforts, defaultEffort: "high")
        case "muse-wonder-1.0":
            return ModelOption(id: id, name: "Muse Wonder 1.0", detail: "Muse Wonder · max effort default", efforts: efforts, defaultEffort: "max")
        case "muse-ember-1.0":
            return ModelOption(id: id, name: "Muse Ember 1.0", detail: "Muse Ember · max effort default · 524,288 max output", efforts: efforts, defaultEffort: "max")
        default:
            // Future Muse Spark, Wonder, and Ember checkpoints still show up. The endpoint
            // also lists non-chat models (muse-image-1.0, muse-voice-transcribe-1.0) that
            // fail on chat/completions, so only those chat prefixes are accepted.
            guard hasChatPrefix(id) else { return nil }
            let defaultEffort = id.lowercased().hasPrefix("muse-spark") ? "high" : "max"
            return ModelOption(id: id, name: id, efforts: efforts, defaultEffort: defaultEffort)
        }
    }

    /// All Muse Spark, Wonder, and Ember models are multimodal (text, image, video, audio, PDF in).
    static func isVisionModel(_ id: String?) -> Bool {
        guard let id, !id.isEmpty else { return true }
        return hasChatPrefix(id)
    }
}
