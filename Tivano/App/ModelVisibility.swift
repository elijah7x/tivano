import Foundation

/// What a model picker offers: the whole sorted catalogue, or the newest three of each
/// line while `hidesOutdatedModels` is on. A picker's own choice, the pins and the
/// choices settings still name stay whatever the trim would do, so a
/// row never vanishes under the model a thread or a pair runs on. Presentation only:
/// resolving a stored id remains `ProviderRegistry.model(_:for:)`'s job.
extension AppModel {
    /// The rows a picker lists for `provider`. `ids` protects extra rows: the picker's
    /// current choice, whose row the list must keep even when the trim drops it.
    @MainActor
    func pickerModels(for provider: ProviderKind, keeping ids: Set<String> = []) -> [ModelOption] {
        let sorted = providers.sortedModels(for: provider)
        guard settings.hidesOutdatedModels else { return sorted }
        let protected = protectedModelIDs(for: provider, plus: ids)
        let knownVersions = knownModelVersions()
        let key = PickerModelsCacheKey(
            provider: provider,
            ids: ids,
            protectedIDs: protected,
            hidesOutdatedModels: settings.hidesOutdatedModels,
            catalogueSignature: catalogueSignature(sorted),
            knownVersionsSignature: KnownVersionsCache.shared.signature
        )
        if let cached = PickerModelsCache.shared.value(for: key) { return cached }
        let result = ModelFamilies.simplified(sorted, knownVersions: knownVersions, protecting: { option in
            protected.contains(option.id) || option.variants.contains { protected.contains($0.id) }
        })
        PickerModelsCache.shared.store(result, for: key)
        return result
    }

    /// Every vendor's versions across all loaded catalogues, so Pi's Claude 4.6 counts as
    /// outdated when another provider lists Claude 5.5. Rebuilt only when a catalogue
    /// changes: pickers ask for every provider on each render.
    private func knownModelVersions() -> [String: Set<[Int]>] {
        let lists = ProviderKind.allCases.map { providers.models(for: $0) }
        let signature = lists.map { catalogueSignature($0) }.joined(separator: "\u{1}")
        if let cached = KnownVersionsCache.shared.value, KnownVersionsCache.shared.signature == signature { return cached }
        var merged: [String: Set<[Int]>] = [:]
        for list in lists {
            merged.merge(ModelFamilies.vendorVersions(list)) { $0.union($1) }
        }
        KnownVersionsCache.shared.signature = signature
        KnownVersionsCache.shared.value = merged
        return merged
    }

    private func catalogueSignature(_ models: [ModelOption]) -> String {
        "\(models.count)\u{0}\(models.map(\.id).joined(separator: "\u{0}"))"
    }

    /// The ids a trimmed picker keeps for `provider`: `ids` first, then the ones the
    /// settings and the open chats still name — the pins, the new-thread and recent
    /// choices, the provider's last model, and every pair's lead and heads (with their
    /// profiles', on the provider each runs on).
    private func protectedModelIDs(for provider: ProviderKind, plus ids: Set<String>) -> Set<String> {
        var protected = ids
        for pin in settings.modelList where pin.provider == provider {
            protected.insert(pin.modelID)
        }
        if let selection = settings.newThreadModelSelection, selection.provider == provider {
            protected.insert(selection.modelID)
        }
        if let pin = settings.lastNewChatModel, pin.provider == provider {
            protected.insert(pin.modelID)
        }
        if let last = settings.lastModel(for: provider) {
            protected.insert(last)
        }
        protectPairModels(settings.hydraPairs, for: provider, into: &protected)
        if let pair = settings.lastNewChatPair {
            protectPairModels([pair], for: provider, into: &protected)
        }
        // Not every thread's model: old chats would keep every outdated model in view.
        // The open chat's model comes in through `ids` from the composer.
        return protected
    }

    /// A pair protects its lead model on its own provider and its heads' on theirs; a
    /// head profile's model goes on the profile's provider, the pair's heads provider
    /// while the profile has none.
    private func protectPairModels(_ pairs: [HydraPair], for provider: ProviderKind, into protected: inout Set<String>) {
        for pair in pairs {
            if pair.provider == provider, let model = pair.orchestratorModel { protected.insert(model) }
            if pair.headsProvider == provider, let model = pair.workerModel { protected.insert(model) }
            for profile in pair.headProfiles where (profile.provider ?? pair.headsProvider) == provider {
                if let model = profile.model { protected.insert(model) }
            }
        }
    }
}

private struct PickerModelsCacheKey: Hashable {
    let provider: ProviderKind
    let ids: Set<String>
    let protectedIDs: Set<String>
    let hidesOutdatedModels: Bool
    let catalogueSignature: String
    let knownVersionsSignature: String
}

@MainActor
private final class PickerModelsCache {
    static let shared = PickerModelsCache()
    private static let limit = 48
    private var values: [PickerModelsCacheKey: [ModelOption]] = [:]
    private var order: [PickerModelsCacheKey] = []

    func value(for key: PickerModelsCacheKey) -> [ModelOption]? {
        values[key]
    }

    func store(_ value: [ModelOption], for key: PickerModelsCacheKey) {
        if values.updateValue(value, forKey: key) == nil {
            order.append(key)
        }
        if order.count > Self.limit {
            values.removeValue(forKey: order.removeFirst())
        }
    }
}

@MainActor
private final class KnownVersionsCache {
    static let shared = KnownVersionsCache()
    var signature = ""
    var value: [String: Set<[Int]>]?
}
