import Foundation
import Observation

@MainActor
@Observable
final class ProviderAccounts {
    enum SwitchMode: String, Codable, Sendable { case manual, automatic }
    struct State: Equatable {
        var auth: ProviderStatus.Auth?
        var limits: PlanLimits?
        var fetchedAt: Date?
        var isChecking = false
        var isSigningIn = false
        var exhaustedUntil: Date?
        var problem: String?
    }
    static let supportedProviders: Set<ProviderKind> = [.codex, .claude]
    static let automaticSwitchingProviders: Set<ProviderKind> = [.codex]
    private static var readers: [UUID: Int] = [:]
    private static var processes: [UUID: Int] = [:]
    private static var exclusive: Set<UUID> = []

    static func beginRead(_ id: UUID) -> Bool {
        guard canStartProcess(id) else { return false }
        readers[id, default: 0] += 1
        return true
    }
    static func endRead(_ id: UUID) { readers[id] = max(0, readers[id, default: 0] - 1) }
    static func beginClaudeCredentialRead(environment: [String: String]) throws -> UUID? {
        guard !CaptureRun.isEnabled else { throw ClaudeCredentialError.capture }
        let managed = environment["CLAUDE_CODE_PROVIDER_MANAGED_BY_HOST"] == "1"
        let account = ProviderAccountStore.load().accounts.first {
            $0.provider == .claude && (managed ? $0.home == environment["CLAUDE_CONFIG_DIR"] : $0.isDefault)
        }
        guard let id = account?.id else {
            if managed { throw ClaudeAccountValidationError.verificationFailed }
            return nil
        }
        guard beginRead(id) else { throw ClaudeAccountValidationError.verificationFailed }
        return id
    }
    static func isSigningInExclusively(_ id: UUID) -> Bool { exclusive.contains(id) }

    static func canStartProcess(_ id: UUID) -> Bool {
        guard !exclusive.contains(id) else { return false }
        if let account = ProviderAccountStore.load().accounts.first(where: { $0.id == id }), account.provider == .claude {
            return !CaptureRun.isEnabled && !account.requiresClaudeActivation && !account.requiresClaudeCleanup
        }
        return true
    }
    static func beginProcess(_ id: UUID) -> Bool {
        guard canStartProcess(id) else { return false }
        processes[id, default: 0] += 1
        return true
    }
    static func endProcess(_ id: UUID) { processes[id] = max(0, processes[id, default: 0] - 1) }
    func isBusy(_ account: ProviderAccount) -> Bool {
        Self.exclusive.contains(account.id) || Self.readers[account.id, default: 0] > 0
            || Self.processes[account.id, default: 0] > 0
            || states[account.id]?.isSigningIn == true || states[account.id]?.isChecking == true
    }
    func account(id: UUID) -> ProviderAccount? { book.accounts.first { $0.id == id } }

    func bindClaudeIdentity(_ identity: ClaudeAccountIdentity, to id: UUID) throws {
        guard let index = book.accounts.firstIndex(where: { $0.id == id && $0.provider == .claude }) else {
            throw ProviderError.failed(AppText.localized("This chat's Claude account is unavailable. Restore the account to continue."))
        }
        if let previous = book.accounts[index].claudeIdentity, !book.accounts[index].isDefault,
           !previous.matches(identity) {
            throw ProviderError.failed(AppText.localized("The Claude account or organization changed. Restore the original login to continue this chat."))
        }
        guard !CaptureRun.isEnabled else { throw ClaudeCredentialError.capture }
        var next = book
        if next.accounts[index].claudeIdentity == nil { next.accounts[index].claudeIdentity = identity }
        try commit(next)
    }

    static func safeClaudeError(_ error: Error) -> String {
        if let error = error as? ClaudeCredentialError { return error.localizedDescription }
        if let error = error as? ClaudeAccountValidationError { return error.localizedDescription }
        return AppText.localized("The Claude account operation failed. Try again or sign in with Claude.")
    }

