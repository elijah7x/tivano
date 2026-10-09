import AppKit
import Foundation
import SwiftUI

/// One timeline row. A class, so a streaming row redraws without re-diffing the whole thread.
@MainActor
@Observable
final class TimelineEntry: Identifiable {
    enum Kind {
        case user
        case assistant
        case reasoning
        case tool
        case plan
        case todos
        case notice
        case turnEnd
    }

    let id: String
    /// Fixed for the row's lifetime, so grouping never observes streaming content.
    let kind: Kind
    let turnID: UUID?
    var item: TimelineItem {
        didSet { if oldValue != item { onChange?() } }
    }
    @ObservationIgnored var onChange: (() -> Void)?

    init(_ item: TimelineItem) {
        id = item.id
        turnID = item.turnID
        kind = switch item.content {
        case .user: .user
        case .assistant: .assistant
        case .reasoning: .reasoning
        case .tool: .tool
        case .plan: .plan
        case .todos: .todos
        case .notice: .notice
        case .turnEnd: .turnEnd
        }
        self.item = item
    }
}

/// Entries compare by identity: a row observes its entry's content itself, so the same
/// object always means the same row, and a rebuilt timeline can skip the rows whose
/// entries it already shows.
extension TimelineEntry: Equatable {
    nonisolated static func == (lhs: TimelineEntry, rhs: TimelineEntry) -> Bool {
        lhs === rhs
    }
}

/// A message from earlier in the chat that the next message talks about: shown as a
/// chip in the chat box, sent ahead of the typed words as a quote.
struct ReplyQuote: Identifiable, Equatable, Sendable {
    var id = UUID()
    var text: String

    var excerpt: String {
        guard let line = text.split(separator: "\n", omittingEmptySubsequences: false).map({ $0.trimmingCharacters(in: .whitespaces) }).first(where: { !$0.isEmpty }) else { return "" }
        let collapsed = line.split(omittingEmptySubsequences: true, whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard collapsed.count > 72 else { return collapsed }
        return String(collapsed.prefix(72)) + "…"
    }
}

extension ReplyQuote {
    /// A sent message read back into the quotes it led with and the words after them,
    /// the reverse of `ComposerDraft.outgoingText`: each `> ` block up to a blank line
    /// that no further `>` line follows. A leading slash command stays with the words.
    /// A message with no leading quote comes back whole.
    nonisolated static func peel(_ text: String) -> (quotes: [ReplyQuote], body: String) {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var command: String?
        if let first = lines.first, first.hasPrefix("/"), lines.count > 2, lines[1].isEmpty, lines[2].hasPrefix(">") {
            command = first
            lines.removeFirst(2)
        }
        var quotes: [ReplyQuote] = []
        var index = 0
        while index < lines.count, lines[index].hasPrefix(">") {
            var block: [String] = []
            while index < lines.count, lines[index].hasPrefix(">") {
                var line = lines[index].dropFirst()
                if line.hasPrefix(" ") { line = line.dropFirst() }
                block.append(String(line))
                index += 1
            }
            quotes.append(ReplyQuote(text: block.joined(separator: "\n")))
            // One blank line separates a block from the next; a blank line before the words stays for the trim below.
            if index + 1 < lines.count, lines[index].isEmpty, lines[index + 1].hasPrefix(">") {
                index += 1
            }
        }
        guard !quotes.isEmpty else { return ([], text) }
        var body = lines[index...].joined(separator: "\n")
        while body.hasPrefix("\n") { body.removeFirst() }
        if let command { body = body.isEmpty ? command : command + " " + body }
        return (quotes, body)
    }
}

/// The slash command or skill the message leads with, picked from the suggestions:
/// a chip in the chat box, the first word of what goes out.
struct DraftCommand: Equatable, Sendable {
    var name: String
    var detail: String
    var isBuiltIn: Bool
}

struct ComposerDraft: Equatable {
    var text = ""
    var attachments: [Attachment] = []
    var quotes: [ReplyQuote] = []
    var command: DraftCommand? = nil

    var isEmpty: Bool {
        attachments.isEmpty && command == nil && !text.contains { !$0.isWhitespace }
    }

    /// What actually goes out: every quote as a markdown blockquote, a blank line, then
    /// the typed words.
    var outgoingText: String {
        let body: String = {
            guard !quotes.isEmpty else { return text }
            let blocks = quotes.map { quote in
                quote.text.split(separator: "\n", omittingEmptySubsequences: false).map { $0.isEmpty ? ">" : "> " + $0 }.joined(separator: "\n")
            }
            return blocks.joined(separator: "\n\n") + "\n\n" + text
        }()
        guard let command else { return body }
        let head = "/\(command.name)"
        if body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return head }
        if quotes.isEmpty { return head + " " + body }
        return head + "\n\n" + body
    }
}

/// A prompt mid-edit (a queued follow-up, or a message already sent): which one, and its
/// text and files as edited so far. A class, so the rows watching which prompt is open
/// never re-render on keystrokes.
@MainActor
@Observable
final class PromptEdit {
    let id: UUID
    var text: String
    var attachments: [Attachment]

    init(id: UUID, text: String, attachments: [Attachment]) {
        self.id = id
        self.text = text
        self.attachments = attachments
    }

    var isEmpty: Bool {
        attachments.isEmpty && !text.contains { !$0.isWhitespace }
    }
}

enum RuntimePhase: Equatable {
    case idle
    case starting
    case running
}

/// Owns a thread's live state: its timeline, its provider session and its pending requests.
@MainActor
@Observable
final class ThreadRuntime {
    let threadID: UUID

    private(set) var entries: [TimelineEntry] = [] {
        didSet {
            let previous = Set(oldValue.map(\.id))
            let current = Set(entries.map(\.id))
            for entry in oldValue where !current.contains(entry.id) { markTurnDirty(entry.turnID) }
            for entry in entries where !previous.contains(entry.id) {
                entry.onChange = { [weak self, weak entry] in
                    guard let self, let entry else { return }
                    self.markTurnDirty(entry.turnID)
                }
                markTurnDirty(entry.turnID)
            }
        }
    }
    private(set) var turns: [TurnRecord] = [] {
        // A turn leaving the thread (reverted) takes any edit of its message, and its
        // cached diff, with it.
        didSet {
            let previous = Dictionary(oldValue.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
            for turn in turns where previous[turn.id] != turn { markTurnDirty(turn.id) }
            if let edit = messageEdit, !turns.contains(where: { $0.id == edit.id }) { messageEdit = nil }
            if turns.count < oldValue.count {
                let kept = Set(turns.map(\.id))
                for turn in oldValue where !kept.contains(turn.id) { turnDiffs.removeValue(for: turn.id) }
            }
        }
    }
    private(set) var usage: ContextUsage?
    /// Forwarded context from another thread, kept with the thread's history rather than
    /// as a message: the source's prompt goes out ahead of the first ordinary message
    /// (see `startTurn`), and never becomes part of the user's own message or draft.
    private(set) var continuation: ThreadContinuation?
    private(set) var phase: RuntimePhase = .idle
    private(set) var isReverting = false
    private(set) var approvals: [ApprovalRequest] = []
    private(set) var questions: [QuestionRequest] = []
    private(set) var backgroundTasks: [String] = []
    private(set) var turnStartedAt: Date?
    /// Bumped whenever the thread's files may differ from what the last diff saw. The diff
    /// cache and the change stats are keyed by it, so the entries of an old revision are
    /// unreachable and go with it rather than lingering until 64 newer ones push them out.
    private(set) var diffRevision = 0 {
        didSet {
            revisionDiffs = RecentCache(limit: 4)
            changeStatsRevision = nil
        }
    }
    /// Queued steering prompts. Enqueued while a turn runs, each one is sent as a
    /// direct user chat message once the running turn finishes, in order.
    /// True from init until a history that was not prefetched has been decoded and installed.
    private(set) var isLoadingHistory = false
        private(set) var followUps: [FollowUpPrompt] = [] {
        // A follow-up leaving the queue (sent, deleted) takes any edit of it with it.
        didSet {
            if let edit = followUpEdit, !followUps.contains(where: { $0.id == edit.id }) { followUpEdit = nil }
        }
    }
    private(set) var hydraMerges: [HydraMergeRecord] = []
    /// The queued follow-up being edited, with the edit so far. Lives on the thread rather
    /// than in the editor, so leaving the thread mid-edit and coming back finds the editor
    /// open where it was left.
    var followUpEdit: PromptEdit?
    /// Whether the queue tab's rows are folded away under its title. Lives on the thread
    /// like `followUpEdit` does: the tab leaves the screen whenever the queue empties, and
    /// a fold the reader set must not spring back open on the next queued prompt.
    var followUpsCollapsed = false

    /// Counts the turns that start on their own — a queued follow-up, a head's report, the
    /// budget note — rather than on a message the reader just sent. The timeline compares it
    /// with the value it last saw, so an unattended turn never drags a reader who scrolled up
    /// down to the end. Never observed: the timeline reads it directly.
    @ObservationIgnored private(set) var autoStartedTurnToken = 0
    /// The sent message being edited (by its turn), the same way.
    var messageEdit: PromptEdit?

    var draft = ComposerDraft() {
        didSet {
            let isEmpty = draft.isEmpty
            if isEmpty != draftIsEmpty { draftIsEmpty = isEmpty }
        }
    }
    /// `draft.isEmpty`, flipped only when it changes: the menu bar's commands read this
    /// rather than the draft, so a keystroke never re-evaluates the command tree.
    private(set) var draftIsEmpty = true
    var isTerminalVisible = false {
        // Opened, the terminal takes the keyboard (see `TerminalHost`); a thread switched to
        // with its terminal already open leaves the keyboard where it is.
        didSet { if isTerminalVisible, !oldValue { terminalWantsFocus = true } }
    }
    @ObservationIgnored var terminalWantsFocus = false
    /// True while the terminal's divider is held: the pane's height follows the pointer, and the chat's panels follow it with no spring until it is let go.
    var isTerminalResizing = false
    var isDiffVisible = false
    /// Which corner of the chat pane the helper panel this thread spawned sits in.
    var subagentPanelDock: PanelDockCorner = .bottomTrailing
    /// The same for the Hydra panel.
    var hydraPanelDock: PanelDockCorner = .bottomTrailing
    /// The head whose timeline the Hydra panel shows.
    var hydraSelectedHeadID: UUID?
    /// The head popped out of the Hydra panel into a second panel of its own, if any, and
    /// the corner that panel sits in.
    var hydraPoppedHeadID: UUID?
    var hydraPoppedPanelDock: PanelDockCorner = .bottomLeading
    /// Heads whose automatic panel the user closed, so they stay in the team panel while
    /// the others fill the room.
    var hydraAutoPopHeld: Set<UUID> = []
    /// The order the user gave the panels inside their corners by dragging; a panel not
    /// listed comes after the listed ones, in the built-in order: helper, team, popped
    /// head, usage, heads popped out automatically.
    var panelStackOrder: [FloatingPanelID] = []
    /// Heads whose automatic panel the user dragged: they keep that corner and count
    /// against its room.
    var hydraAutoPanelDocks: [UUID: PanelDockCorner] = [:]
    /// The Hydra panel was dismissed; the next head to start brings it back.
    var isHydraPanelHidden = false
    /// Heads by the tool row that stands for them in this timeline, so the row can show
    /// who was sent out.
    private(set) var hydraToolHeads: [String: UUID] = [:]
    /// Heads by the provider's own id for them, for the events that come from inside them.
    @ObservationIgnored private var pendingNativeSpend: [String: [TokenSpend]] = [:]
    @ObservationIgnored private var hydraNativeHeads: [String: UUID] = [:]
    /// Reports from Tivano-run heads waiting for the lead to be idle.
    @ObservationIgnored private var hydraPendingReports: [HydraReport] = []
    /// The reports' turn is on its way (see `flushHydraReports`): a head finishing in the
    /// meantime joins it rather than starting a turn of its own.
    @ObservationIgnored private var hydraFlushScheduled = false
    /// The landing under way in this lead's checkout (see `AppModel.landHydraHead`); the
    /// next head's waits behind it, so two never write the same files at once.
    @ObservationIgnored var hydraLanding: Task<Void, Never>?
    /// Delegations still in flight: the heads of each batch report together.
    @ObservationIgnored private var hydraBatches: [UUID: HydraBatch] = [:]
    /// Delegated tasks past the pair's limit, sent out as heads finish.
    @ObservationIgnored private var hydraWaiting: [(delegation: HydraDelegation, batchID: UUID, queuedAt: Date)] = [] {
        didSet { hydraWaitingCount = hydraWaiting.count }
    }
    /// How many delegated tasks wait for a head to finish before they go out, for the
    /// heads popover to say so: a team held to the cap is not a team that lost its tail.
    private(set) var hydraWaitingCount = 0
    /// The per-request budgets behind a lead's delegation blocks: rounds of heads gone
    /// out, refusals given a turn of their own, and a dropped block's notice waiting to
    /// ride on the lead's next turn. A message of the user's own starts the count over;
    /// a turn carrying head reports or a refusal notice continues the same request.
    @ObservationIgnored private var hydraBudget = HydraDelegationBudget()
    /// The delegation block being read as the reply streams: which turn and row it
    /// belongs to, the batch its heads go out under, and how many entries have gone
    /// out so far. One block per turn: the first row with one claims it.
    @ObservationIgnored private var hydraStream: (turnID: UUID, entryID: String, batchID: UUID, sent: Int)?
    /// The reader holding that block's place between flushes (see
    /// `HydraDelegationStreamParser`). Reset wherever `hydraStream` is, so the next block is
    /// read by a parser that starts where the block does.
    @ObservationIgnored private var delegationParser: HydraDelegationStreamParser?
    /// A Tivano-run head's time for one turn (see `HydraBudget`): past it, the head is
    /// stopped and its next turn is its report.
    @ObservationIgnored private var headBudget: Task<Void, Never>?
    @ObservationIgnored private var headBudgetSpent = false
    @ObservationIgnored private var headReportsNext = false
    /// The team's finished work is on its way to the remote (see `AppModel.autoMergeHydraWork`).
    var isHydraMerging = false
    /// This chat's finished work is waiting for another chat's merge to finish, and goes
    /// right after it (see `AppModel.autoMergeHydraWork`).
    var isHydraMergeQueued = false
    /// A quiet retry of a merge that failed in a way that clears by itself is scheduled.
    var hasHydraMergeRetryPending = false
    /// What the merge is doing right now, in words, for the timeline: gathering the
    /// team's files, writing the commit, pushing, opening the merge request, merging.
    var hydraMergeStage: String?
    /// The stage under way, for the pill's track of dots (see `HydraMergeStage`); nil
    /// while no merge runs.
    var hydraMergeStep: HydraMergeStage?
    /// When the merge under way began, so the timeline can show how long it has been at it.
    var hydraMergeStartedAt: Date?
    /// The id the merge's outcome note will land under, chosen when the merge starts. The
    /// timeline draws its merging pill as the block with this id, so the note takes the
    /// pill's place under the same identity and the pill morphs into the merged report
    /// rather than being replaced (see `DisplayBlock.merging`).
    var hydraMergeNoteID: String?
    /// A native head's progress while it runs (its provider's note, its tool count, its
    /// spend), kept here rather than on the thread record: the provider reports it many
    /// times a second, and a write to a thread re-renders everything that lists threads.
    /// Only the panel row that shows this head follows these; they land on the record
    /// once the head finishes (see `AppModel.finishHydraHead`).
    var hydraActivity: String?
    var hydraToolCalls = 0
    var hydraTokens = 0
    /// When the head last did anything (a tool, a word of its reply or its reasoning),
    /// and how many file edits its tools have made: what the watchdog reads to tell a
    /// head that is thinking from one that has stalled (see `AppModel.startHydraWatchdog`).
    /// Not observed: it moves with every flush of every head, and the one view that
    /// reads it (the lead's working pill) is redrawn by the watchdog's label instead.
    @ObservationIgnored var hydraLastEventAt: Date?
    var hydraEditCount = 0
    /// How long the head has been quiet, in seconds; zero before it has done anything.
    var hydraIdleSeconds: TimeInterval { hydraLastEventAt.map { Date.now.timeIntervalSince($0) } ?? 0 }

    private struct HydraBatch {
        var pending: Set<UUID>
        var reports: [HydraReport] = []
    }
    var diffSelection: UUID?
    /// The view the changes popover should open on: a tool row's label, a turn's Review
    /// button, or nil for the changes tab. Held weakly so a row that leaves the screen
    /// never keeps a view alive.
    @ObservationIgnored var diffAnchor: WeakView?
    /// The side of `diffAnchor` the popover hangs from. Anchors are plain, unflipped
    /// views, so `.minY` is below (a tool row, as its chevron promises) and `.maxY` is
    /// above (a Review button, at the foot of its turn).
    @ObservationIgnored var diffAnchorEdge: NSRectEdge = .maxY
    /// Bumped by `showDiff(on:edge:turn:focusEdits:)`, so the popover moves to the new
    /// anchor even when it is already open somewhere else.
    private(set) var diffOpenRequest = 0
    /// The edits a tapped tool row asked to see, patches included. The popover leaves
    /// their cards expanded and scrolls to the first of them, and falls back to a patch
    /// when the turn's diff has nothing for it; empty for the tab and the Review button,
    /// which open the whole selection.
    private(set) var diffFocusEdits: [FileEdit] = []
    /// Bumped whenever `diffFocusEdits` changes, so the popover reloads its file list
    /// even when a second row names the same file with a different patch.
    private(set) var diffFocusRevision = 0

    /// Opens the changes popover on `anchor` (a tool row or a Review button), hanging
    /// from its `edge`, showing `turn`'s changes, or the whole thread's for nil.
    /// `focusEdits` are the tapped row's own edits, so the file it reports is what the
    /// popover opens on even when the turn's diff cannot show it yet.
    func showDiff(on anchor: NSView, edge: NSRectEdge = .maxY, turn: UUID?, focusEdits: [FileEdit] = []) {
        diffAnchor = WeakView(anchor)
        diffAnchorEdge = edge
        if diffSelection != turn { diffSelection = turn }
        setDiffFocus(focusEdits)
        if !isDiffVisible { isDiffVisible = true }
        diffOpenRequest += 1
    }

    /// Drops the edits a tapped tool row focused, so the openers that show a whole
    /// selection (the changes tab, ⌘D) never open on some earlier row's file.
    func clearDiffFocus() {
        setDiffFocus([])
    }

    private func setDiffFocus(_ edits: [FileEdit]) {
        let focus = edits.filter { !$0.path.isEmpty }
        guard focus != diffFocusEdits else { return }
        diffFocusEdits = focus
        diffFocusRevision += 1
    }

    /// The changes tab, the toolbar button, ⌘D and the palette: they show the whole
    /// selection, so any file a tapped tool row focused is dropped first and the
    /// popover opens at the top of the list rather than on some earlier row's file.
    func toggleDiff() {
        clearDiffFocus()
        if !isDiffVisible { diffAnchor = nil }
        isDiffVisible.toggle()
    }

    @ObservationIgnored private weak var app: AppModel?
    @ObservationIgnored private var session: (any ProviderSession)?
    @ObservationIgnored private var sessionsAwaitingReplacement: [any ProviderSession] = []
    @ObservationIgnored private var crashInterruptedTurnIDs: Set<UUID> = []
    @ObservationIgnored private var attemptedCodexCrashRecovery = false
    @ObservationIgnored private var providerHistoryOperation: Task<Void, Never>?
    /// A session being started ahead of the first message (`warmSession`).
    @ObservationIgnored private var warmup: Task<Void, Never>?
    /// The session's ID while no message has gone through it. The provider has nothing
    /// to resume under such an ID: a session warmed while the first message was typed and
    /// replaced before it went (a setting changed the launch) was resumed as "no
    /// conversation found", and the chat was told its agent had lost a conversation that
    /// never was. So the ID reaches the thread with the first message, and a session
    /// replaced before then is followed by one that starts fresh.
    @ObservationIgnored private var unsentSessionID: String?
    @ObservationIgnored private var lastFlushAt = ContinuousClock.now - .seconds(1)
    @ObservationIgnored private var sessionSignature: SessionSignature?
    /// Whether the anti-slop policy has already gone out as a fallback prefix on this
    /// session. The providers that cannot keep it in a system prompt get it once, with
    /// the first turn that carries text; a restarted, retried or explicitly compacted
    /// session takes it again (see `releaseSession`, `compact`).
    @ObservationIgnored private var antiSlopFallbackSent = false
    /// Whether the forwarded continuation has already gone out as a prefix on this
    /// session. Delivered once, with the first ordinary message that goes through the
    /// session; a restarted, retried or explicitly compacted session takes it again
    /// (see `releaseSession`, `compact`).
    @ObservationIgnored private var continuationSent = false
    /// Which session the runtime is listening to. Every session made carries the count it
    /// was made under, and its events are dropped once the count has moved on: a CLI that
    /// closes long after it was let go used to end the turn that replaced it, take down
    /// the live session with it and leave its process running with nothing holding it.
    @ObservationIgnored private var sessionEpoch = 0
    /// Whether `ensureSession` is waiting on a session's `start()`. A session that exits
    /// then is reported by that throwing, and `ensureSession` starts over where it can,
    /// so its exit event neither lets the session go nor fails the turn.
    @ObservationIgnored private var isStartingSession = false
    /// Claude started a turn of its own (a background task it launched finished) while the
    /// previous turn was still being finalized: its events wait here and are replayed into
    /// a turn of their own once `finishTurn` is done with the old one.
    @ObservationIgnored private var opensTurnAfterFinish = false
    @ObservationIgnored private var deferredBackgroundTurnEvents: [ProviderEvent] = []
    /// The turn being finalized, claimed before the first suspension: a completion and an
    /// exit can both arrive for one turn, and the second must not finalize it again.
    @ObservationIgnored private var finishingTurnID: UUID?
    @ObservationIgnored private var entryIndex: [String: TimelineEntry] = [:]
    @ObservationIgnored private var pendingDeltas: [String: PendingDelta] = [:]
    @ObservationIgnored private var flushTask: Task<Void, Never>?
    @ObservationIgnored private var streamByteLengths: [String: Int] = [:]
    @ObservationIgnored private var pendingFlushBytes = 0
    /// Bumped by anything that changes what `saveNow` writes, so the periodic save
    /// during a quiet stretch finds nothing new and does no work.
    @ObservationIgnored private var saveRevision = 0
    @ObservationIgnored private var lastSavedRevision = 0
    @ObservationIgnored private var turnRevisions: [UUID: UInt64] = [:]
    @ObservationIgnored private var savedTurnRevisions: [UUID: UInt64] = [:]
    @ObservationIgnored private var nextTurnRevision: UInt64 = 0
    @ObservationIgnored private var itemPositions: [String: Double] = [:]
    @ObservationIgnored private var installingHistory = false

    private func markTurnDirty(_ id: UUID?) {
        guard !installingHistory else { return }
        saveRevision += 1
        guard let id else { return }
        nextTurnRevision &+= 1
        turnRevisions[id] = nextTurnRevision
    }

    @ObservationIgnored private var saveRetryTask: Task<Void, Never>?
    @ObservationIgnored private var saveFailures = 0
    @ObservationIgnored private var saveNoticeID: String?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var historyLoad: Task<Void, Never>?
    @ObservationIgnored private var persistenceEnabled = true
    @ObservationIgnored private var currentTurnID: UUID?
    /// The turn being closed (see `finishTurn`): its id is taken out of `currentTurnID`
    /// first, and its diffs are then waited for. An event landing in that wait (a late
    /// tool result, a notice, a Hydra note) still belongs to the turn; filed under no turn
    /// it split the turn's rows into two blocks with one id, and the second, the running
    /// tail, stopped drawing.
    @ObservationIgnored private var closingTurnID: UUID?
    /// The pair whose heads-provider fallback was already noted in this timeline.
    @ObservationIgnored private var hydraFallbackNoted: UUID?
    /// The turn a new row is filed under.
    private var turnIDForNewRows: UUID? { currentTurnID ?? closingTurnID }
    /// The provider's latest diff and resume anchor for the running turn. Codex re-sends its
    /// whole turn diff on every file change and Claude names an anchor per message; both land
    /// on the turn record once, as the turn finishes, since every write to `turns` re-runs
    /// the whole timeline body.
    @ObservationIgnored private var currentProviderDiff: String?
    @ObservationIgnored private var currentProviderAnchor: String?
    @ObservationIgnored private var interruptWatchdog: Task<Void, Never>?
    /// The CLI version a message was last sent again at after the CLI said it was too old
    /// for the model, per provider: one resend per version, so a CLI that is still too old
    /// after its update says so rather than trying again forever.
    @ObservationIgnored private var cliResendVersions: [ProviderKind: String] = [:]
    /// The tree each running command tool is diffed from, by tool id, and
    /// the diffs being settled as they finish (see `watchCommand`).
    @ObservationIgnored private var commandTrees: [String: Task<String?, Never>] = [:]
    @ObservationIgnored private var commandStarts: [String: Date] = [:]
    @ObservationIgnored private var commandSettles: [String: Task<Void, Never>] = [:]
    /// Snapshots run one after another: each is several git processes over the whole
    /// checkout, and a turn can have many commands in flight at once.
    @ObservationIgnored private var treeCaptures: Task<String?, Never>?
    /// The tree a command left behind, with the count below as it stood when it was taken.
    /// While that count has not moved, nothing can have changed the working tree since, so
    /// the next command takes it as its own "before" and snapshots nothing.
    @ObservationIgnored private var settledTree: (tree: String, epoch: Int)?
    /// The last tree any command of this turn finished capturing, whatever ran since: a
    /// command starting later than that is diffed from it when no settled tree stands,
    /// rather than from a snapshot started alongside it that the command could outrun.
    @ObservationIgnored private var latestTree: String?
    /// Bumped by anything that could write a file: a command starting, a tool that edits.
    @ObservationIgnored private var treeEpoch = 0
    /// The row a turn's todo list lives on, so each update finds it without scanning the
    /// timeline.
    @ObservationIgnored private var todosEntryID: String?
    /// Paths the lead's native heads changed during this turn. Their tools arrive as
    /// `.agentEvent` and are rehearsed onto the heads' own timelines, so without this the
    /// lead's turn would count none of their work and a merge would take a fraction of it.
    @ObservationIgnored private var hydraTouched: Set<String> = []
    /// Paths this turn has touched so far, kept current as the turn's edits land, so a head
    /// that asks what the turn has already changed is answered from the turn rather than by
    /// walking the timeline. Reset with the turn (see `startTurn`, `install`, `revert`) and
    /// left holding the turn's finished set once it ends (`finishTurn`).
    @ObservationIgnored private(set) var hydraCurrentTurnTouchedPaths: Set<String> = []
    /// Snapshots around a native head's shell commands, by head and tool (see
    /// `watchHydraCommand`).
    @ObservationIgnored private var hydraCommandTrees: [String: Task<String?, Never>] = [:]

    private struct SessionSignature: Equatable {
        var provider: ProviderKind
        var directory: String
        var launchRuntimeMode: RuntimeMode?
        var launchEffort: String?
        var launchFast: Bool?
        /// Antigravity pins model, effort, mode and plan state at launch
        /// (`--model`, `--effort`, `--mode`), so any of them restarts it.
        var launchModel: String?
        var launchInteraction: InteractionMode?
        /// Providers that run heads natively define them at launch, so the team restarts
        /// the session when Hydra is switched or its pair changes.
        var hydra: HydraLaunch?
        /// The anti-slop policy travels with the session, so flipping the setting
        /// restarts it and the policy in force is the one the session was made with.
        var antiSlopEnabled: Bool
    }

    enum DeltaKind {
        case message
        case reasoning
        case toolOutput
        case plan
    }

    private struct PendingDelta {
        var kind: DeltaKind
        var text: String
    }

    init(threadID: UUID, app: AppModel) {
        self.threadID = threadID
        self.app = app
        isLoadingHistory = true
        let prefetched = DocumentPrefetch.shared.take(threadID)
        if let prefetched { install(prefetched, prepared: true) }
        historyLoad = Task.detached(priority: .userInitiated) { [threadID] in
            // Writes are atomic and a read waits for queued ones, so a file that still will
            // not read after a few tries is damaged. Waiting on it for good left the chat
            // blank and a send hanging; it is set aside instead, never saved over.
            var decoded = prefetched ?? Storage.readRecentDocument(threadID)?.document
            var tries = 0
            while decoded == nil && tries < 3 && FileManager.default.fileExists(atPath: Storage.threadURL(threadID).path) && !Task.isCancelled {
                tries += 1
                try? await Task.sleep(for: .seconds(2))
                decoded = Storage.readRecentDocument(threadID)?.document
            }
            guard !Task.isCancelled else { return }
            var keptAt: URL?
            if decoded == nil { keptAt = Storage.setAside(threadID, moving: true) }
            let recent = decoded ?? ThreadDocument(threadID: threadID)
            if prefetched == nil { await self.install(recent, prepared: true) }
            let loaded = Set(recent.turns.map(\.id))
            let remaining = (recent.turnIndex ?? []).filter { !loaded.contains($0.id) }
            if !remaining.isEmpty {
                for attempt in 0..<3 where !Task.isCancelled {
                    if let older = Storage.readTurns(threadID, references: remaining)?.document {
                        await self.finishLoad(older)
                        return
                    }
                    if attempt < 2 { try? await Task.sleep(for: .seconds(2)) }
                }
                guard !Task.isCancelled else { return }
                // The newer turns carry on; the next save prunes the turns its head no longer
                // lists, so the whole thread is copied aside first.
                keptAt = Storage.setAside(threadID, moving: false)
                await self.completeHistoryLoad(unreadable: keptAt, partly: true)
            } else {
                await self.completeHistoryLoad(unreadable: keptAt, partly: false)
            }
        }
    }

    private func install(_ document: ThreadDocument, prepared: Bool = false) {
        installingHistory = true
        itemPositions.merge(document.itemPositions ?? [:]) { _, new in new }
        for reference in document.turnIndex ?? [] {
            savedTurnRevisions[reference.id] = reference.revision
            turnRevisions[reference.id] = turnRevisions[reference.id] ?? reference.revision
            nextTurnRevision = max(nextTurnRevision, reference.revision)
        }
        var recovered = false
        let wasDirty = saveRevision != lastSavedRevision
        turns = document.turns + turns
        if thread?.hydra?.kind == .tivano {
            hydraTokens = turns.flatMap { $0.tokenSpends ?? [] }.reduce(0) { $0 + $1.totalTokens }
        }
        usage = usage ?? document.usage
        continuation = document.continuation ?? continuation
        followUps = document.followUps.filter { !$0.isEmpty } + followUps
        hydraMerges = document.hydraMerges + hydraMerges
        // Thinking with no text is nothing to show or keep: Claude Code redacts its
        // reasoning and streams only empty deltas, which older builds stored as blank
        // entries. They are dropped here and never created below. Threads stored before
        // the app flattened model prose on the way in are cleaned as they are read, so
        // no reply from any earlier build can put an em dash back on screen.
        let items = prepared ? document.items : document.items.filter { !$0.isEmptyReasoning }.map(\.cleanedOfEmDashes)
        recovered = items != document.items || document.followUps.contains(where: \.isEmpty)
        let loaded = items.map { TimelineEntry($0) }
        for entry in loaded {
            entryIndex[entry.id] = entry
            switch entry.item.content {
            case .assistant(let message): recovered = recovered || message.isStreaming
            case .reasoning(let block): recovered = recovered || block.isStreaming
            case .plan(let plan): recovered = recovered || plan.state == .drafting
            default: break
            }
            endStreaming(entry)
            if case .tool(var call) = entry.item.content, call.status == .running {
                recovered = true
                call.finish(.failed)
                entry.item.content = .tool(call)
            }
        }
        entries = loaded + entries
        // A card left in its sent state by a quit mid-hold goes now: its heads went out long ago.
        for entry in loaded {
            guard case .assistant(var message) = entry.item.content, HydraPrompts.hasSentDelegationBlock(in: message.text) else { continue }
            recovered = true
            message.text = HydraPrompts.withoutDelegationBlock(message.text)
            if message.text.isEmpty { message.text = "Sent out heads." }
            entry.item.content = .assistant(message)
        }
        for index in turns.indices where turns[index].status == .running {
            recovered = true
            crashInterruptedTurnIDs.insert(turns[index].id)
            turns[index].status = .interrupted
        }
        // A turn the app quit under has no end marker, so it showed every step inline
        // for good; one is written for it here from the turn record, and the block
        // folds like any finished turn.
        var marked = Set<UUID>()
        for entry in entries where entry.kind == .turnEnd {
            if let turnID = entry.turnID {
                marked.insert(turnID)
            }
        }
        for turn in document.turns.reversed() {
            guard let index = turns.firstIndex(where: { $0.id == turn.id }),
                  !marked.contains(turn.id),
                  let lastIndex = entries.lastIndex(where: { $0.turnID == turn.id })
            else { continue }
            recovered = true
            let endedAt = turns[index].completedAt ?? entries[lastIndex].item.date
            if turns[index].completedAt == nil {
                turns[index].completedAt = endedAt
            }
            let summary = TurnSummary(turnID: turn.id, status: turns[index].status, duration: max(0, endedAt.timeIntervalSince(turns[index].startedAt)), filesChanged: turns[index].touchedPaths?.count ?? 0, additions: 0, deletions: 0, changes: nil)
            let entry = TimelineEntry(TimelineItem(turnID: turn.id, date: endedAt, content: .turnEnd(summary)))
            if let previous = itemPositions[entries[lastIndex].id] {
                let next = itemPositions.values.filter { $0 > previous }.min()
                itemPositions[entry.id] = next.map { previous + ($0 - previous) / 2 } ?? (previous + 1)
            }
            entries.insert(entry, at: lastIndex + 1)
            entryIndex[entry.id] = entry
        }
        installingHistory = false
        if recovered {
            for turn in document.turns { markTurnDirty(turn.id) }
            saveRevision += 1
        }
        if !recovered && !wasDirty { lastSavedRevision = saveRevision }
        if document.turnIndex == nil { saveRevision += 1 }
        if currentTurnID == nil {
            endDelegationStream()
            hydraCurrentTurnTouchedPaths = []
        } else {
            // Native head events can arrive while their history is loading.
            for entry in entries where entry.turnID == currentTurnID {
                if case .tool(let call) = entry.item.content { recordCurrentTurnEdits(call.edits) }
            }
        }
    }

    private func finishLoad(_ document: ThreadDocument) {
        guard isLoadingHistory else { return }
        install(document, prepared: true)
        // Head-only rows can sit between finished turns; restore their exact positions
        // after the older rows have gone through the same prepend/recovery path.
        entries.sort { (itemPositions[$0.id] ?? .greatestFiniteMagnitude) < (itemPositions[$1.id] ?? .greatestFiniteMagnitude) }
        completeHistoryLoad()
    }

    private func completeHistoryLoad(unreadable keptAt: URL? = nil, partly: Bool = false) {
        isLoadingHistory = false
        historyLoad = nil
        if let keptAt {
            let message = String(format: Chrome.localized(partly
                ? "Older parts of this chat couldn't be read. Tivano kept the files in %@."
                : "This chat's history couldn't be read. Tivano kept the files in %@."), keptAt.path)
            append(TimelineItem(turnID: nil, content: .notice(Notice(level: .warning, message: message))))
            saveRevision += 1
        }
        if saveRevision != lastSavedRevision { scheduleSave() }
    }

    /// Anything that continues the history (a new turn) waits for it first.
    func ensureLoaded() async {
        if let historyLoad { await historyLoad.value }
    }

    /// Installs context only while the destination has no conversation of its own.
    func installContinuation(_ value: ThreadContinuation) async -> Bool {
        await ensureLoaded()
        guard let thread, turns.isEmpty, entries.isEmpty, thread.providerSessionID == nil else { return false }
        // Selecting the new row can warm a session before the snapshot is installed.
        releaseSession(stop: true)
        continuation = value
        saveRevision += 1
        saveNow()
        return true
    }

    var isRunning: Bool { phase != .idle }

    var thread: ChatThread? { app?.thread(threadID) }

    /// Whether any head of this lead, native or Tivano-run, is still at work. The native
    /// ones run inside the lead's own session, so a turn with heads at work is never
    /// interrupted on the user's behalf by a new message: only the Stop button and
    /// Escape stop it, and those are the user stopping the lead on purpose.
    var hasWorkingHeads: Bool {
        (app?.runningHydraHeads(of: threadID) ?? 0) > 0
    }

    /// Whether any helper of this lead — a head or a plain helper — is at work: the same
    /// question the folded-helpers line asks about the same helpers, so a lead's own row,
    /// its badge and the line under it never disagree.
    var hasWorkingHelpers: Bool {
        guard let app else { return false }
        for helper in app.children(of: threadID) {
            if let runtime = app.existingRuntime(for: helper.id), runtime.isRunning || runtime.isHydraMerging {
                return true
            }
        }
        return false
    }

    /// Whether any native head of this lead is still at work: those are the ones stopping
    /// the lead's turn would take down. A Tivano-run head lives in a thread of its own and
    /// reports to whatever turn the lead is on, so it survives the lead being stopped.
    var hasWorkingNativeHeads: Bool {
        guard let app else { return false }
        return app.runningHydraHeads(of: threadID) > app.runningTivanoHeads(of: threadID)
    }

    /// Escape on a running turn: the turn is stopped and taken back. The conversation
    /// rewinds to before it, the provider's context too (`revert`, the way editing a message
    /// rewinds it: Claude resumes at the kept turn's last message, Codex rolls the turn
    /// back), so the aborted exchange costs nothing next turn, and its message goes back
    /// in the composer to be changed and sent again. Files stay as the turn left them. With
    /// something already typed in the box, heads out on the turn (their reports belong
    /// to it), or a rewind the provider refuses, the turn is only stopped and stays in
    /// the thread.
    func takeBackRunningTurn() {
        guard draft.isEmpty, !hasWorkingHeads, let turnID = currentTurnID, let turn = turns.first(where: { $0.id == turnID }),
              let itemID = turn.userItemID, let entry = entryIndex[itemID],
              case .user(let message) = entry.item.content, !message.isFromHydra else {
            interrupt()
            return
        }
        interrupt()
        Task {
            // The interrupt lands asynchronously, and a rewind needs the turn finished; the
            // watchdog ends a session that ignores it within eight seconds. Words typed
            // into the box while the stop landed are the reader's, not the message's to
            // overwrite: the stopped turn then stays in the thread.
            for _ in 0..<200 where phase != .idle { try? await Task.sleep(for: .milliseconds(50)) }
            guard phase == .idle, draft.isEmpty, turns.contains(where: { $0.id == turnID }) else { return }
            do {
                try await revert(to: turnID, restoreFiles: false)
            } catch {
                appendNotice(.error, "The stopped message was kept: \(error.localizedDescription)")
                return
            }
            draft.text = message.text
            draft.attachments = message.attachments
        }
    }

    var sentPrompts: [String] {
        entries.compactMap { entry in
            if case .user(let message) = entry.item.content, !message.isFromHydra, !message.isHydraBrief { return message.text }
            return nil
        }
    }

    var hasSentPrompts: Bool {
        entries.contains { entry in
            if case .user(let message) = entry.item.content { return !message.isFromHydra }
            return false
        }
    }

    var pendingPlanApproval: ApprovalRequest? {
        approvals.first { $0.kind == .plan }
    }

    // MARK: - Sending

    func send() {
        guard !isReverting, !draft.isEmpty, phase == .idle else { return }
        let attachments = draft.attachments
        let outgoing = draft.outgoingText.trimmingCharacters(in: .whitespacesAndNewlines)
        if handleLocalCommand(outgoing) {
            draft = ComposerDraft()
            return
        }
        draft = ComposerDraft()
        // With every message going to a head, the lead stays idle for the reports.
        if dispatchSentHead(text: outgoing, attachments: attachments) { return }
        Task { await ensureLoaded(); await startTurn(text: outgoing, attachments: attachments) }
    }

    func sendHydraBrief(_ text: String, attachments: [Attachment]) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty,
              phase == .idle else { return }
        draft = ComposerDraft()
        // The head's clock starts with its brief, so one that never answers counts as quiet.
        hydraLastEventAt = .now
        Task { await ensureLoaded(); await startTurn(text: text, attachments: attachments, hydraBrief: true) }
    }

