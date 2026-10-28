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
                        Text(verbatim: Chrome.localized("Features here are early versions and may be unstable. Turning Alpha off disables local control and remote MCP. Individual feature choices are kept."))
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
        ChromeSection(title: "Hydra") {
            ChromeCard {
                ChromeRow(title: "Decision model (Jev)", detail: "Shadow test: asks TypeSafe Jev to judge head reports and each job before its review, and keeps the judgments on this Mac beside what happened next. Hydra itself does not change. Sends the request, head reports, the lead's replies, review findings and changed file paths with line counts; never diffs or file contents, though the text can quote code. Off stops calls at once; on applies from the next request.") {
                    SettingsSwitch(isOn: $settings.alphaDecisionsEnabled)
                        .accessibilityLabel(Text("Decision model (Jev)"))
                }
                if settings.alphaDecisionsEnabled {
                    ChromeRowDivider()
                    TypeSafeKeyRow()
                    ChromeRowDivider()
                    DecisionLedgerRow()
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

private struct TypeSafeKeyRow: View {
    @State private var key = ""
    @State private var showsKey = false
    @State private var loaded = false
    @State private var storeError: String?

    var body: some View {
        ChromeRow(title: "TypeSafe API key", detail: storeError.map {
            String(format: Chrome.localized("The Keychain did not take the key: %@"), $0)
        } ?? "Stored in your Keychain for this edition. Get one at typesafe.ai.") {
            HStack(spacing: 8) {
                Group {
                    if showsKey {
                        TextField("", text: $key, prompt: Text("Paste your key"))
                    } else {
                        SecureField("", text: $key, prompt: Text("Paste your key"))
                    }
                }
                .textFieldStyle(.roundedBorder)
                .font(.ui(size: 12, design: .monospaced))
                .frame(width: 200)
                Button {
                    showsKey.toggle()
                } label: {
                    Image(systemName: showsKey ? "eye.slash" : "eye")
                        .font(.ui(size: 12))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Chrome.secondaryText)
                .help(Text(verbatim: Chrome.localized(showsKey ? "Hide the API key" : "Show the API key")))
                .accessibilityLabel(Text(verbatim: Chrome.localized(showsKey ? "Hide the API key" : "Show the API key")))
            }
            .disabled(!loaded)
        }
        .task {
            guard !loaded else { return }
            key = await Task.detached { TypeSafeAPI.readKey() ?? "" }.value
            loaded = true
        }
        .onChange(of: key) { _, newValue in
            guard loaded else { return }
            storeError = TypeSafeAPI.storeKey(newValue)
        }
    }
}

private struct DecisionLedgerRow: View {
    var body: some View {
        ChromeRow(title: "Decisions ledger", detail: "Every judgment and its outcome, kept on this Mac. Read it with scripts/hydra_eval.py decisions.") {
            Button {
                NSWorkspace.shared.open(DecisionLedger.directory)
            } label: {
                Text("Show in Finder").frame(height: Chrome.rowButtonLabelHeight)
            }
            .buttonStyle(.glass)
        }
    }
}
