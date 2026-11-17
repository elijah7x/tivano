import AppKit
import SwiftUI

struct TokenUsageSettingsPage: View {
    @Environment(AppModel.self) private var model
    @Environment(\.locale) private var locale
    @State private var sourceStatus: TokenTakenStatus = .notInstalled

    private var isInstalled: Bool {
        if case .installed = sourceStatus { return true }
        return false
    }

    private var statusText: String {
        switch sourceStatus {
        case .notInstalled:
            Chrome.localized("Not installed")
        case .installed(let version):
            if let version {
                String(format: Chrome.localized("Installed · %@"), version)
            } else {
                Chrome.localized("Installed")
            }
        }
    }

    private var sourceDetail: String? {
        isInstalled ? nil : "Install Token Taken to see token usage here."
    }

    private var refreshDetail: String? {
        switch model.tokenUsage.phase {
        case .idle: nil
        case .fetching: Chrome.localized("Refreshing…")
        case .failed(.timedOut): Chrome.localized("Token Taken took too long to respond")
        case .failed(.cancelled): Chrome.localized("Refresh cancelled")
        case .failed: Chrome.localized("Couldn't refresh token usage")
        }
    }

    @ViewBuilder private var lastRefreshed: some View {
        if let fetchedAt = model.tokenUsage.snapshot?.fetchedAt {
            Text(verbatim: fetchedAt.formatted(.relative(presentation: .named).locale(locale)))
                .font(.ui(.subheadline))
                .foregroundStyle(Chrome.secondaryText)
                .help(Text(verbatim: fetchedAt.formatted(.dateTime.locale(locale))))
                .accessibilityValue(Text(verbatim: fetchedAt.formatted(.dateTime.locale(locale))))
        } else {
            Text("Never")
                .font(.ui(.subheadline))
                .foregroundStyle(Chrome.secondaryText)
        }
    }

    var body: some View {
        ChromeSection(title: "Data source") {
            Text("Tivano does not collect token usage itself. It shows the history that Token Taken, a companion app, collects from your AI coding tools on this Mac. Nothing leaves your computer.")
                .font(.ui(.subheadline))
                .foregroundStyle(Chrome.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            ChromeCard {
                ChromeRow(title: "Token Taken", detail: sourceDetail) {
                    HStack(spacing: Chrome.unitHeaderSpacing) {
                        Text(verbatim: statusText)
                            .font(.ui(.subheadline))
                            .foregroundStyle(Chrome.secondaryText)
                        if isInstalled, let appURL = TokenTakenSource.appURL() {
                            Button("Open Token Taken") {
                                NSWorkspace.shared.openApplication(at: appURL, configuration: .init())
                            }
                        }
                    }
                }
                ChromeRowDivider()
                ChromeRow(title: "Last refreshed", detail: refreshDetail) {
                    HStack(spacing: Chrome.unitHeaderSpacing) {
                        lastRefreshed
                        Button("Refresh") { model.tokenUsage.refresh() }
                            .disabled(!isInstalled || model.tokenUsage.isFetching)
                    }
                }
            }
            HStack(spacing: Chrome.sectionSpacing) {
                Button("View token usage") {
                    WindowManager.shared.hideSettings()
                    model.appSpace = .tokens
                }
                .disabled(!isInstalled || model.tokenUsage.snapshot == nil)
                if !isInstalled, let downloadURL = TokenTakenSource.downloadURL {
                    Link("Get Token Taken", destination: downloadURL)
                }
            }
            .font(.ui(.subheadline))
        }
        .onAppear {
            sourceStatus = TokenTakenSource.detect()
            model.tokenUsage.loadCacheIfNeeded()
        }
    }
}