    // MARK: - Follow-up queue

    /// Whether the chat box can queue a message: while a turn runs, and while heads are
    /// out with the lead waiting on them. Return sends to the idle lead at once; the
    /// queue is for what should wait until the heads have reported.
    var canQueue: Bool {
        isRunning || hasWorkingHeads
    }

    /// Instantly queues the composer's draft as a follow-up while a turn runs or heads are
    /// at work. The prompt, pics and other attachments included, is sent as a direct user
    /// chat message once the running turn (or the heads' report) finishes. Stacks up:
    /// every queued prompt runs in order. With nothing to queue behind, the draft simply
    /// goes out: the queue chord is never a dead key.
    func queueDraftAsFollowUp() {
        guard !isReverting, !draft.isEmpty else { return }
        guard canQueue else {
            send()
            return
        }
        enqueueFollowUp(text: draft.outgoingText, attachments: draft.attachments)
        draft = ComposerDraft()
    }

    /// Draft captured by Return while a turn runs: stop the turn, then send this
    /// right away instead of queueing it behind the queue.
    @ObservationIgnored private var pendingSend: PendingSend?
    /// A queued follow-up's turn is on its way to an idle lead (see
    /// `flushFollowUpsIfIdle`): a second prompt queued in the meantime waits its
    /// turn rather than starting one of its own, so two never double-send.
    @ObservationIgnored private var followUpFlushScheduled = false

    private struct PendingSend {
        var text: String
        var attachments: [Attachment]
    }

    /// Interrupts the running turn and sends the draft as soon as the stop
    /// lands, instead of queueing it as a follow-up. The composer clears at
    /// once; the message goes out when the turn fully stops (or immediately,
    /// if the turn finished on its own in the meantime). With heads at work the
    /// turn is left alone and the draft queues instead: see `hasWorkingHeads`.
    func interruptAndSend() {
        guard !isReverting, !draft.isEmpty, phase != .idle else { return }
        // With every message going to a head, Return while the lead works sends the
        // draft to a head and leaves the lead's turn alone.
        if dispatchSentHead(text: draft.outgoingText, attachments: draft.attachments) {
            draft = ComposerDraft()
            return
        }
        // Heads at work are never stopped by a new message. The native ones run inside
        // the lead's own session, so interrupting the turn would kill them mid-task and
        // throw away minutes of their work. The draft goes to a Tivano-run head of its
        // own when the settings allow it, else it waits as a follow-up behind the
        // running turn; either way nothing is interrupted.
        if hasWorkingHeads {
            enqueueFollowUp(text: draft.outgoingText, attachments: draft.attachments)
            draft = ComposerDraft()
            return
        }
        pendingSend = PendingSend(text: draft.outgoingText, attachments: draft.attachments)
        draft = ComposerDraft()
        interrupt()
    }

    /// Pairs the dragged follow-up onto another so they go out as one message: both
    /// carry the target's bundle (or a fresh one), and the dragged prompt moves to sit
    /// right after the bundle's last prompt.
    func bundleFollowUp(_ id: UUID, onto target: UUID) {
        guard id != target,
              let targetIndex = followUps.firstIndex(where: { $0.id == target }),
              followUps.firstIndex(where: { $0.id == id }) != nil else { return }
        let bundle = followUps[targetIndex].bundleID ?? UUID()
        followUps[targetIndex].bundleID = bundle
        var dragged = followUps.remove(at: followUps.firstIndex(where: { $0.id == id })!)
        dragged.bundleID = bundle
        // The target still carries the bundle, so this always finds at least it.
        let insertAt = (followUps.lastIndex(where: { $0.bundleID == bundle }) ?? (followUps.count - 1)) + 1
        followUps.insert(dragged, at: min(insertAt, followUps.count))
        saveRevision += 1
        scheduleSave()
    }

    /// Takes a prompt out of its bundle on purpose (the link tapped, or the row dragged
    /// out): it goes as its own message again, and a bundle left with one prompt dissolves.
    func unbundleFollowUp(_ id: UUID) {
        guard let index = followUps.firstIndex(where: { $0.id == id }), followUps[index].bundleID != nil else { return }
        followUps[index].bundleID = nil
        tidyBundles()
        saveRevision += 1
        scheduleSave()
    }

    /// Drops a prompt from its bundle when neither neighbour shares it, and dissolves
    /// a bundle left with a single prompt.
    private func unbundleIfSeparated(_ id: UUID) {
        guard let index = followUps.firstIndex(where: { $0.id == id }),
              let bundle = followUps[index].bundleID else { return }
        let prevShares = index > 0 && followUps[index - 1].bundleID == bundle
        let nextShares = index + 1 < followUps.count && followUps[index + 1].bundleID == bundle
        guard !prevShares && !nextShares else { return }
        followUps[index].bundleID = nil
        let remaining = followUps.filter { $0.bundleID == bundle }
        if remaining.count == 1, let lone = followUps.firstIndex(where: { $0.id == remaining[0].id }) {
            followUps[lone].bundleID = nil
        }
    }

    /// Clears any bundle held by only one prompt.
    private func tidyBundles() {
        var counts: [UUID: Int] = [:]
        for prompt in followUps {
            if let bundle = prompt.bundleID { counts[bundle, default: 0] += 1 }
        }
        for index in followUps.indices {
            if let bundle = followUps[index].bundleID, counts[bundle] == 1 {
                followUps[index].bundleID = nil
            }
        }
    }

    /// The merged prompt for the bundle starting at `index`, without removing it.
    private func mergedBundle(startingAt index: Int) -> FollowUpPrompt {
        let first = followUps[index]
        guard let bundle = first.bundleID else { return first }
        var end = index
        while end + 1 < followUps.count, followUps[end + 1].bundleID == bundle { end += 1 }
        let members = Array(followUps[index...end])
        var merged = first
        merged.text = Self.bundleText(members)
        merged.attachments = members.flatMap { $0.attachments }
        merged.bundleID = nil
        return merged
    }

    /// The text of a bundle going out as one message. With no attachment among the
    /// members, their texts one after the other; otherwise each message is numbered and
    /// names its own pictures (by their order among the images sent, which is the order
    /// the merged attachments keep) and files (by path) under it, so the model never has
    /// to guess which picture or file came with which of the messages.
    static func bundleText(_ members: [FollowUpPrompt]) -> String {
        let texts = members.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard members.count > 1, members.contains(where: { !$0.attachments.isEmpty }) else {
            return texts.filter { !$0.isEmpty }.joined(separator: "\n\n")
        }
        var imageNumber = 0
        var sections: [String] = []
        for (offset, member) in members.enumerated() {
            let number = offset + 1
            var lines = ["Message \(number):"]
            if !texts[offset].isEmpty { lines.append(texts[offset]) }
            let named = member.attachments.map { attachment -> String in
                guard attachment.isImage else { return "file \(attachment.path)" }
                imageNumber += 1
                return "image \(imageNumber) (\(attachment.name))"
            }
            if !named.isEmpty {
                lines.append("Attached to message \(number): " + named.joined(separator: ", ") + ".")
            }
            sections.append(lines.joined(separator: "\n"))
        }
        let header = "\(members.count) messages sent together. The pictures and files a message came with are named under it, the pictures numbered in the order they are attached."
        return ([header] + sections).joined(separator: "\n\n")
    }

    /// Removes the prompt at `index` and every following adjacent prompt with the same
    /// non-nil bundle, returning them as one merged prompt.
    private func takeBundle(startingAt index: Int) -> FollowUpPrompt {
        let merged = mergedBundle(startingAt: index)
        let bundle = followUps[index].bundleID
        if let bundle {
            var end = index
            while end + 1 < followUps.count, followUps[end + 1].bundleID == bundle { end += 1 }
            followUps.removeSubrange(index...end)
        } else {
            followUps.remove(at: index)
        }
        return merged
    }

    /// Sends a queued follow-up right away instead of waiting its turn: the running turn
    /// stops and the prompt goes out as soon as the stop lands, exactly as Return does with
    /// the draft; idle, it simply sends. The rest of the queue waits for the new turn.
    /// With native heads at work nothing stops, as with Return: the prompt goes to a head
    /// of its own when the settings allow it, else it stays at the front of the queue.
    /// Tivano-run heads live on through a stop, so with only those out the turn stops for
    /// the prompt as it would with none: "now" means now.
    func sendFollowUpNow(_ id: UUID) {
        guard !isReverting else { return }
        guard let index = followUps.firstIndex(where: { $0.id == id }) else { return }
        var start = index
        if let bundle = followUps[index].bundleID {
            while start > 0, followUps[start - 1].bundleID == bundle { start -= 1 }
        }
        let prompt = takeBundle(startingAt: start)
        saveRevision += 1
        scheduleSave()
        guard !prompt.isEmpty else { return }
        if phase == .idle {
            if handleLocalCommand(prompt.text.trimmingCharacters(in: .whitespacesAndNewlines)) { return }
            Task { await ensureLoaded(); await startTurn(text: prompt.text, attachments: prompt.attachments) }
        } else if pendingSend == nil {
            // Native heads at work are never stopped for a queued prompt: they run inside
            // the lead's session and an interrupt would kill them. The prompt goes to a
            // Tivano-run head when the settings allow it, else back to the front of the
            // queue to wait for the turn, and the lead keeps working.
            if hasWorkingNativeHeads {
                if !dispatchQueuedHead(prompt) {
                    followUps.insert(prompt, at: 0)
                    saveRevision += 1
                    scheduleSave()
                }
                return
            }
            pendingSend = PendingSend(text: prompt.text, attachments: prompt.attachments)
            interrupt()
        } else {
            // Return already has a message going out the moment the turn stops; this one
            // goes right behind it.
            followUps.insert(prompt, at: 0)
            saveRevision += 1
            scheduleSave()
        }
    }