    static let maxSwitchesPerPrompt = 8
    private(set) var states: [UUID: State] = [:]
    private var book = ProviderAccountStore.load()
    private(set) var selectionRevision = UUID()
    @ObservationIgnored private weak var registry: ProviderRegistry?
    @ObservationIgnored private var generations: [UUID: UUID] = [:]
    @ObservationIgnored private var claudeReads: [UUID: Task<PlanLimits?, Never>] = [:]
    @ObservationIgnored private var claudeReadTail: Task<PlanLimits?, Never>?
    @ObservationIgnored private var removing: Set<UUID> = []
    /// When each account last hit its limit in a turn, so a usage read begun before that cannot clear it.
    @ObservationIgnored private var limitNotedAt: [UUID: Date] = [:]


    init(registry: ProviderRegistry) {
        self.registry = registry
        // Every supported provider lists the CLI's own login first; added here so reads never write.
        var next = book
        var added = false
        for provider in Self.supportedProviders where !book.accounts.contains(where: { $0.provider == provider && $0.isDefault }) {
            next.accounts.append(ProviderAccount(id: UUID(), provider: provider, home: nil, name: nil, email: nil, plan: nil, accountID: nil, addedAt: .now))
            added = true
        }
        if added {
            do { try commit(next) } catch { /* Keep the persisted book on failure. */ }
        }
    }

    func accounts(for provider: ProviderKind) -> [ProviderAccount] {
        guard Self.supportedProviders.contains(provider) else { return [] }
        let list = book.accounts.filter { $0.provider == provider }
        return list.filter(\.isDefault) + list.filter { !$0.isDefault }
    }

    func activeAccount(for provider: ProviderKind) -> ProviderAccount? {
        let list = accounts(for: provider)
        if provider == .claude, let selected = book.active[provider.rawValue] {
            return list.first { $0.id == selected }
        }
        return list.first { $0.id == book.active[provider.rawValue] } ?? list.first
    }

    func switchMode(for provider: ProviderKind) -> SwitchMode {
        guard Self.automaticSwitchingProviders.contains(provider) else { return .manual }
        return book.switchModes[provider.rawValue].flatMap(SwitchMode.init(rawValue:)) ?? .manual
    }

    func setSwitchMode(_ mode: SwitchMode, for provider: ProviderKind) {
        guard Self.automaticSwitchingProviders.contains(provider) else { return }
        book.switchModes[provider.rawValue] = mode.rawValue
        save()
    }

    func use(_ account: ProviderAccount) {
        guard let stored = self.account(id: account.id) else { return }
        if stored.provider == .claude {
            guard !CaptureRun.isEnabled, !stored.requiresClaudeActivation, !stored.requiresClaudeCleanup else { return }
            var next = book
            next.active[stored.provider.rawValue] = stored.id
            do { try commit(next) }
            catch { states[stored.id, default: State()].problem = Self.safeClaudeError(error); return }
            selectionRevision = UUID()
            registry?.invalidateClaudeAccountViews()
            registry?.resetPlanLimits(.claude)
            Task { [weak self] in _ = await self?.refreshClaudeAccount(stored.id) }
            return
        }
        selectionRevision = UUID()
        book.active[account.provider.rawValue] = account.id
        save()
        registry?.resetPlanLimits(account.provider)
        Task { [weak self] in
            guard let self else { return }
            await refreshAccount(account, force: true)
            guard activeAccount(for: account.provider)?.id == account.id else { return }
            registry?.refreshPlanLimits(account.provider, force: true)
            await registry?.refresh(account.provider)
            await registry?.loadCatalog(account.provider, force: true)
        }
    }

    func activateClaudeAccount(_ account: ProviderAccount) async -> String? {
        guard !CaptureRun.isEnabled else { return ClaudeCredentialError.capture.localizedDescription }
        guard let index = book.accounts.firstIndex(where: { $0.id == account.id && $0.provider == .claude }) else {
            return ClaudeAccountValidationError.authentication.localizedDescription
        }
        guard !book.accounts[index].requiresClaudeCleanup else { return ClaudeCredentialError.cleanupRequired.localizedDescription }
        var next = book
        next.accounts[index].claudeImportPending = false
        next.active[ProviderKind.claude.rawValue] = account.id
        do { try commit(next) }
        catch { return Self.safeClaudeError(error) }
        selectionRevision = UUID()
        registry?.invalidateClaudeAccountViews()
        registry?.resetPlanLimits(.claude)
        _ = await refreshClaudeAccount(account.id)
        return nil
    }

