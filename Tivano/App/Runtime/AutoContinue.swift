import Foundation

/// Offers to pick a chat back up once its provider's usage limit resets. A turn that stops
/// on the limit is noted by the runtime; when that turn then fails, the chat gets an offer,
/// shown as a tab on its composer, and waits only if the user says so. The choice belongs to
/// that one stop: the user can take it back, and a new limit asks again. Heads are left to
/// their leads, and only providers that report the limit reliably are offered.
@MainActor
@Observable
final class AutoContinue {
    /// The message sent to pick the task back up. Every provider gets the same one.
    static let continueMessage = "The usage limit has reset. Continue exactly where you left off and finish the task."

    /// The message sent after a chat moves to another account with usage left.
    static let switchContinueMessage = "The previous account reached its usage limit and this chat now continues on another account. Check the current state of the work first, then continue exactly where you left off and finish the task."

    /// How long past the reset time the chat waits, so the limit has really lifted.
    static let margin: TimeInterval = 60

    /// The providers whose limit signal and reset time can be trusted.
    static let supportedProviders: Set<ProviderKind> = [.claude, .codex, .omp, .commandcode]

    /// One stop on a usage limit. `resetsAt` is nil when no reset time could be found.
    struct Offer: Equatable, Sendable {
        let id: UUID
        let turnID: UUID
        let provider: ProviderKind
        let model: String?
        var resetsAt: Date?
        /// Whether the user chose to continue once the limit resets.
        var isWaiting = false
    }

    /// The chats with an open offer, read by their composer tab.
    private(set) var offers: [UUID: Offer] = [:]

    /// The chats waiting for their limit, and when they go on. Only chats whose user chose
    /// to wait are here: this is what reads as work in progress and keeps the Mac awake.
    private(set) var resumesAt: [UUID: Date] = [:] {
        didSet { app?.updateTaskSleepPrevention() }
    }

