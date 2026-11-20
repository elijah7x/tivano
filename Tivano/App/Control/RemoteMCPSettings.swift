import SwiftUI
import AppKit

struct RemoteMCPSettingsRows: View {
    @Environment(AppModel.self) private var model
    @FocusState private var isAddressFocused: Bool

    var body: some View {
        @Bindable var settings = model.settings
        ChromeRow(title: "Remote MCP", detail: "Let cloud agents such as Muse or Grok Bot control this edition of Tivano over MCP, through a tunnel you run. Each agent needs your approval here once. Approvals and questions in chats still wait in Tivano.") {
            SettingsSwitch(isOn: $settings.remoteMCPEnabled)
                .accessibilityLabel(Text("Remote MCP"))
        }
        ChromeRowDivider()
        ChromeRow(title: "Run remote chats without approval", detail: "Chats that cloud agents create start in Full access: commands and file changes run without asking. Chats created while this is off, and your own chats, keep their permissions. Questions still wait in Tivano.") {
            SettingsSwitch(isOn: $settings.remoteMCPFullAccess)
                .accessibilityLabel(Text("Run remote chats without approval"))
        }
        ChromeRowDivider()
        ChromeRow(title: "Public address", detail: addressDetail) {
            TextField("", text: $settings.remoteMCPPublicURL, prompt: Text("Paste your tunnel's HTTPS address"))
                .textFieldStyle(.plain)
                .focused($isAddressFocused)
                .focusEffectDisabled()
                .font(.ui(.callout, design: .monospaced))
                .foregroundStyle(Chrome.primaryText)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Chrome.overlay(0.06), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .accessibilityLabel(Text("Public address"))
                .onSubmit { model.remoteMCP.refresh() }
                .onChange(of: isAddressFocused) { _, focused in
                    if !focused { model.remoteMCP.refresh() }
                }
        }
        ChromeRowDivider()
        ChromeRow(title: "Server URL", detail: model.remoteMCP.mcpURL) {
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(model.remoteMCP.mcpURL, forType: .string)
            } label: {
                Label { Text(verbatim: Chrome.localized("Copy")) } icon: { Image.themed("doc.on.doc") }
            }
            .chromePillButton()
            .help(Text(verbatim: Chrome.localized("Copy server URL")))
            .accessibilityLabel(Text(verbatim: Chrome.localized("Copy server URL")))
        }
        ChromeRowDivider()
        ChromeRow(title: "Remote MCP status", detail: status) {
            if settings.isRemoteMCPEnabled && !model.remoteMCP.listening {
                Button {
                    model.remoteMCP.refresh()
                } label: {
                    Label { Text(verbatim: Chrome.localized("Retry")) } icon: { Image.themed("arrow.clockwise") }
                }
                .chromePillButton()
                .help(Text(verbatim: Chrome.localized("Retry remote MCP")))
                .accessibilityLabel(Text(verbatim: Chrome.localized("Retry remote MCP")))
            }
        }
        ForEach(model.remoteMCP.grants) { grant in
            ChromeRowDivider()
            ChromeRow(title: grant.clientName, detail: grantDetail(grant)) {
                Button(role: .destructive) {
                    model.remoteMCP.revoke(grant)
                } label: {
                    Label { Text(verbatim: Chrome.localized("Revoke access")) } icon: { Image.themed("xmark.circle") }
                }
                .chromePillButton()
                .help(Text(verbatim: Chrome.localized("Revoke access")))
                .accessibilityLabel(Text(verbatim: Chrome.localized("Revoke access")))
            }
        }
        if model.remoteMCP.grants.count >= 2 {
            ChromeRowDivider()
            ChromeRow(title: "Revoke all") {
                Button(role: .destructive) {
                    model.remoteMCP.revokeAll()
                } label: {
                    Label { Text(verbatim: Chrome.localized("Revoke all")) } icon: { Image.themed("xmark.circle") }
                }
                .chromePillButton()
                .help(Text(verbatim: Chrome.localized("Revoke all")))
                .accessibilityLabel(Text(verbatim: Chrome.localized("Revoke all")))
            }
        }
    }

    private var addressDetail: String {
        let address = model.settings.remoteMCPPublicURL
        if !address.isEmpty && RemoteMCP.normalizedPublicURL(address) == nil {
            return "Enter an HTTPS address, or leave it empty for this Mac only."
        }
        return String(format: Chrome.localized("Your tunnel's HTTPS address, forwarding to http://127.0.0.1:%d. Leave empty to allow only this Mac."), Int(model.remoteMCP.port))
    }

    private var status: String {
        if !model.settings.isRemoteMCPEnabled { return "Disabled" }
        if model.remoteMCP.listening {
            return String(format: Chrome.localized("Listening on 127.0.0.1:%d"), Int(model.remoteMCP.port))
        }
        return "Remote MCP could not start. Retry after freeing the port."
    }

    private func grantDetail(_ grant: RemoteMCPGrant) -> String {
        let scope = Chrome.localized(grant.scopes.contains(.write) ? "Full control" : "Read only")
        guard let lastUsed = grant.lastUsedAt else { return scope }
        return scope + " · " + String(format: Chrome.localized("Last used %@"), lastUsed.formatted(.relative(presentation: .named)))
    }
}