    private func defaultHome() -> String {
        ProviderAccountStore.defaultCodexHome(environment: registry?.baseEnvironment(for: .codex) ?? LoginEnvironment.current)
    }

    private func create(_ provider: ProviderKind, name: String? = nil) throws -> ProviderAccount {
        let id = UUID()
        let home = try ProviderAccountStore.makeHome(provider: provider, id: id, linkingFrom: defaultHome())
        return ProviderAccount(id: id, provider: provider, home: home, name: name, email: nil, plan: nil, accountID: nil, addedAt: .now)
    }

    func addAccount(_ provider: ProviderKind) async -> String? {
        guard Self.supportedProviders.contains(provider) else { return nil }
        if provider == .claude {
            guard !CaptureRun.isEnabled else { return ClaudeCredentialError.capture.localizedDescription }
            await LoginEnvironment.load()
            do {
                let account = try stageClaudeAccount(name: nil)
                if let error = await signInManagedClaude(account, expectedIdentities: [], allowStaged: true) {
                    if self.account(id: account.id)?.requiresClaudeActivation != true { return error }
                    do { try await cleanupClaudeAccount(account) }
                    catch { return Self.safeClaudeError(error) }
                    return error
                }
                return nil
            } catch { return Self.safeClaudeError(error) }
        }
        await LoginEnvironment.load()
        do {
            let account = try create(provider)
            book.accounts.append(account)
            save()
            if let error = await signIn(account) {
                await discard(account)
                return error
            }
            return nil
        } catch { return error.localizedDescription }
    }

    func signIn(_ account: ProviderAccount, expectedIdentities: [ClaudeAccountIdentity] = []) async -> String? {
        if account.provider == .claude {
            guard !CaptureRun.isEnabled else { return ClaudeCredentialError.capture.localizedDescription }
            guard let stored = self.account(id: account.id) else { return ClaudeAccountValidationError.authentication.localizedDescription }
            if !stored.isDefault { return await signInManagedClaude(stored, expectedIdentities: expectedIdentities) }
        }
        if let first = expectedIdentities.first, expectedIdentities.contains(where: { !first.matches($0) }) {
            return ClaudeAccountValidationError.identityChanged.localizedDescription
        }
        guard !removing.contains(account.id), let registry, book.accounts.contains(where: { $0.id == account.id }), !states[account.id, default: State()].isSigningIn else { return nil }
        if account.provider == .claude, isBusy(account) { return AppText.localized("This account is busy. Wait for its sessions and account checks to finish.") }
        if account.provider == .claude { Self.exclusive.insert(account.id) }
        defer { Self.exclusive.remove(account.id) }
        generations[account.id] = UUID()
        states[account.id, default: State()].isSigningIn = true
        defer { states[account.id]?.isSigningIn = false }
        await LoginEnvironment.load()
        guard let executable = registry.executable(for: account.provider) else {
            return String(format: AppText.localized("%@ was not found on your PATH."), account.provider.displayName)
        }
        do {
            let arguments = account.provider.loginCommand.split(whereSeparator: \.isWhitespace).dropFirst().map(String.init)
            let result = try await Shell.run(executable, arguments,
                in: account.provider == .claude ? URL(fileURLWithPath: account.home ?? LoginEnvironment.homeDirectory) : nil,
                environment: registry.environment(for: account.provider, account: account), timeout: 300)
            guard result.succeeded else { return account.provider == .claude ? AppText.localized("Claude sign-in failed. Try signing in again.") : TextCleanup.stripANSI(result.output + result.errorOutput) }
            Self.exclusive.remove(account.id)
            if account.provider == .claude { states[account.id] = State() }
            states[account.id]?.isSigningIn = false
            await refreshAccount(account, force: true)
            if account.provider == .claude, let problem = states[account.id]?.problem { return problem }
            if activeAccount(for: account.provider)?.id == account.id {
                registry.resetPlanLimits(account.provider)
                if account.provider != .claude { registry.refreshPlanLimits(account.provider, force: true) }
            }
            return nil
        } catch {
            let message = account.provider == .claude ? Self.safeClaudeError(error) : error.localizedDescription
            states[account.id]?.problem = message
            return message
        }
    }

