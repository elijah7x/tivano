import SwiftUI

struct ProviderAccountsSection: View {
    @Environment(AppModel.self) private var model
    let provider: ProviderKind
    @State private var isAdding = false
    @State private var isImporting = false
    @State private var isExpanded = false
    @State private var isSingleAccountSigningIn = false
    @State private var error: String?
    @State private var candidates: [CodexImportCandidate] = []

    var body: some View {
        let accounts = model.providers.accounts
        let providerAccounts = accounts.accounts(for: provider)
        let hasExpandableContent = provider == .claude || providerAccounts.count > 1
        let onlyAccount = (provider != .claude && providerAccounts.count == 1) ? providerAccounts.first : nil
        let onlyAccountStatus = onlyAccount.map { account in
            AccountSupport.status(
                for: account,
                accounts: accounts,
                isActive: accounts.activeAccount(for: provider)?.id == account.id,
                isSigningIn: isSingleAccountSigningIn,
                error: nil
            )
        }

        VStack(spacing: 0) {
            ChromeRow(
                title: provider == .claude ? "Account selection" : "Accounts",
                detail: headerDetail(accounts: accounts, providerAccounts: providerAccounts),
                localizesDetail: false
            ) {
                HStack(spacing: 8) {
                    if provider != .claude {
                        GlassPickerButton(options: [(ProviderAccounts.SwitchMode.manual, "Manual"), (.automatic, "Automatic")], selection: Binding(
                            get: { accounts.switchMode(for: provider) },
                            set: { accounts.setSwitchMode($0, for: provider) }
                        ))
                        .help(Text(verbatim: Chrome.localized(accounts.switchMode(for: provider) == .manual
                            ? "New turns use the account you pick."
                            : "When an account reaches its usage limit, Tivano continues the chat on the account with the most usage left.")))
                    }
                    Button {
                        isAdding = true
                        error = nil
                        Task {
                            error = await accounts.addAccount(provider)
                            isAdding = false
                        }
                    } label: {
                        Label {
                            Text(verbatim: Chrome.localized("Add account"))
                        } icon: {
                            Image(systemName: "plus")
                        }
                    }
                    .chromePillButton(iconOnly: true)
                    .disabled(isAdding)
                    .help(Text(verbatim: Chrome.localized("Add account")))
                    .accessibilityLabel(Text(verbatim: Chrome.localized("Add account")))

                    if hasExpandableContent {
                        Button {
                            withAnimation(Chrome.hover) { isExpanded.toggle() }
                        } label: {
                            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                                .font(.ui(.caption, weight: .semibold))
                                .foregroundStyle(Chrome.secondaryText)
                                .frame(width: Chrome.capsuleContentHeight, height: Chrome.capsuleContentHeight)
                                .contentShape(.rect)
                        }
                        .buttonStyle(ChromeQuietButtonStyle())
                        .accessibilityLabel(Text(verbatim: Chrome.localized(provider == .claude ? "Account selection" : "Accounts")))
                        .accessibilityValue(Text(verbatim: Chrome.localized(isExpanded ? "Expanded" : "Collapsed")))
                    } else if let onlyAccount {
                        ProviderAccountMenu(
                            account: onlyAccount,
                            fullNotice: onlyAccountStatus?.fullNotice,
                            isSigningIn: $isSingleAccountSigningIn,
                            error: $error
                        )
                    }
                }
            }
            .accountHelp(onlyAccountStatus?.fullNotice)

            if hasExpandableContent {
                ChromeReveal(isExpanded: isExpanded) {
                    VStack(spacing: 0) {
                        ForEach(providerAccounts) { account in
                            ChromeRowDivider()
                            ProviderAccountSettingsRow(account: account)
                        }
                    }
                }
                .clipped()
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
                    .chromePillButton()
                    .disabled(isImporting)
                }
            }
        }
        .task {
            candidates = accounts.importCandidates(provider)
            await accounts.refresh(provider, force: false)
        }
    }

    private func headerDetail(accounts: ProviderAccounts, providerAccounts: [ProviderAccount]) -> String? {
        var summaryParts: [String] = []
        if let active = accounts.activeAccount(for: provider) {
            summaryParts.append(accounts.title(of: active))
            let windows = AccountSupport.windows(for: active, state: accounts.states[active.id])
            summaryParts.append(contentsOf: windows.map(AccountSupport.windowSummary))
        }
        let needsSignInCount = providerAccounts.filter { AccountSupport.needsSignIn($0, state: accounts.states[$0.id]) }.count
        if needsSignInCount == 1 {
            summaryParts.append(Chrome.localized("1 account needs sign-in"))
        } else if needsSignInCount > 1 {
            summaryParts.append(String(format: Chrome.localized("%lld accounts need sign-in"), needsSignInCount))
        }

        let summaryLine = summaryParts.isEmpty ? nil : summaryParts.joined(separator: " · ")
        let note = provider == .claude
            ? Chrome.localized("Your selection applies only to new Claude chats. Existing chats keep their account. The default account follows your Claude CLI login.")
            : nil
        let lines = [summaryLine, note, error].compactMap { $0 }.filter { !$0.isEmpty }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
}

