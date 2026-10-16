import SwiftUI

/// The flask that marks Alpha: a template that takes whatever colour it is given.
struct AlphaMarkImage: View {
    var body: some View {
        Image("alpha-mark")
            .resizable()
            .renderingMode(.template)
            .aspectRatio(contentMode: .fit)
    }
}

/// Alpha: early features behind one master switch, each with a switch of its own.
struct AlphaSettingsPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        VStack(alignment: .leading, spacing: Chrome.sectionHeaderSpacing) {
            ChromeCard {
                HStack(spacing: 14) {
                    AlphaMarkImage()
                        .frame(width: 26, height: 26)
                        .foregroundStyle(SettingsPage.alpha.tint)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Alpha")
                            .font(.ui(.title3, weight: .semibold))
                            .foregroundStyle(Chrome.primaryText)
                        Text("Features here are early versions and may be unstable. Turn them on with care.")
                            .font(.ui(.subheadline))
                            .foregroundStyle(Chrome.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 12)
                    SettingsSwitch(isOn: $settings.alphaEnabled)
                }
                .padding(.leading, 16)
                .padding(.trailing, Chrome.rowControlTrailingPadding)
                .padding(.vertical, 14)
            }
            if !settings.alphaEnabled {
                Text("Switch Alpha on to try its features.")
                    .font(.ui(.subheadline))
                    .foregroundStyle(Chrome.secondaryText)
                    .padding(.horizontal, 4)
            }
        }
        ChromeSection(title: "Features") {
            ChromeCard {
                ChromeRow(title: "Codex realtime voice", detail: "Talk with Codex out loud. Start a call from Start voice in the sidebar, or from the waveform button in any Codex chat to continue that chat by voice. Codex listens, answers and does the work in the chat. Needs Codex 0.159 or later, signed in with ChatGPT.") {
                    SettingsSwitch(isOn: $settings.alphaVoiceEnabled)
                }
                if settings.alphaVoiceEnabled {
                    ChromeRowDivider()
                    VoiceStyleRow()
                }
            }
        }
        .disabled(!settings.alphaEnabled)
        .opacity(settings.alphaEnabled ? 1 : 0.5)
        .animation(.smooth(duration: 0.2), value: settings.alphaEnabled)
        // Switching voice off, either way, ends a call underway.
        .onChange(of: settings.isVoiceEnabled) { _, enabled in
            if !enabled { model.voice.end() }
        }
    }
}

private struct VoiceStyleRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        var options = model.voice.voices
        if let saved = settings.codexVoice, !options.contains(saved) { options.append(saved) }
        return ChromeRow(title: "Codex voice style", detail: "Applies to your next voice session") {
            GlassPickerButton(
                options: [(String?.none, "Codex default")] + options.map { (String?.some($0), VoiceCatalog.label($0)) },
                selection: $settings.codexVoice
            )
        }
    }
}