    func enqueueFollowUp(text: String, attachments: [Attachment]) {
        let prompt = FollowUpPrompt(
            text: text.trimmingCharacters(in: .whitespacesAndNewlines),
            attachments: attachments
        )
        guard !prompt.isEmpty else { return }
        // With Hydra on, a task queued behind a running turn goes to a head right away,
        // with a note on what the lead is doing, instead of waiting its turn.
        if phase != .idle, dispatchQueuedHead(prompt) { return }
        followUps.append(prompt)
        saveRevision += 1
        scheduleSave()
        // An idle lead takes the next queued message at once, even with heads still
        // out: the queue only ever waits behind a running turn, never behind an
        // idle lead. Without this a prompt queued while the lead is idle (steered
        // behind heads at work) sits until the next turn ends, which may be never.
        flushFollowUpsIfIdle()
    }

    /// Hands a queued prompt to a Tivano-run head, when the app and the chat allow it and
    /// the pair has room for one more. Returns whether the head went out.
    private func dispatchQueuedHead(_ prompt: FollowUpPrompt) -> Bool {
        guard let app, app.settings.hydraQueueHeads || app.settings.hydraAlwaysHeads else { return false }
        return dispatchHead(prompt, origin: .queued)
    }

    /// Hands a message the user sent, idle lead or not, to a Tivano-run head, when every
    /// message goes to heads and the pair has room. The local commands stay with the chat.
    /// Returns whether the head went out; if not, the message goes the ordinary way.
    private func dispatchSentHead(text: String, attachments: [Attachment]) -> Bool {
        guard let app, app.settings.hydraAlwaysHeads else { return false }
        let prompt = FollowUpPrompt(text: text.trimmingCharacters(in: .whitespacesAndNewlines), attachments: attachments)
        guard !prompt.isEmpty, prompt.text != "/plan", prompt.text != "/compact" else { return false }
        return dispatchHead(prompt, origin: .sent)
    }

    /// Sends a prompt out as a Tivano-run head with a note on what the lead is doing, or
    /// that it is idle. Returns whether the head went out.
    private func dispatchHead(_ prompt: FollowUpPrompt, origin: HydraHeadInfo.Origin) -> Bool {
        guard let app, let thread, !thread.isArchived, let launch = app.hydraLaunch(for: thread),
              launch.hasRoom(running: app.runningTivanoHeads(of: threadID)) else { return false }
        let task = TextCleanup.singleLine(prompt.text, limit: 60)
        let context = app.hydraChatContext(for: threadID)
        let leadIsWorking = phase != .idle
        let text = prompt.text
        return app.spawnTivanoHead(from: threadID, task: task, origin: origin, attachments: prompt.attachments) { persona, workplace in
            HydraPrompts.queuedHeadPrompt(persona: persona, task: text, context: context, workplace: workplace, leadIsWorking: leadIsWorking)
        } != nil
    }

    /// Follow-ups queued while the heads were all busy go out as heads once one frees up,
    /// as long as the lead is still at work; an idle lead takes them itself, in order.
    private func dispatchQueuedFollowUps() {
        guard phase != .idle else { return }
        while !followUps.isEmpty {
            let merged = mergedBundle(startingAt: 0)
            guard dispatchQueuedHead(merged) else { break }
            _ = takeBundle(startingAt: 0)
            saveRevision += 1
            scheduleSave()
        }
    }

    /// Sends the next queued follow-up to an idle lead at once, even with heads still
    /// out. A turn the user stopped waits for them instead (see `drainFollowUps`).
    private func flushFollowUpsIfIdle() {
        guard phase == .idle, !followUpFlushScheduled, !followUps.isEmpty,
              thread?.lastStatus != .interrupted else { return }
        followUpFlushScheduled = true
        Task { await startQueuedFollowUpTurn() }
    }

    /// The turn `flushFollowUpsIfIdle` scheduled. Something that started first (the
    /// heads' reports, or the user's own word) owns the queue now: its end drains it.
    private func startQueuedFollowUpTurn() async {
        followUpFlushScheduled = false
        guard phase == .idle else { return }
        // The queue drains exactly as after a completed turn: in order, skipping
        // prompts that emptied while queued.
        _ = drainFollowUps(after: .completed)
    }

    func removeFollowUp(_ id: UUID) {
        followUps.removeAll { $0.id == id }
        tidyBundles()
        saveRevision += 1
        scheduleSave()
    }

    /// Moves a queued follow-up next to another one, for drag reordering. A no-op
    /// when it is already there, so hovering the same half never churns.
    /// Moves a follow-up to sit right before or after `target`; returns whether the queue changed.
    @discardableResult
    func moveFollowUp(_ id: UUID, to target: UUID, placeAfter: Bool) -> Bool {
        guard id != target,
              let from = followUps.firstIndex(where: { $0.id == id }),
              let to = followUps.firstIndex(where: { $0.id == target }) else { return false }
        var dest = to + (placeAfter ? 1 : 0)
        if from < dest { dest -= 1 }
        guard from != dest else { return false }
        let prompt = followUps.remove(at: from)
        followUps.insert(prompt, at: dest)
        unbundleIfSeparated(id)
        saveRevision += 1
        scheduleSave()
        return true
    }

    func updateFollowUp(_ id: UUID, text: String, attachments: [Attachment]) {
        guard let index = followUps.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty, attachments.isEmpty {
            followUps.remove(at: index)
            tidyBundles()
        } else {
            followUps[index].text = text
            followUps[index].attachments = attachments
        }
        saveRevision += 1
        scheduleSave()
    }

    /// Sends the next queued follow-up as a direct user message. Only runs when idle after a
    /// completed turn: an interrupted turn means the user hit stop, so the queue waits for them.
    /// Returns whether a turn starts.
    private func drainFollowUps(after status: TurnStatus) -> Bool {
        guard status == .completed, phase == .idle, !followUps.isEmpty else { return false }
        var next = takeBundle(startingAt: 0)
        saveRevision += 1
        // Skip prompts that emptied while queued (an attachment file deleted on disk still counts,
        // so only the text+attachment check applies).
        while next.isEmpty, !followUps.isEmpty {
            next = takeBundle(startingAt: 0)
            saveRevision += 1
        }
        guard !next.isEmpty else {
            scheduleSave()
            return false
        }
        scheduleSave()
        if handleLocalCommand(next.text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return drainFollowUps(after: status)
        }
        // This turn starts on its own (see autoStartedTurnToken).
        autoStartedTurnToken &+= 1
        Task { await ensureLoaded(); await startTurn(text: next.text, attachments: next.attachments) }
        return true
    }

    func implementPlan(_ entryID: String) {
        guard phase == .idle, let entry = entryIndex[entryID], case .plan(var plan) = entry.item.content else { return }
        plan.state = .accepted
        entry.item.content = .plan(plan)
        saveRevision += 1
        app?.updateThread(threadID) { $0.interactionMode = .build }
        Task { await ensureLoaded(); await startTurn(text: "Implement the plan.", attachments: []) }
    }

    func dismissPlan(_ entryID: String) {
        guard let entry = entryIndex[entryID], case .plan(var plan) = entry.item.content else { return }
        plan.state = .dismissed
        entry.item.content = .plan(plan)
        saveRevision += 1
        scheduleSave()
    }

    private func handleLocalCommand(_ text: String) -> Bool {
        switch text {
        case "/plan":
            if let provider = thread?.provider { app?.providers.recordCommand("plan", for: provider) }
            app?.updateThread(threadID) { $0.interactionMode = $0.interactionMode == .plan ? .build : .plan }
            return true
        case "/compact" where thread?.provider.supportsCompact == true:
            if let provider = thread?.provider { app?.providers.recordCommand("compact", for: provider) }
            compact()
            return true
        default:
            return false
        }
    }

    /// Starts a turn on `text`. `hydraHeads` marks the message as heads reporting back to
    /// their lead rather than the user's own words; `hydraBrief` marks it as the lead's
    /// brief to a head, shown as a pill rather than a plain bubble.
    private func startTurn(text: String, attachments: [Attachment], hydraHeads: [Int]? = nil, hydraBrief: Bool = false) async {
        // A new turn must not race a provider-side archive. This wait occurs before
        // claiming the idle runtime, and the same session is restored before sending.
        await providerHistoryOperation?.value
        guard phase == .idle, !isReverting else {
            enqueueFollowUp(text: text, attachments: attachments)
            return
        }
        guard let app, let initialThread = app.thread(threadID), let project = app.project(initialThread.projectID) else { return }
        guard !initialThread.isArchived else {
            enqueueFollowUp(text: text, attachments: attachments)
            return
        }
        let turnIndex = (turns.map(\.index).max() ?? -1) + 1
        var turn = TurnRecord(index: turnIndex)
        let userItem = TimelineItem(turnID: turn.id, content: .user(UserMessage(text: text, attachments: attachments, hydraHeads: hydraHeads, hydraBrief: hydraBrief ? true : nil)))
        turn.userItemID = userItem.id
        turns.append(turn)
        saveRevision += 1
        currentTurnID = turn.id
        currentProviderDiff = nil
        currentProviderAnchor = nil
        append(userItem)
        phase = .starting
        turnStartedAt = .now
        app.updateThread(threadID) {
            $0.updatedAt = .now
            $0.lastStatus = .running
        }
        // A settled thread put back to work is open again.
        app.reopenIfSettled(threadID)
        endDelegationStream()
        hydraCurrentTurnTouchedPaths = []
        // `hydraHeads == nil` marks a turn of the user's own: it starts the request's
        // delegation budget over. Turns carrying head reports or a refusal notice continue it.
        hydraBudget.beginTurn(userAuthored: hydraHeads == nil)
        // A finished head told more from the panel is at work again: its lead's team
        // counts it, and its next report goes out as a fresh one.
        if let info = initialThread.hydra, info.kind == .tivano, info.isFinished {
            app.updateHydraHead(threadID) {
                $0.status = .running
                $0.finishedAt = nil
            }
        }
        if let info = initialThread.hydra, info.kind == .tivano {
            app.updateHydraHead(threadID) {
                if turns.count > 1 {
                    $0.startedAt = .now
                    $0.queuedAt = nil
                    $0.executionStartedAt = .now
                }
                $0.executionFinishedAt = nil
                $0.landingStartedAt = nil
                $0.landingFinishedAt = nil
            }
        }
        // A Tivano-run head gets so long for a turn, on any provider. The API sessions
        // stop themselves a little sooner from inside the turn; this is the backstop, and
        // the only stop a CLI head has.
        let isFinalReport = headReportsNext
        headReportsNext = false
        if initialThread.hydra?.kind == .tivano {
            let allowance = isFinalReport
                ? HydraBudget.reportSeconds
                : HydraBudget.maxSeconds + (initialThread.provider.isAPIKeyBased ? 90 : 0)
            headBudget?.cancel()
            headBudget = Task { [weak self] in
                try? await Task.sleep(for: .seconds(allowance))
                guard let self, !Task.isCancelled, self.currentTurnID == turn.id, self.phase != .idle else { return }
                self.headBudgetSpent = !isFinalReport
                self.interrupt()
            }
        }
        saveNow()
        // The chat is named as its first message goes in, not when the session finally
        // takes it: a cold session can take seconds, and a first send that fails must
        // not leave the chat nameless for good.
        generateTitle(from: text, attachments: attachments)

        await ensureModel(initialThread)

        let directory = initialThread.worktreePath ?? project.path
        let git = Git(directory)
        let checkpointRef = Git.checkpointRef(thread: threadID, turn: turnIndex, phase: "start")
        // Anything could have happened in the checkout since the last turn, so no snapshot
        // from it stands any more. The heads' files are not cleared here: a native head
        // works on after the lead's reply ends, and what it changed then belongs to the
        // next turn, which takes it up at its end (see `finishTurn`).
        settledTree = nil
        latestTree = nil
        treeEpoch += 1
        // The checkpoint is several git processes over the whole checkout. It runs while
        // the session starts rather than in front of it, and both are waited for before a
        // word reaches the model, so nothing the agent does can slip past the snapshot.
        let checkpoint = Task.detached(priority: .userInitiated) { () -> Bool in
            guard await git.isRepository() else { return false }
            return (try? await git.captureCheckpoint(checkpointRef)) != nil
        }

        do {
            // A session started while the message was being typed is the one to use. The
            // session starts alongside the checkpoint. It is picked up from the runtime
            // afterwards rather than handed back as a value, because a session is not
            // Sendable and this task is one of its own.
            if let warmup { await warmup.value }
            let start = Task { () async throws -> Void in _ = try await self.ensureSession(directory: directory) }
            if await checkpoint.value {
                updateTurn(turn.id) { $0.baseCheckpoint = checkpointRef }
            }
            try await start.value
            if SlashCommand.name(in: text) != nil {
                await app.providers.loadCommands(initialThread.provider, directory: directory)
            }
            // The user can stop a turn while it is still starting.
            guard currentTurnID == turn.id, let session, let thread = app.thread(threadID) else { return }
            let command = SlashCommand.name(in: text).flatMap { name in
                app.providers.commands[ProviderRegistry.commandKey(thread.provider, directory: directory)]?.first { $0.name == name }
            }
            var prompt = text
            let files = attachments.filter { !$0.isImage }
            if !files.isEmpty {
                prompt += "\n\nAttached files:\n" + files.map { "- \($0.path)" }.joined(separator: "\n")
            }
            // A lead whose heads are Tivano-run is told how to ask Tivano for them. A
            // session that keeps that policy in its system prompt (the API providers, and
            // the providers with heads of their own sending them out elsewhere) gets the
            // team note here; every other CLI also gets the policy, having nowhere else
            // to keep it. The user's enabled delegation request is added below both paths.
            if let launch = app.hydraLaunch(for: thread) {
                let merge = launch.autoMerges ? HydraPrompts.mergeStatus(merges: hydraMerges, unmergedFiles: app.hydraUnmergedFileCount(of: threadID)) : nil
                if !launch.runsNatively {
                    let team = HydraPrompts.teamStatus(app.hydraTeam(of: threadID).compactMap(\.hydra))
                    let canDelegate = hydraBudget.canDelegate
                    if Self.keepsHydraPolicyInSystemPrompt(thread.provider) {
                        prompt = (hydraHeads == nil ? HydraPrompts.fallbackTurnNote(team: team, merge: merge) : HydraPrompts.fallbackReportNote(team: team, merge: merge, canDelegate: canDelegate)) + prompt
                    } else if hydraHeads == nil {
                        prompt = HydraPrompts.fallbackPreamble(launch, team: team, merge: merge) + prompt
                    } else {
                        prompt = HydraPrompts.fallbackReportPreamble(launch, team: team, merge: merge, canDelegate: canDelegate) + prompt
                    }
                } else if merge != nil {
                    prompt = HydraPrompts.fallbackTurnNote(team: nil, merge: merge) + prompt
                }
                // Selecting Hydra is a request to delegate. Carry that request at the
                // user-input boundary as well as keeping the routing policy in the session.
                // Automatic reports retain their round limit and review-only instructions.
                if hydraHeads == nil {
                    prompt = HydraPrompts.delegationRequest(launch) + prompt
                }
            }
            // Leave slash commands at the start of the input; deliver guidance with the next ordinary message.
            var injectedAntiSlopPolicy = false
            let antiSlopEpoch = sessionEpoch
            if !Self.keepsHydraPolicyInSystemPrompt(thread.provider),
               SlashCommand.name(in: text) == nil,
               !antiSlopFallbackSent {
                let instructions = AntiSlopPolicy.instructions(enabled: sessionSignature?.antiSlopEnabled ?? app.settings.antiSlopEnabled)
                if !instructions.isEmpty {
                    prompt = instructions + "\n\n" + prompt
                    injectedAntiSlopPolicy = true
                }
            }
            // Forwarded context from the source thread precedes the first ordinary
            // message, after the prompt the user's own words built. A slash command
            // consumes no ordinary prompt, so it neither carries the snapshot nor
            // spends the one delivery.
            var injectedContinuation = false
            let continuationEpoch = sessionEpoch
            if let continuation, !continuationSent, SlashCommand.name(in: text) == nil {
                prompt = continuation.prompt + "\n\n" + prompt
                injectedContinuation = true
            }
            // A block dropped with no refusal turn left to say so still reaches the lead:
            // its notice rides on the front of whatever turn comes next. Taken here, with
            // the send about to run, so a turn that aborts while starting keeps it waiting.
            if let notice = hydraBudget.takeDropNotice() {
                prompt = notice + prompt
            }
            phase = .running
            try await session.send(TurnInput(
                text: prompt,
                images: thread.provider.supportsImages ? attachments.filter(\.isImage) : [],
                model: thread.model,
                effort: thread.effort,
                serviceTier: serviceTier(for: thread),
                fastMode: thread.fastMode,
                runtimeMode: thread.runtimeMode,
                interactionMode: thread.interactionMode,
                isFinalReport: isFinalReport,
                command: command
            ))
            // Failed sends and replaced sessions must leave delivery pending.
            if injectedAntiSlopPolicy, sessionEpoch == antiSlopEpoch {
                antiSlopFallbackSent = true
            }
            if injectedContinuation, sessionEpoch == continuationEpoch {
                continuationSent = true
            }
            // The session has a conversation the provider can resume from here on.
            if let unsentSessionID {
                self.unsentSessionID = nil
                app.updateThread(threadID) { $0.providerSessionID = unsentSessionID }
            }
            if let command { app.providers.recordCommand(command.name, for: thread.provider) }
        } catch {
            guard currentTurnID == turn.id else { return }
            if finishTurnUpdatingCLI(error.localizedDescription, status: .failed, turnID: turn.id) { return }
            appendNotice(.error, error.localizedDescription)
            await finishTurn(status: .failed, turnID: turn.id)
        }
    }

    /// Whether the provider's session carries the lead's Hydra policy from launch: the API
    /// sessions put it in their system prompt, and the providers with heads of their own
    /// define the heads, or the policy for Tivano-run ones, at launch. Such a session takes
    /// the team as part of its signature, so a change to the team restarts it.
    private static func keepsHydraPolicyInSystemPrompt(_ provider: ProviderKind) -> Bool {
        AppModel.hydraIsNative(provider) || provider.isAPIKeyBased
    }

    /// Codex takes fast mode per turn as a service tier; models without a fast tier send none.
    private func serviceTier(for thread: ChatThread) -> String? {
        guard thread.provider == .codex,
              let tier = app?.providers.model(thread.model, for: thread.provider)?.fastTier else { return nil }
        return thread.fastMode ? tier : "default"
    }

    /// A thread with no model yet takes the provider's default, so the session launches
    /// with the model the app would show.
    private func ensureModel(_ thread: ChatThread) async {
        guard thread.model == nil, let app else { return }
        await app.providers.loadCatalog(thread.provider)
        if let model = app.providers.defaultModel(for: thread.provider) {
            app.updateThread(threadID) {
                $0.model = model.id
                $0.effort = $0.effort ?? model.defaultEffort
            }
        }
    }

    /// The provider process, started while the user is still typing the first message,
    /// so sending does not wait for the CLI to boot: about half a second for `claude`.
    /// Only for CLI providers without a session; a send in the meantime waits for the
    /// warm-up instead of starting a second process.
    func warmSession() {
        guard phase == .idle, session == nil, warmup == nil, !isReverting,
              let app, let thread = app.thread(threadID), !thread.isArchived, !thread.provider.isAPIKeyBased,
              let project = app.project(thread.projectID) else { return }
        let directory = thread.worktreePath ?? project.path
        warmup = Task { [weak self] in
            guard let self else { return }
            await ensureModel(thread)
            guard phase == .idle, session == nil else { warmup = nil; return }
            // A start that fails is not retried on every keystroke: the send makes its own.
            if (try? await ensureSession(directory: directory)) != nil { warmup = nil }
        }
    }

