import SwiftUI

struct TextGenerationModelRows: View {
    @Environment(AppModel.self) private var model

    @State private var isPresented = false

    private enum Mode: Hashable {
        case automatic, choose, off
    }

    private var mode: Mode {
        switch model.settings.textGeneration {
        case .automatic: .automatic
        case .claude, .codex: .choose
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
        case .automatic, .off: nil
        }
        let selection = provider.map {
            NewThreadModelSelection(
                provider: $0,
                modelID: settings.textGenerationModelID ?? model.fastTextModel(for: $0)?.id ?? "",
                effort: settings.textGenerationEffort
            )
        }
        let option = selection.flatMap { registry.model($0.modelID, for: $0.provider) }
        let effortTitle = settings.textGenerationEffort.flatMap { effort in
            option?.efforts.contains(effort) == true ? Chrome.localized(ModelOption.effortTitle(effort)) : nil
        }
        let title = provider.map {
            [$0.displayName,
             option?.shortName
                ?? settings.textGenerationModelID.map { String(format: Chrome.localized("%@ (unavailable)"), $0) }
                ?? model.fastTextModel(for: $0)?.shortName ?? ($0 == .claude ? "Haiku" : "Terra"),
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
                    initialProvider: provider ?? (registry.availableProviders.contains(.claude) ? .claude : .codex),
                    automaticTitle: "Automatic",
                    allowedProviders: [.claude, .codex],
                    offSelected: settings.textGeneration == .off,
                    selectOff: {
                        settings.textGeneration = .off
                        isPresented = false
                    }
                ) { selection in
                    if let selection {
                        settings.textGeneration = selection.provider == .claude ? .claude : .codex
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
