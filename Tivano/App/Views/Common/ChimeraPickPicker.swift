import SwiftUI

struct ChimeraPickPicker: View {
    @Environment(AppModel.self) private var model
    @Binding private var pick: ChimeraPick?
    /// Off by default: the icon names the provider, so the button shows the model itself.
    private let showsProvider: Bool
    private let width: CGFloat?
    /// Off where a concrete model is required (the casting card).
    private let allowsFollowLead: Bool
    @State private var isPresented = false

    init(pick: Binding<ChimeraPick?>, showsProvider: Bool = false, width: CGFloat? = nil, allowsFollowLead: Bool = true) {
        self.allowsFollowLead = allowsFollowLead
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
        } ?? Chrome.localized("Follow the lead")
        let available = pick.map { model.chimeraCanRun($0) } ?? true
        let displayedTitle = available ? title : String(format: Chrome.localized("%@ (unavailable)"), title)
        let helpTitle = showsProvider ? displayedTitle : (pick.map { "\($0.provider.displayName) · \(displayedTitle)" } ?? displayedTitle)
        ModelChoiceButton(
            title: displayedTitle,
            help: helpTitle,
            iconName: pick?.provider.iconName,
            accessibilityLabel: "Model",
            width: width,
            isPresented: $isPresented
        ) {
            NewThreadModelPicker(
                selection: selection,
                selectedModelID: selection?.modelID,
                initialProvider: pick?.provider ?? providers.first,
                automaticTitle: "Follow the lead",
                showsAutomaticChoice: allowsFollowLead,
                allowedProviders: providers
            ) { selection in
                if let selection {
                    pick = ChimeraPick(provider: selection.provider, model: selection.modelID, effort: selection.effort)
                } else {
                    pick = nil
                    isPresented = false
                }
            }
        }
        .task(id: pick?.provider) {
            if let provider = pick?.provider { await registry.loadCatalog(provider) }
        }
    }
}