    private func ensureSession(directory: String, allowNewSession: Bool = true) async throws -> any ProviderSession {
        guard let app, let thread = app.thread(threadID) else { throw ProviderError.notRunning }
        // Copilot switches modes live, except that Auto's assisted-approval judge is a
        // session flag: entering or leaving Auto resumes the session with it set right.
        let copilotLaunchMode: RuntimeMode? = thread.provider == .copilot && thread.runtimeMode == .auto ? .auto : nil
        // A pair that sends its heads out on another provider names their model from that
        // provider's catalogue, which this chat may never have loaded. The lead's brief
        // names the model, and the brief is part of the session's signature, so the
        // catalogue loads first rather than the session restarting once it has.
        if app.hydraIsOn(thread), let pair = app.hydraPair(for: thread), app.hydraHeadsProvider(of: pair) != thread.provider {
            await app.providers.loadCatalog(app.hydraHeadsProvider(of: pair))
        }
        // Providers with heads of their own define them at launch (or, with the heads
        // sent out elsewhere, the policy for asking Tivano for them); the API
        // providers put the lead's Hydra policy in their system prompt. Either way the
        // team is part of the session, and a change to it restarts one.
        let hydra = Self.keepsHydraPolicyInSystemPrompt(thread.provider) ? app.hydraLaunch(for: thread) : nil
        let signature = SessionSignature(
            provider: thread.provider,
            directory: directory,
            launchRuntimeMode: thread.provider == .cursor || thread.provider == .grok || thread.provider == .devin || thread.provider == .antigravity ? thread.runtimeMode : copilotLaunchMode,
            launchEffort: thread.provider == .claude || thread.provider == .antigravity ? thread.effort : nil,
            launchFast: thread.provider == .claude ? thread.fastMode : nil,
            launchModel: thread.provider == .antigravity ? thread.model : nil,
            launchInteraction: thread.provider == .antigravity ? thread.interactionMode : nil,
            hydra: hydra,
            antiSlopEnabled: app.settings.antiSlopEnabled
        )
        if let session, session.isRunning, sessionSignature == signature {
            if let codex = session as? CodexSession, thread.hydra?.codexHistoryArchived == true {
                try await codex.restoreHeadHistory()
                app.updateHydraHead(threadID) {
                    $0.codexHistoryArchived = false
                    $0.providerHistoryIssue = nil
                }
            }
            return session
        }
        // A message sent right after launch waits for the login shell, where a CLI installed
        // off the fallback PATH is found; this must not read as "not installed".
        await LoginEnvironment.load()
        releaseSession(stop: true)
        try await waitForReplacedSessions()
        // The session the heads lived in is gone, and so are they.
        stopNativeHeads()

        if thread.provider.isAPIKeyBased {
            guard !app.settings.apiKey(for: thread.provider).isEmpty else {
                throw ProviderError.notInstalled(thread.provider)
            }
            func makeAPISession(resumeID: String?) -> any ProviderSession {
                let configuration = SessionConfiguration(
                    provider: thread.provider,
                    executable: nil,
                    workingDirectory: URL(fileURLWithPath: directory),
                    environment: app.providers.environment(for: thread.provider),
                    resumeID: resumeID,
                    resumeAt: resumeID == nil ? nil : thread.providerResumeAt,
                    model: thread.model,
                    effort: thread.effort,
                    fastMode: thread.fastMode,
                    runtimeMode: thread.runtimeMode,
                    interactionMode: thread.interactionMode,
                    apiKey: app.settings.apiKey(for: thread.provider),
                    hydra: hydra,
                    transcript: apiTranscript(),
                    isHydraHead: thread.hydra?.kind == .tivano,
                    antiSlopEnabled: signature.antiSlopEnabled
                )
                let created: any ProviderSession = switch thread.provider {
                case .deepseek: DeepSeekSession(configuration: configuration)
                case .meta: MetaSession(configuration: configuration)
                case .zai: ZaiSession(configuration: configuration)
                default: DeepSeekSession(configuration: configuration)
                }
                observe(created)
                return created
            }
            var candidate = makeAPISession(resumeID: thread.providerSessionID)
            session = candidate
            sessionSignature = signature
            let sessionID: String
            var started = false
            defer {
                if !started {
                    candidate.onEvent = nil
                    if session === candidate {
                        releaseSession(stop: true)
                    } else {
                        candidate.stop()
                    }
                }
            }
            do {
                sessionID = try await candidate.start()
            } catch where thread.providerSessionID != nil && thread.providerResumeAt == nil && allowNewSession && session === candidate && !Task.isCancelled {
                // The session that would not resume is let go of entirely, handler and
                // all, before the one that starts over takes its place.
                releaseSession(stop: true)
                try await waitForReplacedSessions()
                candidate = makeAPISession(resumeID: nil)
                session = candidate
                sessionSignature = signature
                sessionID = try await candidate.start()
            }
            guard session === candidate, !Task.isCancelled else { throw CancellationError() }
            started = true
            app.updateThread(threadID) { $0.providerSessionID = sessionID }
            return candidate
        }

        guard let executable = app.providers.executable(for: thread.provider) else {
            throw ProviderError.notInstalled(thread.provider)
        }
        func makeSession(resumeID: String?) -> any ProviderSession {
            let configuration = SessionConfiguration(
                provider: thread.provider,
                executable: executable,
                workingDirectory: URL(fileURLWithPath: directory),
                environment: app.providers.environment(for: thread.provider),
                resumeID: resumeID,
                resumeAt: resumeID == nil ? nil : thread.providerResumeAt,
                model: thread.model,
                effort: thread.effort,
                fastMode: thread.fastMode,
                runtimeMode: thread.runtimeMode,
                interactionMode: thread.interactionMode,
                hydra: hydra,
                isHydraHead: thread.provider == .codex && thread.hydra?.kind == .tivano,
                managesCodexHeadHistory: thread.provider == .codex && thread.hydra?.tracksProviderHistory == true
                    && (resumeID == nil || thread.hydra?.ownedCodexSessionID == resumeID),
                codexHistoryArchived: thread.hydra?.ownedCodexSessionID == resumeID && thread.hydra?.codexHistoryArchived == true,
                codexHistoryDirectory: thread.hydra?.ownedCodexWorkingDirectory,
                antiSlopEnabled: signature.antiSlopEnabled,
                modelCatalog: thread.provider.namesModelVariants ? app.providers.models(for: thread.provider) : []
            )
            let created: any ProviderSession = switch thread.provider {
            case .codex: CodexSession(configuration: configuration)
            case .claude: ClaudeSession(configuration: configuration)
            case .antigravity: AntigravitySession(configuration: configuration)
            case .copilot: CopilotSession(configuration: configuration)
            case .commandcode: CommandCodeSession(configuration: configuration)
            case .pi: PiSession(configuration: configuration)
            case .cursor, .opencode, .opencodeGo, .grok, .devin: ACPSession(configuration: configuration)
            case .deepseek: DeepSeekSession(configuration: configuration)
            case .meta: MetaSession(configuration: configuration)
            case .zai: ZaiSession(configuration: configuration)
            }
            observe(created)
            return created
        }

        var candidate = makeSession(resumeID: thread.providerSessionID)
        session = candidate
        sessionSignature = signature
        let sessionID: String
        var started = false
        isStartingSession = true
        defer {
            isStartingSession = false
            if !started {
                candidate.onEvent = nil
                if session === candidate {
                    releaseSession(stop: true)
                } else {
                    candidate.stop()
                }
            }
        }
        do {
            sessionID = try await candidate.start()
        } catch where allowNewSession && session === candidate && !Task.isCancelled
            && !(thread.provider == .codex && thread.hydra?.codexHistoryArchived == true
                && thread.hydra?.ownedCodexSessionID == thread.providerSessionID && thread.providerSessionID != nil)
            && Self.startsOver(after: error, resuming: thread) {
            // The session that would not resume is let go of entirely, handler and all,
            // before the one that starts over takes its place. A conversation the provider
            // no longer has cannot be picked up at a rewind anchor either, so the anchor
            // goes with it, and the chat is told its agent starts afresh.
            releaseSession(stop: true)
            try await waitForReplacedSessions()
            if Self.lostConversation(error) {
                app.updateThread(threadID) { $0.providerResumeAt = nil }
                if currentTurnID != nil {
                    appendNotice(.warning, "\(thread.provider.displayName) no longer has this conversation. It starts a new one here, without the messages above.")
                }
            } else if currentTurnID != nil {
                appendNotice(.warning, String(format: Chrome.localized("%@ couldn't pick this conversation back up (%@). It starts a new one here, without the messages above."), thread.provider.displayName, error.localizedDescription))
            }
            candidate = makeSession(resumeID: nil)
            session = candidate
            sessionSignature = signature
            sessionID = try await candidate.start()
        }
        guard session === candidate, !Task.isCancelled else { throw CancellationError() }
        started = true
        recordSessionID(sessionID)
        if let codex = candidate as? CodexSession { recoverCrashedCodexTurn(using: codex) }
        if thread.provider == .codex, thread.hydra?.kind == .tivano,
           thread.hydra?.tracksProviderHistory == true {
            app.updateHydraHead(threadID) {
                // A resumed/imported id never gains ownership retroactively.
                if thread.providerSessionID == nil { $0.ownedCodexSessionID = sessionID }
                if $0.ownedCodexSessionID == sessionID {
                    $0.codexHistoryArchived = false
                    $0.ownedCodexWorkingDirectory = directory
                    $0.providerHistoryIssue = nil
                }
            }
        }
        return candidate
    }

    /// A completion owns one process incarnation and one completed turn. The strong
    /// reference keeps that process available through landing; it confers no authority
    /// over a replacement session or a later turn on the same process.
    struct CodexHeadCompletionSession {
        fileprivate let session: CodexSession
        fileprivate let epoch: Int
        fileprivate let providerSessionID: String
        fileprivate let turnID: UUID
    }

    func retainCodexHeadSessionForHistory() -> CodexHeadCompletionSession? {
        guard canArchiveCompletedHeadHistory,
              let app, app.settings.hydraArchivesCodexHeads,
              let head = thread, head.provider == .codex, let info = head.hydra,
              info.kind == .tivano, info.origin == .delegated, info.tracksProviderHistory,
              !info.codexHistoryArchived, let ownedID = info.ownedCodexSessionID,
              head.providerSessionID == ownedID, head.parentThreadID != nil,
              let turn = turns.last, turn.status == .completed,
              let codex = session as? CodexSession, codex.isRunning else { return nil }
        return CodexHeadCompletionSession(session: codex, epoch: sessionEpoch, providerSessionID: ownedID, turnID: turn.id)
    }

    private func isCurrentCompletionSession(_ completed: CodexHeadCompletionSession) -> Bool {
        session === completed.session && sessionEpoch == completed.epoch
            && turns.last?.id == completed.turnID
    }

    /// Called from the landing task's defer, including early returns and failed landings.
    /// A restarted or re-steered head owns its own shutdown; this completion cannot stop it.
    func stopCompletedCodexHeadSession(_ completed: CodexHeadCompletionSession) async {
        await waitForProviderHistory()
        // A rewind may have acquired the same idle session as the archive finished.
        // Let it release that session, or clean it up after a failed rewind returns.
        while isCurrentCompletionSession(completed), phase == .idle, isReverting {
            guard (try? await Task.sleep(for: .milliseconds(50))) != nil else { return }
        }
        guard isCurrentCompletionSession(completed), phase == .idle, !isReverting else { return }
        stopSession()
    }

    /// A repeated completion or a settings change must not close a process in the
    /// middle of its already-dispatched archive. With no archive this stays synchronous.
    func stopHeadSessionAfterProviderHistory() {
        guard providerHistoryOperation != nil else {
            stopSession()
            return
        }
        let originalSession = session
        let epoch = sessionEpoch
        let completedTurn = turns.last?.id
        Task {
            await waitForProviderHistory()
            while session === originalSession, sessionEpoch == epoch,
                  turns.last?.id == completedTurn, phase == .idle, isReverting {
                guard (try? await Task.sleep(for: .milliseconds(50))) != nil else { return }
            }
            guard session === originalSession, sessionEpoch == epoch,
                  turns.last?.id == completedTurn, phase == .idle, !isReverting else { return }
            stopSession()
        }
    }

    /// Triggered only by a newly completed head, never by settings changes, startup,
    /// sidebar hiding, or local archive. No historical sweep or automatic retry.
    func archiveCodexHeadHistory(completion: CodexHeadCompletionSession) {
        guard isCurrentCompletionSession(completion),
              thread?.providerSessionID == completion.providerSessionID,
              providerHistoryOperation == nil, canArchiveCompletedHeadHistory,
              let app, app.settings.hydraArchivesCodexHeads,
              let head = thread, head.provider == .codex, let info = head.hydra,
              info.kind == .tivano, info.origin == .delegated, info.tracksProviderHistory, info.status == .completed,
              !info.codexHistoryArchived, let ownedID = info.ownedCodexSessionID,
              head.providerSessionID == ownedID, head.parentThreadID != nil,
              let codex = session as? CodexSession, codex.isRunning else { return }
        let epoch = sessionEpoch
        let continuationToken = autoStartedTurnToken
        providerHistoryOperation = Task { [weak self] in
            guard let self else { return }
            defer { providerHistoryOperation = nil }
            do {
                try await codex.archiveHeadHistory(expectedID: ownedID, stillEligible: { [weak self] in
                    guard let self, let current = thread else { return false }
                    return session === codex && sessionEpoch == epoch && canArchiveCompletedHeadHistory
                        && autoStartedTurnToken == continuationToken
                        && app.settings.hydraArchivesCodexHeads && current.provider == .codex
                        && current.providerSessionID == ownedID && current.hydra?.ownedCodexSessionID == ownedID
                        && current.hydra?.status == .completed && !current.isArchived
                }, willArchive: {
                    app.updateHydraHead(threadID) { $0.codexHistoryArchived = true }
                    do {
                        try await app.saveProviderHistoryIntent()
                    } catch {
                        app.updateHydraHead(threadID) { $0.codexHistoryArchived = false }
                        throw error
                    }
                })
                guard thread?.provider == .codex, thread?.providerSessionID == ownedID,
                      thread?.hydra?.ownedCodexSessionID == ownedID else { return }
                app.updateHydraHead(threadID) {
                    $0.codexHistoryArchived = true
                    $0.providerHistoryIssue = nil
                }
                appendNotice(.info, Chrome.localized("This head's Codex session history is archived. Its Tivano transcript is kept; a follow-up restores the same Codex session."))
            } catch {
                guard thread?.provider == .codex, thread?.providerSessionID == ownedID else { return }
                let message = String(format: Chrome.localized("Codex history archive was not confirmed: %@ No deletion was requested."), error.localizedDescription)
                app.updateHydraHead(threadID) { $0.providerHistoryIssue = message }
                appendNotice(.warning, message)
            }
            scheduleSave()
        }
    }

    /// `hasSentPrompts` intentionally counts a head's initial brief elsewhere. History
    /// cleanup must instead use the same user-authored distinction as `sentPrompts`:
    /// neither a Hydra brief nor a head report is a direct user follow-up.
    private var canArchiveCompletedHeadHistory: Bool {
        phase == .idle && !isReverting && !isLoadingHistory && sentPrompts.isEmpty
            && pendingSend == nil && followUps.isEmpty && !followUpFlushScheduled
            && hydraPendingReports.isEmpty && hydraBatches.isEmpty && hydraWaiting.isEmpty
            && !hydraFlushScheduled && !hasWorkingHeads
    }

    func waitForProviderHistory() async {
        while let operation = providerHistoryOperation { await operation.value }
    }

    /// Puts the session's ID on the thread, or holds it back while no message has gone
    /// through the session (`unsentSessionID`). A thread whose conversation the session
    /// picked up takes the ID at once: a provider may hand out a new one for it.
    private func recordSessionID(_ sessionID: String) {
        guard let app else { return }
        if app.thread(threadID)?.providerSessionID == nil {
            unsentSessionID = sessionID
        } else {
            app.updateThread(threadID) { $0.providerSessionID = sessionID }
        }
    }

    /// Whether a session that would not resume the thread's conversation starts over
    /// from nothing: only when the provider confirms the conversation is gone.
    private static func startsOver(after error: Error, resuming thread: ChatThread) -> Bool {
        guard thread.providerSessionID != nil else { return false }
        if lostConversation(error) { return true }
        // A rewind anchor is never given up, and neither is a conversation that only hit a
        // passing failure: a new session would drop the history for nothing. Anything else
        // starts over, out loud, since not every agent words a missing session the same way.
        return thread.providerResumeAt == nil && !passingFailure(error)
    }

    /// A failure that says nothing about the conversation itself: the agent was slow, the
    /// network or sign-in failed, or a limit was hit. Retrying the same session is right.
    private static func passingFailure(_ error: Error) -> Bool {
        if error is SessionDeadlineError || error is URLError || error is CancellationError { return true }
        if case ProviderError.notInstalled = error { return true }
        let text = error.localizedDescription.lowercased()
        return ["timed out", "timeout", "network", "offline", "connection refused", "could not connect",
                "unauthorized", "not authenticated", "sign in", "log in", "login", "401", "403",
                "rate limit", "429", "usage limit", "overloaded"].contains { text.contains($0) }
    }

    /// The provider's word for a conversation it no longer has: Claude Code's "No
    /// conversation found with session ID", Command Code's own line.
    private static func lostConversation(_ error: Error) -> Bool {
        let text = error.localizedDescription
        return text.localizedCaseInsensitiveContains("no conversation found")
            || text.localizedCaseInsensitiveContains("no longer has this conversation")
            || ["thread", "rollout", "session"].contains { subject in
                text.range(of: "\(subject)(?: id)?[^\n.:]{0,120}(?:not found|does not exist)", options: [.regularExpression, .caseInsensitive]) != nil
                    || text.localizedCaseInsensitiveContains("no \(subject) found")
            }
    }

    /// The conversation before the current turn as plain exchanges, for an API session
    /// that starts over: it keeps its history in memory only, so this is how a head
    /// steered on after its session went, or any chat reopened later, still knows what
    /// was said and done. Tool calls stay out; the replies say what they did. Bounded, so
    /// a long thread does not send its whole past with every relaunch.
    private func apiTranscript() -> [TranscriptMessage] {
        // One pass to collect the exchanges, then the runs are joined rather than
        // appended into one another: repeated `+=` on array elements copies the whole
        // reply for every fragment, which is quadratic on fragmented history.
        let exclude = currentTurnID
        var fragments: [(assistant: Bool, text: String)] = []
        fragments.reserveCapacity(entries.count)
        for entry in entries where entry.item.turnID != exclude {
            switch entry.item.content {
            case .user(let message) where !message.text.isEmpty:
                fragments.append((assistant: false, text: message.text))
            case .assistant(let message) where !message.text.isEmpty:
                fragments.append((assistant: true, text: message.text))
            default:
                break
            }
        }
        var transcript: [TranscriptMessage] = []
        transcript.reserveCapacity(fragments.count)
        var index = 0
        while index < fragments.count {
            if !fragments[index].assistant {
                transcript.append(TranscriptMessage(role: .user, text: fragments[index].text))
                index += 1
                continue
            }
            // The status lines a turn streams between its tools read as one reply.
            let runStart = index
            while index < fragments.count, fragments[index].assistant { index += 1 }
            let joined = fragments[runStart..<index].map(\.text).joined(separator: "\n\n")
            transcript.append(TranscriptMessage(role: .assistant, text: joined))
        }
        var kept = Array(transcript.suffix(40))
        var budget = 60_000
        for index in kept.indices.reversed() {
            let length = kept[index].text.count
            if length <= budget {
                budget -= length
            } else if budget > 200 {
                kept[index].text = "…" + String(kept[index].text.suffix(budget))
                budget = 0
            } else {
                kept.removeSubrange(...index)
                break
            }
        }
        return kept
    }

    // MARK: - Controls

