import SwiftUI

/// Sets up the model presets Chimera uses when casting roles in a conversation.
struct ChimeraSettingsPage: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Chrome.sectionHeaderSpacing) {
            ChromeCard {
                HStack(spacing: 14) {
                    ChimeraMarkImage()
                        .frame(width: 26, height: 26)
                        .foregroundStyle(Chrome.primaryText)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Chimera")
                            .font(.ui(.title3, weight: .semibold))
                            .foregroundStyle(Chrome.primaryText)
                        Text(verbatim: Chrome.localized("The lead assigns roles mid-conversation. You pick the model for each role before it starts."))
                            .font(.ui(.subheadline))
                            .foregroundStyle(Chrome.secondaryText)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 12)
                }
                .padding(.leading, 16)
                .padding(.trailing, Chrome.rowControlTrailingPadding)
                .padding(.vertical, 14)
            }
        }
        ChimeraPresetsSection()
    }
}