    func rename(_ account: ProviderAccount, to name: String) {
        guard let index = book.accounts.firstIndex(where: { $0.id == account.id }) else { return }
        if account.provider == .claude {
            guard !CaptureRun.isEnabled else { return }
            var next = book
            next.accounts[index].name = name.trimmed.isEmpty ? nil : name.trimmed
            do { try commit(next) }
            catch { states[account.id, default: State()].problem = Self.safeClaudeError(error) }
        } else {
            book.accounts[index].name = name.trimmed.isEmpty ? nil : name.trimmed
            save()
        }
    }

    func remove(_ account: ProviderAccount, hasDependentChats: Bool = true) async -> String? {
        guard let stored = self.account(id: account.id), !stored.isDefault else { return nil }
        if stored.provider == .claude {
            guard !CaptureRun.isEnabled else { return ClaudeCredentialError.capture.localizedDescription }
            guard !hasDependentChats else { return AppText.localized("This account is bound to saved chats. Delete those chats before removing the account.") }
            guard !isBusy(stored) else { return AppText.localized("This account is busy. Wait for its sessions and account checks to finish.") }
            Self.exclusive.insert(stored.id)
        }
        guard states[stored.id]?.isSigningIn != true else { return nil }
        removing.insert(stored.id)
        defer { removing.remove(stored.id); Self.exclusive.remove(stored.id) }
        generations[stored.id] = nil
        if stored.provider == .claude {
            do { try await cleanupClaudeAccount(stored); return nil }
            catch { return Self.safeClaudeError(error) }
        }
        await discard(stored, signingOut: true)
        return nil
    }

    /// The book is saved before signing out or deleting the home, so a failed save leaves the
    /// account signed in and intact.
    private func discard(_ account: ProviderAccount, signingOut: Bool = false) async {
        let wasActive = activeAccount(for: account.provider)?.id == account.id
        var updated = book
        updated.accounts.removeAll { $0.id == account.id }
        if updated.active[account.provider.rawValue] == account.id {
            updated.active[account.provider.rawValue] = nil
        }
        guard ProviderAccountStore.save(updated) else { return }
        book = updated
        generations[account.id] = nil
        states[account.id] = nil
        if wasActive, let fallback = accounts(for: account.provider).first { use(fallback) }
        if signingOut, let registry, let executable = registry.executable(for: account.provider) {
            _ = try? await Shell.run(executable, ["logout"], environment: registry.environment(for: account.provider, account: account), timeout: 20)
        }
        if let home = account.home { ProviderAccountStore.removeHome(home) }
    }

    func refresh(_ provider: ProviderKind, force: Bool) async {
        if provider == .claude {
            guard !CaptureRun.isEnabled, let account = activeAccount(for: .claude) else { return }
            _ = await refreshClaudeAccount(account.id, force: force)
            return
        }
        await LoginEnvironment.load()
        await withTaskGroup(of: Void.self) { group in
            for account in accounts(for: provider) {
                group.addTask { await self.refreshAccount(account, force: force) }
            }
        }
    }

    private func refreshAccount(_ account: ProviderAccount, force: Bool) async {
        if account.provider == .claude {
            _ = await refreshClaudeAccount(account.id, force: force)
            return
        }
        guard !removing.contains(account.id), let registry, book.accounts.contains(where: { $0.id == account.id }), let executable = registry.executable(for: account.provider) else { return }
        if !force, let date = states[account.id]?.fetchedAt, Date.now.timeIntervalSince(date) < 300 { return }
        guard states[account.id]?.isSigningIn != true else { return }
        let generation = UUID()
        let startedAt = Date.now
        generations[account.id] = generation
        states[account.id, default: State()].isChecking = true
        let environment = registry.environment(for: account.provider, account: account)
        let auth = await ProviderRegistry.auth(account.provider, executable, environment)
        let limits = try? await CodexSession.readPlanLimits(executable: executable, environment: environment)
        guard generations[account.id] == generation, book.accounts.contains(where: { $0.id == account.id }) else { return }
        states[account.id]?.auth = auth
        states[account.id]?.limits = limits
        states[account.id]?.fetchedAt = .now
        states[account.id]?.isChecking = false
        updateIdentity(account)
        if let limits { receiveLimits(limits, for: account.id, startedAt: startedAt) }
    }

