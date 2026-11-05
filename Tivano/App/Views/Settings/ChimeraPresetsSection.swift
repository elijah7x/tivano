import SwiftUI

struct ChimeraPresetsSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        let firstProvider = ProviderKind.alphabetical.first {
            settings.isEnabled($0) && model.providers.status($0).isInstalled
        }
        ChromeSection(title: "Model presets") {
            ChromeCard {
                ForEach($settings.chimeraPresets) { $preset in
                    ChromeRow(title: "Model") {
                        ChimeraPickPicker(pick: Binding(
                            get: { preset.pick },
                            set: { if let pick = $0 { preset.pick = pick } }
                        ))
                        TextField("Describe what this model is good at", text: $preset.specialty)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel(Text("Describe what this model is good at"))
                        Button {
                            withAnimation(Chrome.panelSlide) {
                                settings.chimeraPresets.removeAll { $0.id == preset.id }
                            }
                        } label: {
                            Image(systemName: "minus.circle")
                                .font(.ui(.callout, weight: .medium))
                                .foregroundStyle(Chrome.secondaryText)
                                .frame(width: 24, height: 24)
                                .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .help(Text(verbatim: Chrome.localized("Remove this preset")))
                        .accessibilityLabel(Text("Remove this preset"))
                    }
                    ChromeRowDivider()
                }
                ChromeRow(
                    title: settings.chimeraPresets.isEmpty ? "No presets yet" : "Add preset",
                    detail: settings.chimeraPresets.isEmpty ? "Add a model and describe what it is good at." : nil
                ) {
                    Button {
                        guard let provider = firstProvider else { return }
                        withAnimation(Chrome.panelSlide) {
                            settings.chimeraPresets.append(ChimeraPreset(
                                specialty: "", pick: ChimeraPick(provider: provider, model: model.providers.defaultModel(for: provider)?.id, effort: nil)
                            ))
                        }
                    } label: {
                        Label("Add preset", systemImage: "plus")
                    }
                    .buttonStyle(.glass)
                    .disabled(firstProvider == nil)
                }
            }
            Text("Describe what each model is good at. In a real conversation Chimera reads these to match helpers with models and pre-fills the casting card, so you rarely pick by hand. Nothing runs until you confirm.")
                .font(.ui(.subheadline))
                .foregroundStyle(Chrome.secondaryText)
                .padding(.horizontal, 4)
        }
    }
}
