import SwiftUI

struct ProviderAccountsSection: View {
    @Environment(AppModel.self) private var model
    let provider: ProviderKind
    @State private var isAdding = false
    @State private var isImporting = false
    @State private var error: String?
    @State private var candidates: [CodexImportCandidate] = []

    var body: some View {
        let accounts = model.providers.accounts
        VStack(spacing: 0) {
            ChromeRow(title: "Account switching", detail: accounts.switchMode(for: provider) == .manual
                ? "New turns use the account you pick."
                : "When an account reaches its usage limit, Tivano continues the chat on the account with the most usage left.") {
                GlassPickerButton(options: [(ProviderAccounts.SwitchMode.manual, "Manual"), (.automatic, "Automatic")], selection: Binding(
                    get: { accounts.switchMode(for: provider) },
                    set: { accounts.setSwitchMode($0, for: provider) }
                ))
            }
            ForEach(accounts.accounts(for: provider)) { account in
                ChromeRowDivider()
                ProviderAccountSettingsRow(account: account)
            }
            ChromeRowDivider()
            ChromeRow(title: "Add account", detail: error) {
                Button("Add account") {
                    isAdding = true
                    error = nil
                    Task {
                        error = await accounts.addAccount(provider)
                        isAdding = false
                    }
                }
                .buttonStyle(.glass)
                .disabled(isAdding)
            }
            if !candidates.isEmpty {
                ChromeRowDivider()
                ChromeRow(title: String(format: Chrome.localized("Found %lld Codex accounts saved by other tools"), candidates.count), detail: "Importing copies their sign-in into Tivano. The copy in the other tool may need to sign in again after Tivano refreshes it.") {
                    Button("Import") {
                        isImporting = true
                        Task {
                            await accounts.importAccounts(candidates)
                            candidates = accounts.importCandidates(provider)
                            isImporting = false
                        }
                    }
                    .buttonStyle(.glass)
                    .disabled(isImporting)
                }
            }
        }
        .task {
            candidates = accounts.importCandidates(provider)
            await accounts.refresh(provider, force: false)
        }
    }
}

private struct ProviderAccountSettingsRow: View {
    @Environment(AppModel.self) private var model
    let account: ProviderAccount
    @State private var isRenaming = false
    @State private var confirmsRemoval = false
    @State private var newName = ""
    @State private var error: String?

    private var accounts: ProviderAccounts { model.providers.accounts }
    private var state: ProviderAccounts.State? { accounts.states[account.id] }
    private var isActive: Bool { accounts.activeAccount(for: account.provider)?.id == account.id }
    private var isSignedIn: Bool {
        if case .signedIn? = state?.auth { return true }
        return false
    }

    var body: some View {
        ChromeRow(title: accounts.title(of: account), detail: detail, localizesDetail: false) {
            VStack(alignment: .trailing) {
                ForEach(windows) { window in
                    Text(String(format: Chrome.localized("%@ · %lld%%"), Chrome.localized(window.title), Int(window.percent.rounded())))
                        .monospacedDigit()
                }
            }
            Menu {
                if !isActive && isSignedIn {
                    Button("Use this account") { accounts.use(account) }
                }
                Button("Sign in again") {
                    error = nil
                    Task { error = await accounts.signIn(account) }
                }
                .disabled(state?.isSigningIn == true)
                Button("Rename…") {
                    newName = account.name ?? ""
                    isRenaming = true
                }
                if !account.isDefault {
                    Button("Remove account", role: .destructive) { confirmsRemoval = true }
                }
            } label: {
                Label("Account actions", systemImage: "ellipsis")
                    .labelStyle(.iconOnly)
            }
            .menuStyle(.borderlessButton)
        }
        .alert("Rename account", isPresented: $isRenaming) {
            TextField("Name", text: $newName)
            Button("Save") { accounts.rename(account, to: newName) }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Remove this account?", isPresented: $confirmsRemoval, titleVisibility: .visible) {
            Button("Remove account", role: .destructive) {
                Task { await accounts.remove(account) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Tivano signs this account out and deletes its sign-in folder on this Mac. Chats keep their history.")
        }
    }

    private var windows: [PlanLimits.Window] {
        let windows = (state?.limits?.windows ?? []).filter { !$0.id.contains("extra") }
        let selected = [windows.first { $0.title.hasPrefix("5-hour") }, windows.first { $0.title.hasPrefix("Weekly") }].compactMap { $0 }
        return selected.isEmpty ? Array(windows.prefix(2)) : selected
    }

    private var detail: String {
        var parts = [state?.limits?.planName ?? account.plan, account.email == accounts.title(of: account) ? nil : account.email].compactMap { $0 }.filter { !$0.isEmpty }
        if let error {
            parts.append(error)
        } else if state?.isSigningIn == true {
            parts.append(Chrome.localized("Waiting for sign-in…"))
        } else if state?.isChecking == true {
            parts.append(Chrome.localized("Checking…"))
        } else if state?.auth == .signedOut {
            parts.append(Chrome.localized("Signed out"))
        } else if let reset = state?.exhaustedUntil, reset > .now {
            let formatter = RelativeDateTimeFormatter()
            parts.append(String(format: Chrome.localized("Usage limit reached · resets %@"), formatter.localizedString(for: reset, relativeTo: .now)))
        } else if isActive {
            parts.append(Chrome.localized("In use"))
        }
        return parts.joined(separator: " · ")
    }
}
