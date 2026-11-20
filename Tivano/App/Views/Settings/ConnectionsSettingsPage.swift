import AppKit
import SwiftUI

/// MCP servers, local control, remote MCP and code hosts in one place.
struct ConnectionsSettingsPage: View {
    var query = ""

    private var trimmedQuery: String { query.trimmed }

    private func shows(_ keys: [String]) -> Bool {
        guard !trimmedQuery.isEmpty else { return true }
        return keys.contains { key in
            [key, Chrome.localized(key)].contains {
                $0.localizedCaseInsensitiveContains(trimmedQuery)
            }
        }
    }

    var body: some View {
        MCPSettingsPage(query: query)

        if shows(["Local control", "CLI", "tivano"]) {
            ChromeSection(title: "Local control") {
                ChromeCard { LocalControlSettingsRows() }
                CLIInstallationSettings()
            }
        }

        if shows(["Remote MCP", "MCP"]) {
            ChromeSection(title: "Remote MCP") {
                ChromeCard { RemoteMCPSettingsRows() }
            }
        }

        if shows(["Code hosts", "GitHub", "Cursor Origin", "Origin CLI", "Pull requests"]) {
            ChromeSection(title: "Code hosts") {
                VStack(alignment: .leading, spacing: Chrome.unitSpacing) {
                    GitHubSettingsCard()
                    ChromeCard {
                        CursorOriginStatusRow()
                        ChromeRowDivider()
                        ChromeRow(title: "Pull requests", detail: "Opened with the GitHub CLI (gh), GitLab CLI (glab), Cursor Origin CLI (origin) or Gitea CLI (tea) from your PATH.") {
                            EmptyView()
                        }
                    }
                }
            }
        }
    }
}

/// Whether the `origin` CLI that opens and merges Cursor Origin pull requests is installed
/// and signed in, read from `origin auth status`.
private struct CursorOriginStatusRow: View {
    private enum Status: Equatable {
        case checking, missing, signedOut, signedIn(String?)
    }

    @State private var status = Status.checking

    var body: some View {
        ChromeRow(title: "Origin CLI", detail: detail) {
            if status == .signedOut {
                Button("Copy command") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("origin auth login", forType: .string)
                }
                .chromePillButton()
            }
        }
        .task { status = await Self.check() }
    }

    private var detail: String {
        switch status {
        case .checking: Chrome.localized("Checking…")
        case .missing: Chrome.localized("The origin CLI is not on your PATH.")
        case .signedOut: Chrome.localized("Not signed in. Run `origin auth login` in Terminal.")
        case .signedIn(let account?): String(format: Chrome.localized("Signed in as %@"), account)
        case .signedIn(nil): Chrome.localized("Signed in")
        }
    }

    private static func check() async -> Status {
        guard LoginEnvironment.which("origin") != nil else { return .missing }
        guard let result = try? await Shell.run(tool: "origin", ["auth", "status"], timeout: 20) else { return .signedOut }
        let text = TextCleanup.stripANSI(result.output + "\n" + result.errorOutput)
        guard result.succeeded, text.range(of: "Token:\\s+valid", options: .regularExpression) != nil else { return .signedOut }
        let account = text.firstMatch(of: /Account:[ \t]*(\S+)/).map { String($0.output.1) }
        return .signedIn(account)
    }
}
