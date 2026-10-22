import SwiftUI

struct GitHubSettingsSection: View {
    private var connection: GitHubConnection { .shared }

    var body: some View {
        ChromeSection(title: "GitHub") {
            ChromeCard {
                if connection.isConnected {
                    HStack(spacing: 10) {
                        AsyncImage(url: connection.user?.avatarURL) { image in
                            image.resizable().scaledToFill()
                        } placeholder: {
                            Image("mcp-github").resizable().scaledToFit()
                        }
                        .frame(width: 28, height: 28)
                        .clipShape(Circle())
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: connection.user.map { $0.name ?? $0.login } ?? "GitHub")
                                .foregroundStyle(Chrome.primaryText)
                            if let detail = accountDetail {
                                Text(verbatim: detail).font(.ui(.subheadline)).foregroundStyle(Chrome.secondaryText)
                            }
                        }
                        Spacer(minLength: 12)
                        Button("Disconnect") { connection.disconnect() }.buttonStyle(.glass)
                    }
                    .padding(.leading, 16)
                    .padding(.trailing, Chrome.rowControlTrailingPadding)
                    .padding(.vertical, 11)
                } else if case .checking = connection.phase {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Checking GitHub connection…").foregroundStyle(Chrome.secondaryText)
                    }
                    .padding(16)
                } else {
                    ChromeRow(title: "Connect GitHub", detail: "Let agents push and open pull requests.") {
                        EmptyView()
                    }
                    GitHubConnectView().padding(.horizontal, 16).padding(.bottom, 11)
                }
            }
        }
    }

    private var accountDetail: String? {
        guard let user = connection.user else { return nil }
        switch connection.source {
        case .githubCLI: return String(format: Chrome.localized("@%@, using the GitHub CLI login"), user.login)
        case .tivano: return String(format: Chrome.localized("@%@, saved in your Keychain"), user.login)
        case nil: return "@\(user.login)"
        }
    }
}