    private func updateIdentity(_ account: ProviderAccount) {
        guard let index = book.accounts.firstIndex(where: { $0.id == account.id }) else { return }
        if account.provider == .claude { return }
        guard let identity = ProviderAccountStore.codexIdentity(home: account.home ?? defaultHome()) else { return }
        book.accounts[index].email = identity.email
        book.accounts[index].accountID = identity.accountID
        book.accounts[index].plan = identity.plan
        save()
    }

    func importCandidates(_ provider: ProviderKind) -> [CodexImportCandidate] {
        guard provider == .codex else { return [] }
        let existing = accounts(for: provider).compactMap { ProviderAccountStore.codexIdentity(home: $0.home ?? defaultHome()) }
        return ProviderAccountStore.codexImportCandidates(defaultHome: defaultHome()).filter { candidate in
            !existing.contains { sameIdentity($0, candidate.identity) }
        }
    }

    private func sameIdentity(_ lhs: CodexIdentity, _ rhs: CodexIdentity) -> Bool {
        // One email can sign in to several workspaces; only fall back to it without account ids.
        if let left = lhs.accountID, let right = rhs.accountID {
            return left == right && (lhs.userID == nil || rhs.userID == nil || lhs.userID == rhs.userID)
        }
        guard let email = lhs.email, !email.isEmpty else { return false }
        return email.lowercased() == rhs.email?.lowercased()
    }

    func importAccounts(_ candidates: [CodexImportCandidate]) async {
        await LoginEnvironment.load()
        for candidate in candidates {
            guard importCandidates(.codex).contains(where: { $0.id == candidate.id }) else { continue }
            var created: ProviderAccount?
            do {
                let account = try create(.codex, name: candidate.label)
                created = account
                try ProviderAccountStore.importCodexCredential(candidate, into: account.home!)
                book.accounts.append(account)
                updateIdentity(account)
                save()
            } catch {
                if let home = created?.home { ProviderAccountStore.removeHome(home) }
            }
        }
        await refresh(.codex, force: true)
    }

    func importClaudeAccounts(_ candidates: [ClaudeSwapImportCandidate]) async -> [String] {
        guard !CaptureRun.isEnabled else { return [ClaudeCredentialError.capture.localizedDescription] }
        await LoginEnvironment.load()
        var results: [String] = []
        for candidate in candidates {
            let duplicate = accounts(for: .claude).contains { account in
                let sameAccount = candidate.accountID.map { $0 == account.accountID }
                    ?? (candidate.email.lowercased() == account.email?.lowercased())
                return sameAccount && candidate.organizationID == account.organizationID
            }
            if duplicate {
                results.append(String(format: AppText.localized("%@ — already saved; skipped"), candidate.email))
                continue
            }
            var created: ProviderAccount?
            defer {
                if let created { Self.exclusive.remove(created.id) }
            }
            do {
                var account = try stageClaudeAccount(name: candidate.label)
                created = account
                Self.exclusive.insert(account.id)
                account.email = candidate.email
                account.accountID = candidate.accountID
                account.organizationID = candidate.organizationID
                var stagedBook = book
                guard let stagedIndex = stagedBook.accounts.firstIndex(where: { $0.id == account.id }) else { throw ClaudeAccountValidationError.authentication }
                stagedBook.accounts[stagedIndex] = account
                try commit(stagedBook)
                guard let home = account.home else { throw ClaudeCredentialError.invalidDirectory }
                try await ClaudeAccountCredentials.offMain {
                    let credential = try ClaudeSwapImport.credential(for: candidate)
                    try ClaudeAccountCredentials.write(credential, configDirectory: home)
                    try ProviderAccountStore.writeClaudeIdentity(candidate, into: home)
                }
                account.email = candidate.email
                account.accountID = candidate.accountID
                account.organizationID = candidate.organizationID
                account.organizationName = candidate.organizationName
                account.claudeCleanupRequired = false
                var next = book
                guard let index = next.accounts.firstIndex(where: { $0.id == account.id }) else { throw ClaudeAccountValidationError.authentication }
                next.accounts[index] = account
                try commit(next)
                results.append(String(format: AppText.localized("%@ — saved; awaiting activation"), candidate.email))
            } catch {
                var failure = error
                if let created {
                    do { try await cleanupClaudeAccount(created) }
                    catch { failure = error }
                }
                results.append(String(format: AppText.localized("%@ — import failed: %@"), candidate.email, Self.safeClaudeError(failure)))
            }
        }
        return results
    }

