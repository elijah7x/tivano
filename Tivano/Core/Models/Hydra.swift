import Foundation
import SwiftUI

// Hydra: one chat, many heads. With Hydra on, the chat's agent leads a team of helper
// agents ("heads") that it sends out on the parts of a big job, in parallel. Every head is
// Tivano-run, whatever the lead's provider: the lead asks for heads with the delegation
// block, each head is a thread of its own in the app with the model and effort from the
// pair the user set up, and its report goes back to the lead as the next message. The
// lead's own sub-agent tools (Claude's Agent, Codex's collab agents, Copilot's task) are
// switched off while it leads, so no head ever runs inside the provider instead. A pair
// may send the heads out on another provider than the lead's (a Claude lead over Gemini
// heads, say).

/// A purpose-tuned head configuration on a pair ("quick", "deep"): the lead routes a
/// delegation to it by name and that head runs on the profile's model and effort instead
/// of the pair's shared worker fields. A nil field inherits the pair's: no provider keeps
/// the head on the pair's heads provider, no model or effort takes the pair's own.
struct HydraHeadProfile: Codable, Hashable, Identifiable, Sendable {
    var id: UUID
    /// The name the lead writes in a delegation's `profile` field; free-form, so the
    /// name itself carries the purpose ("quick", "visual", "docs").
    var name: String
    var provider: ProviderKind?
    var model: String?
    var effort: String?

    init(name: String) {
        id = UUID()
        self.name = name
    }

    /// The profile in words for the lead's brief: "deep (claude-opus-5 on Anthropic)".
    var briefLabel: String {
        let on = [model, provider?.displayName].compactMap { $0 }.joined(separator: " on ")
        return on.isEmpty ? name : "\(name) (\(on))"
    }

    /// The name as it appears in agent names ("Deep Work" gives "deep-work"), so a
    /// profile named in that form still matches whatever the spacing or case.
    var agentSlug: String {
        String(name.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" })
    }

    /// Whether a delegation's `profile` names this one: case-insensitive, and blind to
    /// the whitespace a name typed in Settings or written in a lead's JSON can carry. An
    /// agent slug ("deep-work" from a spawned agent's name) matches the same way.
    func matches(_ name: String) -> Bool {
        let wanted = name.trimmed
        return self.name.trimmed.caseInsensitiveCompare(wanted) == .orderedSame
            || agentSlug == wanted
    }
}

/// A lead-and-heads pairing: which model runs the heads when a chat on this provider leads.
/// `orchestratorModel` nil means any model on the provider; a nil worker field means the
/// heads inherit the chat's own model or effort. `workerProvider` nil keeps the heads on
/// the lead's provider; set, they run there instead, on `workerModel` or that provider's
/// default model, with `workerEffort` from that provider's own efforts.
struct HydraPair: Codable, Hashable, Identifiable, Sendable {
    var id: UUID
    var provider: ProviderKind
    var orchestratorModel: String?
    var orchestratorEffort: String?
    var workerProvider: ProviderKind?
    var workerModel: String?
    var workerEffort: String?
    /// DeepSeek Harness's agent mode a chat takes on entering the pair as its lead; nil is the standard one.
    var orchestratorDshMode: DshAgentMode?
    /// DeepSeek Harness's agent mode for heads on it; nil runs them in the standard mode.
    var workerDshMode: DshAgentMode?
    /// How many heads may work at once; nil puts no cap on them, as with no pair at all.
    var maxHeads: Int?
    /// The name the user gave the pair, shown wherever the pair is named in place of its models; nil or blank is none.
    var name: String?
    /// The purpose-tuned heads of the pair's advanced mode; empty, every head runs on the
    /// shared worker fields above, as before.
    var headProfiles: [HydraHeadProfile]
    /// What the pair's heads are good at, in the user's words ("fast, for mechanical
    /// edits", "front-end"). Hydra 2 puts it in the lead's policy; nil or blank is none.
    var headsNote: String?

    static let maxHeadsRange = 1...8

    init(provider: ProviderKind) {
        id = UUID()
        self.provider = provider
        headProfiles = []
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = container.value(.id, default: UUID())
        provider = try container.decode(ProviderKind.self, forKey: .provider)
        orchestratorModel = container.value(.orchestratorModel, default: nil)
        orchestratorEffort = container.value(.orchestratorEffort, default: nil)
        workerProvider = container.value(.workerProvider, default: nil)
        workerModel = container.value(.workerModel, default: nil)
        workerEffort = container.value(.workerEffort, default: nil)
        orchestratorDshMode = container.value(.orchestratorDshMode, default: nil)
        workerDshMode = container.value(.workerDshMode, default: nil)
        name = container.value(.name, default: nil)
        maxHeads = Self.clampedCap(container.value(.maxHeads, default: nil))
        headProfiles = container.value(.headProfiles, default: [])
        headsNote = container.value(.headsNote, default: nil)
    }

    /// The provider the heads run on: the lead's, unless the pair sends them elsewhere.
    var headsProvider: ProviderKind { workerProvider ?? provider }

    /// Whether the heads run on another provider than the lead.
    var sendsHeadsElsewhere: Bool { workerProvider.map { $0 != provider } ?? false }

    /// The user's name for the pair, trimmed, or nil when there is none.
    var customName: String? {
        let trimmed = (name ?? "").trimmed
        return trimmed.isEmpty ? nil : trimmed
    }

    /// A cap kept inside the range, or none.
    static func clampedCap(_ cap: Int?) -> Int? {
        cap.map { min(max($0, maxHeadsRange.lowerBound), maxHeadsRange.upperBound) }
    }