    func interrupt() {
        guard phase != .idle else { return }
        let turnID = currentTurnID
        interruptWatchdog?.cancel()
        interruptWatchdog = nil
        // Nothing has been sent yet: the provider has no turn of its own to stop, and
        // asking it would do nothing at all, leaving the watchdog to kill a session that
        // is only just starting. The turn ends here instead, and the message it was about
        // to send never goes.
        if phase == .starting {
            currentTurnID = nil
            Task { await finishTurn(status: .interrupted, turnID: turnID) }
            return
        }
        Task {
            guard currentTurnID == turnID, turnID != nil else { return }
            if let session {
                await session.interrupt()
            } else {
                await finishTurn(status: .interrupted, turnID: turnID)
            }
        }
        interruptWatchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard let self, !Task.isCancelled, self.currentTurnID == turnID, turnID != nil else { return }
            self.releaseSession(stop: true)
            await self.finishTurn(status: .interrupted)
        }
    }

    func resolve(_ request: ApprovalRequest, option: ApprovalRequest.Option) {
        approvals.removeAll { $0.id == request.id }
        if request.kind == .plan, let itemID = request.toolItemID,
           let entry = entryIndex[itemID], case .plan(var plan) = entry.item.content {
            plan.state = option.role == .approve ? .accepted : .dismissed
            entry.item.content = .plan(plan)
            saveRevision += 1
            scheduleSave()
        }
        let delivered = answerDeliveryHandler()
        guard let session else { delivered(false); return }
        session.resolveApproval(request.id, optionID: option.id, delivered: delivered)
    }

    func answer(_ request: QuestionRequest, answers: [String: [String]]) {
        questions.removeAll { $0.id == request.id }
        let delivered = answerDeliveryHandler()
        guard let session else { delivered(false); return }
        session.answerQuestion(request.id, answers: answers, delivered: delivered)
    }

    private func answerDeliveryHandler() -> @MainActor (Bool) -> Void {
        let name = thread?.provider.displayName ?? Chrome.localized("the provider")
        return { [weak self] delivered in
            guard !delivered else { return }
            self?.appendNotice(.warning, String(format: Chrome.localized("Your answer didn't reach %@: its session had already closed. Send a message to carry on."), name))
        }
    }

    func compact() {
        guard phase == .idle else { return }
        guard let session, session.isRunning else {
            appendNotice(.info, "Nothing to compact yet.")
            return
        }
        appendNotice(.info, "Compacting context.")
        Task {
            do {
                try await session.compact()
                // Compaction replaces the session's history with a summary, and the
                // fallback prefix went with it: the next turn carries the policy again,
                // and the forwarded context along with it.
                antiSlopFallbackSent = false
                continuationSent = false
            } catch {
                appendNotice(.warning, error.localizedDescription)
            }
        }
    }

    /// What restoring the files to before a turn would touch: the whole checkout against
    /// the turn's checkpoint. A `git add` of the checkout into a scratch index plus a
    /// numstat, hundreds of milliseconds on a big repository, so the message editor asks
    /// for it from the pencil's hover and again on the click, and both get one run.
    /// Kept while the thread's files stay as the last turn left them (`diffRevision`) and
    /// for ten seconds, so edits made outside the app are picked up soon after.
    func revertPreview(for turnID: UUID) -> Task<RevertPreview, Error> {
        if let entry = revertPreviews[turnID], entry.revision == diffRevision, entry.startedAt.duration(to: .now) < .seconds(10) {
            return entry.task
        }
        let revision = diffRevision
        let task = Task { [weak self] () throws -> RevertPreview in
            guard let self else { throw ProviderError.notRunning }
            let result: Result<RevertPreview, Error>
            do { result = .success(try await self.previewRevert(to: turnID)) } catch { result = .failure(error) }
            if self.revertPreviews[turnID]?.revision == revision { self.revertPreviews[turnID]?.result = result }
            return try result.get()
        }
        // Previews of files as they were before the last turn are stale for every message.
        revertPreviews = revertPreviews.filter { $0.value.revision == revision }
        revertPreviews[turnID] = RevertPreviewEntry(revision: revision, startedAt: .now, task: task, result: nil)
        return task
    }

    /// The preview already in hand for a turn, if a hover fetched it: the editor opens on
    /// it at once instead of on a spinner.
    func cachedRevertPreview(for turnID: UUID) -> Result<RevertPreview, Error>? {
        guard let entry = revertPreviews[turnID], entry.revision == diffRevision,
              entry.startedAt.duration(to: .now) < .seconds(10) else { return nil }
        return entry.result
    }

    private struct RevertPreviewEntry {
        let revision: Int
        let startedAt: ContinuousClock.Instant
        let task: Task<RevertPreview, Error>
        var result: Result<RevertPreview, Error>?
    }

    /// Bounded by the thread's turns: only entries of the current revision are kept.
    @ObservationIgnored private var revertPreviews: [UUID: RevertPreviewEntry] = [:]

    /// The files this thread's agent changed from a turn on, as undoing them would find them.
    /// Only the paths its tools and shell commands touched are looked at, so work done in the
    /// same checkout by other threads or by hand never shows up here, let alone gets undone.
    private func previewRevert(to turnID: UUID) async throws -> RevertPreview {
        guard let app, let thread, let project = app.project(thread.projectID),
              let index = turns.firstIndex(where: { $0.id == turnID }), let base = turns[index].baseCheckpoint else {
            throw ProviderError.failed("No file checkpoint is available for this message. You can still keep the file changes.")
        }
        let removed = turns[index...]
        let paths = Set(removed.flatMap { $0.touchedPaths ?? [] }).sorted()
        let end = removed.compactMap(\.endCheckpoint).last
        return try await Git(thread.worktreePath ?? project.path).previewRestore(base: base, end: end, paths: paths)
    }

    /// Edits a sent message: the conversation rewinds to before its turn, the files it and
    /// everything after it changed are put back when asked, and the edited message goes out
    /// from there. Whatever was in the composer stays there. A rewind that fails throws and
    /// leaves the conversation as it was. Rewound but with the files not restored, the edit
    /// waits in the composer beside the notice instead of going out against the wrong tree.
    func resend(_ turnID: UUID, text: String, attachments: [Attachment], restoreFiles: Bool) async throws {
        let restored = try await revert(to: turnID, restoreFiles: restoreFiles)
        let edited = ComposerDraft(text: text, attachments: attachments)
        guard restored else {
            draft = edited
            return
        }
        let kept = draft
        draft = edited
        send()
        draft = kept
    }

    /// Rewinds the conversation to before a turn, optionally restoring the files it changed.
    /// Throws, with the conversation untouched, when it cannot; returns whether the files
    /// were restored as asked, a failure there being reported in the thread.
    @discardableResult
    func revert(to turnID: UUID, restoreFiles: Bool) async throws -> Bool {
        // Rewind restores/resumes and mutates the provider's same history. Acquire its
        // idle turn only after a prior archive has finished, just as a new send does.
        await waitForProviderHistory()
        guard phase == .idle, !isReverting else { throw ProviderError.failed("Wait for the running turn to finish first.") }
        guard let app, let thread = app.thread(threadID), let project = app.project(thread.projectID),
              let index = turns.firstIndex(where: { $0.id == turnID }) else {
            throw ProviderError.failed("This message is no longer in the thread.")
        }
        guard app.runningTivanoHeads(of: threadID) == 0 else {
            throw ProviderError.failed("Stop the running agents before reverting this conversation.")
        }
        let removed = Array(turns[index...])
        let directory = thread.worktreePath ?? project.path

        isReverting = true
        defer { isReverting = false }
        if restoreFiles {
            guard let base = removed.first?.baseCheckpoint else {
                throw ProviderError.failed("This turn has no file checkpoint. Choose to keep the file changes instead.")
            }
            _ = try await Git(directory).output(["rev-parse", "--verify", base])
        }
        switch thread.provider {
        case .codex:
            if let targetID = removed.lazy.compactMap(\.providerTurnID).first {
                guard thread.providerSessionID != nil,
                      let codex = try await ensureSession(directory: directory, allowNewSession: false) as? CodexSession else {
                    throw ProviderError.failed("The original Codex conversation is unavailable.")
                }
                let sessionID = try await codex.rollback(from: targetID)
                app.updateThread(threadID) { $0.providerSessionID = sessionID }
            } else if thread.providerSessionID != nil || removed.contains(where: { $0.status != .failed }) {
                throw ProviderError.failed("The selected message has no Codex turn ID, so its history cannot be safely reverted.")
            }
            stopSession()
        case .copilot:
            guard thread.providerSessionID != nil,
                  let copilot = try await ensureSession(directory: directory, allowNewSession: false) as? CopilotSession else {
                throw ProviderError.failed("The original Copilot conversation is unavailable.")
            }
            try await copilot.rollback(turns: removed.count)
            stopSession()
        case .claude:
            releaseSession(stop: true)
            if index == 0 {
                stopSession()
                app.updateThread(threadID) {
                    $0.providerSessionID = nil
                    $0.providerResumeAt = nil
                }
            } else {
                guard thread.providerSessionID != nil, let anchor = turns[index - 1].providerAnchor else {
                    throw ProviderError.failed("Claude has no resume point before this message. The conversation was kept.")
                }
                stopSession()
                app.updateThread(threadID) { $0.providerResumeAt = anchor }
            }
        default:
            // A provider that cannot rewind a conversation of its own starts a new one:
            // the files, the timeline and the draft are put back all the same, and the
            // next turn opens from the shortened history rather than the one that was
            // reverted away.
            releaseSession(stop: true)
            app.updateThread(threadID) {
                $0.providerSessionID = nil
                $0.providerResumeAt = nil
            }
        }

        var fileError: String?
        if restoreFiles, let base = removed.first?.baseCheckpoint {
            do {
                // Only what this thread changed and nothing has changed since goes back.
                let preview = try await previewRevert(to: turnID)
                try await Git(directory).restore(preview.restorable.map(\.path), from: base)
            } catch {
                fileError = "Conversation reverted, but files could not be restored: \(error.localizedDescription)"
            }
        }

        let removedIDs = Set(removed.map(\.id))
        entries.removeAll { entry in
            guard let turn = entry.item.turnID else { return false }
            return removedIDs.contains(turn)
        }
        entryIndex = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        turns.removeSubrange(index...)
        // A head's paths list is what the turn in flight has changed; the turn they
        // belonged to is gone.
        hydraTouched.removeAll()
        hydraCurrentTurnTouchedPaths = []
        // The thread's status is its last remaining turn's, or none: with every turn gone
        // it is unused again, so a new thread reuses it and ⌘W deletes it.
        app.updateThread(threadID) { $0.lastStatus = turns.last?.status }
        saveRevision += 1
        usage = nil
        if let fileError { appendNotice(.error, fileError) }
        diffSelection = nil
        diffRevision += 1
        scheduleSave()
        return fileError == nil
    }

    /// The files this thread's agent changed across every turn, or nil when it changed none.
    private(set) var changeStats: FileChangeSummary?

    @ObservationIgnored private var changeStatsRevision: Int?

    /// Runs once per diff revision: showing the thread again (switching threads, reopening the
    /// window) reuses what the last run found instead of running git and the parser again.
    func refreshChangeStats() async {
        let revision = diffRevision
        guard changeStatsRevision != revision else { return }
        let files = await parsedDiff(selection: nil)
        guard revision == diffRevision else { return }
        let stats = files.isEmpty ? nil : FileChangeSummary(files: files)
        if stats != changeStats { changeStats = stats }
        changeStatsRevision = revision
    }

    /// Parsed patches shared by the changes tab, the diff panel and the historical file
    /// cards. A finished turn's diff is fixed by its checkpoints and reported edits, so it is
    /// kept by turn for the runtime's life (a revert takes the turn, and its entry, away);
    /// the whole thread's and a running turn's move with the revision and go with it.
    /// Concurrent callers share one run.
    @ObservationIgnored private var turnDiffs = RecentCache<UUID, Task<[DiffFile], Never>>(limit: 64)
    @ObservationIgnored private var revisionDiffs = RecentCache<String, Task<[DiffFile], Never>>(limit: 4)
    @ObservationIgnored private var repositoryRootLookup: (directory: URL, id: UUID, task: Task<URL, Never>)?

    private func repositoryRoot(for git: Git) -> Task<URL, Never> {
        if let lookup = repositoryRootLookup, lookup.directory == git.directory { return lookup.task }
        let id = UUID()
        let task = Task { [weak self] in
            var repository = git.directory
            if let prefix = try? await git.output(["rev-parse", "--show-prefix"]) {
                for _ in prefix.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "/") {
                    repository.deleteLastPathComponent()
                }
            }
            if let self, repositoryRootLookup?.id == id { repositoryRootLookup = nil }
            return repository
        }
        repositoryRootLookup = (git.directory, id, task)
        return task
    }

    /// A finished turn's diff outlives revisions; anything else is keyed by the revision.
    private func fixedTurn(_ selection: UUID?) -> UUID? {
        guard let selection, let turn = turns.first(where: { $0.id == selection }), turn.status != .running else { return nil }
        return selection
    }

    private func cachedDiff(selection: UUID?) -> Task<[DiffFile], Never>? {
        if let turn = fixedTurn(selection) { return turnDiffs.value(for: turn) }
        return revisionDiffs.value(for: selection?.uuidString ?? "all")
    }

    private func cacheDiff(_ task: Task<[DiffFile], Never>, selection: UUID?) {
        if let turn = fixedTurn(selection) {
            turnDiffs.insert(task, for: turn)
        } else {
            revisionDiffs.insert(task, for: selection?.uuidString ?? "all")
        }
    }

    func hasCachedDiff(selection: UUID?) -> Bool {
        cachedDiff(selection: selection) != nil
    }

    func turnsWithChanges() -> [TurnRecord] {
        var edited: Set<UUID> = []
        for entry in entries {
            guard let id = entry.turnID, case .tool(let call) = entry.item.content, !call.edits.isEmpty else { continue }
            edited.insert(id)
        }
        return turns.filter { $0.endCheckpoint != nil || $0.providerDiff != nil || $0.touchedPaths?.isEmpty == false || edited.contains($0.id) }
    }

    func parsedDiff(selection: UUID?, providerFiles: [DiffFile]? = nil) async -> [DiffFile] {
        if let task = cachedDiff(selection: selection) { return await task.value }
        guard let app, let thread = app.thread(threadID), let project = app.project(thread.projectID) else { return [] }
        let root = thread.worktreePath ?? project.path
        let git = Git(root)
        let repository = repositoryRoot(for: git)
        let selectedTurns = selection.map { id in turns.filter { $0.id == id } } ?? turns
        guard !selectedTurns.isEmpty else { return [] }
        let selectedIDs = Set(selectedTurns.map(\.id))
        // The agent's writes to its own notes and settings, a scratch file in /tmp, a
        // stray write into a head's copy: none of it is the chat's work, and a memory
        // note it saved showed on the turn's card as "Edited 1 file" in a chat that had
        // changed nothing. A file in another sidebar project is work, and stays.
        let projectRoots = app.projects.map(\.path)
        let edits = entries.flatMap { entry -> [FileEdit] in
            guard let id = entry.turnID, selectedIDs.contains(id), case .tool(let call) = entry.item.content else { return [] }
            return call.edits.filter { Self.isProjectFile($0.path, root: root, projects: projectRoots) }
        }
        // Only the files this chat's turns reported count. A turn without a record (one cut off
        // by a crash) contributes nothing rather than lifting the filter: the snapshot spans the
        // whole checkout and would otherwise show every merge and other thread's work since the
        // chat began.
        let touched = Set(selectedTurns.flatMap { $0.touchedPaths ?? [] }.map { TouchedPaths.normalize($0, root: root) })
        var span: (first: String, last: String)?
        if let ended = selectedTurns.lastIndex(where: { $0.endCheckpoint != nil }),
           let first = selectedTurns[...ended].first(where: { $0.baseCheckpoint != nil })?.baseCheckpoint,
           let last = selectedTurns[ended].endCheckpoint {
            span = (first, last)
        }
        let task = Task { () -> [DiffFile] in
            let repositoryPath = await repository.value.path
            let providerPatch = providerFiles == nil ? selectedTurns.compactMap(\.providerDiff).joined(separator: "\n") : ""
            let reported = providerFiles ?? DiffParser.parse(providerPatch)
            let paths = Set((Array(touched) + reported.flatMap { [$0.path] + ($0.oldPath.map { [$0] } ?? []) } + edits.map(\.path)).compactMap { path -> String? in
                guard !path.isEmpty else { return nil }
                let absolute = URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: root, isDirectory: true)).standardizedFileURL.path
                return TouchedPaths.relative(absolute, root: repositoryPath)
            })
            var snapshot: String?
            // The paths are the repository's, and git reads a pathspec against the folder it
            // runs in: a project inside a larger repository asks for the whole diff instead.
            let atTop = URL(fileURLWithPath: repositoryPath).resolvingSymlinksInPath().standardizedFileURL.path
                == URL(fileURLWithPath: root).resolvingSymlinksInPath().standardizedFileURL.path
            if let span { snapshot = try? await git.diff(from: span.first, to: span.last, paths: paths.isEmpty || !atTop ? nil : paths.sorted()) }
            return await Self.resolveDiff(repositoryRoot: repository.value.path, snapshot: snapshot, providerPatch: providerPatch, providerFiles: providerFiles, edits: edits, touched: touched, root: root)
        }
        cacheDiff(task, selection: selection)
        return await task.value
    }

    /// Whether a path an agent reported editing lies in the chat's checkout or in another
    /// sidebar project: the files a turn's card and diff can speak for.
    private static func isProjectFile(_ path: String, root: String, projects: [String]) -> Bool {
        TouchedPaths.relative(path, root: root) != nil || projects.contains { TouchedPaths.relative(path, root: $0) != nil }
    }

    @concurrent
    private nonisolated static func resolveDiff(repositoryRoot: String, snapshot: String?, providerPatch: String, providerFiles: [DiffFile]?, edits: [FileEdit], touched: Set<String>, root: String) async -> [DiffFile] {
        TurnDiff.merge(snapshot: snapshot.map { DiffParser.parse($0) }, providerPatch: providerPatch, edits: edits, touched: touched, root: root, repositoryRoot: repositoryRoot, providerFiles: providerFiles)
    }

    @concurrent
    private nonisolated static func parseDiff(_ patch: String) async -> [DiffFile] {
        DiffParser.parse(patch)
    }

    /// Only the session observed last is listened to: one observed before it may still
    /// speak as it closes, and nothing it says reaches the thread.
    func observe(_ provider: any ProviderSession) {
        sessionEpoch += 1
        let epoch = sessionEpoch
        provider.onEvent = { [weak self] event in
            guard let self, self.sessionEpoch == epoch else { return }
            self.handle(event)
        }
    }

    /// Lets a session go: from here on it drives nothing, whatever it still has to say as
    /// it closes. Its handler is cleared a turn of the loop later, because a session that
    /// is ending usually says so from inside that very handler.
    private func releaseSession(stop: Bool) {
        backgroundTasks = []
        opensTurnAfterFinish = false
        deferredBackgroundTurnEvents.removeAll()
        sessionEpoch += 1
        sessionSignature = nil
        unsentSessionID = nil
        // A new session has a new history: whatever the fallback prefix did in the old
        // one, it has to go out again, and a forwarded context needs a new session to
        // land in. Reset before any early return, so a session that was never made still
        // leaves the next one to deliver both.
        antiSlopFallbackSent = false
        continuationSent = false
        guard let old = session else { return }
        session = nil
        if stop {
            sessionsAwaitingReplacement.append(old)
            old.stop()
        }
        Task { old.onEvent = nil }
    }

    private func waitForReplacedSessions() async throws {
        let epoch = sessionEpoch
        let oldSessions = sessionsAwaitingReplacement
        for old in oldSessions {
            await old.stopAndWait(timeout: 2)
            guard sessionEpoch == epoch, !Task.isCancelled else { throw CancellationError() }
        }
        // By identity: another start may have waited on and cleared some of these meanwhile.
        sessionsAwaitingReplacement.removeAll { session in oldSessions.contains { $0 === session } }
    }

    private func recoverCrashedCodexTurn(using codex: CodexSession) {
        guard !attemptedCodexCrashRecovery else { return }
        attemptedCodexCrashRecovery = true
        // Reading provider history must never sit in front of the user's send.
        Task { [weak self, weak codex] in
            guard let self else { return }
            await self.ensureLoaded()
            guard let turn = self.turns.last(where: { self.crashInterruptedTurnIDs.contains($0.id) && $0.providerTurnID != nil }),
                  let providerTurnID = turn.providerTurnID, let codex else { return }
            let read: (status: TurnStatus, lastAgentMessage: String?)?
            do { read = try await codex.readTurn(providerTurnID) } catch { return }
            guard let result = read, result.status == .completed,
                  let index = self.turns.firstIndex(where: { $0.id == turn.id && $0.status == .interrupted }),
                  let endIndex = self.entries.lastIndex(where: { $0.turnID == turn.id && $0.kind == .turnEnd }),
                  case .turnEnd(var summary) = self.entries[endIndex].item.content else { return }
            self.turns[index].status = .completed
            summary.status = .completed
            self.entries[endIndex].item.content = .turnEnd(summary)
            let turnEntries = self.entries[..<endIndex].filter { $0.turnID == turn.id }
            let lastTool = turnEntries.lastIndex(where: { $0.kind == .tool })
            let hasReply = turnEntries.enumerated().contains { offset, entry in
                entry.kind == .assistant && (lastTool.map { offset > $0 } ?? true)
            }
            var recoveredItems = [TimelineItem(turnID: turn.id, content: .notice(Notice(level: .info, message: Chrome.localized("Recovered how the last turn ended from Codex."))))]
            if !hasReply, let text = result.lastAgentMessage, !text.trimmed.isEmpty {
                recoveredItems.append(TimelineItem(turnID: turn.id, content: .assistant(AssistantMessage(text: TextCleanup.withoutEmDashes(text)))))
            }
            for (offset, item) in recoveredItems.enumerated() {
                let entry = TimelineEntry(item)
                self.entries.insert(entry, at: endIndex + offset)
                self.entryIndex[item.id] = entry
            }
            self.saveRevision += 1
            self.saveNow()
        }
    }

    func stopSession() {
        releaseSession(stop: true)
        stopNativeHeads()
        // The session's own end is dropped with it (see `releaseSession`), so a turn cut
        // off here is closed by hand: left running, the thread showed the working line
        // for good once reopened, Return queued instead of sending, a head's lead heard
        // nothing until the budget fired. `finishTurn` saves what the turn had.
        guard phase != .idle else { return }
        // A turn cut off here has events its save timer has not written yet, and the timer
        // may not outlive the runtime.
        saveNow()
        // Nothing is left to end the turn, so it ends here, as interrupted. It leaves
        // `currentTurnID` first, the way a stop during a start does, so a message still on
        // its way to the session never goes.
        let turnID = currentTurnID
        currentTurnID = nil
        Task { await finishTurn(status: .interrupted, turnID: turnID) }
    }

    // MARK: - Events

    /// Opens the turn Claude started by itself while `finishTurn` was finalizing the one
    /// before, and hands it the events that waited. Returns whether there was one.
    private func replayBackgroundTurn() -> Bool {
        guard opensTurnAfterFinish else { return false }
        opensTurnAfterFinish = false
        let events = deferredBackgroundTurnEvents
        deferredBackgroundTurnEvents.removeAll()
        finishingTurnID = nil
        closingTurnID = nil
        for event in events { handle(event) }
        return true
    }

    private func openBackgroundTurn() {
        rehearseTurn(nil)
        let name = thread?.provider.displayName ?? Chrome.localized("The agent")
        appendNotice(.info, String(format: Chrome.localized("%@ picked the work back up after a background task finished."), name))
    }

    private func handle(_ event: ProviderEvent) {
        if opensTurnAfterFinish {
            deferredBackgroundTurnEvents.append(event)
            return
        }
        switch event {
        case .sessionReady(let sessionID):
            recordSessionID(sessionID)
        case .turnStarted(let providerTurnID):
            if finishingTurnID != nil, currentTurnID == nil || finishingTurnID == currentTurnID {
                opensTurnAfterFinish = true
                deferredBackgroundTurnEvents.append(event)
                return
            }
            if currentTurnID == nil { openBackgroundTurn() }
            phase = .running
            if let currentTurnID, let providerTurnID {
                updateTurn(currentTurnID) {
                    if $0.providerTurnID == nil { $0.providerTurnID = providerTurnID }
                }
            }
            saveNow()
        case .backgroundTasks(let descriptions):
            backgroundTasks = descriptions
        case .messageDelta(let id, let text):
            queueDelta(id, .message, text)
        case .messageCompleted(let id, let text):
            flushDeltas()
            completeMessage(id, text: text)
        case .reasoningDelta(let id, let text):
            queueDelta(id, .reasoning, text)
        case .reasoningCompleted(let id, let text):
            flushDeltas()
            completeReasoning(id, text: text)
        case .toolStarted(let id, let call):
            flushDeltas()
            upsertTool(id, call)
            if call.kind == .command { watchCommand(id, call) }
        case .toolOutput(let id, let text):
            queueDelta(id, .toolOutput, text)
        case .toolUpdated(let id, let update):
            flushDeltas()
            applyToolUpdate(id, update)
            if let entry = entryIndex[id], case .tool(let call) = entry.item.content,
               call.kind == .command, call.status != .running {
                settleCommand(id)
            }
            if let status = update.status, status != .running, let headID = hydraToolHeads[id] {
                hydraToolFinished(headID, status: status, output: update.output)
            }
        case .planDelta(let id, let text):
            queueDelta(id, .plan, text)
        case .planCompleted(let id, let markdown):
            flushDeltas()
            completePlan(id, markdown: markdown)
        case .todos(let steps):
            upsertTodos(steps)
        case .approval(let request):
            approvals.removeAll { $0.id == request.id }
            approvals.append(request)
            app?.threadNeedsAttention(threadID)
        case .question(let request):
            questions.removeAll { $0.id == request.id }
            questions.append(request)
            app?.threadNeedsAttention(threadID)
        case .requestResolved(let id):
            approvals.removeAll { $0.id == id }
            questions.removeAll { $0.id == id }
        case .usage(let usage):
            self.usage = usage
            saveRevision += 1
            // The turn just spent from the account, so the balance read before it is stale.
            if let provider = thread?.provider {
                app?.providers.invalidateCredits(provider)
                app?.providers.invalidatePlanLimits(provider)
            }
        case .diff(let diff):
            if currentTurnID != nil { currentProviderDiff = diff }
        case .notice(let notice):
            appendNotice(notice.level, notice.message)
        case .usageLimit(let resetsAt):
            app?.autoContinue.noteLimit(threadID, resetsAt: resetsAt)
        case .modeChanged(let mode):
            app?.updateThread(threadID) { $0.interactionMode = mode }
        case .models(let list, _):
            if let provider = thread?.provider { app?.providers.updateCatalog(list, for: provider) }
        case .commands(let list):
            if let app, let thread, let project = app.project(thread.projectID) {
                app.providers.updateCommands(list, for: thread.provider, directory: thread.worktreePath ?? project.path)
            }
        case .title(let title):
            // Provider titles are only a fallback; they must not replace the one Tivano writes.
            guard turns.count <= 1, let app, let thread, !thread.hasCustomTitle,
                  app.textEngine(preferring: thread.provider) == nil else { break }
            app.updateThread(threadID) { $0.title = TextCleanup.withoutEmDashes(title) }
        case .assistantMessageID(let anchor):
            if currentTurnID != nil { currentProviderAnchor = anchor }
        case .turnCompleted(let status, let error):
            flushDeltas()
            let turnID = currentTurnID
            if let error, finishTurnUpdatingCLI(error, status: status, turnID: turnID) { break }
            if let error { appendNotice(.error, error) }
            Task { await finishTurn(status: status, turnID: turnID) }
        case .exited(let error):
            backgroundTasks = []
            flushDeltas()
            // A session that exits while it starts is reported by its `start()` throwing:
            // `ensureSession` starts over where it can, and otherwise the turn ends with
            // that error. Letting the session go here broke the start-over, which needs
            // the session it replaces still in place, and failed the turn before it.
            if isStartingSession { break }
            releaseSession(stop: false)
            approvals.removeAll()
            questions.removeAll()
            stopNativeHeads()
            if currentTurnID != nil {
                let name = thread?.provider.displayName ?? "The agent"
                let turnID = currentTurnID
                if let error, finishTurnUpdatingCLI(error, status: .failed, turnID: turnID) { break }
                appendNotice(.error, error ?? "\(name) stopped unexpectedly.")
                Task { await finishTurn(status: .failed, turnID: turnID) }
            }
        case .tokenSpend(let spend):
            if let agentID = spend.agentID, thread?.hydra?.kind != .native {
                if let headID = hydraNativeHeads[agentID], let headRuntime = app?.runtime(for: headID) {
                    headRuntime.recordTokenSpend(spend)
                } else {
                    pendingNativeSpend[agentID, default: []].append(spend)
                }
            } else {
                recordTokenSpend(spend)
            }
        case .agentStarted(let spawn):
            hydraAgentStarted(spawn)
        case .agentEvent(let agentID, let event):
            hydraAgentEvent(agentID, event)
        case .agentProgress(let agentID, let summary, let lastTool, let tokens, let toolCalls):
            guard let headID = hydraNativeHeads[agentID], let headRuntime = app?.runtime(for: headID) else { break }
            if let summary, !summary.isEmpty { headRuntime.hydraActivity = summary } else if let lastTool { headRuntime.hydraActivity = lastTool }
            if let tokens { headRuntime.hydraTokens = tokens }
            if let toolCalls { headRuntime.hydraToolCalls = toolCalls }
            headRuntime.hydraLastEventAt = .now
        case .agentFinished(let agentID, let status, let summary):
            hydraAgentFinished(agentID, status: status, summary: summary)
        }
    }

    /// A model newer than the installed CLI fails with the CLI's own "version X or newer
    /// is required". That is not left to the user: the turn ends, the CLI runs its own
    /// updater, and the message goes out again on the new version. Returns whether the
    /// error was taken that way; the caller then neither posts it nor ends the turn.
    private func finishTurnUpdatingCLI(_ error: String, status: TurnStatus, turnID: UUID?) -> Bool {
        guard let turnID, let provider = thread?.provider, ProviderRegistry.updatesOwnCLI(provider),
              ProviderRegistry.needsNewerCLI(error) else { return false }
        // Part of the turn, so the resend's rewind takes it away with the failed attempt.
        appendNotice(.info, "This model needs a newer \(provider.displayName). Updating it, then sending your message again.")
        Task { [weak self] in
            guard let self else { return }
            await finishTurn(status: status, turnID: turnID)
            await resendAfterCLIUpdate(turnID, provider: provider, error: error)
        }
        return true
    }

    private func resendAfterCLIUpdate(_ turnID: UUID, provider: ProviderKind, error: String) async {
        guard let app else { return }
        let command = provider == .claude ? "claude update" : "codex update"
        await app.providers.updateCLIIfDue(provider, force: true)
        guard let version = await app.providers.installedCLIVersion(provider), cliResendVersions[provider] != version else {
            appendNotice(.error, "\(error)\n\nTivano could not bring \(provider.displayName) up to date. Run `\(command)` in Terminal, then send the message again.")
            return
        }
        cliResendVersions[provider] = version
        // The session still runs the binary that refused: the next one starts the new one.
        releaseSession(stop: true)
        guard phase == .idle, let turn = turns.first(where: { $0.id == turnID }), let itemID = turn.userItemID,
              let entry = entryIndex[itemID], case .user(let message) = entry.item.content, !message.isFromHydra else {
            appendNotice(.error, "\(error)\n\n\(provider.displayName) is up to date now (\(version)). Send the message again.")
            return
        }
        do {
            try await resend(turnID, text: message.text, attachments: message.attachments, restoreFiles: false)
        } catch {
            appendNotice(.error, "\(provider.displayName) is up to date now (\(version)), but the message could not be sent again: \(error.localizedDescription) Send it again.")
        }
    }

    private func recordTokenSpend(_ spend: TokenSpend) {
        guard spend.totalTokens > 0,
              let index = turns.lastIndex(where: { $0.id == currentTurnID }) ?? (thread?.hydra?.kind == .native ? turns.indices.last : nil) else { return }
        var amounts = turns[index].tokenSpends ?? []
        if let source = amounts.firstIndex(where: { $0.provider == spend.provider && $0.model == spend.model && $0.agentID == spend.agentID }) {
            amounts[source].merge(spend)
        } else {
            amounts.append(spend)
        }
        turns[index].tokenSpends = amounts
        if thread?.hydra?.kind == .tivano { hydraTokens += spend.totalTokens }
        saveRevision += 1
        scheduleSave()
    }

    /// Closes the running turn. `turnID` names the turn when the caller has already taken
    /// it out of `currentTurnID`, as a stop during the start of a turn does, so that the
    /// message on its way can no longer be sent.
    private func finishTurn(status: TurnStatus, turnID explicitTurnID: UUID? = nil) async {
        interruptWatchdog?.cancel()
        interruptWatchdog = nil
        headBudget?.cancel()
        headBudget = nil
        guard let turnID = explicitTurnID ?? currentTurnID, let turn = turns.first(where: { $0.id == turnID }) else {
            phase = .idle
            turnStartedAt = nil
            drainPendingSend()
            return
        }
        // Claimed before the first suspension below: a completion and an exit can both
        // arrive for one turn, and the second finalizer finds it taken.
        guard finishingTurnID != turnID else { return }
        finishingTurnID = turnID
        defer { finishingTurnID = nil }
        // Command diffs land before the turn's own summary counts them, and
        // while the turn is still current so the snapshots can be compared. The heads'
        // commands settle with them: their files are part of this turn's work.
        for id in Array(commandTrees.keys) { settleCommand(id) }
        for key in Array(hydraCommandTrees.keys) { settleHydraCommand(key) }
        // A completion queued behind a stop can arrive after the next turn has begun; the
        // turn it names is over, and the one running is left alone.
        guard currentTurnID == nil || currentTurnID == turnID else { return }
        // A finished turn waits for its diffs; a stopped or failed one gives them three
        // seconds and lets the rest land on their own, so Stop never hangs on git.
        closingTurnID = turnID
        defer { closingTurnID = nil }
        let settles = Array(commandSettles.values)
        commandSettles.removeAll()
        if status == .completed {
            for task in settles { await task.value }
        } else {
            await withTaskGroup(of: Void.self) { group in
                group.addTask { for task in settles { await task.value } }
                group.addTask { try? await Task.sleep(for: .seconds(3)) }
                await group.next()
                group.cancelAll()
            }
        }
        currentTurnID = nil
        flushDeltas()
        approvals.removeAll()
        questions.removeAll()
        // One pass over the turn's rows: they are closed, and the files their tools
        // reported are collected for the summary below rather than scanned for again.
        var reportedEdits: [FileEdit] = []
        for entry in entries where entry.item.turnID == turnID {
            endStreaming(entry)
            guard case .tool(var call) = entry.item.content else { continue }
            if call.status == .running {
                call.finish(status == .completed ? .completed : .failed)
                entry.item.content = .tool(call)
                saveRevision += 1
            }
            reportedEdits.append(contentsOf: call.edits)
        }
        let providerDiff = currentProviderDiff
        let providerAnchor = currentProviderAnchor
        currentProviderDiff = nil
        currentProviderAnchor = nil
        updateTurn(turnID) {
            $0.status = status
            $0.completedAt = .now
            if let providerDiff { $0.providerDiff = providerDiff }
            if let providerAnchor { $0.providerAnchor = providerAnchor }
        }
        if let providerAnchor, thread?.providerResumeAt != nil {
            app?.updateThread(threadID) { $0.providerResumeAt = providerAnchor }
        }

        let providerPatch = providerDiff ?? turns.first(where: { $0.id == turnID })?.providerDiff ?? ""
        // Parsed off the main actor, and only once: a turn's patch can be large, and
        // this lands exactly as the reply appears.
        let providerFiles = providerPatch.isEmpty ? [] : await Self.parseDiff(providerPatch)
        if let app, let thread = app.thread(threadID), let project = app.project(thread.projectID) {
            let root = thread.worktreePath ?? project.path
            let git = Git(root)
            var endCheckpoint: String?
            if turn.baseCheckpoint != nil {
                let ref = Git.checkpointRef(thread: threadID, turn: turn.index, phase: "end")
                if (try? await git.captureCheckpoint(ref)) != nil { endCheckpoint = ref }
            }
            // Only files this thread's agent edited count, never edits made elsewhere in
            // the repository meanwhile. A path outside the checkout is no part of the turn:
            // the agent writes to its own notes and settings too, and git cannot stage a
            // file it does not hold.
            var touched = Set<String>()
            for edit in reportedEdits {
                if let path = TouchedPaths.relative(edit.path, root: root) { touched.insert(path) }
            }
            // The provider's own repository diff is no part of a turn's record, because
            // it spans every file that changed in the checkout while the turn ran, another
            // chat's work included, and one such file was once merged out under a chat that
            // had changed nothing; a change of the turn that no edit reported is caught by
            // the merge's checkout sweep instead.
            // What the lead's native heads changed, which their own timelines carry: this
            // turn takes it, whether it came during the turn or between the last and this.
            touched.formUnion(hydraTouched)
            hydraTouched.removeAll()
            let touchedPaths = touched.sorted()
            // One write of `turns`: every write re-evaluates the timeline body.
            updateTurn(turnID) {
                if let endCheckpoint { $0.endCheckpoint = endCheckpoint }
                $0.touchedPaths = touchedPaths
            }
            // The turn is done touching: the live set is folded in so it holds the turn's
            // finished paths for any head that asks afterwards what this turn changed
            // (see `hydraCurrentTurnTouchedPaths`). It is cleared in `startTurn`,
            // `install` and `revert`, not here.
            hydraCurrentTurnTouchedPaths.formUnion(touched)
        }
        diffRevision += 1
        let changes = FileChangeSummary(files: await parsedDiff(selection: turnID, providerFiles: providerFiles))

        let summary = TurnSummary(
            turnID: turnID,
            status: status,
            duration: Date.now.timeIntervalSince(turn.startedAt),
            filesChanged: changes.files.count,
            additions: changes.additions,
            deletions: changes.deletions,
            changes: changes
        )
        append(TimelineItem(turnID: turnID, content: .turnEnd(summary)))
        phase = .idle
        turnStartedAt = nil
        // The turn's own events shared one save every few seconds; whatever they left is
        // written here, so a finished turn is always on disk.
        saveNow()
        settleForegroundHeads(after: status)
        guard thread?.isArchived != true else {
            headBudgetSpent = false
            let continues = replayBackgroundTurn()
            app?.turnFinished(threadID, status: status, continues: continues)
            return
        }
        // The Return-while-running message jumps the queue: it goes right away
        // and anything queued waits for it. A reply that ends in a delegation block
        // sends the heads out instead, and their reports come back as a message of
        // their own; the lead is free meanwhile, so the next queued prompt starts on
        // it at once rather than waiting out the heads, and the reports follow that
        // turn. Either way the app hears whether a next turn is on its way, so
        // "finished" only sounds when nothing is.
        var continues: Bool
        if replayBackgroundTurn() {
            continues = true
        } else if pendingSend != nil {
            continues = drainPendingSend()
        } else if status == .completed, case let delegation = spawnDelegatedHeads(for: turnID), delegation != .none {
            continues = true
            if delegation == .headsOut { _ = drainFollowUps(after: status) }
        } else if status == .completed, flushHydraReports() {
            continues = true
        } else {
            // A turn that failed or was stopped with a block in its reply: the block leaves
            // the reply and a note says no heads went out, rather than the raw block
            // sitting there as if something were coming.
            if status != .completed { dropDelegationBlock(for: turnID, status: status) }
            continues = drainFollowUps(after: status)
        }
        // Reports that came in while this turn ran are heard whatever became of it. Only a
        // turn the user stopped is left alone, as their queued messages are: they are in
        // charge of the chat then, and the reports go out with their next word.
        if !continues, status != .interrupted, flushHydraReports() { continues = true }
        // Heads still out will report, and the lead will work again: the job is not
        // finished until it has heard from all of them.
        if !continues, status == .completed, let app, app.runningTivanoHeads(of: threadID) > 0 { continues = true }
        // A head stopped for its budget writes its report as its next turn, so its lead
        // hears what it managed rather than only that it was stopped.
        if headBudgetSpent {
            headBudgetSpent = false
            if status == .interrupted, thread?.hydra?.kind == .tivano {
                headReportsNext = true
                // This turn starts on its own (see autoStartedTurnToken).
                autoStartedTurnToken &+= 1
                Task { await ensureLoaded(); await startTurn(text: HydraBudget.finalNote, attachments: []) }
                continues = true
            }
        }
        app?.turnFinished(threadID, status: status, continues: continues)
        // The job is done: the lead has answered, every head is back and nothing is
        // waiting. With the setting on, the work goes out and lands by itself, whether
        // heads took part or the lead did it all; a job that changed no file is let be.
        // Native heads are not in the batches: they run on inside the lead's session after
        // the lead's reply ends, and report in a turn of their own later. A merge while any
        // head is still at work would commit its half-done files and then, the head having
        // finished before the next turn began, never come back for the rest.
        if !continues, status == .completed,
           hydraPendingReports.isEmpty, hydraBatches.isEmpty, hydraWaiting.isEmpty,
           let app, let thread, app.hydraIsOn(thread), app.settings.hydraAutoMerge,
           app.runningHydraHeads(of: threadID) == 0 {
            Task { await app.autoMergeHydraWork(of: threadID) }
        }
    }

    /// Sends the message captured by Return while a turn ran, once the stop
    /// lands. Runs for any finish status: if the turn completed on its own in
    /// the meantime, the message still goes right away. Returns whether a turn starts.
    @discardableResult
    private func drainPendingSend() -> Bool {
        guard phase == .idle, let pending = pendingSend else { return false }
        pendingSend = nil
        let text = pending.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !pending.attachments.isEmpty else {
            scheduleSave()
            return false
        }
        if handleLocalCommand(text) { return false }
        Task { await ensureLoaded(); await startTurn(text: pending.text, attachments: pending.attachments) }
        return true
    }

    // MARK: - Hydra

    /// An idle provider may still have a report or a user message waiting to run.
    /// Those continuations must finish before its files take part in a merge.
    var isReadyForHydraMerge: Bool {
        phase == .idle && !isLoadingHistory && !isReverting && pendingSend == nil
            && turns.last?.status == .completed && !hasWorkingHeads
            && hydraPendingReports.isEmpty && hydraBatches.isEmpty && hydraWaiting.isEmpty
            && !hydraFlushScheduled
    }

    /// The auto-merge has landed these turns' work: the next merge starts from what came
    /// after them, rather than offering the same files again.
    func markHydraMerged(_ turnIDs: [UUID]) {
        let ids = Set(turnIDs)
        var changed = false
        for index in turns.indices where ids.contains(turns[index].id) && !turns[index].hydraMerged {
            turns[index].hydraMerged = true
            changed = true
        }
        guard changed else { return }
        saveRevision += 1
        saveNow()
    }

    /// The turns whose work has not been merged yet, oldest first.
    var hydraUnmergedTurns: [TurnRecord] {
        turns.filter { !$0.hydraMerged }
    }

    /// The auto-merge's latest outcome for this thread, kept for the lead's next message.
    func recordHydraMerge(_ record: HydraMergeRecord) {
        hydraMerges.append(record)
        if hydraMerges.count > 20 { hydraMerges.removeFirst(hydraMerges.count - 20) }
        saveRevision += 1
        saveNow()
    }

    /// How many distinct files the finished, unmerged turns of this thread touched.
    var hydraUnmergedFileCount: Int {
        Set(hydraUnmergedTurns.filter { $0.status != .running }.flatMap { $0.touchedPaths ?? [] }).count
    }

    /// The head a tool row in this timeline sent out, if any.
    func hydraHead(forTool toolID: String) -> UUID? {
        hydraToolHeads[toolID]
    }

    /// Captures-only mapping of a tool row to its head thread.
    func rehearseHydraHead(toolID: String, headID: UUID) {
        hydraToolHeads[toolID] = headID
    }

    /// A head the provider started inside this session, or more said about one already
    /// known: a name for the tool call that spawned it, its brief.
    private func hydraAgentStarted(_ spawn: AgentSpawn) {
        guard let app, let thread, app.hydraIsOn(thread) else { return }
        if let headID = hydraNativeHeads[spawn.id] {
            let named = !spawn.description.isEmpty && spawn.description != "Subagent"
            app.updateThread(headID) { head in
                guard var info = head.hydra else { return }
                if named, info.task != spawn.description {
                    info.task = spawn.description
                    head.title = "\(info.persona.name) · \(TextCleanup.singleLine(spawn.description, limit: 60))"
                }
                if info.toolUseID == nil { info.toolUseID = spawn.toolUseID }
                head.hydra = info
            }
            if let toolUseID = spawn.toolUseID { hydraToolHeads[toolUseID] = headID }
            if let prompt = spawn.prompt, let headRuntime = app.existingRuntime(for: headID), !headRuntime.hasSentPrompts {
                headRuntime.rehearseBrief(prompt)
            }
            return
        }
        guard let head = app.spawnNativeHead(from: threadID, spawn: spawn) else { return }
        hydraNativeHeads[spawn.id] = head.id
        if let pending = pendingNativeSpend.removeValue(forKey: spawn.id) {
            for spend in pending { app.runtime(for: head.id).recordTokenSpend(spend) }
        }
        if let toolUseID = spawn.toolUseID { hydraToolHeads[toolUseID] = head.id }
    }

    /// An event from inside a head's transcript, rehearsed on the head's own timeline.
    private func hydraAgentEvent(_ agentID: String, _ event: ProviderEvent) {
        guard let app else { return }
        // A head heard from before it was announced: on Claude the agent id is the tool
        // call that spawned it, so the row already names its task.
        if hydraNativeHeads[agentID] == nil, let entry = entryIndex[agentID], case .tool(let call) = entry.item.content, call.kind == .agent {
            hydraAgentStarted(AgentSpawn(id: agentID, taskID: nil, toolUseID: agentID, description: call.title, prompt: nil, model: nil, isBackground: false))
        }
        guard let headID = hydraNativeHeads[agentID], let headRuntime = app.existingRuntime(for: headID) else { return }
        switch event {
        case .turnStarted:
            // A head briefed again by its lead works another turn.
            if !headRuntime.isRunning {
                headRuntime.rehearseTurn(nil)
                app.updateHydraHead(headID) {
                    $0.status = .running
                    $0.finishedAt = nil
                }
            }
        case .turnCompleted(let status, _):
            hydraAgentFinished(agentID, status: status, summary: nil)
        case .toolStarted(let toolID, let call):
            headRuntime.hydraToolCalls += 1
            headRuntime.hydraActivity = ToolPresentation.label(for: call)
            headRuntime.hydraLastEventAt = .now
            noteHydraEdits(call.edits)
            if call.kind == .command { watchHydraCommand("\(agentID)-\(toolID)", call) }
            headRuntime.rehearse(event)
        case .toolUpdated(let toolID, let update):
            if let edits = update.edits { noteHydraEdits(edits) }
            if let status = update.status, status != .running { settleHydraCommand("\(agentID)-\(toolID)") }
            headRuntime.rehearse(event)
        case .usage, .sessionReady, .models, .commands, .title, .assistantMessageID, .backgroundTasks:
            break
        default:
            headRuntime.rehearse(event)
        }
    }

    /// A head finished: its timeline closes and its status lands, and the tool row that
    /// sent it out completes if the provider left it running in the background.
    private func hydraAgentFinished(_ agentID: String, status: TurnStatus, summary: String?) {
        guard let app, let headID = hydraNativeHeads[agentID] else { return }
        app.finishHydraHead(headID, status: status, summary: summary)
        if let headRuntime = app.existingRuntime(for: headID), headRuntime.isRunning {
            headRuntime.rehearse(.turnCompleted(status: status, error: nil))
        }
    }

    /// The tool call that sent out a foreground head has returned: the head is done, and
    /// the result is its report. A background head's call returns at once and says
    /// nothing about the head, which the provider ends on its own.
    private func hydraToolFinished(_ headID: UUID, status: ToolCall.Status, output: String?) {
        guard let app, let head = app.thread(headID), let info = head.hydra, info.kind == .native, !info.isBackground, !info.isFinished,
              let nativeID = info.nativeID else { return }
        let outcome: TurnStatus = switch status {
        case .completed: .completed
        case .declined: .interrupted
        default: .failed
        }
        hydraAgentFinished(nativeID, status: outcome, summary: output)
    }

    /// The lead's turn is over, so any foreground head still marked as working went with
    /// it: a stopped turn stopped them, a finished one finished them. Background heads
    /// outlive the turn and end on the provider's word.
    private func settleForegroundHeads(after status: TurnStatus) {
        guard let app else { return }
        for (nativeID, headID) in hydraNativeHeads {
            guard let head = app.thread(headID), let info = head.hydra, !info.isBackground, !info.isFinished else { continue }
            hydraAgentFinished(nativeID, status: status == .completed ? .completed : .interrupted, summary: nil)
        }
    }

    /// The session the heads ran in has stopped: whichever were still running are done.
    private func stopNativeHeads() {
        guard let app else { return }
        for headID in hydraNativeHeads.values {
            guard let head = app.thread(headID), head.hydra?.isFinished == false else { continue }
            app.finishHydraHead(headID, status: .interrupted, summary: nil)
            if let headRuntime = app.existingRuntime(for: headID), headRuntime.isRunning {
                headRuntime.rehearse(.turnCompleted(status: .interrupted, error: nil))
            }
        }
        hydraNativeHeads.removeAll()
    }

    /// Asks the session to stop a native head. Returns whether it could.
    func stopNativeHead(_ nativeID: String) async -> Bool {
        guard let session else { return false }
        return await session.stopAgent(nativeID)
    }

    /// The app finished a head of this lead's (see `AppModel.finishHydraHead`): a native
    /// head's tool row completes; a Tivano-run head's report goes to the lead, once its
    /// batch is complete. A head reporting again (steered on from the panel) replaces
    /// any report of its own still waiting.
    func hydraHeadFinished(_ headID: UUID, info: HydraHeadInfo, status: HydraHeadInfo.Status, summary: String?, landing: HydraLanding? = nil, copyPath: String? = nil) {
        switch info.kind {
        case .native:
            guard let toolID = info.toolUseID, let entry = entryIndex[toolID], case .tool(let call) = entry.item.content, call.status == .running else { return }
            let outcome: ToolCall.Status = status == .completed ? .completed : .failed
            applyToolUpdate(toolID, ToolUpdate(output: summary, status: outcome))
            // A head back with the lead idle and a prompt still queued (steered
            // behind the team while the lead sat idle) lets the lead take it now
            // rather than holding it until some later turn ends.
            flushFollowUpsIfIdle()
        case .tivano:
            let report = HydraReport(
                headIndex: info.index, task: info.task, origin: info.origin, status: status, text: summary ?? "",
                landing: landing, copyPath: copyPath, elapsed: Date.now.timeIntervalSince(info.startedAt), toolCalls: info.toolCalls
            )
            hydraPendingReports.removeAll { $0.headIndex == info.index }
            if let batchID = info.batchID, hydraBatches[batchID] != nil {
                hydraBatches[batchID]?.pending.remove(headID)
                hydraBatches[batchID]?.reports.removeAll { $0.headIndex == info.index }
                hydraBatches[batchID]?.reports.append(report)
            } else {
                hydraPendingReports.append(report)
            }
            // A finished head makes room: for a task still waiting in a batch first, then
            // for whatever the user queued while every head was busy.
            spawnWaitingHeads()
            dispatchQueuedFollowUps()
            settleBatches()
            // An idle lead hears at once; one the user stopped waits for their next word.
            if phase == .idle, thread?.lastStatus != .interrupted { flushHydraReports() }
            // After the reports: whatever is still queued behind an idle lead goes
            // next, rather than waiting out the heads still at work.
            flushFollowUpsIfIdle()
        }
    }

    /// A batch with every head back and nothing left to send out hands its reports over.
    private func settleBatches() {
        for (batchID, batch) in hydraBatches where batch.pending.isEmpty && !hydraWaiting.contains(where: { $0.batchID == batchID }) {
            hydraBatches[batchID] = nil
            hydraPendingReports += batch.reports.sorted { $0.headIndex < $1.headIndex }
        }
    }

    /// Sends the reports waiting on an idle lead as one message. Returns whether a turn
    /// starts. The reports stay put until the turn takes them: heads finishing together
    /// then go out as one message, instead of each starting a turn the next one cuts short.
    @discardableResult
    private func flushHydraReports() -> Bool {
        guard phase == .idle, !hydraFlushScheduled, !flushableHydraReports().isEmpty else { return false }
        hydraFlushScheduled = true
        // This turn starts on its own (see autoStartedTurnToken).
        autoStartedTurnToken &+= 1
        Task { await startHydraReportTurn() }
        return true
    }

    /// The reports an idle lead can hear now: every one waiting. A delegation's reports
    /// only get here once its whole batch is back (see `settleBatches`), and a head the
    /// user queued or sent out directly has nothing to do with a batch; neither waits on
    /// another delegation still out, which can mean waiting out a job of twenty minutes.
    private func flushableHydraReports() -> [HydraReport] {
        hydraPendingReports.sorted { $0.headIndex < $1.headIndex }
    }

    /// The turn `flushHydraReports` scheduled. A lead no longer idle (the user got a word
    /// in first) keeps the reports waiting for the end of that turn instead.
    private func startHydraReportTurn() async {
        // Cleared first and the reports left where they are: a turn that cannot run now
        // must be able to be asked for again, by the next head to finish or by the end of
        // whatever the lead is doing instead.
        hydraFlushScheduled = false
        guard phase == .idle, !isReverting, let app else { return }
        let reports = flushableHydraReports()
        guard !reports.isEmpty else { return }
        let sent = Set(reports.map(\.headIndex))
        hydraPendingReports.removeAll { sent.contains($0.headIndex) }
        let stillWorking = app.workingHydraHeadNames(of: threadID, excluding: sent)
        let text = HydraPrompts.reportMessage(reports, stillWorking: stillWorking, reviewsHeads: app.settings.hydraReviewHeads)
        await ensureLoaded()
        await startTurn(text: text, attachments: [], hydraHeads: reports.map(\.headIndex))
    }

    /// How many tasks one delegation block may send out. Well past what a lead writes in
    /// practice, and the pair's cap still decides how many run at a time.
    private static let maxDelegatedTasks = 32

    /// What a reply's delegation block led to, for the end of the turn.
    private enum DelegationOutcome {
        /// No block, or nothing came of it.
        case none
        /// Heads went out; the lead is free until they report.
        case headsOut
        /// The lead is being told something instead, in a turn of its own already on its way.
        case turnStarted
    }

    /// A reply row of a turn that did not finish, holding a block: the block leaves it,
    /// and the timeline says the heads never went out.
    private func dropDelegationBlock(for turnID: UUID, status: TurnStatus) {
        if let stream = hydraStream, stream.turnID == turnID, stream.sent > 0,
           let streamedEntry = entryIndex[stream.entryID],
           case .assistant(var streamedMessage) = streamedEntry.item.content {
            endDelegationStream()
            streamedMessage.text = HydraPrompts.withoutDelegationBlock(streamedMessage.text)
            if streamedMessage.text.isEmpty { streamedMessage.text = "Asked for heads." }
            streamedEntry.item.content = .assistant(streamedMessage)
            saveRevision += 1
            scheduleSave()
            settleBatches()
            appendHydraNote("Hydra sent \(stream.sent == 1 ? "one head" : "\(stream.sent) heads") before the turn \(status == .interrupted ? "was stopped" : "failed"); the rest of the block never went out. Ask again to send them.")
            return
        }
        if let stream = hydraStream, stream.turnID == turnID, stream.sent == 0 { endDelegationStream() }
        guard let entry = entries.last(where: { $0.turnID == turnID && $0.kind == .assistant && Self.holdsDelegationBlock($0) }),
              case .assistant(var message) = entry.item.content else { return }
        message.text = HydraPrompts.withoutDelegationBlock(message.text)
        if message.text.isEmpty { message.text = "Asked for heads." }
        entry.item.content = .assistant(message)
        saveRevision += 1
        scheduleSave()
        appendHydraNote("Hydra sent no heads: the turn \(status == .interrupted ? "was stopped" : "failed") before they could go out. Ask again to send them.")
        // The timeline note is for the UI; the lead hears it too, on its next turn.
        hydraBudget.noteDropped(HydraPrompts.interruptedBlockMessage(stopped: status == .interrupted))
    }

    private static func holdsDelegationBlock(_ entry: TimelineEntry) -> Bool {
        guard case .assistant(let message) = entry.item.content else { return false }
        return HydraPrompts.hasDelegationBlock(in: message.text)
    }

    /// A reply on any provider may end in a delegation block: its tasks go out as
    /// Tivano-run heads, up to the pair's limit at a time, and the block leaves the reply.
    /// A block Tivano cannot read leaves the reply as well, and the lead hears so in
    /// a turn of its own: a block never stays in a reply doing nothing.
    private func spawnDelegatedHeads(for turnID: UUID) -> DelegationOutcome {
        // The row holding the block: the last reply row that has one, since a reply can
        // come as several rows with tool calls between them and the block may sit in any
        // of them; with none, the last reply row (which may be empty of blocks).
        guard let app, let thread, let launch = app.hydraLaunch(for: thread),
              let entry = entries.last(where: { $0.turnID == turnID && $0.kind == .assistant && Self.holdsDelegationBlock($0) })
                ?? entries.last(where: { $0.turnID == turnID && $0.kind == .assistant }),
              case .assistant(var message) = entry.item.content else { return .none }
        // A block read as it streamed: an entry that closed after the last flush goes out
        // now, then the block is finished here rather than read again from the top.
        scanStreamedDelegations(entryID: hydraStream?.entryID ?? entry.id, turnID: turnID, text: message.text)
        if let stream = hydraStream, stream.turnID == turnID,
           let streamedEntry = entryIndex[stream.entryID],
           case .assistant(var streamedMessage) = streamedEntry.item.content {
            hydraStream = nil
            streamedMessage.text = HydraPrompts.markingDelegationBlockSent(streamedMessage.text)
            streamedEntry.item.content = .assistant(streamedMessage)
            saveRevision += 1
            let all = HydraPrompts.streamedDelegations(in: streamedMessage.text)?.delegations ?? []
            let total = all.isEmpty ? stream.sent : all.count
            // What the app's last read of the block missed goes out here rather than being
            // reported as lost: only the ceiling of a block, or a request that has had all
            // its rounds of heads, holds a task back, and only that is named in the note.
            var sent = stream.sent
            if total > sent, hydraBudget.canDelegate {
                let rest = Array(all.dropFirst(sent).prefix(max(0, Self.maxDelegatedTasks - sent)))
                if !rest.isEmpty {
                    hydraWaiting += rest.map { (delegation: $0, batchID: stream.batchID, queuedAt: Date.now) }
                    sent += rest.count
                    hydraStream = (turnID: turnID, entryID: stream.entryID, batchID: stream.batchID, sent: sent)
                    spawnWaitingHeads(launch: launch)
                }
            }
            if total > sent {
                appendHydraNote("""
                    Not every task went out
                    \(sent) of the \(total) tasks in that block went to heads. The last \(total - sent) did not: ask for them again once these report back.
                    """)
            }
            holdSentDelegationBlock(streamedEntry.id)
            settleBatches()
            scheduleSave()
            return hydraBatches.isEmpty && hydraWaiting.isEmpty ? .none : .headsOut
        }
        guard let delegations = HydraPrompts.delegations(in: message.text) else {
            guard HydraPrompts.hasDelegationBlock(in: message.text) else { return .none }
            message.text = HydraPrompts.withoutDelegationBlock(message.text)
            if message.text.isEmpty { message.text = "Asking for heads." }
            entry.item.content = .assistant(message)
            saveRevision += 1
            scheduleSave()
            return refuseBlock(HydraPrompts.unreadableBlockMessage(reason: nil), dropped: "Its delegation block could not be read, and it had been told so already.")
        }
        let stripped = HydraPrompts.withoutDelegationBlock(message.text)
        // An empty block is the lead saying it did the work itself: the block leaves the
        // reply, a one-line note says no heads went out, and no turn is spent on it.
        if delegations.isEmpty {
            message.text = stripped.isEmpty ? "Done, with no heads." : stripped
            entry.item.content = .assistant(message)
            saveRevision += 1
            scheduleSave()
            appendHydraNote("No heads went out: the lead did this itself.")
            return .none
        }
        // One request gets so many rounds of heads; past that the lead hears why none went
        // out and finishes by itself, so no request chains heads without end.
        guard hydraBudget.canDelegate else {
            message.text = stripped.isEmpty ? "Asking for more heads." : stripped
            entry.item.content = .assistant(message)
            saveRevision += 1
            scheduleSave()
            return refuseBlock(HydraPrompts.heldBackMessage(count: delegations.count), dropped: "This request has had all \(HydraPrompts.maxDelegationRounds) of its rounds of heads, and the lead had been told so already.")
        }
        hydraBudget.chargeRound()
        // The card stays a moment in its sent state, then leaves the reply (see `holdSentDelegationBlock`).
        message.text = HydraPrompts.markingDelegationBlockSent(message.text)
        entry.item.content = .assistant(message)
        saveRevision += 1
        let batchID = UUID()
        hydraBatches[batchID] = HydraBatch(pending: [])
        // The pair's cap paces these out through `hydraWaiting`, so the ceiling is only on
        // how many tasks one block may hold. A lead that writes more than that hears which
        // ones did not go out, rather than losing the tail of its own list in silence.
        hydraWaiting += delegations.prefix(Self.maxDelegatedTasks).map { (delegation: $0, batchID: batchID, queuedAt: Date.now) }
        if delegations.count > Self.maxDelegatedTasks {
            let dropped = delegations.count - Self.maxDelegatedTasks
            appendHydraNote("""
                Not every task went out
                \(Self.maxDelegatedTasks) of the \(delegations.count) tasks in that block went to heads. The last \(dropped) did not: ask for them again once these report back.
                """)
        }
        spawnWaitingHeads(launch: launch)
        holdSentDelegationBlock(entry.id)
        settleBatches()
        scheduleSave()
        return hydraBatches.isEmpty && hydraWaiting.isEmpty ? .none : .headsOut
    }

    /// The delegation card keeps its place for `HydraPrompts.delegationSentHold` once the
    /// heads are out, wearing its done wave. Then it fades where it stands, still holding
    /// its room (`hydra-leaving`), and only once it is gone from sight does the block leave
    /// the reply and the text below close up: two steps, so the card never fades over
    /// content that has already moved up under it.
    private func holdSentDelegationBlock(_ entryID: String) {
        Task { [weak self] in
            try? await Task.sleep(for: HydraPrompts.delegationSentHold)
            guard let self, let entry = self.entryIndex[entryID],
                  case .assistant(var message) = entry.item.content,
                  HydraPrompts.hasSentDelegationBlock(in: message.text) else { return }
            message.text = HydraPrompts.markingDelegationBlockLeaving(message.text)
            withAnimation(.easeOut(duration: 0.4)) { entry.item.content = .assistant(message) }
            try? await Task.sleep(for: HydraPrompts.delegationLeaveFade)
            guard case .assistant(var faded) = entry.item.content,
                  HydraPrompts.hasSentDelegationBlock(in: faded.text) else { return }
            faded.text = HydraPrompts.withoutDelegationBlock(faded.text)
            if faded.text.isEmpty { faded.text = "Sent out heads." }
            withAnimation(Chrome.panelSlide) { entry.item.content = .assistant(faded) }
            self.saveRevision += 1
            self.scheduleSave()
        }
    }

    /// Tells the lead, in a turn of its own, that the block its reply ended in sent no heads
    /// out, and why: `message` is what it hears. Only so many times per request (see
    /// `HydraDelegationBudget.maxRefusals`): a lead that keeps answering with the same block
    /// would otherwise be answered with the same refusal, turn after turn, for as long as the
    /// app runs. Past the cap the block is dropped with a note in the timeline saying
    /// `dropped`, and the turn ends as a plain reply would — but the refusal also rides on
    /// the front of the lead's next turn, so a drop is never quieter than a refusal.
    private func refuseBlock(_ message: String, dropped: String) -> DelegationOutcome {
        guard hydraBudget.refuse(message) else {
            appendHydraNote("No heads went out\n\(dropped) The block was dropped from the reply.")
            return .none
        }
        Task { await ensureLoaded(); await startTurn(text: message, attachments: [], hydraHeads: []) }
        return .turnStarted
    }

    /// Heads go out as their entries close so the first is at work while the lead writes
    /// the rest; the batch is made on the first entry and the round counted then; the cap
    /// paces the rest through `hydraWaiting`; `spawnDelegatedHeads` finishes the block
    /// at the end of the turn.
    ///
    /// The block is read by `delegationParser`, which keeps its place in the row between
    /// flushes, so a long reply is walked once rather than from the top on every flush.
    /// `text` is the row's text as it stands; the parser takes only what has arrived since
    /// the last flush. Entries are held to once per parser: the count already out lives in
    /// `hydraStream`, so a re-read row cannot send a head twice.
    private func scanStreamedDelegations(entryID: String, turnID: UUID, text: String, isDelta: Bool = false) {
        guard let app, let thread, let launch = app.hydraLaunch(for: thread),
              entryIndex[entryID]?.turnID == turnID else { return }
        if let hydraStream, hydraStream.entryID != entryID || hydraStream.turnID != turnID { return }
        var parser: HydraDelegationStreamParser
        if isDelta, let existing = delegationParser, existing.entryID == entryID, existing.turnID == turnID {
            parser = existing
        } else {
            parser = HydraDelegationStreamParser(turnID: turnID, entryID: entryID)
        }
        parser.ingest(text)
        delegationParser = parser

        guard !parser.delegations.isEmpty else { return }
        let sent = hydraStream?.sent ?? 0
        let fresh = Array(parser.delegations.dropFirst(sent).prefix(max(0, Self.maxDelegatedTasks - sent)))
        guard !fresh.isEmpty else { return }
        guard hydraStream != nil || hydraBudget.canDelegate else { return }
        let batchID: UUID
        if hydraStream == nil {
            batchID = UUID()
            hydraBatches[batchID] = HydraBatch(pending: [])
            hydraBudget.chargeRound()
            hydraStream = (turnID: turnID, entryID: entryID, batchID: batchID, sent: 0)
        } else {
            batchID = hydraStream!.batchID
        }
        hydraWaiting += fresh.map { (delegation: $0, batchID: batchID, queuedAt: Date.now) }
        hydraStream?.sent = sent + fresh.count
        spawnWaitingHeads(launch: launch)
    }

    /// Ends the streamed block and the reader that held its place. Called wherever the
    /// block is finished with (`dropDelegationBlock`, `spawnDelegatedHeads`, a new turn), so
    /// the next block is read by a parser that starts where that block does.
    private func endDelegationStream() {
        hydraStream = nil
        delegationParser = nil
    }

    /// Sends out delegated tasks still waiting, as far as the pair's cap allows; without
    /// a pair, or an uncapped one, all of them.
    private func spawnWaitingHeads(launch: HydraLaunch? = nil) {
        guard let app, let thread, !hydraWaiting.isEmpty else { return }
        let launch = launch ?? app.hydraLaunch(for: thread)
        // Heads not on the provider the pair names (it is off or not installed): said once
        // per job, in the lead's timeline, rather than never.
        if let pair = app.hydraPair(for: thread), let note = app.hydraHeadsFallbackNote(of: pair), hydraFallbackNoted != pair.id {
            hydraFallbackNoted = pair.id
            appendHydraNote("Hydra: \(note)")
        }
        while !hydraWaiting.isEmpty, launch?.hasRoom(running: app.runningTivanoHeads(of: threadID)) ?? true {
            let next = hydraWaiting.removeFirst()
            let delegation = next.delegation
            // The lead's announced name is authoritative: resolving it here pins the
            // spawned head to exactly that roster name. Unknown or already-taken names
            // resolve to nil and the head goes out next in order, as before.
            let preferredIndex = delegation.name.flatMap(HydraRoster.index(named:))
            guard let head = app.spawnTivanoHead(from: threadID, task: delegation.task, origin: .delegated, batchID: next.batchID, preferredIndex: preferredIndex, project: delegation.project, profile: delegation.profile, brief: { persona, workplace in
                HydraPrompts.delegatedHeadPrompt(persona: persona, delegation: delegation, workplace: workplace)
            }) else { continue }
            app.updateHydraHead(head.id) { $0.queuedAt = next.queuedAt }
            hydraBatches[next.batchID, default: HydraBatch(pending: [])].pending.insert(head.id)
        }
    }

    // MARK: - Timeline mutations

    /// A note from Hydra in the timeline, with no turn behind it: what it merged, what it
    /// could not. Its first line is its title. An `id` lets the note land under an identity
    /// the timeline is already drawing (the merging pill, see `hydraMergeNoteID`).
    func appendHydraNote(_ text: String, id: String? = nil) {
        append(TimelineItem(id: id ?? UUID().uuidString, turnID: nil, content: .user(UserMessage(text: text, hydraHeads: []))))
        app?.updateThread(threadID) { $0.updatedAt = .now }
        scheduleSave()
    }

    private func append(_ item: TimelineItem) {
        for entry in entries.suffix(6) { endStreaming(entry) }
        let entry = TimelineEntry(item)
        entries.append(entry)
        entryIndex[item.id] = entry
        saveRevision += 1
    }

    private func remove(_ id: String) {
        entries.removeAll { $0.id == id }
        entryIndex[id] = nil
        streamByteLengths[id] = nil
        saveRevision += 1
    }

    private func endStreaming(_ entry: TimelineEntry) {
        switch entry.item.content {
        case .assistant(var message) where message.isStreaming:
            message.isStreaming = false
            entry.item.content = .assistant(message)
        case .reasoning(var block) where block.isStreaming:
            block.isStreaming = false
            entry.item.content = .reasoning(block)
        case .plan(var plan) where plan.state == .drafting:
            plan.state = .proposed
            entry.item.content = .plan(plan)
        default:
            break
        }
    }

    private func queueDelta(_ id: String, _ kind: DeltaKind, _ text: String) {
        if entryIndex[id] == nil {
            switch kind {
            case .message:
                // Not until there is something to read: some providers open a text
                // block with an empty delta, which would leave a blank reply row behind.
                guard !text.isEmpty else { return }
                append(TimelineItem(id: id, turnID: turnIDForNewRows, content: .assistant(AssistantMessage(text: "", isStreaming: true))))
            case .reasoning:
                // Not until there is something to read: a redacted thinking block
                // only ever sends empty deltas and would leave a blank entry behind.
                guard !text.isEmpty else { return }
                append(TimelineItem(id: id, turnID: turnIDForNewRows, content: .reasoning(ReasoningBlock(text: "", isStreaming: true))))
            case .plan:
                append(TimelineItem(id: id, turnID: turnIDForNewRows, content: .plan(ProposedPlan(markdown: "", state: .drafting))))
            case .toolOutput:
                return
            }
        }
        guard !text.isEmpty else { return }
        // Prose is flattened as it streams, so a reply can never render an em dash.
        // Tool output is process text, not the model's own writing, and passes through.
        let prose = kind == .toolOutput ? text : TextCleanup.withoutEmDashes(text)
        pendingDeltas[id, default: PendingDelta(kind: kind, text: "")].text += prose
        if kind != .toolOutput {
            let base = streamByteLengths[id] ?? {
                switch entryIndex[id]?.item.content {
                case .assistant(let message): return message.text.utf8.count
                case .reasoning(let block): return block.text.utf8.count
                case .plan(let plan): return plan.markdown.utf8.count
                default: return 0
                }
            }()
            streamByteLengths[id] = base + prose.utf8.count
            pendingFlushBytes = max(pendingFlushBytes, base + prose.utf8.count)
        }
        let isHead = thread?.hydra != nil
        if isHead { StreamLoad.shared.noteStreaming(self) }
        var delay = Self.flushDelay(for: pendingFlushBytes, scrolling: ScrollActivity.shared.isScrolling)
        if isHead { delay = max(delay, StreamLoad.shared.headFlushDelayMilliseconds) }
        let remaining = Duration.milliseconds(delay) - (ContinuousClock.now - lastFlushAt)
        let firstVisible: Bool
        switch entryIndex[id]?.item.content {
        case .assistant(let message): firstVisible = message.text.isEmpty
        case .reasoning(let block): firstVisible = block.text.isEmpty
        case .plan(let plan): firstVisible = plan.markdown.isEmpty
        default: firstVisible = false
        }
        if firstVisible || remaining <= .zero {
            flushDeltas()
            return
        }
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: remaining)
            guard !Task.isCancelled else { return }
            self?.flushDeltas()
        }
    }

    /// How long to wait before flushing deltas onto their rows: 45 ms up to 8 KB of UTF-8,
    /// 90 ms up to 64 KB (roughly two bytes per prose character), 150 ms beyond.
    private nonisolated static func flushDelay(for length: Int?, scrolling: Bool) -> Int {
        let paced = switch length ?? 0 {
        case ..<8_192: 45
        case ..<65_536: 90
        default: 150
        }
        // Under a scrolling reader the row is not being read: it takes at most six
        // flushes a second then, so the frames of the scroll are not spent laying the
        // streaming text out again (in the chat and in every head panel at once).
        return scrolling ? max(paced, 160) : paced
    }


    /// How many runtimes are streaming onto the screen right now, so a head's flushes
    /// slow down as more heads talk at once. One head flushes at its own pace; with N
    /// heads streaming, each waits about N times `headFlushBudget`, which keeps the
    /// whole team to roughly one panel re-layout every `headFlushBudget` regardless of
    /// how many heads went out. A runtime that has not flushed for two seconds no longer
    /// counts, so a head that went quiet stops slowing the others.
    @MainActor
    final class StreamLoad {
        static let shared = StreamLoad()
        /// The interval the whole team of heads shares, in milliseconds.
        private static let headFlushBudget = 70
        private static let stale: Duration = .seconds(2)
        private var lastSeen: [ObjectIdentifier: ContinuousClock.Instant] = [:]

        func noteStreaming(_ runtime: ThreadRuntime) {
            lastSeen[ObjectIdentifier(runtime)] = .now
        }

        func forget(_ runtime: ThreadRuntime) {
            lastSeen[ObjectIdentifier(runtime)] = nil
        }

        /// Runtimes that flushed within the last two seconds.
        var streamingCount: Int {
            let now = ContinuousClock.now
            lastSeen = lastSeen.filter { now - $0.value < Self.stale }
            return lastSeen.count
        }

        /// The least a head waits between two flushes while `streamingCount` heads talk.
        var headFlushDelayMilliseconds: Int {
            max(45, streamingCount * Self.headFlushBudget)
        }

    }

    private func flushDeltas(scheduleSave: Bool = true) {
        flushTask?.cancel()
        flushTask = nil
        guard !pendingDeltas.isEmpty else { return }
        lastFlushAt = .now
        let deltas = pendingDeltas
        pendingDeltas.removeAll()
        pendingFlushBytes = 0
        var heard = false
        var streamedRows: [(id: String, delta: String)] = []
        for (id, delta) in deltas {
            // Appended in place (see `appendStreamed`): binding the payload out of the enum
            // copied the whole message on every flush.
            guard let entry = entryIndex[id], entry.item.content.appendStreamed(delta.text, kind: delta.kind) else { continue }
            saveRevision += 1
            if delta.kind != .plan { heard = true }
            if delta.kind == .message, entry.kind == .assistant { streamedRows.append((id, delta.text)) }
        }
        // Once per flush, not per word: a head still talking is a head still at work.
        if heard { noteHydraHeadEvent() }
        if let turnID = currentTurnID {
            for row in streamedRows {
                scanStreamedDelegations(entryID: row.id, turnID: turnID, text: row.delta, isDelta: true)
            }
        }
        if scheduleSave { self.scheduleSave() }
    }

    private func completeMessage(_ id: String, text: String) {
        streamByteLengths[id] = nil
        let text = TextCleanup.withoutEmDashes(text)
        guard let entry = entryIndex[id] else {
            guard !text.isEmpty else { return }
            append(TimelineItem(id: id, turnID: turnIDForNewRows, content: .assistant(AssistantMessage(text: text))))
            return
        }
        guard case .assistant(var message) = entry.item.content else { return }
        if !text.isEmpty { message.text = text }
        message.isStreaming = false
        if !message.text.contains(where: { !$0.isWhitespace }) {
            remove(id)
        } else {
            entry.item.content = .assistant(message)
            saveRevision += 1
            if let turnID = currentTurnID { scanStreamedDelegations(entryID: id, turnID: turnID, text: message.text) }
        }
        scheduleSave()
    }

    private func completeReasoning(_ id: String, text: String) {
        streamByteLengths[id] = nil
        let text = TextCleanup.withoutEmDashes(text)
        guard let entry = entryIndex[id], case .reasoning(var block) = entry.item.content else {
            guard !text.isEmpty else { return }
            append(TimelineItem(id: id, turnID: turnIDForNewRows, content: .reasoning(ReasoningBlock(text: text))))
            return
        }
        if !text.isEmpty { block.text = text }
        block.isStreaming = false
        if !block.text.contains(where: { !$0.isWhitespace }) {
            remove(id)
        } else {
            entry.item.content = .reasoning(block)
            saveRevision += 1
        }
        scheduleSave()
    }

    private func completePlan(_ id: String, markdown: String) {
        let markdown = TextCleanup.withoutEmDashes(markdown)
        if let entry = entryIndex[id], case .plan(var plan) = entry.item.content {
            if !markdown.isEmpty { plan.markdown = markdown }
            plan.state = .proposed
            entry.item.content = .plan(plan)
            saveRevision += 1
        } else if !markdown.isEmpty {
            append(TimelineItem(id: id, turnID: turnIDForNewRows, content: .plan(ProposedPlan(markdown: markdown, state: .proposed))))
        }
        scheduleSave()
    }

    private func upsertTool(_ id: String, _ call: ToolCall) {
        noteToolMayWrite(call.kind)
        recordCurrentTurnEdits(call.edits)
        var call = call
        call.edits = Self.capped(call.edits)
        guard let entry = entryIndex[id], case .tool(var existing) = entry.item.content else {
            append(TimelineItem(id: id, turnID: turnIDForNewRows, content: .tool(call)))
            noteHydraHeadEvent(edits: call.edits.count, tool: true)
            return
        }
        if !call.title.isEmpty { existing.title = call.title }
        existing.detail = call.detail ?? existing.detail
        existing.kind = call.kind
        // Edits count once, when they first land on the call.
        let landed = !call.edits.isEmpty && existing.edits.isEmpty ? call.edits.count : 0
        if !call.edits.isEmpty { existing.edits = call.edits }
        if existing.status == .running, call.status != .running { existing.finish(call.status) }
        entry.item.content = .tool(existing)
        saveRevision += 1
        noteHydraHeadEvent(edits: landed)
    }

    /// Something happened on this runtime's own timeline, and it is a head's: its
    /// watchdog clock restarts and the edits that landed count (see
    /// `AppModel.startHydraWatchdog`). A Tivano-run head counts its tools here, where
    /// its own session reports them; a native head's count comes with its lead's events
    /// (see `hydraAgentEvent`), which also rehearse here, so it is not counted twice.
    private func noteHydraHeadEvent(edits: Int = 0, tool: Bool = false) {
        guard let info = thread?.hydra else { return }
        hydraLastEventAt = .now
        hydraEditCount += edits
        if tool, info.kind == .tivano { hydraToolCalls += 1 }
    }

    /// A tool that is not plainly a read can have written a file, which makes the tree a
    /// command left behind no answer for what is on disk now. Commands keep their own
    /// count in `watchCommand`, which knows whether this one can write at all.
    private func noteToolMayWrite(_ kind: ToolCall.Kind?) {
        guard let kind, kind != .read, kind != .search, kind != .web, kind != .command else { return }
        settledTree = nil
        treeEpoch += 1
    }

    private func applyToolUpdate(_ id: String, _ update: ToolUpdate) {
        if let edits = update.edits { recordCurrentTurnEdits(edits) }
        noteToolMayWrite(update.kind)
        if entryIndex[id] == nil {
            append(TimelineItem(id: id, turnID: turnIDForNewRows, content: .tool(ToolCall(kind: update.kind ?? .other, title: update.title ?? "Tool"))))
        }
        guard let entry = entryIndex[id], case .tool(var call) = entry.item.content else { return }
        if let title = update.title, !title.isEmpty { call.title = title }
        if let detail = update.detail { call.detail = detail }
        if let kind = update.kind { call.kind = kind }
        var landed = 0
        if let edits = update.edits, !edits.isEmpty {
            if call.edits.isEmpty { landed = edits.count }
            call.edits = Self.capped(edits)
        }
        if let output = update.output { call.setOutput(output) }
        if let exitCode = update.exitCode { call.exitCode = exitCode }
        if let status = update.status {
            if status == .running { call.status = .running } else { call.finish(status) }
        }
        entry.item.content = .tool(call)
        saveRevision += 1
        noteHydraHeadEvent(edits: landed)
        scheduleSave()
    }

    // MARK: - Command edits

    /// Agents that edit files from the shell (python heredocs, sed -i, patch)
    /// never report an edit, so a command's row gets its edits from the
    /// working tree instead: a tree known to predate the command, another
    /// captured as it finishes, and the diff between the two. Git-backed projects only.
    ///
    /// Nothing is captured as the command starts. The agent runs the command itself,
    /// the moment its tool call arrives, and a heredoc is done in a blink while a
    /// snapshot of a big checkout takes seconds: a snapshot started here raced the
    /// command and, more often than not, already held its write. Before and after then
    /// matched, the row got no edits, the turn counted no file, and the lead's merge had
    /// nothing to take; a sibling chat's sweep landed the work under its own title
    /// instead. The "before" is now always a tree that was complete before the command
    /// began (see `treeBeforeCommand`).
    private func watchCommand(_ id: String, _ call: ToolCall) {
        // A command that cannot write needs no snapshots at all: reading the checkout is
        // most of what an agent runs, and each snapshot is seconds of git on a big tree.
        guard commandTrees[id] == nil, ShellCommandKind.mayWriteFiles(call.title), repositoryGit != nil,
              let before = treeBeforeCommand() else { return }
        commandTrees[id] = Task<String?, Never> { before }
        commandStarts[id] = .now
        settledTree = nil
        treeEpoch += 1
    }

    /// A tree-ish that stood complete before a command starting now: the tree the last
    /// command left when nothing has run since, else the last snapshot any command in
    /// this turn finished, else the turn's own start checkpoint, which the turn waited
    /// for before its first word reached the model. Each is older than the command, so
    /// a diff from it can only hold more than the command wrote, never less; what an
    /// earlier tool of the turn already reported is taken back out as the row settles.
    private func treeBeforeCommand() -> String? {
        if let settled = settledTree, settled.epoch == treeEpoch { return settled.tree }
        if let latestTree { return latestTree }
        guard let currentTurnID, let turn = turns.first(where: { $0.id == currentTurnID }) else { return nil }
        return turn.baseCheckpoint
    }

    /// Repository-relative paths that other rows of a turn already carry as edits, so a
    /// command settling against an older tree does not show the turn's earlier work as
    /// its own. A path the command also touched stays on the row that reported it first
    /// and still counts for the turn.
    private func attributedPaths(inTurnOf id: String, git: Git, repositoryRoot: URL) -> Set<String> {
        guard let turnID = entryIndex[id]?.item.turnID else { return [] }
        var paths = Set<String>()
        for entry in entries where entry.id != id && entry.item.turnID == turnID {
            guard case .tool(let call) = entry.item.content else { continue }
            for edit in call.edits {
                let trimmed = edit.path.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                let absolute = trimmed.hasPrefix("/") || trimmed.hasPrefix("~") ? trimmed : (git.directory.path as NSString).appendingPathComponent(trimmed)
                if let relative = TouchedPaths.relative(absolute, root: repositoryRoot.path) { paths.insert(relative) }
            }
        }
        return paths
    }

    private func settleCommand(_ id: String) {
        let commandStart = commandStarts.removeValue(forKey: id)
        let turnStart = turns.first(where: { $0.id == currentTurnID })?.startedAt ?? .distantPast
        let owner = claimOwner
        guard let before = commandTrees.removeValue(forKey: id), let git = repositoryGit else { return }
        let epoch = treeEpoch
        commandSettles[id] = Task { [weak self] in
            guard let base = await before.value, let self else { return }
            guard let after = await captureTree(git).value else { return }
            latestTree = after
            // Nothing else started or ran alongside while the snapshot was taken, so it
            // still stands for the working tree and the next command starts from it.
            if treeEpoch == epoch, commandTrees.isEmpty, hydraCommandTrees.isEmpty { settledTree = (after, epoch) }
            guard base != after, let changed = try? await git.changedPaths(from: base, to: after) else { return }
            let repository = repositoryRoot(for: git)
            let attributed = attributedPaths(inTurnOf: id, git: git, repositoryRoot: await repository.value)
            // Only the files that are work: a head that builds in its copy leaves thousands of
            // compiler-cache records under build.noindex where the project's .gitignore missed
            // them, and a diff of all of those once put 7,632 edits and 7 MB on two rows, then
            // into the merge as strays. Listed first and diffed by name, they never get that far.
            var real = changed.filter { !$0.isEmpty && !TouchedPaths.isBuildOutput($0) && !attributed.contains($0) }
            let root = await repository.value.path
            real = await unclaimedCommandPaths(real, root: root, owner: owner, turnStart: turnStart, commandStart: commandStart)
            guard !real.isEmpty, let patch = try? await git.diff(from: base, to: after, paths: real), !patch.isEmpty else { return }
            let edits = await Self.fileEdits(from: patch, repositoryRoot: repository.value)
            guard !edits.isEmpty, let entry = entryIndex[id], case .tool(var call) = entry.item.content else { return }
            // A provider that did report its edits keeps them.
            guard call.edits.allSatisfy({ $0.diff == nil }) else { return }
            call.edits = edits
            CheckoutClaims.claim(real, root: root, owner: owner)
            if entry.turnID == currentTurnID { recordCurrentTurnEdits(edits) }
            entry.item.content = .tool(call)
            saveRevision += 1
            noteHydraHeadEvent(edits: edits.count)
            scheduleSave()
        }
    }

    /// One working-tree snapshot at a time for this thread, each waiting for the one
    /// before it: they are heavy, and a turn's commands would otherwise run several at
    /// once, with eight heads doing the same in the same checkout.
    private func captureTree(_ git: Git) -> Task<String?, Never> {
        let previous = treeCaptures
        let capture = Task { () -> String? in
            _ = await previous?.value
            return await Task.detached(priority: .utility) { try? await git.captureTree() }.value
        }
        treeCaptures = capture
        return capture
    }

    private func recordCurrentTurnEdits(_ edits: [FileEdit]) {
        guard currentTurnID != nil, let root = workingRoot else { return }
        let paths = edits.compactMap { TouchedPaths.relative($0.path, root: root) }
        claimReportedPaths(paths, root: root)
        hydraCurrentTurnTouchedPaths.formUnion(paths)
    }

    /// Files a native head reported editing. They land on the head's own timeline, but the
    /// work is done in the lead's checkout and counts as the lead's turn.
    private func noteHydraEdits(_ edits: [FileEdit]) {
        guard !edits.isEmpty, let root = workingRoot else { return }
        let paths = edits.compactMap { TouchedPaths.relative($0.path, root: root) }
        claimReportedPaths(paths, root: root)
        hydraTouched.formUnion(paths)
        hydraCurrentTurnTouchedPaths.formUnion(paths)
    }

    /// A native head's shell command, watched exactly as the lead's own are and for the
    /// same reason: agents edit from the shell without reporting it. What changed goes to
    /// the turn's files rather than onto a row, because the row lives in the head's
    /// runtime and it is the lead's turn that a merge takes its files from.
    private func watchHydraCommand(_ key: String, _ call: ToolCall) {
        guard hydraCommandTrees[key] == nil, ShellCommandKind.mayWriteFiles(call.title), repositoryGit != nil,
              let before = treeBeforeCommand() else { return }
        hydraCommandTrees[key] = Task<String?, Never> { before }
        commandStarts[key] = .now
        settledTree = nil
        treeEpoch += 1
    }

    private func settleHydraCommand(_ key: String) {
        let commandStart = commandStarts.removeValue(forKey: key)
        let turnStart = turns.first(where: { $0.id == currentTurnID })?.startedAt ?? .distantPast
        let owner = claimOwner
        guard let before = hydraCommandTrees.removeValue(forKey: key), let git = repositoryGit else { return }
        let epoch = treeEpoch
        // Kept with the lead's own settles, so the turn waits for them before it counts
        // its files.
        commandSettles[key] = Task { [weak self] in
            guard let base = await before.value, let self else { return }
            guard let after = await captureTree(git).value else { return }
            latestTree = after
            if treeEpoch == epoch, commandTrees.isEmpty, hydraCommandTrees.isEmpty { settledTree = (after, epoch) }
            guard base != after, let paths = try? await git.changedPaths(from: base, to: after) else { return }
            let root = await repositoryRoot(for: git).value.path
            var writes = paths.filter { !$0.isEmpty && !TouchedPaths.isBuildOutput($0) }
            writes = await unclaimedCommandPaths(writes, root: root, owner: owner, turnStart: turnStart, commandStart: commandStart)
            guard !writes.isEmpty else { return }
            CheckoutClaims.claim(writes, root: root, owner: owner)
            let touched = writes.compactMap { path in
                workingRoot.flatMap { TouchedPaths.relative((root as NSString).appendingPathComponent(path), root: $0) }
            }
            hydraTouched.formUnion(touched)
            hydraCurrentTurnTouchedPaths.formUnion(touched)
        }
    }

    private var claimOwner: UUID {
        guard let thread = app?.thread(threadID), thread.hydra != nil,
              thread.worktreePath == nil, let parentID = thread.parentThreadID else { return threadID }
        return parentID
    }

    private func claimReportedPaths(_ paths: [String], root: String) {
        let owner = claimOwner
        let repository = repositoryRoot(for: Git(root))
        Task {
            let repositoryRoot = await repository.value.path
            let relative = paths.compactMap {
                TouchedPaths.relative((root as NSString).appendingPathComponent($0), root: repositoryRoot)
            }
            CheckoutClaims.claim(relative, root: repositoryRoot, owner: owner)
        }
    }

    private func unclaimedCommandPaths(_ paths: [String], root: String, owner: UUID, turnStart: Date, commandStart: Date?) async -> [String] {
        // A checkout snapshot sees sibling writes too; their latest claim keeps them theirs.
        let foreign = CheckoutClaims.foreign(paths, root: root, owner: owner, since: turnStart)
        var own = paths.filter { !foreign.contains($0) }
        if CheckoutClaims.othersActive(root: root, owner: owner, since: turnStart), let commandStart {
            let candidates = own
            // An old before-tree can include writes finished before this command began.
            let earlier = await Task.detached(priority: .utility) {
                Set(candidates.filter { path in
                    let file = (root as NSString).appendingPathComponent(path)
                    guard let attributes = try? FileManager.default.attributesOfItem(atPath: file),
                          let modified = attributes[.modificationDate] as? Date else { return false }
                    return modified < commandStart.addingTimeInterval(-1)
                })
            }.value
            own.removeAll { earlier.contains($0) }
        }
        return own
    }

    /// The folder this thread's agent works in: its own copy of the checkout, or the
    /// project itself.
    private var workingRoot: String? {
        guard let app, let thread = app.thread(threadID), let project = app.project(thread.projectID) else { return nil }
        return thread.worktreePath ?? project.path
    }

    private var repositoryGit: Git? {
        guard let currentTurnID, let turn = turns.first(where: { $0.id == currentTurnID }), turn.baseCheckpoint != nil,
              let app, let thread = app.thread(threadID), let project = app.project(thread.projectID) else { return nil }
        return Git(thread.worktreePath ?? project.path)
    }

    /// How much of a patch an edit carries. Past it the edit is stats only, so neither the
    /// timeline nor the thread file grows by the whole of a written file.
    private nonisolated static let editDiffLimit = 200_000

    /// Edits as a provider reported them, with an outsized patch dropped: a Write tool
    /// hands over the entire new file, which can be megabytes, and every save would then
    /// write all of it again. The same cap the edits taken from a command's diff have.
    private static func capped(_ edits: [FileEdit]) -> [FileEdit] {
        edits.map { edit in
            guard let diff = edit.diff, diff.utf8.count > editDiffLimit else { return edit }
            var capped = edit
            capped.diff = nil
            return capped
        }
    }

    /// One edit per file in a multi-file patch, with the file's own section as its diff.
    @concurrent
    nonisolated static func fileEdits(from patch: String, repositoryRoot: URL) async -> [FileEdit] {
        var sections: [String] = []
        var current: [Substring] = []
        for line in patch.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("diff --git ") {
                if !current.isEmpty { sections.append(current.joined(separator: "\n")) }
                current = [line]
            } else if !current.isEmpty {
                current.append(line)
            }
        }
        if !current.isEmpty { sections.append(current.joined(separator: "\n")) }
        return sections.compactMap { section in
            guard let file = DiffParser.parse(section).first else { return nil }
            // Huge sections are stats only, so the thread file stays small.
            let diff = section.utf8.count <= editDiffLimit ? section : nil
            let path = URL(fileURLWithPath: file.path, relativeTo: repositoryRoot).standardizedFileURL.path
            return FileEdit(path: path, diff: diff, additions: file.additions, deletions: file.deletions)
        }
    }

    private func upsertTodos(_ steps: [TodoStep]) {
        // The row is remembered rather than searched for: a turn rewrites its list many
        // times, and the timeline behind it can hold thousands of rows. Without it, the
        // running turn's entries are the last ones, and an earlier turn ends the walk.
        if let id = todosEntryID, let entry = entryIndex[id], entry.item.turnID == currentTurnID {
            entry.item.content = .todos(steps)
            saveRevision += 1
            return
        }
        var existing: TimelineEntry?
        for entry in entries.reversed() {
            if let turnID = entry.item.turnID, turnID != currentTurnID { break }
            if entry.item.turnID == currentTurnID, case .todos = entry.item.content { existing = entry; break }
        }
        if let entry = existing {
            todosEntryID = entry.id
            entry.item.content = .todos(steps)
            saveRevision += 1
        } else if !steps.isEmpty {
            let item = TimelineItem(turnID: turnIDForNewRows, content: .todos(steps))
            todosEntryID = item.id
            append(item)
        }
        scheduleSave()
    }

    private func appendNotice(_ level: Notice.Level, _ message: String) {
        append(TimelineItem(turnID: turnIDForNewRows, content: .notice(Notice(level: level, message: message))))
        scheduleSave()
    }

    private func updateTurn(_ id: UUID, _ change: (inout TurnRecord) -> Void) {
        guard let index = turns.firstIndex(where: { $0.id == id }) else { return }
        change(&turns[index])
        saveRevision += 1
    }

    /// Names the chat the moment its first message goes in, so the row never sits at
    /// 'New thread' while a session starts. Only a chat with no name of its own is ever
    /// named here, so a later turn cannot overwrite a title.
    private func generateTitle(from text: String, attachments: [Attachment]) {
        guard let app, let thread = app.thread(threadID), !thread.hasCustomTitle else { return }
        guard turns.count == 1 || thread.title == ChatThread.untitled else { return }
        let names = attachments.map(\.name)
        let input = names.isEmpty ? text : text + "\nAttached: " + names.joined(separator: ", ")
        app.updateThread(threadID) { $0.title = TextCleanup.singleLine(text, limit: 48) }
        guard let engine = app.textEngine(preferring: thread.provider) else { return }
        let threadID = threadID
        Task {
            guard let title = await TextGeneration.threadTitle(for: input, engine: engine) else { return }
            app.updateThread(threadID) { thread in
                if !thread.hasCustomTitle { thread.title = title }
            }
        }
    }

    // MARK: - Persistence

    func scheduleSave() {
        guard persistenceEnabled else { return }
        guard phase != .idle else {
            saveTask?.cancel()
            saveTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(800))
                guard !Task.isCancelled else { return }
                self?.saveNow()
            }
            return
        }
        // A running turn fires this after nearly every event it streams, and every save
        // rewrites the whole thread file, which runs to megabytes. While the turn runs its
        // events share one save every few seconds: the timer already running writes
        // whatever the thread holds by then, and `finishTurn` saves what is left. A long
        // thread waits longer, so no chat rewrites more than about 250 KB a second however
        // big it grows: five seconds up to a megabyte, twenty for five megabytes and more.
        guard saveTask == nil else { return }
        let bytes = DiskWriter.shared.lastWrittenSize(of: Storage.threadURL(threadID)) ?? 0
        let seconds = min(20, max(5, Double(bytes) / 250_000))
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        // The timer that calls this is finished the moment it runs, so its handle goes
        // whatever happens below. Left standing across a skipped save, `scheduleSave` would
        // see a task already over and return, and nothing would be written until the turn
        // ended: the five-second bound on what a crash costs is exactly this handle.
        saveTask?.cancel()
        saveTask = nil
        // A save before the history is installed would write an empty thread over the file.
        guard persistenceEnabled, !isLoadingHistory, saveRetryTask == nil else { return }
        // The periodic save fires every few seconds while a turn runs, even when the
        // turn's events changed nothing since the last write: skip the snapshot then.
        // `finishTurn` and friends still land on disk, as their mutations bump the
        // revision before the save below.
        guard saveRevision != lastSavedRevision else { return }
        let snapshot = snapshotForSave()
        let revision = saveRevision
        let url = Storage.threadURL(threadID)
        DiskWriter.shared.writeThread(snapshot) { [weak self] success in
            let reason = DiskWriter.shared.lastWriteError(of: url) ?? Chrome.localized("the disk write failed")
            Task { @MainActor [weak self] in
                guard let self, self.persistenceEnabled else { return }
                if success {
                    self.lastSavedRevision = max(self.lastSavedRevision, revision)
                    for reference in snapshot.head.turnIndex ?? [] {
                        self.savedTurnRevisions[reference.id] = max(self.savedTurnRevisions[reference.id] ?? 0, reference.revision)
                    }
                    self.saveFailures = 0
                    self.saveRetryTask?.cancel()
                    self.saveRetryTask = nil
                    if let id = self.saveNoticeID {
                        self.remove(id)
                        self.saveNoticeID = nil
                        self.scheduleSave()
                    }
                } else if revision > self.lastSavedRevision {
                    if self.saveNoticeID == nil {
                        let item = TimelineItem(turnID: self.turnIDForNewRows, content: .notice(Notice(level: .warning, message: String(format: Chrome.localized("Tivano couldn't save this chat to disk (%@). It keeps trying."), reason))))
                        self.saveNoticeID = item.id
                        self.append(item)
                    }
                    guard self.saveRetryTask == nil else { return }
                    let delay = [2, 5, 15, 60][min(self.saveFailures, 3)]
                    self.saveFailures += 1
                    self.saveRetryTask = Task { [weak self] in
                        try? await Task.sleep(for: .seconds(delay))
                        guard !Task.isCancelled, let self else { return }
                        self.saveRetryTask = nil
                        self.saveNow()
                    }
                }
            }
        }
    }

    /// The current document, or nil when the last save already holds it: quit writes
    /// only the threads that changed.
    func unsavedSnapshot() -> ThreadSave? {
        guard !isLoadingHistory, saveRevision != lastSavedRevision else { return nil }
        return snapshotForSave()
    }

    /// Whether dropping this runtime loses nothing the saved document does not hold: no
    /// turn or session, nothing typed or mid-edit, nothing queued or owed to the lead,
    /// no landing under way. Panel geometry and the head links of old tool rows are UI
    /// conveniences a fresh runtime starts without, as it does after a relaunch.
    var holdsOnlyPersistedState: Bool {
        phase == .idle && session == nil && providerHistoryOperation == nil && !isReverting && pendingSend == nil && !isLoadingHistory
            && draft.isEmpty && followUpEdit == nil && messageEdit == nil
            && approvals.isEmpty && questions.isEmpty
            && hydraPendingReports.isEmpty && hydraBatches.isEmpty && hydraWaiting.isEmpty && hydraNativeHeads.isEmpty
            && !hydraFlushScheduled && hydraLanding == nil && !isHydraMerging && headBudget == nil
            && commandTrees.isEmpty && commandSettles.isEmpty
    }

    func cancelPersistence() {
        persistenceEnabled = false
        historyLoad?.cancel()
        historyLoad = nil
        saveRetryTask?.cancel()
        saveRetryTask = nil
        saveTask?.cancel()
        saveTask = nil
        flushTask?.cancel()
        flushTask = nil
    }

    private func snapshotForSave() -> ThreadSave {
        flushDeltas(scheduleSave: false)
        // Positions remain stable when a row is deleted or inserted, so editing one
        // turn never makes all the following turn files dirty just to renumber them.
        var nextPositions = [Double?](repeating: nil, count: entries.count)
        var nextKnown: Double?
        for index in entries.indices.reversed() {
            nextPositions[index] = nextKnown
            if let position = itemPositions[entries[index].id] { nextKnown = position }
        }
        var previous = 0.0
        for (offset, entry) in entries.enumerated() {
            if let position = itemPositions[entry.id] {
                previous = position
            } else {
                let position = nextPositions[offset].map { previous + ($0 - previous) / 2 } ?? (previous + 1)
                itemPositions[entry.id] = position
                previous = position
            }
        }
        var head = ThreadDocument(threadID: threadID)
        let finished = turns.filter { $0.status != .running && $0.id != currentTurnID && $0.id != finishingTurnID }
        let finishedIDs = Set(finished.map(\.id))
        var dirty: [UUID: StoredTurn] = [:]
        head.turnIndex = finished.map { turn in
            if turnRevisions[turn.id] == nil { markTurnDirty(turn.id) }
            let revision = turnRevisions[turn.id] ?? 0
            if savedTurnRevisions[turn.id] != revision {
                dirty[turn.id] = StoredTurn(turn: turn, items: [], itemPositions: [:])
            }
            return ThreadTurnReference(id: turn.id, revision: revision)
        }
        head.itemPositions = [:]
        for entry in entries {
            if let id = entry.turnID, finishedIDs.contains(id) {
                if dirty[id] != nil {
                    dirty[id]?.items.append(entry.item)
                    dirty[id]?.itemPositions[entry.id] = itemPositions[entry.id]
                }
            } else {
                head.items.append(entry.item)
                head.itemPositions?[entry.id] = itemPositions[entry.id]
            }
        }
        head.turns = turns.filter { !finishedIDs.contains($0.id) }
        head.usage = usage
        head.continuation = continuation
        head.followUps = followUps
        head.hydraMerges = hydraMerges
        return ThreadSave(head: head, dirtyTurns: dirty)
    }

    func snapshotForPersistence() -> ThreadDocument {
        flushDeltas(scheduleSave: false)
        var document = ThreadDocument(threadID: threadID)
        document.items = entries.map(\.item)
        document.turns = turns
        document.usage = usage
        document.continuation = continuation
        document.followUps = followUps
        document.hydraMerges = hydraMerges
        return document
    }
}

