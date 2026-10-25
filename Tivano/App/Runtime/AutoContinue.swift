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
              let app, let thread = app.thread(threadID), !thread.isHydraHead,
              Self.supportedProviders.contains(thread.provider) else { return }
        clear(threadID)
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
    func offer(for threadID: UUID) -> Offer? {
        guard let offer = offers[threadID], let thread = app?.thread(threadID),
              !thread.isArchived, thread.model == offer.model else { return nil }
        return offer
    }

    /// The user chose to continue once the limit resets.
    func wait(_ threadID: UUID) {
        guard var offer = offers[threadID], let resetsAt = offer.resetsAt else { return }
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
        guard offers[threadID] != nil || tasks[threadID] != nil else { return }
        clear(threadID)
    }

    private func resume(_ threadID: UUID, offerID: UUID) {
        guard let app, let offer = offers[threadID], offer.id == offerID, offer.isWaiting else { return }
        clear(threadID)
        // The chat moved on while it waited: nothing to continue.
        guard let thread = app.thread(threadID), !thread.isArchived, thread.model == offer.model,
              let runtime = app.existingRuntime(for: threadID), !runtime.isRunning,
              runtime.turns.last?.id == offer.turnID else { return }
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