    /// The pair a project's new chats start on. The rule applies only when all three hold:
    /// Hydra is on, the project names a pair, and that pair is in `available` (the pairs
    /// the model picker can offer now). In every other case the result is nil and the
    /// caller uses its own fallback.
    static func projectPair(_ id: UUID?, hydraOn: Bool, in available: [HydraPair]) -> HydraPair? {
        guard hydraOn, let id else { return nil }
        return available.first { $0.id == id }
    }
}

/// What a session launches with while Hydra is on: where the heads run and on what,
/// resolved from the pair, and how many may run at once.
struct HydraLaunch: Hashable, Sendable {
    /// The provider the heads run on: the lead's own, unless the pair sends them out on
    /// another one (see `HydraPair.workerProvider`).
    var headsProvider: ProviderKind
    /// The heads' model and provider in words, for the lead's brief, when they run on
    /// another provider than the lead: "Gemini 3.8 Flash on Antigravity".
    var headsLabel: String?
    /// The heads' provider's own model id for the heads, or nil to inherit the lead's model
    /// (on the lead's provider) or take the heads' provider's default (elsewhere).
    var workerModel: String?
    var workerEffort: String?
    /// The agent mode heads on DeepSeek Harness start in; nil is the standard one.
    var workerDshMode: DshAgentMode?
    /// The cap on heads at work at once: the lower of the pair's and the Hydra page's;
    /// nil, with neither set, lets as many out as the work asks for.
    var maxHeads: Int?
    /// The pair's purpose-tuned heads (its advanced mode): a delegation naming one runs
    /// on that profile's model and effort. Empty, every head takes the worker fields.
    var headProfiles: [HydraHeadProfile] = []
    /// Whether Tivano-run heads get copies of the checkout of their own.
    var isolatesHeads = true
    /// Whether Tivano lands the team's finished work itself (see
    /// `AppModel.autoMergeHydraWork`); the lead is told so it never merges by hand.
    var autoMerges = false
    /// The projects in the sidebar, the chat's own first: the lead may send a head to any
    /// of them by name, and its work lands and merges there.
    var projects: [HydraProjectRef] = []
    /// The pair's note on what its heads are good at.
    var headsNote: String?
    /// Whether the heads run on exactly the lead's provider and model: no pair, or a
    /// pair that changes nothing. The lead then delegates only for parallel or
    /// context-isolating work.
    var headsMatchLead = true
    /// The delegation tilt, from Settings › Hydra.
    var tilt: HydraTilt = .active

    /// How many Tivano-run heads may work at once for a pair with no cap of its own. The
    /// tasks past it wait their turn (`ThreadRuntime.spawnWaitingHeads`) and go out as
    /// heads finish, so a lead may still ask for as many as the job needs. Twenty-one heads
    /// at once each streaming into the app, each on its own copy of the checkout and its
    /// own CLI, kept the main thread and the GPU busy past the point of answering, and
    /// the app had to be force quit.
    static let uncappedConcurrency = 8

    /// Whether one more head may go out with `running` already at work.
    func hasRoom(running: Int) -> Bool {
        running < (maxHeads ?? Self.uncappedConcurrency)
    }

    /// The profile a delegation asked for; nil when the name matches none, and the head
    /// then runs on the worker fields like any unrouted one.
    func profile(named name: String) -> HydraHeadProfile? {
        headProfiles.first { $0.matches(name) }
    }
}

/// How much a Tivano-run head gets for one turn, on any provider: a nudge when it only
/// reads, a word to wrap up, then a stop and one more turn for its report, so the lead
/// always hears back. The API sessions pace themselves with these from inside the turn;
/// every other provider gets the stop from the head's runtime.
enum HydraBudget {
    /// Tools without a change before the head is asked to act.
    static let pacingTools = 24
    /// The wrap-up and the hard stop are wide enough for a real piece of work: a head cut
    /// off in the middle of a refactor costs the lead more than a slow head does.
    static let wrapUpTools = 120
    static let maxTools = 160
    static let wrapUpSeconds: TimeInterval = 25 * 60
    static let maxSeconds: TimeInterval = 35 * 60
    /// What a stopped head gets to write its report in.
    static let reportSeconds: TimeInterval = 3 * 60

    static let pacingNote = "[Tivano] You have run \(pacingTools) tools without changing a file. If the task is research, reply with your findings now. Otherwise act on what you know: make the change, or reply with what blocks you."
    static let wrapUpNote = "[Tivano] Your budget is nearly spent. Finish now: complete the smallest correct version of the task, then reply with your report."
    /// What a v2 head's report must end with, appended to every budget note a v2 head
    /// gets, so a head cut short still reports in the format the lead reads.
    static let v2ReportTrailer = "End your report with exactly these three lines, each `none` when empty:\nDeviations: ...\nUnfinished: ...\nUncertain: ..."
    static let finalNote = "[Tivano] Your budget is spent and your tools are gone. Reply now with your report: what you changed, how far it got, and what is left."
}

/// A head's identity: its name, its colour and the dragon head that is its glyph.
struct HydraPersona: Hashable, Sendable {
    let name: String
    /// The asset with the head's own dragon: one of twenty-five, drawn as a template so
    /// it takes the head's colour.
    let asset: String
    /// The colour as 0xRRGGBB.
    let hex: UInt32

    init(_ name: String, _ asset: String, _ hex: UInt32) {
        self.name = name
        self.asset = asset
        self.hex = hex
    }

    var color: Color {
        Color(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }

}

/// The names heads are given, in the order they are sent out, each with a dragon head
/// of its own. Past twenty-five the roster starts over with a number after the name.
enum HydraRoster {
    static let personas: [HydraPersona] = [
        HydraPersona("Hank", "hydra-head-01", 0xFF8A3D),
        HydraPersona("Walter", "hydra-head-02", 0x3D8BFF),
        HydraPersona("Ada", "hydra-head-03", 0x34C46A),
        HydraPersona("Otto", "hydra-head-04", 0xA35BE0),
        HydraPersona("Nova", "hydra-head-05", 0xF25C9A),
        HydraPersona("Remy", "hydra-head-06", 0x2BB5B0),
        HydraPersona("Iris", "hydra-head-07", 0xE8B430),
        HydraPersona("Milo", "hydra-head-08", 0xE84F4F),
        HydraPersona("Juno", "hydra-head-09", 0x6A5CFF),
        HydraPersona("Ezra", "hydra-head-10", 0x4FD1A1),
        HydraPersona("Lena", "hydra-head-11", 0x2FB8E6),
        HydraPersona("Bo", "hydra-head-12", 0xB0784A),
        HydraPersona("Kai", "hydra-head-13", 0x8FD14F),
        HydraPersona("Vera", "hydra-head-14", 0xD946EF),
        HydraPersona("Finn", "hydra-head-15", 0xF97316),
        HydraPersona("Mira", "hydra-head-16", 0xC084FC),
        HydraPersona("Odin", "hydra-head-17", 0xB45309),
        HydraPersona("Suki", "hydra-head-18", 0xF472B6),
        HydraPersona("Rex", "hydra-head-19", 0x2563EB),
        HydraPersona("Zola", "hydra-head-20", 0x65A30D),
        HydraPersona("Pip", "hydra-head-21", 0x94A3B8),
        HydraPersona("Ivo", "hydra-head-22", 0x0D9488),
        HydraPersona("Lux", "hydra-head-23", 0xFACC15),
        HydraPersona("Tova", "hydra-head-24", 0x059669),
        HydraPersona("Gus", "hydra-head-25", 0x7DD3FC),
    ]