    func refreshClaudeAccount(_ id: UUID, force: Bool = false) async -> PlanLimits? {
        guard !CaptureRun.isEnabled, let account = account(id: id), account.provider == .claude,
              !account.requiresClaudeActivation, !account.requiresClaudeCleanup,
              !removing.contains(id), states[id]?.isSigningIn != true else { return nil }
        if let task = claudeReads[id] { return await task.value }
        // Even explicit refresh shares the one-minute floor, including failures.
        if let date = states[id]?.fetchedAt,
           Date.now.timeIntervalSince(date) < (force ? 60 : 300) { return states[id]?.limits }
        guard let registry, let executable = registry.executable(for: .claude), Self.beginRead(id) else { return nil }
        let environment = registry.environment(for: .claude, account: account)
        let startedAt = Date.now
        states[id, default: State()].isChecking = true
        let previousRead = claudeReadTail
        let task = Task { @MainActor [weak self] () -> PlanLimits? in
            _ = await previousRead?.value
            let result = await PlanLimitsReader.read(.claude, executable: executable, environment: environment)
                ?? PlanLimitsReader.failure("The provider did not return usage data. The usage request may have failed or may be unsupported.")
            guard let self else { Self.endRead(id); return result }
            defer { self.claudeReads[id] = nil; Self.endRead(id) }
            guard self.account(id: id) != nil else { return nil }
            self.states[id, default: State()].limits = result
            self.states[id]?.fetchedAt = .now
            self.states[id]?.isChecking = false
            self.states[id]?.problem = result.problem
            // Stored identity is a label, never evidence of a fresh authentication check.
            if self.states[id]?.auth == nil { self.states[id]?.auth = .unknown }
            self.receiveLimits(result, for: id, startedAt: startedAt)
            return result
        }
        claudeReads[id] = task
        claudeReadTail = task
        return await task.value
    }

    private func commit(_ next: ProviderAccountBook) throws {
        do { try ProviderAccountStore.saveThrowing(next) }
        catch { throw ClaudeCredentialError.saveAccount }
        book = next
    }

    private func stageClaudeAccount(name: String?) throws -> ProviderAccount {
        guard !CaptureRun.isEnabled else { throw ClaudeCredentialError.capture }
        var account = try create(.claude, name: name)
        account.claudeImportPending = true
        account.claudeCleanupRequired = true
        var next = book
        next.accounts.append(account)
        do { try commit(next) }
        catch {
            // No credentials have been written before this durable record.
            if let home = account.home { ProviderAccountStore.removeHome(home) }
            throw error
        }
        return account
    }

    private func cleanupClaudeAccount(_ account: ProviderAccount) async throws {
        guard !CaptureRun.isEnabled else { throw ClaudeCredentialError.capture }
        guard let index = book.accounts.firstIndex(where: { $0.id == account.id }), let home = book.accounts[index].home else { return }
        var pending = book
        pending.accounts[index].claudeCleanupRequired = true
        try commit(pending)
        try await ClaudeAccountCredentials.offMain {
            try ClaudeAccountCredentials.remove(configDirectory: home)
            try ProviderAccountStore.removeHomeThrowing(home)
        }
        var next = book
        next.accounts.removeAll { $0.id == account.id }
        let selected = next.active[ProviderKind.claude.rawValue] == account.id
        if selected { next.active[ProviderKind.claude.rawValue] = nil }
        try commit(next)
        states[account.id] = nil
        ProviderRegistry.forgetClaudeIdentity(account.id)
        if selected {
            selectionRevision = UUID()
            registry?.invalidateClaudeAccountViews()
            registry?.resetPlanLimits(.claude)
        }
    }

