import SwiftUI

struct TextGenerationModelRows: View {
    @Environment(AppModel.self) private var model

    @State private var isPresented = false

    private enum Mode: Hashable {
        case automatic, choose, off
    }

    private static let allowedProviders: [ProviderKind] = [.claude, .codex, .grok, .pi]

    private var mode: Mode {
        switch model.settings.textGeneration {
        case .automatic: .automatic
        case .claude, .codex, .grok, .pi: .choose
        case .off: .off
        }
    }

    private var detail: String {
        switch mode {
        case .automatic:
            String(format: Chrome.localized("Claude chats use %@; other chats use %@ at low effort. For thread titles, commit messages and composer predictions."),
                   model.fastTextModel(for: .claude)?.name ?? "Haiku",
                   model.fastTextModel(for: .codex)?.name ?? "Terra")
        case .choose:
            "Writes thread titles, commit messages and composer predictions. Fast, inexpensive models are usually enough."
        case .off:
            "No thread titles, commit messages or composer predictions are generated."
        }
    }

    var body: some View {
        let settings = model.settings
        let registry = model.providers
        let provider: ProviderKind? = switch settings.textGeneration {
        case .claude: .claude
        case .codex: .codex
        case .grok: .grok
        case .pi: .pi
        case .automatic, .off: nil
        }
        let selection = provider.map {
            NewThreadModelSelection(
                provider: $0,
                // Grok and Pi without a saved model run the CLI's default, so nothing in
                // the catalog shows as selected (see AppModel.textEngine).
                modelID: settings.textGenerationModelID
                    ?? ([.grok, .pi].contains($0) ? nil : model.fastTextModel(for: $0)?.id ?? registry.defaultModel(for: $0)?.id)
                    ?? "",
                effort: settings.textGenerationEffort
            )
        }
        let option = selection.flatMap { registry.model($0.modelID, for: $0.provider) }
        let effortTitle = settings.textGenerationEffort.flatMap { effort in
            option?.efforts.contains(effort) == true ? Chrome.localized(ModelOption.effortTitle(effort)) : nil
        }
        let fallbackModelName: (ProviderKind) -> String? = { provider in
            switch provider {
            case .claude: model.fastTextModel(for: .claude)?.shortName ?? "Haiku"
            case .codex: model.fastTextModel(for: .codex)?.shortName ?? "Terra"
            case .grok, .pi: Chrome.localized("Default")
            default: registry.defaultModel(for: provider)?.shortName
            }
        }
        let title = provider.map {
            [$0.displayName,
             option?.shortName
                ?? settings.textGenerationModelID.map { String(format: Chrome.localized("%@ (unavailable)"), $0) }
                ?? fallbackModelName($0),
             effortTitle].compactMap { $0 }.joined(separator: " · ")
        } ?? Chrome.localized(settings.textGeneration == .off ? "Off" : "Automatic")

        ChromeRow(title: "Model", detail: detail) {
            ModelChoiceButton(
                title: title,
                help: title,
                iconName: provider?.iconName,
                accessibilityLabel: "Model",
                isPresented: $isPresented
            ) {
                NewThreadModelPicker(
                    selection: selection,
                    selectedModelID: selection?.modelID,
                    initialProvider: provider ?? Self.allowedProviders.first { registry.availableProviders.contains($0) } ?? .claude,
                    automaticTitle: "Automatic",
                    allowedProviders: Self.allowedProviders,
                    offSelected: settings.textGeneration == .off,
                    selectOff: {
                        settings.textGeneration = .off
                        isPresented = false
                    }
                ) { selection in
                    if let selection {
                        let choice: TextGenerationChoice
                        switch selection.provider {
                        case .claude: choice = .claude
                        case .codex: choice = .codex
                        case .grok: choice = .grok
                        case .pi: choice = .pi
                        default: return
                        }
                        settings.textGeneration = choice
                        settings.textGenerationModelID = selection.modelID
                        settings.textGenerationEffort = selection.effort
                    } else {
                        settings.textGeneration = .automatic
                    }
                    if selection == nil { isPresented = false }
                }
            }
        }
    }
}