    static func persona(at index: Int) -> HydraPersona {
        let count = personas.count
        let base = personas[((index % count) + count) % count]
        let round = max(0, index) / count
        guard round > 0 else { return base }
        return HydraPersona("\(base.name) \(round + 1)", base.asset, base.hex)
    }

    /// The roster index for an announced head name, case-insensitive, without any
    /// round suffix ("otto", "Otto 2"). Nil when the name is not on the roster (a
    /// lead inventing names says "Ives", say, which is nobody: the nearest roster
    /// name is "Ivo"). Only exact roster names are authoritative; anything else
    /// falls back to the next sequential head so an announcement never renames a
    /// stranger into the team.
    static func index(named name: String) -> Int? {
        var bare = name.trimmed
        // A trailing round number ("Otto 2") is the display suffix, not the name.
        if let space = bare.lastIndex(of: " "), Int(bare[bare.index(after: space)...]) != nil {
            bare = String(bare[..<space]).trimmed
        }
        return personas.firstIndex { $0.name.compare(bare, options: .caseInsensitive) == .orderedSame }
    }

    /// The roster persona for an announced head name, its round kept: "Nova 3" is the
    /// third Nova, "otto" the first Otto. Nil when the name is not on the roster.
    static func persona(named name: String) -> HydraPersona? {
        guard let index = index(named: name) else { return nil }
        let bare = name.trimmed
        if let space = bare.lastIndex(of: " "),
           let round = Int(bare[bare.index(after: space)...]), round > 1 {
            return persona(at: index + (round - 1) * personas.count)
        }
        return persona(at: index)
    }
}

/// A head thread's place in its lead's team: who it is, what it was sent to do, how it
/// runs and how far it has got.
struct HydraHeadInfo: Codable, Hashable, Sendable {
    /// Tivano-run heads are sessions of their own that Tivano starts and reports
    /// back for. Native heads ran inside the lead's own provider session; no lead spawns
    /// them any more, and the case stays so older records still decode.
    enum Kind: String, Codable, Sendable {
        case native
        case tivano
    }

    /// Delegated by the lead. Queued and sent origins are kept for records from older
    /// versions, which let the user route messages directly to heads.
    enum Origin: String, Codable, Sendable {
        case delegated
        case queued
        case sent
    }

    enum Status: String, Codable, Sendable {
        case running
        case completed
        case failed
        case stopped

        var isFinished: Bool { self != .running }
    }

    /// The head's place in the roster: its name, colour and shape.
    var index: Int
    var task: String
    var kind: Kind
    var origin: Origin
    var status: Status = .running
    /// The head's report, once it has one: the provider's summary for a native head, the
    /// final reply for a Tivano-run one.
    var summary: String?
    /// The provider's one-line progress note, or the last tool the head used.
    var activity: String?
    var toolCalls = 0
    var tokens = 0
    var startedAt = Date.now
    var finishedAt: Date?
    /// When the task was put in the queue that holds work for a head which cannot start
    /// yet, before anyone dispatched it. Nil for native heads and older records.
    var queuedAt: Date?
    /// When the head's brief was handed to its session, before its first turn ran. Kept
    /// apart from `queuedAt` so the time a task spent waiting for a slot is not counted as
    /// work, and apart from `startedAt`, which a native head gets from its provider's
    /// events. Nil for a native head, whose timing is its provider's to report.
    var executionStartedAt: Date?
    /// When that turn finished, however it ended. Nil while the head is at work, and for a
    /// native head.
    var executionFinishedAt: Date?
    /// When the head's work started going into the lead's checkout: after the patch was
    /// prepared and after any wait behind another head's landing, so it measures the write
    /// itself and not the queue. Nil when nothing was ever applied.
    var landingStartedAt: Date?
    /// When that ended, cleanly, in conflict markers or as a kept patch. Nil until it has,
    /// and for a landing that never began.
    var landingFinishedAt: Date?
    /// The provider's id for a native head: Claude's spawning tool call, Codex's child
    /// thread, Copilot's agent id.
    var nativeID: String?
    /// Claude's task id, which is what stops a running head.
    var nativeTaskID: String?
    /// The tool row in the lead's timeline that stands for this head.
    var toolUseID: String?
    /// The delegation a Tivano-run head belongs to: its report waits for the others.
    var batchID: UUID?
    /// The head profile the delegation routed this head to, when the pair has profiles:
    /// shown with the head and consulted again if the head is steered on.
    var profile: String?
    /// Whether Tivano can stop this head where it runs.
    var canStop = true
    /// A native head whose spawning tool call returned at once: only the provider's own
    /// word ends it, never the tool result.
    var isBackground = true
    /// Set on a Tivano-run head with a copy of the checkout of its own: the tree the copy
    /// started from, which its work is measured against when it lands. Moves on with
    /// every landing, so a head steered on afterwards lands only what is new.
    var baseTree: String?
    /// The landing checkout, kept after the head's temporary copy is released. Nil on
    /// older records, which keep the previous project and lead checkout rules.
    var targetCheckout: String?
    /// Kept until an explicit route succeeds, so a failed or stopped route cannot
    /// resume in the lead's project after its runtime is reloaded.
    var pendingProjectReference: String?
    /// Where the head's work went the last time it reported.
    var landing: HydraLanding?
    /// When the auto-merge took this head's work out: the next merge leaves it be. The
    /// head is what remembers, not the lead's turns: a head can finish between two of the
    /// lead's turns, and a merge that only counted heads finished since its first
    /// unmerged turn began skipped exactly those, leaving their files in the checkout.
    var mergedAt: Date?
    /// The three lines its last report ended with; nil on older heads.
    var reportNotes: HydraReportNotes?
    /// Hydra 2: the job in the lead's `hydraJobs` this head belongs to.
    var jobID: UUID?

