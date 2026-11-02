import SwiftUI

struct ProviderAccountsSection: View {
    @Environment(AppModel.self) private var model
    let provider: ProviderKind
    @State private var isAdding = false
    @State private var isImporting = false
    @State private var error: String?
    @State private var candidates: [CodexImportCandidate] = []
    @State private var claudeCandidates: [ClaudeSwapImportCandidate] = []
    @State private var selectedClaudeCandidates: Set<String> = []
    @State private var importResults: [String] = []
    @State private var didPreviewClaude = false

    var body: some View {
        let accounts = model.providers.accounts
        VStack(spacing: 0) {
            if provider == .claude {
                ChromeRow(title: "Account selection", detail: "Your selection applies only to new Claude chats. Existing chats keep their profile. The default profile follows your CLI login.") {}
            } else {
            ChromeRow(title: "Account switching", detail: accounts.switchMode(for: provider) == .manual
                ? "New turns use the account you pick."
                : "When an account reaches its usage limit, Tivano continues the chat on the account with the most usage left.") {
                GlassPickerButton(options: [(ProviderAccounts.SwitchMode.manual, "Manual"), (.automatic, "Automatic")], selection: Binding(
                    get: { accounts.switchMode(for: provider) },
                    set: { accounts.setSwitchMode($0, for: provider) }
                ))
            }
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
            if provider == .claude {
                ChromeRowDivider()
                ChromeRow(title: "Import from CSWAP", detail: "Import saves a copy without enabling it. The CSWAP backup may be outdated. macOS may ask for credential access.") {
                    Button("Choose accounts") {
                        error = nil
                        Task {
                        await LoginEnvironment.load()
                        do {
                            claudeCandidates = try ClaudeSwapImport.candidates()
                            selectedClaudeCandidates = []
                            importResults = []
                            didPreviewClaude = true
                        } catch {
                            self.error = ProviderAccounts.safeClaudeError(error)
                        }
                        }
                    }
                    .buttonStyle(.glass)
                    .disabled(isImporting)
                }
                if didPreviewClaude && claudeCandidates.isEmpty {
                    ChromeRowDivider()
                    ChromeRow(title: "No CSWAP accounts found", detail: nil) {}
                }
                ForEach(claudeCandidates) { candidate in
                    ChromeRowDivider()
                    ChromeRow(title: candidate.label ?? candidate.email,
                              detail: [candidate.email, candidate.organizationName ?? candidate.organizationID, candidate.slot].compactMap { $0 }.joined(separator: " · "),
                              localizesDetail: false) {
                        SettingsSwitch(isOn: Binding(
                            get: { selectedClaudeCandidates.contains(candidate.id) },
                            set: { if $0 { selectedClaudeCandidates.insert(candidate.id) } else { selectedClaudeCandidates.remove(candidate.id) } }
                        ))
                        .disabled(isImporting)
                        .accessibilityLabel(candidate.email)
                    }
                }
                if !claudeCandidates.isEmpty {
                    ChromeRowDivider()
                    ChromeRow(title: "Import selected accounts", detail: "Existing accounts with the same account and organization are skipped.") {
                        Button("Import") {
                            isImporting = true
                            let selected = claudeCandidates.filter { selectedClaudeCandidates.contains($0.id) }
                            Task {
                                importResults = await accounts.importClaudeAccounts(selected)
                                selectedClaudeCandidates = []
                                isImporting = false
                            }
                        }
                        .buttonStyle(.glass)
                        .disabled(isImporting || selectedClaudeCandidates.isEmpty)
                    }
                }
                ForEach(Array(importResults.enumerated()), id: \.offset) { _, result in
                    ChromeRowDivider()
                    ChromeRow(title: "Import result", detail: result, localizesDetail: false) {}
                }
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
    @State private var confirmsActivation = false
    @State private var isSigningIn = false
    @State private var newName = ""
    @State private var error: String?

    private var accounts: ProviderAccounts { model.providers.accounts }
    private var state: ProviderAccounts.State? { accounts.states[account.id] }
    private var dependentChats: [ChatThread] {
        model.threads.filter { $0.provider == .claude && ($0.claudeAccountID == account.id
            || (account.isDefault && $0.claudeAccountID == nil && $0.claudeUsesDefaultAccount == true)) }
    }
    private var hasDependentChats: Bool { !dependentChats.isEmpty }
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
                if !account.requiresClaudeCleanup || !account.requiresClaudeActivation {
                    if account.requiresClaudeActivation {
                        Button("Enable imported login") { confirmsActivation = true }
                    }
                    if !account.requiresClaudeActivation {
                        if !isActive && !account.requiresClaudeCleanup && (isSignedIn || account.provider == .claude) {
                            Button("Use this account") { accounts.use(account) }
                        }
                    }
                    Button("Sign in again") {
                        error = nil
                        isSigningIn = true
                        Task {
                            if account.provider == .claude {
                                error = await ThreadRuntime.signInClaudeAccount(account, app: model,
                                    expectedIdentities: dependentChats.compactMap(\.claudeIdentity))
                            } else {
                                error = await accounts.signIn(account)
                            }
                            isSigningIn = false
                        }
                    }
                    .disabled(isSigningIn || state?.isSigningIn == true)
                    Button("Rename…") {
                        newName = account.name ?? ""
                        isRenaming = true
                    }
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
        .confirmationDialog("Enable imported login?", isPresented: $confirmsActivation, titleVisibility: .visible) {
            Button("Enable imported login") {
                Task { error = await accounts.activateClaudeAccount(account) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Refreshing this copied login may require CSWAP or another Tivano instance to sign in again. We recommend signing in separately in each instance.")
        }
        .alert("Rename account", isPresented: $isRenaming) {
            TextField("Name", text: $newName)
            Button("Save") { accounts.rename(account, to: newName) }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Remove this account?", isPresented: $confirmsRemoval, titleVisibility: .visible) {
            Button("Remove account", role: .destructive) {
                Task { error = await accounts.remove(account, hasDependentChats: hasDependentChats) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if account.provider == .claude {
                Text("Accounts used by saved Claude chats cannot be removed. Removing another account deletes only its local Tivano credentials and profile; CSWAP is unchanged.")
            } else {
                Text("Tivano signs this account out and deletes its sign-in folder on this Mac. Chats keep their history.")
            }
        }
    }

    private var windows: [PlanLimits.Window] {
        guard !account.requiresClaudeActivation, !account.requiresClaudeCleanup else { return [] }
        let windows = (state?.limits?.windows ?? []).filter { !$0.id.contains("extra") }
        let selected = [windows.first { $0.title.hasPrefix("5-hour") }, windows.first { $0.title.hasPrefix("Weekly") }].compactMap { $0 }
        return selected.isEmpty ? Array(windows.prefix(2)) : selected
    }

    private var detail: String {
        var parts = [state?.limits?.planName ?? account.plan, account.email == accounts.title(of: account) ? nil : account.email, account.organizationName ?? account.organizationID].compactMap { $0 }.filter { !$0.isEmpty }
        if let error {
            parts.append(error)
        } else if account.requiresClaudeCleanup {
            parts.append(Chrome.localized(account.requiresClaudeActivation ? "Cleanup required. Retry removing this account." : "Login replacement was interrupted. Sign in again to recover this account."))
        } else if account.requiresClaudeActivation {
            parts.append(Chrome.localized("Saved, not activated"))
        } else if isSigningIn || state?.isSigningIn == true {
            parts.append(Chrome.localized("Waiting for sign-in…"))
        } else if state?.isChecking == true {
            parts.append(Chrome.localized("Checking…"))
        } else if state?.auth == .signedOut {
            parts.append(Chrome.localized("Signed out"))
        } else if let problem = state?.problem ?? state?.limits?.problem {
            parts.append(Chrome.localized(problem))
        } else if let reset = state?.exhaustedUntil, reset > .now {
            let formatter = RelativeDateTimeFormatter()
            parts.append(String(format: Chrome.localized("Usage limit reached · resets %@"), formatter.localizedString(for: reset, relativeTo: .now)))
        } else if isActive {
            parts.append(Chrome.localized(account.provider == .claude ? "Selected for new chats" : "In use"))
        }
        return parts.joined(separator: " · ")
    }
}