private struct ProviderAccountSettingsRow: View {
    @Environment(AppModel.self) private var model
    let account: ProviderAccount
    @State private var isSigningIn = false
    @State private var error: String?

    private var accounts: ProviderAccounts { model.providers.accounts }
    private var state: ProviderAccounts.State? { accounts.states[account.id] }
    private var isActive: Bool { accounts.activeAccount(for: account.provider)?.id == account.id }

    var body: some View {
        let status = AccountSupport.status(
            for: account,
            accounts: accounts,
            isActive: isActive,
            isSigningIn: isSigningIn,
            error: error
        )
        let windows = AccountSupport.windows(for: account, state: state)

        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(verbatim: accounts.title(of: account))
                        .font(.ui(.body))
                        .foregroundStyle(Chrome.primaryText)
                        .truncationMode(.tail)
                    if isActive {
                        Image(systemName: "checkmark")
                            .font(.ui(.subheadline, weight: .semibold))
                            .foregroundStyle(Chrome.secondaryText)
                            .accessibilityLabel(Text(verbatim: Chrome.localized(account.provider == .claude ? "Selected for new chats" : "In use")))
                    }
                }
                if !status.detail.isEmpty {
                    Text(verbatim: status.detail)
                        .font(.ui(.subheadline))
                        .foregroundStyle(Chrome.secondaryText)
                        .truncationMode(.tail)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing) {
                ForEach(windows) { window in
                    Text(verbatim: AccountSupport.windowSummary(window))
                        .monospacedDigit()
                }
            }
            ProviderAccountMenu(
                account: account,
                fullNotice: status.fullNotice,
                isSigningIn: $isSigningIn,
                error: $error
            )
        }
        .padding(.leading, 16)
        .padding(.trailing, Chrome.rowControlTrailingPadding)
        .padding(.vertical, 11)
        .accountHelp(status.fullNotice)
    }
}

private struct ProviderAccountMenu: View {
    @Environment(AppModel.self) private var model
    let account: ProviderAccount
    let fullNotice: String?
    @Binding var isSigningIn: Bool
    @Binding var error: String?
    @State private var isRenaming = false
    @State private var isRemoving = false
    @State private var confirmsRemoval = false
    @State private var confirmsForceRemoval = false
    @State private var newName = ""