    /// Explicit provenance for heads created by this version. Older/imported heads
    /// decode false; persona names or prompt text never establish ownership.
    var tracksProviderHistory = false
    var ownedCodexSessionID: String?
    var ownedCodexWorkingDirectory: String?
    /// An archive was dispatched; reconcile before resume even if its reply was lost.
    var codexHistoryArchived = false
    var providerHistoryIssue: String?

    var persona: HydraPersona { HydraRoster.persona(at: index) }
    /// The name the panel shows.
    var displayName: String { persona.name }
    var isFinished: Bool { status.isFinished }
    /// Whether the head works in a copy of the checkout that Tivano made for it.
    var hasOwnCopy: Bool { baseTree != nil }

    init(index: Int, task: String, kind: Kind, origin: Origin) {
        self.index = index
        self.task = task
        self.kind = kind
        self.origin = origin
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        index = container.value(.index, default: 0)
        task = container.value(.task, default: "")
        kind = container.value(.kind, default: .tivano)
        origin = container.value(.origin, default: .delegated)
        // A status that cannot be read (a record from a newer build, say) reads as
        // stopped, never as completed: a lead told a head is done when nobody knows what
        // became of it would answer the user for a team that never came back.
        status = container.value(.status, default: .stopped)
        summary = container.value(.summary, default: nil)
        activity = container.value(.activity, default: nil)
        toolCalls = container.value(.toolCalls, default: 0)
        tokens = container.value(.tokens, default: 0)
        startedAt = container.value(.startedAt, default: .now)
        finishedAt = container.value(.finishedAt, default: nil)
        // A head from a build before these existed has none of them, and reads as one
        // whose timing nobody recorded rather than one that has not begun.
        queuedAt = container.value(.queuedAt, default: nil)
        executionStartedAt = container.value(.executionStartedAt, default: nil)
        executionFinishedAt = container.value(.executionFinishedAt, default: nil)
        landingStartedAt = container.value(.landingStartedAt, default: nil)
        landingFinishedAt = container.value(.landingFinishedAt, default: nil)
        nativeID = container.value(.nativeID, default: nil)
        nativeTaskID = container.value(.nativeTaskID, default: nil)
        toolUseID = container.value(.toolUseID, default: nil)
        batchID = container.value(.batchID, default: nil)
        profile = container.value(.profile, default: nil)
        // Tivano owns a Tivano-run head's turn, so it can always stop one; only a
        // native head depends on the provider having said so.
        canStop = container.value(.canStop, default: kind == .tivano)
        isBackground = container.value(.isBackground, default: true)
        baseTree = container.value(.baseTree, default: nil)
        // Missing on a library saved before explicit checkouts: nil keeps the old rules.
        targetCheckout = container.value(.targetCheckout, default: nil)
        pendingProjectReference = container.value(.pendingProjectReference, default: nil)
        landing = container.value(.landing, default: nil)
        mergedAt = container.value(.mergedAt, default: nil)
        reportNotes = container.value(.reportNotes, default: nil)
        jobID = container.value(.jobID, default: nil)
        tracksProviderHistory = container.value(.tracksProviderHistory, default: false)
        ownedCodexSessionID = container.value(.ownedCodexSessionID, default: nil)
        ownedCodexWorkingDirectory = container.value(.ownedCodexWorkingDirectory, default: nil)
        codexHistoryArchived = container.value(.codexHistoryArchived, default: false)
        providerHistoryIssue = container.value(.providerHistoryIssue, default: nil)
    }
}

/// Where a head named in a lead's prose leads: its own chat, and what it was sent to do,
/// so the name in the text can be hovered and opened. Keyed by persona name in the
/// timeline's environment.
struct HydraMentionTarget: Hashable, Sendable {
    var threadID: UUID
    var task: String
    var status: HydraHeadInfo.Status
    /// The link a mention carries; the timeline opens it as the head's chat.
    static let scheme = "tivano-head"
    var url: URL { URL(string: "\(Self.scheme)://\(threadID.uuidString)") ?? URL(fileURLWithPath: "/") }
    /// The head a mention link points at, or nil for any other URL.
    static func threadID(in url: URL) -> UUID? {
        guard url.scheme == scheme, let host = url.host() else { return nil }
        return UUID(uuidString: host)
    }
}

/// Where a Tivano-run head's work went when it reported: into the lead's checkout, into
/// it with conflicts left to settle, or into a patch file when it would not apply.
struct HydraLanding: Codable, Hashable, Sendable {
    struct File: Codable, Hashable, Sendable {
        var path: String
        var additions: Int
        var deletions: Int
    }

    /// The files the head changed, with what the change amounted to.
    var files: [File] = []
    /// Files the three-way merge left conflict markers in.
    var conflicts: [String] = []
    /// Build-output diff sections left out before the patch was parsed.
    var droppedBuildOutputFiles = 0
    /// Where the patch went when none of it could be applied.
    var patchPath: String?
    var error: String?

    /// The head changed nothing.
    var isEmpty: Bool { files.isEmpty && patchPath == nil && error == nil }
    /// The work is in the checkout, conflict markers or not.
    var landed: Bool { !files.isEmpty && patchPath == nil && error == nil }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        files = container.value(.files, default: [])
        conflicts = container.value(.conflicts, default: [])
        droppedBuildOutputFiles = container.value(.droppedBuildOutputFiles, default: 0)
        patchPath = container.value(.patchPath, default: nil)
        error = container.value(.error, default: nil)
    }