private extension TimelineItem.Content {
    /// Appends streamed text to the payload in place, and says whether the payload took it.
    /// Binding the payload out of the enum while the enum still holds it left two
    /// references, so every flush copied the whole message before appending; releasing
    /// the enum's reference first keeps the string unique and the append amortized
    /// O(delta). Written through the entry's `item`, this is still one observed mutation.
    mutating func appendStreamed(_ text: String, kind: ThreadRuntime.DeltaKind) -> Bool {
        switch (kind, self) {
        case (.message, .assistant(var message)):
            self = .todos([])
            message.text += text
            self = .assistant(message)
        case (.reasoning, .reasoning(var block)):
            self = .todos([])
            block.text += text
            self = .reasoning(block)
        case (.toolOutput, .tool(var call)):
            self = .todos([])
            call.appendOutput(text)
            self = .tool(call)
        case (.plan, .plan(var plan)):
            self = .todos([])
            plan.markdown += text
            self = .plan(plan)
        default:
            return false
        }
        return true
    }
}

// MARK: - Rehearsal

extension ThreadRuntime {
    /// Starts a turn with no provider behind it, for the website captures: the user message
    /// lands, the working line appears, and `rehearse(_:)` then feeds the events a provider
    /// would. `touchedPaths` and `providerDiff` give the turn a diff for the changes tab.
    func rehearseTurn(_ text: String?, touchedPaths: [String] = [], providerDiff: String? = nil) {
        let turnIndex = (turns.map(\.index).max() ?? -1) + 1
        var turn = TurnRecord(index: turnIndex)
        turn.touchedPaths = touchedPaths.isEmpty ? nil : touchedPaths
        turn.providerDiff = providerDiff
        if let text {
            let userItem = TimelineItem(turnID: turn.id, content: .user(UserMessage(text: text)))
            turn.userItemID = userItem.id
            turns.append(turn)
            saveRevision += 1
            append(userItem)
        } else {
            turns.append(turn)
            saveRevision += 1
        }
        currentTurnID = turn.id
        hydraCurrentTurnTouchedPaths = Set(touchedPaths)
        phase = .running
        turnStartedAt = .now
        app?.updateThread(threadID) {
            $0.updatedAt = .now
            $0.lastStatus = .running
        }
    }