    private func signInManagedClaude(_ account: ProviderAccount, expectedIdentities: [ClaudeAccountIdentity], allowStaged: Bool = false) async -> String? {
        guard !isBusy(account), let registry, let home = account.home else {
            return AppText.localized("This account is busy. Wait for its sessions and account checks to finish.")
        }
        if account.requiresClaudeCleanup && account.requiresClaudeActivation && !allowStaged {
            return ClaudeCredentialError.cleanupRequired.localizedDescription
        }
        var expected = expectedIdentities
        if let identity = account.claudeIdentity { expected.append(identity) }
        if let accountID = account.accountID, let organizationID = account.organizationID {
            expected.append(.init(accountID: accountID, organizationID: organizationID, email: account.email ?? ""))
        }
        if let first = expected.first, expected.contains(where: { !first.matches($0) }) {
            return ClaudeAccountValidationError.identityChanged.localizedDescription
        }
        Self.exclusive.insert(account.id)
        ProviderRegistry.forgetClaudeIdentity(account.id)
        states[account.id, default: State()].isSigningIn = true
        defer { Self.exclusive.remove(account.id); states[account.id]?.isSigningIn = false }
        await LoginEnvironment.load()
        guard let executable = registry.executable(for: .claude) else {
            return String(format: AppText.localized("%@ was not found on your PATH."), ProviderKind.claude.displayName)
        }
        var temporary: ProviderAccount?
        do {
            let staged = try stageClaudeAccount(name: AppText.localized("Claude sign-in cleanup"))
            temporary = staged
            Self.exclusive.insert(staged.id)
            states[staged.id, default: State()].isSigningIn = true
            defer { Self.exclusive.remove(staged.id); states[staged.id]?.isSigningIn = false }
            let environment = registry.environment(for: .claude, account: staged)
            let result = try await Shell.run(executable, ProviderKind.claude.loginCommand.split(whereSeparator: \.isWhitespace).dropFirst().map(String.init),
                in: URL(fileURLWithPath: staged.home!), environment: environment, timeout: 300)
            guard result.succeeded else { throw ClaudeAccountValidationError.authentication }
            let identity = try await ProviderRegistry.claudeIdentity(executable: executable, environment: environment, directory: URL(fileURLWithPath: staged.home!), signingInAccountID: staged.id)
            guard expected.allSatisfy({ $0.matches(identity) }) else { throw ClaudeAccountValidationError.identityChanged }
            let (login, snapshot, oldMetadata) = try await ClaudeAccountCredentials.offMain { () throws -> (Data?, ClaudeAccountCredentials.Snapshot, Data?) in
                (try ClaudeAccountCredentials.read(environment: environment, isManaged: true),
                 try ClaudeAccountCredentials.snapshot(configDirectory: home),
                 try ClaudeAccountCredentials.readFile(directory: home, name: ".claude.json"))
            }
            guard let login else { throw ClaudeCredentialError.missingCredential }
            var metadata = try oldMetadata.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            metadata["oauthAccount"] = ["accountUuid": identity.accountID, "organizationUuid": identity.organizationID, "emailAddress": identity.email]
            let newMetadata = try JSONSerialization.data(withJSONObject: metadata)
            let replacement = try ClaudeAccountCredentials.replacingLogin(login, in: snapshot.credential)
            guard let index = book.accounts.firstIndex(where: { $0.id == account.id }) else { throw ClaudeAccountValidationError.authentication }
            let original = book.accounts[index]
            var pending = book
            pending.accounts[index].claudeCleanupRequired = true
            try commit(pending)
            do {
                try await ClaudeAccountCredentials.offMain {
                    try ClaudeAccountCredentials.restore(.init(keychain: replacement, file: nil), configDirectory: home)
                    try ProviderAccountStore.replaceClaudeMetadata(newMetadata, home: home)
                }
                var next = book
                guard let index = next.accounts.firstIndex(where: { $0.id == account.id }) else { throw ClaudeAccountValidationError.authentication }
                var updated = original
                updated.claudeIdentity = identity
                updated.email = identity.email
                updated.accountID = identity.accountID
                updated.organizationID = identity.organizationID
                updated.claudeImportPending = false
                updated.claudeCleanupRequired = false
                next.accounts[index] = updated
                try commit(next)
            } catch {
                let failure = error
                // Keep the durable cleanup marker if either rollback operation fails.
                try await ClaudeAccountCredentials.offMain {
                    try ClaudeAccountCredentials.restore(snapshot, configDirectory: home)
                    try ProviderAccountStore.replaceClaudeMetadata(oldMetadata, home: home)
                }
                var restored = book
                guard let index = restored.accounts.firstIndex(where: { $0.id == account.id }) else { throw ClaudeAccountValidationError.authentication }
                restored.accounts[index] = original
                try commit(restored)
                throw failure
            }
            states[account.id] = State(auth: .signedIn(identity.email))
            try await cleanupClaudeAccount(staged)
            temporary = nil
            registry.invalidateClaudeAccountViews()
            registry.resetPlanLimits(.claude)
            ProviderRegistry.forgetClaudeIdentity(account.id)
            return nil
        } catch {
            var failure = error
            if let temporary {
                do { try await cleanupClaudeAccount(temporary) }
                catch { failure = error }
            }
            let message = Self.safeClaudeError(failure)
            states[account.id, default: State()].problem = message
            return message
        }
    }