    @ObservationIgnored private weak var app: AppModel?
    /// Limits hit by the running turn: the turn and the reset time, when the provider said.
    @ObservationIgnored private var noted: [UUID: (turnID: UUID, resetsAt: Date?)] = [:]
    /// The countdown, or the reset-time lookup, of each chat's offer.
    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]

    @ObservationIgnored private var switchCounts: [UUID: Int] = [:]
    @ObservationIgnored private var pendingSwitch: Set<UUID> = []

    init(app: AppModel) {
        self.app = app
    }

    /// The provider said its usage limit is spent, during this turn of the thread.
    func noteLimit(_ threadID: UUID, turnID: UUID, resetsAt: Date?) {
        // A later note with a time beats an earlier one without.
        if let existing = noted[threadID], existing.turnID == turnID, existing.resetsAt != nil, resetsAt == nil { return }
        noted[threadID] = (turnID, resetsAt)
    }

    /// The thread's turn ended. A turn that failed on its limit opens an offer; the failure
    /// itself is reported as usual, since nothing waits until the user chooses to.
    func turnFinished(_ threadID: UUID, turnID: UUID, status: TurnStatus, continues: Bool, userStopped: Bool) {
        guard let note = noted.removeValue(forKey: threadID), note.turnID == turnID,
              status == .failed, !continues, !userStopped,
              let app, let thread = app.thread(threadID) else { return }
        clear(threadID)
        guard !thread.isHydraHead,
              Self.supportedProviders.contains(thread.provider) else { return }
        let accounts = app.providers.accounts
        let usedAccount = app.existingRuntime(for: threadID)?.codexAccountInUse
        guard ProviderAccounts.supportedProviders.contains(thread.provider),
              accounts.switchMode(for: thread.provider) == .automatic,
              switchCounts[threadID, default: 0] < ProviderAccounts.maxSwitchesPerPrompt else {
            openOffer(threadID, turnID: turnID, note: note, thread: thread)
            return
        }
        // Account states load lazily, so a chat that hits its limit before Settings was opened
        // reads them first; an account read in the last five minutes is not asked again.
        tasks[threadID] = Task { [weak self] in
            await accounts.refresh(thread.provider, force: false)
            guard let self, !Task.isCancelled else { return }
            self.tasks[threadID] = nil
            guard accounts.switchMode(for: thread.provider) == .automatic else {
                self.openOffer(threadID, turnID: turnID, note: note, thread: thread)
                return
            }
            guard !self.switchAccount(threadID, turnID: turnID, provider: thread.provider, used: usedAccount, resetsAt: note.resetsAt) else { return }
            // Every account is spent: wait for whichever recovers first, on that account.
            var offerNote = note
            if let recovery = accounts.earliestRecovery(for: thread.provider),
               recovery.date < (note.resetsAt ?? .distantFuture) {
                if accounts.activeAccount(for: thread.provider)?.id != recovery.account.id { accounts.use(recovery.account) }
                offerNote.resetsAt = recovery.date
            }
            self.openOffer(threadID, turnID: turnID, note: offerNote, thread: thread)
        }
    }

    /// Moves the chat to another signed-in account with usage left and continues it there.
    /// Returns false when no account can take over.
    private func switchAccount(_ threadID: UUID, turnID: UUID, provider: ProviderKind, used: UUID?, resetsAt: Date?) -> Bool {
        guard let app else { return false }
        let accounts = app.providers.accounts
        guard let active = accounts.activeAccount(for: provider) else { return false }
        let used = used ?? active.id
        guard let current = accounts.accounts(for: provider).first(where: { $0.id == used }),
              // Another chat may have moved to a fresh account already; follow it rather than skip past it.
              let next = active.id != used && accounts.isUsable(active.id) ? active : accounts.nextAccount(for: provider, after: used)
        else { return false }
        if next.id != active.id { accounts.use(next) }
        switchCounts[threadID, default: 0] += 1
        let message: String
        if let reset = resetsAt {
            message = String(format: AppText.localized("Switched Codex from %@ to %@: the usage limit resets at %@."), accounts.title(of: current), accounts.title(of: next), Self.format(reset))
        } else {
            message = String(format: AppText.localized("Switched Codex from %@ to %@: the usage limit was reached."), accounts.title(of: current), accounts.title(of: next))
        }
        app.runtime(for: threadID).appendNotice(.info, message)
        resumeSwitch(threadID, turnID: turnID, provider: provider)
        return true
    }

    private func openOffer(_ threadID: UUID, turnID: UUID, note: (turnID: UUID, resetsAt: Date?), thread: ChatThread) {
        let resetsAt = note.resetsAt.flatMap { UsageLimitSignal.supportsResetTime($0) ? $0 : nil }
        let offer = Offer(id: UUID(), turnID: turnID, provider: thread.provider, model: thread.model, resetsAt: resetsAt)
        guard resetsAt == nil else {
            offers[threadID] = offer
            return
        }
        // No time in the message: read the account's spent window before showing anything,
        // so the tab does not flash "no reset time" while the answer is on its way.
        tasks[threadID] = Task { [weak self] in
            let reset = await self?.readResetTime(thread.provider)
            // Clearing the offer cancels this task, so one that is not cancelled is still current.
            guard let self, !Task.isCancelled else { return }
            self.tasks[threadID] = nil
            var resolved = offer
            resolved.resetsAt = reset
            self.offers[threadID] = resolved
        }
    }

    /// The offer the chat's composer shows, if it still applies: a chat whose model changed
    /// since the stop has moved on, and the old limit is no longer its question.
    /// Read from the composer's body, so it only reads: a wait it no longer shows is
    /// cancelled by the waiting task itself (see `wait`).
    func offer(for threadID: UUID) -> Offer? {
        guard let offer = offers[threadID], applies(offer, to: threadID) else { return nil }
        return offer
    }

    private func applies(_ offer: Offer, to threadID: UUID) -> Bool {
        guard let thread = app?.thread(threadID) else { return false }
        return !thread.isArchived && thread.provider == offer.provider && thread.model == offer.model
    }

    /// The user chose to continue once the limit resets.
    func wait(_ threadID: UUID) {
        guard var offer = offer(for: threadID), let resetsAt = offer.resetsAt else { return }
        tasks[threadID]?.cancel()
        offer.isWaiting = true
        offers[threadID] = offer
        let resumeAt = resetsAt.addingTimeInterval(Self.margin)
        resumesAt[threadID] = resumeAt
        let offerID = offer.id
        tasks[threadID] = Task { [weak self] in
            // Short sleeps, measured against the wall clock each time, so a Mac that slept
            // through the reset or a clock that moved still goes on at the right moment.
            while true {
                guard !Task.isCancelled, let self,
                      let current = self.offers[threadID],
                      current.id == offerID, current.isWaiting else { return }
                // A wait the composer no longer shows (the model changed) must not run on unseen.
                guard self.applies(current, to: threadID) else {
                    self.clear(threadID)
                    return
                }
                let remaining = resumeAt.timeIntervalSinceNow
                guard remaining > 0 else { break }
                try? await Task.sleep(for: .seconds(min(remaining, 60)))
                if Task.isCancelled { return }
            }
            self?.resume(threadID, offerID: offerID)
        }
    }

    /// The user took back the choice to wait: the offer stands again.
    func stopWaiting(_ threadID: UUID) {
        guard var offer = offers[threadID], offer.isWaiting else { return }
        tasks.removeValue(forKey: threadID)?.cancel()
        offer.isWaiting = false
        offers[threadID] = offer
        resumesAt[threadID] = nil
    }

    /// The limit has reset and the user asked to continue now.
    func continueNow(_ threadID: UUID) {
        guard let app, offers[threadID] != nil else { return }
        clear(threadID)
        app.runtime(for: threadID).sendLimitContinuation(Self.continueMessage)
    }

    /// The user does not want this offer, or the chat went away.
    func dismiss(_ threadID: UUID) {
        clear(threadID)
    }

    /// A new turn opened in the chat: whatever started it, the stop is behind it now.
    func turnOpened(_ threadID: UUID) {
        if pendingSwitch.remove(threadID) == nil { switchCounts[threadID] = nil }
        guard offers[threadID] != nil || tasks[threadID] != nil else { return }
        clear(threadID)
    }

    private func resumeSwitch(_ threadID: UUID, turnID: UUID, provider: ProviderKind) {
        guard let app, let thread = app.thread(threadID), !thread.isArchived,
              thread.provider == provider, let runtime = app.existingRuntime(for: threadID),
              runtime.turns.last?.id == turnID,
              // Switching turned to Manual while the chat waited to go on: leave it stopped.
              app.providers.accounts.switchMode(for: provider) == .automatic else {
            clear(threadID)
            return
        }
        guard runtime.phase == .idle, !runtime.isReverting else {
            tasks[threadID] = Task { [weak self] in
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                self?.resumeSwitch(threadID, turnID: turnID, provider: provider)
            }
            return
        }
        clear(threadID)
        pendingSwitch.insert(threadID)
        runtime.sendLimitContinuation(Self.switchContinueMessage)
    }

    private func resume(_ threadID: UUID, offerID: UUID) {
        guard let app, let offer = offers[threadID], offer.id == offerID, offer.isWaiting else { return }
        guard applies(offer, to: threadID) else {
            clear(threadID)
            return
        }
        guard let runtime = app.existingRuntime(for: threadID) else {
            clear(threadID)
            return
        }
        // A rewind can temporarily block sending without superseding the failed turn.
        guard runtime.phase == .idle, !runtime.isReverting else {
            tasks[threadID] = Task { [weak self] in
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                self?.resume(threadID, offerID: offerID)
            }
            return
        }
        // The chat moved on while it waited: nothing to continue.
        guard runtime.turns.last?.id == offer.turnID else {
            clear(threadID)
            return
        }
        clear(threadID)
        // The account chosen when the wait began may have been swapped since; go on with one that has usage left.
        let accounts = app.providers.accounts
        if accounts.switchMode(for: offer.provider) == .automatic,
           let active = accounts.activeAccount(for: offer.provider), !accounts.isUsable(active.id),
           let next = accounts.nextAccount(for: offer.provider, after: active.id) {
            accounts.use(next)
        }
        runtime.sendLimitContinuation(Self.continueMessage)
    }

    private func clear(_ threadID: UUID) {
        tasks.removeValue(forKey: threadID)?.cancel()
        offers[threadID] = nil
        if resumesAt[threadID] != nil { resumesAt[threadID] = nil }
    }

    /// The reset time of the account's most-spent window, read fresh.
    private func readResetTime(_ provider: ProviderKind) async -> Date? {
        guard let app, PlanLimitsReader.exposesLimits(provider) else { return nil }
        let limits: PlanLimits?
        if provider.isAPIKeyBased {
            let apiKey = app.settings.apiKey(for: provider)
            guard !apiKey.isEmpty else { return nil }
            limits = await PlanLimitsReader.read(provider, apiKey: apiKey)
        } else {
            guard let executable = app.providers.executable(for: provider) else { return nil }
            limits = await PlanLimitsReader.read(provider, executable: executable, environment: app.providers.environment(for: provider))
        }
        var spent: PlanLimits.Window?
        for window in limits?.windows ?? [] {
            guard let resetsAt = window.resetsAt, UsageLimitSignal.supportsResetTime(resetsAt) else { continue }
            if spent == nil || window.percent > spent!.percent { spent = window }
        }
        guard let spent, spent.percent >= 95 else { return nil }
        return spent.resetsAt
    }

    #if DEBUG
    /// Opens an offer without a stop behind it, for `UsageLimitPreview`.
    func preview(_ threadID: UUID, resetsAt: Date?, waiting: Bool) {
        guard let thread = app?.thread(threadID) else { return }
        let turnID = app?.existingRuntime(for: threadID)?.turns.last?.id ?? UUID()
        offers[threadID] = Offer(id: UUID(), turnID: turnID, provider: thread.provider, model: thread.model, resetsAt: resetsAt)
        if waiting { wait(threadID) }
    }
    #endif

    /// The reset time as the tab prints it; the formatter lives with the signal so provider sessions can use it too.
    static func format(_ date: Date) -> String { UsageLimitSignal.format(date) }
}
