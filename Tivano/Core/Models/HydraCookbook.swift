import Foundation

/// A pair worth having, written as a recipe: which model leads at what effort and
/// which model builds at what effort. A recipe names models, not providers: each
/// side lists the providers that serve its model, and the first one set up on this
/// Mac whose catalog has the model is the one the pair runs on.
struct HydraPairRecipe: Identifiable, Sendable {
    struct Side: Sendable {
        /// Providers that serve this side's model, best first: the model's own house
        /// ahead of aggregators, so a lead on Claude's own CLI wins over one relayed.
        let providers: [ProviderKind]
        /// Names to look for in the provider's catalog, best first; a recipe whose
        /// names find nothing is not offered.
        let models: [String]
        /// The effort asked for, kept only when the model found offers it.
        let effort: String?
    }

    let id: String
    let title: String
    let tagline: String
    let lead: Side
    let heads: Side
    let maxHeads: Int?
    let headsNote: String?

    init(id: String, title: String, tagline: String, lead: Side, heads: Side, maxHeads: Int?, headsNote: String? = nil) {
        self.id = id
        self.title = title
        self.tagline = tagline
        self.lead = lead
        self.heads = heads
        self.maxHeads = maxHeads
        self.headsNote = headsNote
    }
}

enum HydraCookbook {
    /// The best pairs, strongest first: cross-model pairs, then one model at two efforts.
    static let recipes: [HydraPairRecipe] = [
        HydraPairRecipe(id: "claude-fable-opus", title: "Fable 5.1 leads Opus 5.5", tagline: "The deepest lead over the strongest builders: Fable plans and checks, Opus heads build. Set the thinking effort of each side yourself.", lead: .init(providers: [.claude, .commandcode], models: ["Fable"], effort: nil), heads: .init(providers: [.claude, .commandcode], models: ["Opus"], effort: nil), maxHeads: nil),
        HydraPairRecipe(id: "claude-opus-gemini-flash", title: "Opus 5.5 leads Gemini 3.8 Flash", tagline: "A careful lead and a wide, fast team: Opus writes the briefs, six Gemini Flash heads sprint through them.", lead: .init(providers: [.claude, .commandcode], models: ["Opus"], effort: "high"), heads: .init(providers: [.antigravity, .commandcode], models: ["Gemini 3.8 Flash", "Gemini", "Flash"], effort: "medium"), maxHeads: 6, headsNote: "fast, for parallel and mechanical work"),
        HydraPairRecipe(id: "claude-opus-deepseek", title: "Opus 5.5 leads DeepSeek V4.1", tagline: "Opus keeps the plan tight; DeepSeek V4.1 Flash heads keep the bill small on the routine parts.", lead: .init(providers: [.claude, .commandcode], models: ["Opus"], effort: "high"), heads: .init(providers: [.deepseek, .commandcode], models: ["V4.1 Flash", "V4.1", "DeepSeek"], effort: "high"), maxHeads: nil, headsNote: "low-cost routine work"),
        HydraPairRecipe(id: "claude-opus-glm", title: "Opus 5.5 leads GLM-5.3 Flash", tagline: "Opus keeps the plan tight; GLM-5.3 Flash heads on a Z.ai Coding Plan keep the bill flat.", lead: .init(providers: [.claude, .commandcode], models: ["Opus"], effort: "high"), heads: .init(providers: [.zai, .commandcode], models: ["5.3 Flash", "GLM"], effort: "high"), maxHeads: nil, headsNote: "low-cost routine work"),
        HydraPairRecipe(id: "claude-fable-composer", title: "Fable 5.1 leads Composer 2.5", tagline: "Fable thinks; Cursor's Composer heads type at the speed Composer is known for.", lead: .init(providers: [.claude, .commandcode], models: ["Fable"], effort: "high"), heads: .init(providers: [.cursor], models: ["Composer"], effort: nil), maxHeads: nil, headsNote: "fast mechanical edits"),
        HydraPairRecipe(id: "astra-spark", title: "Astra 6 leads Spark 1.3 Contributor", tagline: "GPT-6 Astra orchestrates at high; Muse Spark Contributor heads build at medium.", lead: .init(providers: [.codex, .commandcode], models: ["Astra"], effort: "high"), heads: .init(providers: [.meta, .commandcode], models: ["Contributor"], effort: "medium"), maxHeads: nil),
        HydraPairRecipe(id: "astra-terra", title: "Astra 6 leads Terra 5.6", tagline: "OpenAI top to bottom: Astra plans and reviews, Terra does the work at medium.", lead: .init(providers: [.codex, .commandcode], models: ["Astra"], effort: "high"), heads: .init(providers: [.codex, .commandcode], models: ["Terra"], effort: "medium"), maxHeads: nil),
        HydraPairRecipe(id: "astra-sol", title: "Astra 6 leads Sol 5.6", tagline: "Astra plans and reviews; Sol heads take the complex building at medium.", lead: .init(providers: [.codex, .commandcode], models: ["Astra"], effort: "high"), heads: .init(providers: [.codex, .commandcode], models: ["Sol"], effort: "medium"), maxHeads: nil, headsNote: "complex implementation"),
        HydraPairRecipe(id: "sol-luna", title: "Sol 5.6 leads Luna 5.6", tagline: "Sol keeps the plan; quick Luna heads get through the routine parts.", lead: .init(providers: [.codex, .commandcode], models: ["Sol"], effort: "high"), heads: .init(providers: [.codex, .commandcode], models: ["Luna"], effort: "medium"), maxHeads: nil, headsNote: "quick routine work"),
        HydraPairRecipe(id: "astra-astra", title: "Astra 6 high, Astra 6 medium", tagline: "One model, two efforts: Astra thinks hard about the plan and the review, and Astra heads build at a working effort.", lead: .init(providers: [.codex, .commandcode], models: ["Astra"], effort: "high"), heads: .init(providers: [.codex, .commandcode], models: ["Astra"], effort: "medium"), maxHeads: nil),
        HydraPairRecipe(id: "claude-opus-opus", title: "Opus 5.5 max, Opus 5.5 medium", tagline: "Opus thinks as hard as it can where it counts; Opus heads at medium do the building.", lead: .init(providers: [.claude, .commandcode], models: ["Opus"], effort: "max"), heads: .init(providers: [.claude, .commandcode], models: ["Opus"], effort: "medium"), maxHeads: nil),
        HydraPairRecipe(id: "claude-fable-fable", title: "Fable 5.1 high, Fable 5.1 medium", tagline: "For the hardest, longest jobs: every seat on the most capable model, the lead at high and the heads at medium.", lead: .init(providers: [.claude, .commandcode], models: ["Fable"], effort: "high"), heads: .init(providers: [.claude, .commandcode], models: ["Fable"], effort: "medium"), maxHeads: nil),
    ]

    /// The effort asked for when the model offers it; nil otherwise, which keeps the default.
    static func effort(_ wanted: String?, for option: ModelOption?) -> String? {
        guard let wanted, let option, option.efforts.contains(wanted) else { return nil }
        return wanted
    }

    /// Whether a pair like this one is already set up: the same providers and models.
    static func isAdded(_ pair: HydraPair, in pairs: [HydraPair]) -> Bool {
        pairs.contains { $0.provider == pair.provider && $0.headsProvider == pair.headsProvider && $0.orchestratorModel == pair.orchestratorModel && $0.workerModel == pair.workerModel }
    }
}
