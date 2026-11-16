import AppKit
import SwiftUI

/// Software updates, release notes and the installed build's version card.
struct VersionSettingsPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            AboutSoftwareUpdateSection()
            ChromeSection(title: "Version information") {
                appCard
            }
        }
    }

    private var appCard: some View {
        @Bindable var settings = model.settings
        return ChromeCard {
            HStack(spacing: 14) {
                Image(nsImage: AppIconManager.shared.image)
                    .resizable()
                    .frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Tivano")
                        .font(.ui(.title3, weight: .semibold))
                    Text(verbatim: String(format: Chrome.localized("Version %@ (%@)"), AppInfo.version, AppInfo.build))
                        .font(.ui(.callout))
                        .foregroundStyle(Chrome.secondaryText)
                }
                Spacer()
            }
            .padding(16)
            if AppInfo.allowsAppUpdates {
                ChromeRowDivider()
                AboutUpdateCheckRow()
                ChromeRowDivider()
                ChromeRow(title: "Automatically update", detail: "Downloads new versions in the background and installs them while you're away.") {
                    SettingsSwitch(isOn: $settings.autoUpdateEnabled)
                }
            }
        }
    }
}