    init() {}
}

/// A head the lead asked for through the delegation block.
/// `name` is the head's announced name when the lead gave one: it is
/// authoritative, so the spawned head carries exactly that roster name instead of the
/// next sequential one. Nil means the lead did not name it and the roster order decides.
struct HydraDelegation: Hashable, Sendable {
    var task: String
    var prompt: String
    var name: String?
    /// The project the head works in when the lead named one ("project": a sidebar
    /// project's name, or an absolute path). A worktree of a repository already in the
    /// sidebar reuses that project and keeps the named checkout; only a new repository
    /// is added. Nil keeps the head in the chat's own project.
    var project: String?
    /// The head profile the lead routed the task to (`"profile"` in the block); nil runs
    /// the head on the pair's shared worker model and effort.
    var profile: String?
    /// Hydra 2: the paths this head owns (`"files"`). Two entries of one block may not
    /// share a path.
    var files: [String] = []
    /// Whether the entry carried `"files"` at all: an empty list is a read-only head,
    /// a missing one is a mistake the lead is told about.
    var filesGiven = false
    /// Hydra 2: the name of a finished head of this lead's job to send back to its part
    /// in its own session (`"continue"`), instead of a new head.
    var continueHead: String?
}

/// The stages a Hydra merge walks through, in this order, one dot each on the merging
/// pill's track. With several projects the merge runs the stages after the first once per
/// project, so the track starts over with the project's name on the words.
enum HydraMergeStage: Int, CaseIterable, Sendable {
    case gathering
    case committing
    case describing
    case pushing
    case opening
    case merging
    case syncing

    /// The stage in words, as the pill and the sidebar show it.
    var words: String {
        switch self {
        case .gathering: "Gathering the team's files"
        case .committing: "Writing the commit"
        case .describing: "Writing the commit message"
        case .pushing: "Pushing the branch"
        case .opening: "Opening the merge request"
        case .merging: "Merging"
        case .syncing: "Bringing the checkout up to date"
        }
    }
}

/// A project the lead may send heads to: its name in the sidebar and its folder.
struct HydraProjectRef: Hashable, Sendable {
    var name: String
    var path: String
}

/// What a head sends back to its lead.
struct HydraReport: Hashable, Sendable {
    var headIndex: Int
    var task: String
    var origin: HydraHeadInfo.Origin
    var status: HydraHeadInfo.Status
    var text: String
    /// Where a Tivano-run head's work went; nil for a head that changed nothing or has
    /// no copy of its own.
    var landing: HydraLanding?
    /// The head's own copy of the checkout, for work that did not land.
    var copyPath: String?
    var elapsed: TimeInterval?
    var toolCalls = 0
    /// The head's provider, as the user knows it.
    var provider: String?
    /// The head failed with an error before a tool ran or a word was said: its provider's
    /// environment (install, sign-in, configuration, MCP servers) is at fault, not its task.
    var startupFailure = false
    /// Hydra 2: the three lines the head's report ended with, when it wrote them.
    var notes: HydraReportNotes?
    /// Whether the head was asked to end its report with the three Hydra 2 notes.
    var expectsNotes = false
}

/// The per-request budgets behind a lead's delegation blocks: how many rounds of heads
/// have gone out for the user's current request, and how many times the lead has been
/// told in a turn of its own that a block sent no heads out. A turn the user authored
/// starts both over; a turn carrying head reports or a refusal notice continues the
/// same request and does not.
struct HydraDelegationBudget {
    /// Rounds of heads gone out for the current request.
    private(set) var rounds = 0
    /// Refusals given a turn of their own in the current request.
    private(set) var refusals = 0
    /// A dropped block's notice, waiting to ride on the front of the lead's next turn:
    /// past `maxRefusals` no turn of its own is spent on a refusal, and a turn that
    /// ended before its block's heads went out spent none to begin with, but the lead
    /// still hears that its heads never went out. A drop is never quieter than a refusal.
    private(set) var dropNotice: String?

    /// Whether another round of heads may still go out for this request.
    var canDelegate: Bool { rounds < HydraPrompts.maxDelegationRounds }

    /// What a new turn does to the budget: `userAuthored` is what `hydraHeads == nil`
    /// says at turn start — the user's own words, not heads reporting back and not a
    /// refusal notice. The drop notice is not a turn start's to clear: `takeDropNotice`
    /// spends it when it actually reaches the lead.
    mutating func beginTurn(userAuthored: Bool) {
        guard userAuthored else { return }
        rounds = 0
        refusals = 0
    }

    /// A round of heads went out.
    mutating func chargeRound() {
        rounds += 1
    }

    /// A block sent no heads out. Returns whether the refusal gets a turn of its own;
    /// past the cap the notice waits for the lead's next turn instead, so a reply that
    /// still ends in a block ends as a plain reply, but never in silence.
    mutating func refuse(_ message: String) -> Bool {
        guard refusals < Self.maxRefusals else {
            noteDropped(message)
            return false
        }
        refusals += 1
        return true
    }

    /// A block dropped without a refusal of its own: the lead hears it on its next
    /// turn all the same.
    mutating func noteDropped(_ message: String) {
        dropNotice = HydraPrompts.droppedBlockNotice(message)
    }

    /// The notice waiting for the lead, spent: it rides on the front of one turn, once.
    mutating func takeDropNotice() -> String? {
        defer { dropNotice = nil }
        return dropNotice
    }

    /// How many times one request may tell the lead that its block was unreadable or held
    /// back, each in a turn of its own. Enough for a lead to fix a malformed block and to
    /// hear once that its rounds are spent; past it a reply that still ends in a block is
    /// treated as a plain reply, so no chat ever loops turn after turn on the same refusal.
    static let maxRefusals = 3
}

/// The words Hydra puts in front of the lead and the heads, per provider.
enum HydraPrompts {
    /// Where a Tivano-run head works: a copy of the checkout made for it, or the checkout
    /// itself when the project cannot be copied (no git, no commits yet) or the user
    /// prefers it so.
    enum Workplace {
        case ownCopy(path: String)
        case shared(path: String)
    }

    /// What a head is told about the checkout it works in and what it may do to it. The
    /// shared case is a head's lot when its project cannot be copied or the user turned
    /// the copies off.
    static func workplaceRules(_ workplace: Workplace) -> String {
        switch workplace {
        case .ownCopy(let path):
            """
            You have your own copy of the project at \(path): a git worktree Tivano made for you from the project's checkout as it was when you were sent out, uncommitted work included. Work in it directly, on the files as they are; your tools already run there. When you report, Tivano carries your changes into that checkout itself. So never commit, branch, stash, push, check out, reset, restore or clean anything, and never make or remove worktrees, whatever the project's own guidelines say about agents and worktrees: this copy already is yours. Do not use git to check your work either.
            Never build, test or verify anything in your copy: the lead runs every check itself, in its own checkout. Anything under the project folder that git does not ignore lands in the lead's checkout, so leave no build output there.
            """
        case .shared(let path):
            """
            You work in the lead's checkout at \(path), alongside the lead and the other heads, who are changing other files at the same time. Changes you did not make are expected there: leave every one of them alone, never stash, check out, reset, restore or clean anything, and never move work into a branch or worktree, whatever the project's own guidelines say about agents and worktrees. Do not use git status or git diff to check your work: they show everyone's changes, and the lead does the verifying.
            """
        }
    }

