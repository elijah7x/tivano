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
    }
    static let supportedProviders: Set<ProviderKind> = [.codex]
    static let maxSwitchesPerPrompt = 8
    private(set) var states: [UUID: State] = [:]
    private var book = ProviderAccountStore.load()
    @ObservationIgnored private weak var registry: ProviderRegistry?
    @ObservationIgnored private var generations: [UUID: UUID] = [:]
    @ObservationIgnored private var removing: Set<UUID> = []
    /// When each account last hit its limit in a turn, so a usage read begun before that cannot clear it.
    @ObservationIgnored private var limitNotedAt: [UUID: Date] = [:]


    init(registry: ProviderRegistry) {
        self.registry = registry
        // Every supported provider lists the CLI's own login first; added here so reads never write.
        var added = false
        for provider in Self.supportedProviders where !book.accounts.contains(where: { $0.provider == provider && $0.isDefault }) {
            book.accounts.append(ProviderAccount(id: UUID(), provider: provider, home: nil, name: nil, email: nil, plan: nil, accountID: nil, addedAt: .now))
            added = true
        }
        if added { save() }
    }

    func accounts(for provider: ProviderKind) -> [ProviderAccount] {
        guard Self.supportedProviders.contains(provider) else { return [] }
        let list = book.accounts.filter { $0.provider == provider }
        return list.filter(\.isDefault) + list.filter { !$0.isDefault }
    }

    func activeAccount(for provider: ProviderKind) -> ProviderAccount? {
        let list = accounts(for: provider)
        return list.first { $0.id == book.active[provider.rawValue] } ?? list.first
    }

    func switchMode(for provider: ProviderKind) -> SwitchMode {
        book.switchModes[provider.rawValue].flatMap(SwitchMode.init(rawValue:)) ?? .manual
    }

    func setSwitchMode(_ mode: SwitchMode, for provider: ProviderKind) {
        guard Self.supportedProviders.contains(provider) else { return }
        book.switchModes[provider.rawValue] = mode.rawValue
        save()
    }

    func use(_ account: ProviderAccount) {
        guard book.accounts.contains(where: { $0.id == account.id }) else { return }
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

    func signIn(_ account: ProviderAccount) async -> String? {
        guard !removing.contains(account.id), let registry, book.accounts.contains(where: { $0.id == account.id }), !states[account.id, default: State()].isSigningIn else { return nil }
        generations[account.id] = UUID()
        states[account.id, default: State()].isSigningIn = true
        defer { states[account.id]?.isSigningIn = false }
        await LoginEnvironment.load()
        guard let executable = registry.executable(for: account.provider) else {
            return ResetCreditError.codexUnavailable.localizedDescription
        }
        do {
            let arguments = account.provider.loginCommand.split(whereSeparator: \.isWhitespace).dropFirst().map(String.init)
            let result = try await Shell.run(executable, arguments, environment: registry.environment(for: account.provider, account: account), timeout: 300)
            guard result.succeeded else { return TextCleanup.stripANSI(result.output + result.errorOutput) }
            await refreshAccount(account, force: true)
            if activeAccount(for: account.provider)?.id == account.id {
                registry.resetPlanLimits(account.provider)
                registry.refreshPlanLimits(account.provider, force: true)
            }
            return nil
        } catch { return error.localizedDescription }
    }

    func rename(_ account: ProviderAccount, to name: String) {
        guard let index = book.accounts.firstIndex(where: { $0.id == account.id }) else { return }
        book.accounts[index].name = name.trimmed.isEmpty ? nil : name.trimmed
        save()
    }

    func remove(_ account: ProviderAccount) async {
        guard let stored = book.accounts.first(where: { $0.id == account.id }), !stored.isDefault, states[account.id]?.isSigningIn != true else { return }
        removing.insert(account.id)
        defer { removing.remove(account.id) }
        await discard(stored, signingOut: true)
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
        await LoginEnvironment.load()
        await withTaskGroup(of: Void.self) { group in
            for account in accounts(for: provider) {
                group.addTask { await self.refreshAccount(account, force: force) }
            }
        }
    }

    private func refreshAccount(_ account: ProviderAccount, force: Bool) async {
        guard !removing.contains(account.id), let registry, book.accounts.contains(where: { $0.id == account.id }), let executable = registry.executable(for: account.provider) else { return }
        if !force, let date = states[account.id]?.fetchedAt, Date.now.timeIntervalSince(date) < 300 { return }
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
        guard let index = book.accounts.firstIndex(where: { $0.id == account.id }), let identity = ProviderAccountStore.codexIdentity(home: account.home ?? defaultHome()) else { return }
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
        accounts(for: provider).enumerated().compactMap { index, account -> (ProviderAccount, Double, Int)? in
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
