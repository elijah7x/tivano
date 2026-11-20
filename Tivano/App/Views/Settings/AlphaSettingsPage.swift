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
                        Text("Labs")
                            .font(.ui(.title3, weight: .semibold))
                            .foregroundStyle(Chrome.primaryText)
                        Text(verbatim: Chrome.localized("Features here are early versions and may be unstable. Turning Labs off disables them. Individual feature choices are kept."))
                            .font(.ui(.subheadline))
                            .foregroundStyle(Chrome.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 12)
                    SettingsSwitch(isOn: $settings.alphaEnabled)
                        .accessibilityLabel(Text("Labs"))
                }
                .padding(.leading, 16)
                .padding(.trailing, Chrome.rowControlTrailingPadding)
                .padding(.vertical, 14)
            }
            if !settings.alphaEnabled {
                Text("Switch Labs on to try its features.")
                    .font(.ui(.subheadline))
                    .foregroundStyle(Chrome.secondaryText)
                    .padding(.horizontal, 4)
            }
        }
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
