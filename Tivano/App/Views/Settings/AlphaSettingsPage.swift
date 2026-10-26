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

/// Alpha: early features behind one master switch, each with a switch of its own. Each
/// feature is a section of its own, named for what it is, so another one is a section more.
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
                        Text(verbatim: Chrome.localized(settings.isHydra2Enabled
                            ? "Features here are early versions and may be unstable. Turning Alpha off ends the current voice call, disables local control and remote MCP, and returns new Hydra requests to the current Hydra. Individual feature choices are kept."
                            : "Features here are early versions and may be unstable. Turning Alpha off ends the current voice call and disables local control and remote MCP. Individual feature choices are kept."))
                            .font(.ui(.subheadline))
                            .foregroundStyle(Chrome.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 12)
                    SettingsSwitch(isOn: $settings.alphaEnabled)
                        .accessibilityLabel(Text("Alpha"))
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
        ChromeSection(title: "Realtime voice") {
            ChromeCard {
                ChromeRow(title: "Codex realtime voice", detail: "Talk with Codex out loud. Start a call from Start voice in the sidebar, or from the waveform button in any Codex chat to continue that chat by voice. Codex listens, answers and does the work in the chat. Needs Codex 0.159 or later, signed in with ChatGPT. Turning this off ends the current call.") {
                    SettingsSwitch(isOn: $settings.alphaVoiceEnabled)
                        .accessibilityLabel(Text("Codex realtime voice"))
                }
                if settings.alphaVoiceEnabled {
                    ChromeRowDivider()
                    VoiceStyleRow()
                }
            }
        }
        .modifier(AlphaGated(isOn: settings.alphaEnabled))
        // Switching voice off, either way, ends a call underway.
        .onChange(of: settings.isVoiceEnabled) { _, enabled in
            if !enabled { model.voice.end() }
        }
        ChromeSection(title: "Hydra") {
            ChromeCard {
                ChromeRow(title: "Hydra 2.0", detail: settings.isHydra2Enabled
                    ? "Every new request in a Hydra chat runs the new team design: the lead keeps judgement and does coupled work itself, heads get your request and the team's file split, report deviations and open points, can be sent back to rework their part, and another vendor's model may review the changes before the job settles and any automatic merge. Turning it off returns new requests to the current Hydra."
                    : "Every new request in a Hydra chat runs the new team design: the lead keeps judgement and does coupled work itself, heads get your request and the team's file split, report deviations and open points, can be sent back to rework their part, and another vendor's model reviews the changes before they merge. Turning it off returns new requests to the current Hydra.") {
                    SettingsSwitch(isOn: $settings.alphaHydra2Enabled)
                        .accessibilityLabel(Text("Hydra 2.0"))
                }
            }
        }
        .modifier(AlphaGated(isOn: settings.alphaEnabled))
        ChromeSection(title: "Local control") {
            ChromeCard {
                LocalControlSettingsRows()
            }
            .modifier(AlphaGated(isOn: settings.alphaEnabled))
            // The command can be installed or removed with Alpha off: installing it never
            // turns local control on.
            CLIInstallationSettings()
        }
        ChromeSection(title: "Remote MCP") {
            ChromeCard {
                RemoteMCPSettingsRows()
            }
        }
        .modifier(AlphaGated(isOn: settings.alphaEnabled))
    }
}

/// A feature's controls while Alpha is off: shown, dimmed and out of reach.
private struct AlphaGated: ViewModifier {
    let isOn: Bool

    func body(content: Content) -> some View {
        content
            .disabled(!isOn)
            .opacity(isOn ? 1 : 0.5)
            .animation(.smooth(duration: 0.2), value: isOn)
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
            .accessibilityLabel(Text("Codex voice style"))
        }
    }
}