    private var accounts: ProviderAccounts { model.providers.accounts }
    private var state: ProviderAccounts.State? { accounts.states[account.id] }
    private var dependentChats: [ChatThread] {
        model.threads.filter {
            $0.provider == .claude
                && ($0.hasStartedTurn || $0.providerSessionID != nil)
                && ($0.claudeAccountID == account.id
                    || (account.isDefault && $0.claudeAccountID == nil && $0.claudeUsesDefaultAccount == true))
        }
    }
    private var isActive: Bool { accounts.activeAccount(for: account.provider)?.id == account.id }
    private var isSignedIn: Bool {
        if case .signedIn? = state?.auth { return true }
        return false
    }

    var body: some View {
        Menu {
            if let fullNotice, !fullNotice.isEmpty {
                Button {} label: {
                    Text(verbatim: fullNotice)
                }
                .disabled(true)
                Divider()
            }
            if !account.requiresClaudeCleanup || !account.requiresClaudeActivation {
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
                .disabled(isSigningIn || isRemoving || state?.isSigningIn == true)
                Button("Rename…") {
                    newName = account.name ?? ""
                    isRenaming = true
                }
            }
            if !account.isDefault {
                Button("Remove account", role: .destructive) { confirmsRemoval = true }
                    .disabled(isRemoving || isSigningIn || state?.isSigningIn == true)
                if account.provider == .claude && account.requiresClaudeCleanup {
                    Button("Remove from Tivano anyway", role: .destructive) { confirmsForceRemoval = true }
                        .disabled(isRemoving || isSigningIn || state?.isSigningIn == true)
                }
            }
        } label: {
            Label("Account actions", systemImage: "ellipsis")
                .labelStyle(.iconOnly)
        }
        .menuStyle(.borderlessButton)
        .alert("Rename account", isPresented: $isRenaming) {
            TextField("Name", text: $newName)
            Button("Save") { accounts.rename(account, to: newName) }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Remove this account?", isPresented: $confirmsRemoval, titleVisibility: .visible) {
            Button("Remove account", role: .destructive) {
                error = nil
                isRemoving = true
                Task {
                    if account.provider == .claude {
                        error = await ThreadRuntime.removeClaudeAccount(account, app: model)
                    } else {
                        error = await accounts.remove(account)
                    }
                    isRemoving = false
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if account.provider == .claude {
                Text(verbatim: claudeRemovalMessage)
            } else {
                Text("Tivano signs this account out and deletes its sign-in folder on this Mac. Chats keep their history.")
            }
        }
        .confirmationDialog("Remove from Tivano anyway?", isPresented: $confirmsForceRemoval, titleVisibility: .visible) {
            Button("Remove from Tivano anyway", role: .destructive) {
                error = nil
                isRemoving = true
                Task {
                    error = await ThreadRuntime.removeClaudeAccount(account, app: model, forceRemoveLocal: true)
                    isRemoving = false
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes this account from Tivano even if macOS Keychain denies credential cleanup. You can delete any remaining Keychain item in Keychain Access.")
        }
    }

    private var claudeRemovalMessage: String {
        let total = dependentChats.count
        guard total > 0 else {
            return Chrome.localized("Tivano signs this Claude account out and deletes its local profile on this Mac.")
        }
        let archived = dependentChats.count(where: \.isArchived)
        if archived > 0 {
            return String(
                format: Chrome.localized("Tivano signs this Claude account out and deletes its local profile on this Mac. %lld saved chats (%lld archived) keep their history, but cannot send new messages."),
                total, archived
            )
        }
        return String(
            format: Chrome.localized("Tivano signs this Claude account out and deletes its local profile on this Mac. %lld saved chats keep their history, but cannot send new messages."),
            total
        )
    }
}

@MainActor
private enum AccountSupport {
    static let resetFormatter = RelativeDateTimeFormatter()

    static func windows(for account: ProviderAccount, state: ProviderAccounts.State?) -> [PlanLimits.Window] {
        guard !account.requiresClaudeActivation, !account.requiresClaudeCleanup else { return [] }
        let windows = (state?.limits?.windows ?? []).filter { !$0.id.contains("extra") }
        let selected = [windows.first { $0.title.hasPrefix("5-hour") }, windows.first { $0.title.hasPrefix("Weekly") }].compactMap { $0 }
        return selected.isEmpty ? Array(windows.prefix(2)) : selected
    }

    static func windowSummary(_ window: PlanLimits.Window) -> String {
        String(format: Chrome.localized("%@ · %lld%%"), Chrome.localized(window.title), Int(window.percent.rounded()))
    }

    static func isAuthProblem(_ problem: String, limits: PlanLimits?) -> Bool {
        limits?.problemKind == .authentication
            || problem == "Codex's stored login has expired. Run `codex login` in a terminal, then check again."
            || problem == Chrome.localized("Codex's stored login has expired. Run `codex login` in a terminal, then check again.")
            || problem == "Claude sign-in has expired. Sign in again."
            || problem == Chrome.localized("Claude sign-in has expired. Sign in again.")
            || problem == ClaudeAccountValidationError.authentication.localizedDescription
            || PlanLimitsReader.failure(problem).problemKind == .authentication
    }

    static func needsSignIn(_ account: ProviderAccount, state: ProviderAccounts.State?) -> Bool {
        guard state?.isSigningIn != true else { return false }
        if account.requiresClaudeActivation && !account.requiresClaudeCleanup { return true }
        if account.requiresClaudeCleanup && !account.requiresClaudeActivation { return true }
        if state?.auth == .signedOut { return true }
        if let problem = state?.problem ?? state?.limits?.problem {
            return isAuthProblem(problem, limits: state?.limits)
        }
        return false
    }

    static func status(
        for account: ProviderAccount,
        accounts: ProviderAccounts,
        isActive: Bool,
        isSigningIn: Bool,
        error: String?
    ) -> (detail: String, fullNotice: String?) {
        let state = accounts.states[account.id]
        var parts = [
            state?.limits?.planName ?? account.plan,
            account.email == accounts.title(of: account) ? nil : account.email,
            account.organizationName ?? account.organizationID
        ]
        .compactMap { $0 }
        .filter { !$0.isEmpty }

        var fullNotice: String?
        if let error {
            parts.append(error)
            fullNotice = error
        } else if account.requiresClaudeCleanup {
            let message = Chrome.localized(account.requiresClaudeActivation
                ? "Removing this account did not finish. Try again."
                : "Sign-in was interrupted. Sign in again to restore this account.")
            parts.append(message)
            fullNotice = message
        } else if account.requiresClaudeActivation {
            let message = Chrome.localized("Sign in again to use this account.")
            parts.append(message)
            fullNotice = message
        } else if isSigningIn || state?.isSigningIn == true {
            parts.append(Chrome.localized("Waiting for sign-in…"))
        } else if state?.isChecking == true {
            parts.append(Chrome.localized("Checking…"))
        } else if state?.auth == .signedOut {
            parts.append(Chrome.localized("Signed out"))
            if let problem = state?.problem ?? state?.limits?.problem {
                fullNotice = Chrome.localized(problem)
            }
        } else if let problem = state?.problem ?? state?.limits?.problem {
            let localizedProblem = Chrome.localized(problem)
            fullNotice = localizedProblem
            parts.append(isAuthProblem(problem, limits: state?.limits)
                ? Chrome.localized("Login expired")
                : localizedProblem)
        } else if let reset = state?.exhaustedUntil, reset > .now {
            parts.append(String(format: Chrome.localized("Usage limit reached · resets %@"), Self.resetFormatter.localizedString(for: reset, relativeTo: .now)))
        } else if isActive {
            parts.append(Chrome.localized(account.provider == .claude ? "Selected for new chats" : "In use"))
        }
        return (parts.joined(separator: " · "), fullNotice)
    }
}

private extension View {
    @ViewBuilder
    func accountHelp(_ text: String?) -> some View {
        if let text, !text.isEmpty {
            help(Text(verbatim: text))
        } else {
            self
        }
    }
}
