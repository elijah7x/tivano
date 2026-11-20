import Foundation

/// A pair worth having, written as a recipe: which model leads at what effort and
/// which model builds at what effort. A recipe names models, not providers: each
/// side lists the providers that serve its model, and the first one set up on this
/// Mac whose catalog has the model is the one the pair runs on.
struct HydraPairRecipe: Identifiable, Sendable {
    enum Category: String, CaseIterable, Sendable {
        case hardest
        case everyday
        case fast

        var title: String {
            switch self {
            case .hardest: "For the hardest problems"
            case .everyday: "Everyday work"
            case .fast: "When speed and cost matter"
            }
        }
    }

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
    let category: Category
    let title: String
    let tagline: String
    let lead: Side
    let heads: Side
    let maxHeads: Int?
    let headsNote: String?

    init(
        id: String,
        category: Category,
        title: String,
        tagline: String,
        lead: Side,
        heads: Side,
        maxHeads: Int? = nil,
        headsNote: String? = nil
    ) {
        self.id = id
        self.category = category
        self.title = title
        self.tagline = tagline
        self.lead = lead
        self.heads = heads
        self.maxHeads = maxHeads
        self.headsNote = headsNote
    }
}

enum HydraCookbook {
    /// Durable pairs grouped by purpose; each resolves to the newest matching family member.
    static let recipes: [HydraPairRecipe] = [
        HydraPairRecipe(
            id: "claude-fable-opus",
            category: .hardest,
            title: "Fable leads Opus",
            tagline: "The strongest model plans and reviews, the all-rounder builds.",
            lead: .init(providers: [.claude, .commandcode], models: ["Fable"], effort: "high"),
            heads: .init(providers: [.claude, .commandcode], models: ["Opus"], effort: nil)
        ),
        HydraPairRecipe(
            id: "astra-sol",
            category: .hardest,
            title: "Astra leads Sol",
            tagline: "Astra plans and reviews; Sol handles the implementation.",
            lead: .init(providers: [.codex, .commandcode], models: ["Astra"], effort: "high"),
            heads: .init(providers: [.codex, .commandcode], models: ["Sol"], effort: "medium")
        ),
        HydraPairRecipe(
            id: "claude-opus-sonnet",
            category: .everyday,
            title: "Opus leads Sonnet",
            tagline: "Opus sets the plan, and Sonnet handles everyday coding.",
            lead: .init(providers: [.claude, .commandcode], models: ["Opus"], effort: "high"),
            heads: .init(providers: [.claude, .commandcode], models: ["Sonnet"], effort: "medium")
        ),
        HydraPairRecipe(
            id: "gemini-carbon-hydrogen",
            category: .everyday,
            title: "Gemini Carbon leads Hydrogen",
            tagline: "Carbon leads the design, and Hydrogen carries out the everyday work.",
            lead: .init(providers: [.antigravity, .commandcode], models: ["Carbon"], effort: "high"),
            heads: .init(providers: [.antigravity, .commandcode], models: ["Hydrogen"], effort: "medium")
        ),
        HydraPairRecipe(
            id: "claude-opus-gemini-flash",
            category: .fast,
            title: "Opus leads Flash",
            tagline: "Opus writes the briefs, and up to six Flash sub-agents run them in parallel.",
            lead: .init(providers: [.claude, .commandcode], models: ["Opus"], effort: "high"),
            heads: .init(providers: [.antigravity, .commandcode], models: ["Gemini Flash", "Flash"], effort: "medium"),
            maxHeads: 6,
            headsNote: "fast"
        ),
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