    func noteLimit(_ accountID: UUID, until: Date?) {
        guard book.accounts.contains(where: { $0.id == accountID }) else { return }
        states[accountID, default: State()].exhaustedUntil = min(until ?? Date.now.addingTimeInterval(6 * 3600), Date.now.addingTimeInterval(8 * 86400))
        limitNotedAt[accountID] = .now
    }

    func isExhausted(_ accountID: UUID) -> Bool {
        states[accountID]?.exhaustedUntil.map { $0 > .now } ?? false
    }

    /// `startedAt` is when the read began; one older than the account's last limit stop
    /// cannot clear it. Reads whose start is unknown never clear a stop.
    func receiveLimits(_ limits: PlanLimits, for accountID: UUID, startedAt: Date = .distantPast) {
        guard limits.problem == nil, !limits.windows.isEmpty else { return }
        states[accountID, default: State()].limits = limits
        let exhausted = limits.windows.filter { !$0.id.contains("extra") && $0.percent >= 100 }
        if exhausted.isEmpty {
            guard startedAt > limitNotedAt[accountID] ?? .distantPast else { return }
            states[accountID]?.exhaustedUntil = nil
        } else {
            noteLimit(accountID, until: exhausted.compactMap(\.resetsAt).max())
        }
    }

    func nextAccount(for provider: ProviderKind, after currentID: UUID) -> ProviderAccount? {
        guard Self.automaticSwitchingProviders.contains(provider) else { return nil }
        return accounts(for: provider).enumerated().compactMap { index, account -> (ProviderAccount, Double, Int)? in
            guard account.id != currentID, let peak = usablePeak(account.id) else { return nil }
            return (account, peak, index)
        }.min { $0.1 == $1.1 ? $0.2 < $1.2 : $0.1 < $1.1 }?.0
    }

    /// Whether the account is signed in and has usage left, by its last read.
    func isUsable(_ accountID: UUID) -> Bool { usablePeak(accountID) != nil }

    /// The account's highest window use, or nil when it cannot take a turn. A window whose
    /// reset time has passed counts as empty, so an old full reading does not shut it out.
    private func usablePeak(_ accountID: UUID) -> Double? {
        guard let state = states[accountID], case .signedIn? = state.auth, !isExhausted(accountID) else { return nil }
        let percents = (state.limits?.windows ?? []).filter { !$0.id.contains("extra") }.map { window in
            window.resetsAt.map { $0 <= .now } == true ? 0 : window.percent
        }
        guard percents.allSatisfy({ $0 < 100 }) else { return nil }
        return percents.max() ?? .infinity
    }

    /// The signed-in account that recovers first when every account is spent, and when.
    func earliestRecovery(for provider: ProviderKind) -> (account: ProviderAccount, date: Date)? {
        accounts(for: provider).compactMap { account -> (ProviderAccount, Date)? in
            guard case .signedIn? = states[account.id]?.auth, let until = states[account.id]?.exhaustedUntil else { return nil }
            return (account, until)
        }.min { $0.1 < $1.1 }
    }

    func title(of account: ProviderAccount) -> String {
        account.name ?? account.email ?? AppText.localized(account.isDefault ? "Default account" : "New account")
    }

    private func save() { ProviderAccountStore.save(book) }
}