    /// How the lead tells the user what the heads did: one short human sentence per
    /// head, head's name first, everyday words for what changed for the user, file
    /// details on one short second line only, no audit-speak, no icons.
    static let reportStyleRule = "For each head, give one plain sentence starting with its name and describing the user-visible result; add the file details only when useful, and keep the whole account bounded to a line or two per head. Omit repeated summaries, audit jargon and decorative symbols. Say plainly what you still need from the user and what you settled or fixed yourself."

    // MARK: - Tivano-run heads

    /// How many times in a row a lead may send heads out for one request of the user's: a
    /// big job wants scouts to read, workers to change, and one round for what failed or
    /// what the reports showed was missing. Past that the lead finishes by itself, so no
    /// request can chain heads that verify heads that verify heads.
    static let maxDelegationRounds = 3

    /// The current request's heads and any still running, in one line, with earlier
    /// finished heads counted separately so the lead knows they cannot be sent back.
    static func teamStatus(_ heads: [HydraHeadInfo], currentJobID: UUID?, now: Date = .now) -> String? {
        guard !heads.isEmpty else { return nil }
        let current = heads.filter { ($0.jobID == currentJobID && currentJobID != nil) || $0.status == .running }
        let earlierCount = heads.count - current.count
        guard !current.isEmpty else {
            return "No heads on this request yet; \(earlierCount == 1 ? "1 head" : "\(earlierCount) heads") finished on earlier requests and cannot be sent back: send a new head for their part."
        }
        let parts = current.map { info -> String in
            let name = info.persona.name
            switch info.status {
            case .running:
                let minutes = Int(now.timeIntervalSince(info.startedAt) / 60)
                return "\(name) (working\(minutes > 0 ? " for \(minutes)m" : ""))"
            case .completed:
                if let landing = info.landing {
                    if landing.isEmpty { return "\(name) (done, changed nothing)" }
                    if landing.landed { return "\(name) (done, landed \(landing.files.count == 1 ? "1 file" : "\(landing.files.count) files"))" }
                    return "\(name) (done, patch kept)"
                }
                return "\(name) (done)"
            case .failed: return "\(name) (failed)"
            case .stopped: return "\(name) (stopped)"
            }
        }
        let earlier = earlierCount > 0 ? " \(earlierCount) more finished on earlier requests; they cannot be sent back." : ""
        return "Your heads on this request: " + parts.joined(separator: ", ") + "." + earlier
    }

    /// The policy for a lead whose session keeps it in its system prompt: the API
    /// providers, and Claude, Codex and Copilot, which define it at launch.
    static func fallbackPolicy(_ launch: HydraLaunch) -> String {
        return v2Policy(launch)
    }

    /// The true merge state for the front of a lead's message, so it never promises a merge that already happened or claims one that failed.
    static func mergeStatus(merges: [HydraMergeRecord], unmergedFiles: Int, now: Date = .now) -> String? {
        func files(_ count: Int) -> String { count == 1 ? "1 file" : "\(count) files" }
        func when(_ date: Date) -> String { date.formatted(date: .omitted, time: .shortened) }
        func merged(_ record: HydraMergeRecord) -> String {
            let link = [record.label, record.url?.absoluteString].compactMap { $0 }.joined(separator: " ")
            let scope = record.project.map { " in \($0)" } ?? ""
            return "the team's work already merged as \(link)\(scope) at \(when(record.at)) (\(files(record.files)))."
        }
        func pendingLine(_ prefix: String) -> String {
            let one = unmergedFiles == 1
            return "\(prefix) \(one ? "is" : "are") not merged yet; \(one ? "it goes" : "they go") out by \(one ? "itself" : "themselves") once you finish this answer with every head back."
        }
        let pending = unmergedFiles > 0
            ? pendingLine("\(files(unmergedFiles)) changed since then")
            : "Nothing has changed since, so no merge is pending and none is coming."
        guard let last = merges.last else {
            guard unmergedFiles > 0 else { return nil }
            return "Merge state: \(pendingLine("\(files(unmergedFiles)) changed in this chat"))"
        }
        switch last.outcome {
        case .merged:
            return "Merge state: \(merged(last)) \(pending)"
        case .failed:
            if last.retryable == true {
                return "Merge state: the last try at \(when(last.at)) did not land yet (\(last.detail ?? "no reason recorded")). Tivano retries it by itself within a minute; nothing is needed from the user, so do not ask for anything or describe it as a problem. Do not claim a successful merge."
            }
            return "Merge state: the last merge failed at \(when(last.at)): \(last.detail ?? "no reason recorded"). The work is still in the checkout and goes out by itself once that is settled; if the reason needs the user (a sign-in, conflict markers, a real conflict with the remote), say exactly that."
        case .held:
            // Written only by earlier versions: a merge never waits on another chat now.
            guard unmergedFiles > 0 else {
                return "Merge state: nothing from this job is left to merge. Do not claim a new merge or promise another one."
            }
            return "Merge state: \(pendingLine("\(files(unmergedFiles)) from this job"))"
        case .settled:
            return "Merge state: at \(when(last.at)), Hydra found every change from this chat already on main, so nothing was sent. \(pending) Do not describe this as a new merge."
        case .stray:
            // A stray note right after a merge is a footnote to it: the merge is the news.
            var parts = ["Merge state:"]
            if let landed = merges.last(where: { $0.outcome == .merged }) { parts.append(merged(landed)) }
            parts.append("At \(when(last.at)) \(last.detail ?? "files were changed outside every project")")
            parts.append(pending)
            return parts.joined(separator: " ")
        }
    }

    /// In front of the user's own message: the team so far, when there is one.
    static func fallbackTurnNote(team: String?, merge: String? = nil) -> String {
        let parts = [team, merge].compactMap { $0 }
        guard !parts.isEmpty else { return "" }
        return "[Hydra] " + parts.joined(separator: " ") + "\n\n---\n\n"
    }