    /// The brief a head was given, once the provider says what it was: a user message at
    /// the top of a timeline that started without one.
    func rehearseBrief(_ text: String) {
        guard let turn = turns.last, turn.userItemID == nil else { return }
        let userItem = TimelineItem(turnID: turn.id, content: .user(UserMessage(text: text)))
        updateTurn(turn.id) { $0.userItemID = userItem.id }
        let entry = TimelineEntry(userItem)
        entries.insert(entry, at: 0)
        entryIndex[userItem.id] = entry
        saveRevision += 1
        scheduleSave()
    }

    /// One provider event, through the same path a live session's events take.
    func rehearse(_ event: ProviderEvent) {
        handle(event)
    }

    /// Tells the changes tab and the diff panel that the turn's diff changed.
    func noteDiffChanged() {
        diffRevision += 1
    }

    /// A summary computed for a turn recorded before summaries were stored with the turn
    /// (see `TurnFinishedBlock`): kept on the turn-end entry, so the thread's next open reads
    /// it instead of running git for every historical card again.
    func storeLegacyChanges(_ changes: FileChangeSummary, turnID: UUID) {
        guard let entry = entries.last(where: { $0.turnID == turnID && $0.kind == .turnEnd }),
              case .turnEnd(var summary) = entry.item.content, summary.changes == nil else { return }
        summary.changes = changes
        entry.item.content = .turnEnd(summary)
        scheduleSave()
    }
}
