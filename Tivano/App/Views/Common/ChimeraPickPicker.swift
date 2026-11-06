import SwiftUI

struct ChimeraPickPicker: View {
    @Environment(AppModel.self) private var model
    @Binding private var pick: ChimeraPick?
    /// Off where the icon alone names the provider and room is short (the casting card).
    private let showsProvider: Bool
    private let width: CGFloat?
    @State private var isPresented = false

    init(pick: Binding<ChimeraPick?>, showsProvider: Bool = true, width: CGFloat? = nil) {
        _pick = pick
        self.showsProvider = showsProvider
        self.width = width
    }

    var body: some View {
        let registry = model.providers
        let providers = ProviderKind.alphabetical.filter {
            model.settings.isEnabled($0) && registry.status($0).isInstalled
        }
        let option = pick.flatMap { pick in
            let known = pick.model.flatMap { registry.model($0, for: pick.provider) }
            return pick.model == nil ? registry.defaultModel(for: pick.provider) : known
        }
        let selection = pick.map {
            NewThreadModelSelection(provider: $0.provider, modelID: $0.model ?? option?.id ?? "", effort: $0.effort)
        }
        let effortTitle = option.flatMap { option in
            option.efforts.isEmpty ? nil : Chrome.localized(ModelOption.effortTitle(
                pick?.effort.flatMap { option.efforts.contains($0) ? $0 : nil } ?? option.defaultEffort ?? ""
            ))
        }
        let title = pick.map {
            [showsProvider ? $0.provider.displayName : nil, option?.shortName ?? $0.model ?? Chrome.localized("Default model"), effortTitle]
                .compactMap { $0 }.joined(separator: " · ")
        } ?? Chrome.localized("Choose a model")
        let available = pick.map { model.chimeraCanRun($0) } ?? true
        let displayedTitle = available ? title : String(format: Chrome.localized("%@ (unavailable)"), title)
        ModelChoiceButton(
            title: displayedTitle,
            help: displayedTitle,
            iconName: pick?.provider.iconName,
            accessibilityLabel: "Model",
            width: width,
            isPresented: $isPresented
        ) {
            NewThreadModelPicker(
                selection: selection,
                selectedModelID: selection?.modelID,
                initialProvider: pick?.provider ?? providers.first,
                showsAutomaticChoice: false,
                allowedProviders: providers
            ) { selection in
                pick = selection.map { ChimeraPick(provider: $0.provider, model: $0.modelID, effort: $0.effort) }
            }
        }
        .disabled(providers.isEmpty)
        .task(id: pick?.provider) {
            if let provider = pick?.provider { await registry.loadCatalog(provider) }
        }
    }
}
