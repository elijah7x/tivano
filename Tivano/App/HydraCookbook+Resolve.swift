import Foundation

/// A recipe on this Mac: whether its providers are ready and which catalog models it
/// resolves to. This needs the provider registry and the settings, which live in the
/// app layer, so it sits apart from the recipes themselves.
extension HydraCookbook {
    /// Whether a provider is set up and switched on here.
    @MainActor static func isReady(_ provider: ProviderKind, registry: ProviderRegistry, settings: AppSettings) -> Bool {
        settings.isEnabled(provider) && registry.status(provider).isInstalled
    }

    /// The provider a side runs on here: the first of its providers that is ready and
    /// lists the model, or nil while none does.
    @MainActor static func provider(for side: HydraPairRecipe.Side, registry: ProviderRegistry, settings: AppSettings) -> ProviderKind? {
        side.providers.first { provider in
            isReady(provider, registry: registry, settings: settings)
                && (side.models.isEmpty || model(named: side.models, for: provider, registry: registry) != nil)
        }
    }

    /// The provider a recipe still needs, if none of a side's providers is ready: the
    /// side's first choice, as the one to set up.
    @MainActor static func missingProvider(for recipe: HydraPairRecipe, registry: ProviderRegistry, settings: AppSettings) -> ProviderKind? {
        for side in [recipe.lead, recipe.heads] where !side.providers.contains(where: { isReady($0, registry: registry, settings: settings) }) {
            return side.providers.first
        }
        return nil
    }

    /// The pair a recipe makes on this Mac, or nil while a side has no ready provider
    /// that lists its model.
    @MainActor static func resolve(_ recipe: HydraPairRecipe, registry: ProviderRegistry, settings: AppSettings) -> HydraPair? {
        guard let leadProvider = provider(for: recipe.lead, registry: registry, settings: settings),
              let headsProvider = provider(for: recipe.heads, registry: registry, settings: settings) else { return nil }
        var pair = HydraPair(provider: leadProvider)
        let lead = model(named: recipe.lead.models, for: leadProvider, registry: registry)
        pair.orchestratorModel = lead?.id
        pair.orchestratorEffort = effort(recipe.lead.effort, for: lead ?? registry.defaultModel(for: leadProvider))
        if headsProvider != leadProvider { pair.workerProvider = headsProvider }
        let heads = model(named: recipe.heads.models, for: headsProvider, registry: registry)
        pair.workerModel = heads?.id
        pair.workerEffort = effort(recipe.heads.effort, for: heads ?? registry.defaultModel(for: headsProvider))
        pair.maxHeads = recipe.maxHeads
        pair.headsNote = recipe.headsNote
        return pair
    }

    /// A fragment names a family; the newest member the catalog lists wins, so a new
    /// release moves a recipe up on its own.
    @MainActor static func model(named names: [String], for provider: ProviderKind, registry: ProviderRegistry) -> ModelOption? {
        let options = registry.models(for: provider)
        for name in names {
            let matches = options.filter { $0.name.localizedCaseInsensitiveContains(name) || $0.id.localizedCaseInsensitiveContains(name) }
            guard !matches.isEmpty else { continue }
            return matches.max { lhs, rhs in
                let lhsVersion = version(of: lhs.name) ?? -1
                let rhsVersion = version(of: rhs.name) ?? -1
                if lhsVersion != rhsVersion { return lhsVersion < rhsVersion }
                return options.firstIndex(where: { $0.id == lhs.id })! > options.firstIndex(where: { $0.id == rhs.id })!
            }
        }
        return nil
    }

    /// The first version number in a catalog name ('Gemini 3.8 Flash' → 3.8), if any.
    private static func version(of name: String) -> Double? {
        guard let match = name.firstMatch(of: #/[0-9]+(?:\.[0-9]+)?/#) else { return nil }
        return Double(match.output)
    }
}