    /// What the lead hears when its delegation block is refused: the request has had its
    /// rounds of heads, and the rest is the lead's own.
    static func heldBackMessage(count: Int) -> String {
        """
        Hydra held back \(count == 1 ? "a head" : "\(count) heads").
        None of the heads you asked for went out: this request has had all \(maxDelegationRounds) of its rounds of heads already. Do the rest yourself now, without git status or git diff on the heads' work, and answer the user.
        """
    }

    /// What the lead hears when its reply ended before the block's heads could go out:
    /// the block was dropped, and none of that work was delegated.
    static func interruptedBlockMessage(stopped: Bool) -> String {
        """
        No heads went out.
        Your reply's delegation block was dropped: the turn \(stopped ? "was stopped" : "failed") before the heads could go out, and none of that work was delegated. Do it yourself, or send the block again.
        """
    }

    /// A dropped block's message, riding on the front of the lead's next turn: past the
    /// refusal cap no turn of its own is spent on it, but the lead still hears that its
    /// heads never went out. Opens with [Hydra], which the policy tells the lead is
    /// Tivano speaking, not the user.
    static func droppedBlockNotice(_ message: String) -> String {
        "[Hydra] " + message + "\n\n---\n\n"
    }

    /// The opening fence of a delegation block: three backticks, the word hydra in any
    /// case, and the end of that line.
    private static func delegationOpener(in text: String) -> Range<String.Index>? {
        text.firstMatch(of: #/```[ \t]*hydra(?:-sent|-leaving)?[ \t]*\r?\n/#.ignoresCase())?.range
    }

    /// Every three backticks that open a line from `start` on, in order. A fence with an
    /// info string after it counts too: inside a prompt that is what a quoted snippet
    /// looks like, and the parser needs those to know where not to cut.
    private static func lineStartFences(in text: String, from start: String.Index) -> [Range<String.Index>] {
        var fences: [Range<String.Index>] = []
        var cursor = start
        while let fence = text[cursor...].firstRange(of: "```") {
            if fence.lowerBound == text.startIndex || text[text.index(before: fence.lowerBound)].isNewline {
                fences.append(fence)
            }
            cursor = fence.upperBound
        }
        return fences
    }

    /// Where the delegation block sits in a reply: from its opening fence up to and
    /// including its closing fence, which is the last three backticks that open a line
    /// after the opener, never the first. A prompt may quote a fenced snippet of its own,
    /// and cutting at the first fence inside it lost the whole block. Without a closing
    /// fence at all (the reply is still streaming, or the lead forgot it) the block runs
    /// to the end of the text.
    static func delegationBlockRange(in text: String) -> Range<String.Index>? {
        guard let opener = delegationOpener(in: text) else { return nil }
        let end = lineStartFences(in: text, from: opener.upperBound).last?.upperBound ?? text.endIndex
        return opener.lowerBound..<end
    }

    /// Whether the reply has a delegation block at all, readable or not.
    static func hasDelegationBlock(in text: String) -> Bool { delegationBlockRange(in: text) != nil }

    /// The same test over a tail of a reply still streaming: a block is there once its
    /// opening fence is, so a reader that has scanned the text up to some point only
    /// needs to scan what arrived since (see `HydraButton`).
    static func hasDelegationOpener(in tail: Substring) -> Bool {
        tail.firstMatch(of: #/```[ \t]*hydra(?:-sent|-leaving)?[ \t]*\r?\n/#.ignoresCase()) != nil
    }

    /// The delegation block at the end of a reply, if the lead wrote one. The body up to
    /// the last fence is tried first; when that does not parse, a prompt has most likely
    /// quoted a fence of its own and the closer is somewhere else, so every earlier fence
    /// is tried in turn, from the last back to the first, and lastly the end of the text
    /// for a block whose closer never came. An empty array is a block that asks for no
    /// heads (the lead did the work itself) and comes back as an empty list, not as nil.
    /// While the reply streams, `streamedDelegations(in:)` reads the same block entry by entry.
    static func delegations(in text: String) -> [HydraDelegation]? {
        guard let opener = delegationOpener(in: text) else { return nil }
        let bodyStart = opener.upperBound
        var ends = lineStartFences(in: text, from: bodyStart).reversed().map(\.lowerBound)
        ends.append(text.endIndex)
        for end in ends {
            if let parsed = delegations(fromBody: String(text[bodyStart..<end])) { return parsed }
        }
        return nil
    }

    /// The heads a block body asks for: a JSON array of entries (or one bare entry),
    /// read by `delegation(fromEntry:)`, which holds the rules for which entries are kept
    /// and how they are titled and named.
    /// An empty array is read as asking for nothing; entries with nothing usable in them
    /// are not read at all.
    private static func delegations(fromBody body: String) -> [HydraDelegation]? {
        guard let json = JSONValue.parse(body) else { return nil }
        if let array = json.array, array.isEmpty { return [] }
        let entries: [JSONValue] = json.array ?? (json.object == nil ? [] : [json])
        let parsed = entries.compactMap(delegation(fromEntry:))
        return parsed.isEmpty ? nil : parsed
    }

    /// The reply with its delegation block taken out, for what the lead said to the user.
    static func withoutDelegationBlock(_ text: String) -> String {
        var kept = text
        if let range = delegationBlockRange(in: text) { kept.removeSubrange(range) }
        return kept.trimmed
    }

    /// How long the delegation card stays once its heads are out, wearing its done wave,
    /// before it leaves the reply.
    static let delegationSentHold: Duration = .seconds(3.2)

    /// How long the card takes to fade out in place, still holding its room in the reply,
    /// before the block goes and the text below closes up (see `markingDelegationBlockLeaving`).
    static let delegationLeaveFade: Duration = .milliseconds(450)

    /// Whether the reply holds a delegation block already marked sent or on its way out
    /// (see `markingDelegationBlockSent` and `markingDelegationBlockLeaving`).
    static func hasSentDelegationBlock(in text: String) -> Bool {
        mayOpenDelegationFence(text) && text.contains(sentBlockOpener)
    }

    /// Whether the reply's delegation block is fading out (its info string is `hydra-leaving`).
    static func hasLeavingDelegationBlock(in text: String) -> Bool {
        mayOpenDelegationFence(text) && text.contains(leavingBlockOpener)
    }

    // Built once: a regex literal is parsed and compiled again on every call, which was
    // most of installing a long history (one check per reply). `Regex` is not marked
    // Sendable, but a built one is only read when matching, so sharing it is safe.
    nonisolated(unsafe) private static let sentBlockOpener = #/```[ \t]*hydra-(?:sent|leaving)[ \t]*\r?\n/#.ignoresCase()
    nonisolated(unsafe) private static let leavingBlockOpener = #/```[ \t]*hydra-leaving[ \t]*\r?\n/#.ignoresCase()

    /// Whether some fence's info string starts with an h, after spaces or tabs: every
    /// delegation opener does, so a reply without one skips the regex.
    private static func mayOpenDelegationFence(_ text: String) -> Bool {
        var text = text
        return text.withUTF8 { bytes in
            let backtick = UInt8(ascii: "`")
            var index = 0
            while index + 3 < bytes.count {
                if bytes[index] == backtick, bytes[index + 1] == backtick, bytes[index + 2] == backtick {
                    var after = index + 3
                    while after < bytes.count, bytes[after] == UInt8(ascii: " ") || bytes[after] == UInt8(ascii: "\t") { after += 1 }
                    if after < bytes.count, bytes[after] | 0x20 == UInt8(ascii: "h") { return true }
                }
                index += 1
            }
            return false
        }
    }

    /// The reply with its sent block's info string turned into `hydra-leaving`: the card fades
    /// where it stands, still taking up its room, so nothing below slides up under it. A
    /// removal that glided the card over the closing text read as a ghost of the card.
    static func markingDelegationBlockLeaving(_ text: String) -> String {
        guard hasSentDelegationBlock(in: text), !hasLeavingDelegationBlock(in: text), let opener = delegationOpener(in: text) else { return text }
        return text.replacingCharacters(in: opener, with: "```hydra-leaving\n")
    }

    /// The reply with its delegation block's info string turned from `hydra` into `hydra-sent`,
    /// so the timeline draws the card in its done state for a moment before the block goes.
    static func markingDelegationBlockSent(_ text: String) -> String {
        guard let opener = delegationOpener(in: text), !hasSentDelegationBlock(in: text) else { return text }
        return text.replacingCharacters(in: opener, with: "```hydra-sent\n")
    }

    /// What the lead hears when its block was there but could not be read: no heads went
    /// out, how to write the block so it can be read, and that the attempt cost it nothing.
    static func unreadableBlockMessage(reason: String?) -> String {
        var message = "[Hydra] Your delegation block could not be read, so no heads went out."
        if let reason = reason?.trimmed, !reason.isEmpty {
            message += " " + reason + (reason.last.map { ".!?".contains($0) } == true ? "" : ".")
        }
        return message + " Write the block again at the end of your reply: one fenced block whose info string is hydra, holding a JSON array of objects with a task string and a prompt string. Inside a prompt never open a fenced code block of your own (no three backticks): describe code in words, quote identifiers with single backticks, or indent snippets. This does not count as a round of heads."
    }

    /// A lead has been told never to put a check in a brief, but some do anyway: the
    /// lines that ask a head to build or verify are taken out before the head sees them.
    private static let verificationMarkers: [String] = [
        "xcodebuild", "swift build", "swift test", "swiftlint", "npm test", "npm run build",
        "npm run test", "yarn build", "yarn test", "pnpm test", "cargo build", "cargo test",
        "go test", "pytest", "gradle", "eslint", "tsc ", "build succeeded", "run the build",
        "run the tests", "run the test suite", "build and prove", "prove it builds",
        "prove it compiles", "check that it builds", "check it still builds",
        "make sure it builds", "make sure it compiles", "confirm the build",
        "verify the build", "verify that it builds", "make sure nothing else broke",
        "run the suite", "build verification",
    ]

    /// Drops every line of a brief that asks the head to build, test, lint or otherwise
    /// verify. A prompt with no such line comes back unchanged.
    static func withoutVerificationSteps(_ prompt: String) -> String {
        let kept = prompt.split(separator: "\n", omittingEmptySubsequences: false).filter { line in
            let lowered = line.lowercased()
            return !verificationMarkers.contains { lowered.contains($0) }
        }
        if kept.count == prompt.split(separator: "\n", omittingEmptySubsequences: false).count { return prompt }
        return kept.joined(separator: "\n")
            + "\nMake the assigned edits and report; the lead handles all validation."
    }

    /// What the lead's chat looked like when a queued task was handed to a head, so the
    /// head knows what is going on without the lead's context. Built from the timeline,
    /// not from another model call, so a queued task costs nothing extra.
    struct ChatContext {
        var lastUserPrompt: String?
        var lastReply: String?
        var touchedPaths: [String] = []
    }

    /// One line on where a head's work went, for its section of the report. Nothing for
    /// a head that worked in the checkout itself: its changes are simply there.
    static func landingLine(for report: HydraReport) -> String? {
        guard let landing = report.landing else {
            guard let path = report.copyPath else { return nil }
            return report.status == .completed ? "Changed nothing." : "Nothing landed; its unfinished work is in its copy at \(path)."
        }
        if landing.isEmpty { return "Changed nothing." }
        let files = landing.files.prefix(25).map { file -> String in
            var line = "\(file.path) (+\(file.additions) −\(file.deletions))"
            if landing.conflicts.contains(file.path) { line += " with conflicts" }
            return line
        }
        let listed = files.joined(separator: ", ")
            + (landing.files.count > 25 ? ", and \(landing.files.count - 25) more" : "")
        let omitted = landing.droppedBuildOutputFiles == 0 ? "" : "; \(landing.droppedBuildOutputFiles) build-output file\(landing.droppedBuildOutputFiles == 1 ? " was" : "s were") left out"
        if landing.patchPath != nil { return "Did not land: \(listed)\(omitted)." }
        if let error = landing.error { return "Did not land (\(error)): \(listed)\(omitted)." }
        return "Landed in your checkout: \(listed)\(omitted)."
    }

    static func duration(_ seconds: TimeInterval) -> String {
        Duration.seconds(Int(seconds))
            .formatted(.units(allowed: [.seconds, .minutes], width: .narrow, maximumUnitCount: 2, fractionalPart: .hide(rounded: .down)))
    }

    static func list(_ names: [String]) -> String {
        switch names.count {
        case 0: ""
        case 1: names[0]
        default: names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
        }
    }

}
