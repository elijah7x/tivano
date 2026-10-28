import Foundation

/// The mark a project wears in the activity list's icon style: an emoji, or the name of an
/// SF Symbol. Stored as one string, `emoji:\U0001F528` or `symbol:hammer`, so the library needs no
/// shape of its own and a library written before the field reads straight through.
enum ProjectIcon: Hashable, Sendable, Codable {
    case emoji(String)
    case symbol(String)

    /// The emoji, when the mark is one.
    var emoji: String? {
        if case .emoji(let value) = self { return value }
        return nil
    }

    /// The symbol's name, when the mark is one.
    var symbolName: String? {
        if case .symbol(let name) = self { return name }
        return nil
    }

    /// The stored form: the kind, a colon, the value.
    var storage: String {
        switch self {
        case .emoji(let value): "emoji:\(value)"
        case .symbol(let name): "symbol:\(name)"
        }
    }

    /// Reads the stored form. A value with no kind in front of it is a symbol's name, so a
    /// library written by hand still reads.
    init?(storage: String) {
        guard !storage.isEmpty else { return nil }
        if storage.hasPrefix("emoji:") {
            self = .emoji(String(storage.dropFirst("emoji:".count)))
        } else if storage.hasPrefix("symbol:") {
            self = .symbol(String(storage.dropFirst("symbol:".count)))
        } else {
            self = .symbol(storage)
        }
    }

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let icon = ProjectIcon(storage: raw) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "An empty project icon"))
        }
        self = icon
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(storage)
    }
}

struct Project: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var name: String
    var path: String
    var addedAt: Date
    var isExpanded: Bool
    /// Keeps the project in the shelved group until work resumes.
    var isShelved: Bool
    /// When last shelved or unshelved, so a manual unshelve restarts the idle clock.
    var shelfChangedAt: Date?
    var scripts: [ProjectScript]
    /// The pair that each new chat in this project starts on. Nil means no rule: the chat
    /// starts on the pair the app remembers (see `AppModel.newThread`). The pair must be
    /// in Settings and its provider must be on, or the rule does not apply.
    var hydraPairID: UUID?
    /// The project's mark in the activity list's icon style: its emoji or SF Symbol. Nil
    /// draws the folder mark, so a project reads at a glance before one has been picked.
    var icon: ProjectIcon?

    init(name: String, path: String) {
        id = UUID()
        self.name = name
        self.path = path
        addedAt = .now
        isExpanded = true
        isShelved = false
        shelfChangedAt = nil
        scripts = []
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        path = try container.decode(String.self, forKey: .path)
        name = container.value(.name, default: URL(fileURLWithPath: path).lastPathComponent)
        addedAt = container.value(.addedAt, default: .now)
        isExpanded = container.value(.isExpanded, default: true)
        isShelved = container.value(.isShelved, default: false)
        shelfChangedAt = container.value(.shelfChangedAt, default: nil)
        scripts = container.value(.scripts, default: [])
        hydraPairID = container.value(.hydraPairID, default: nil)
        icon = container.value(.icon, default: nil)
    }

    var url: URL { URL(fileURLWithPath: path) }
}

struct ProjectScript: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var name: String
    var command: String
    var symbol: String
    var runOnWorktreeCreate: Bool

    init(name: String, command: String, symbol: String = "play", runOnWorktreeCreate: Bool = false) {
        id = UUID()
        self.name = name
        self.command = command
        self.symbol = symbol
        self.runOnWorktreeCreate = runOnWorktreeCreate
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = container.value(.id, default: UUID())
        name = try container.decode(String.self, forKey: .name)
        command = try container.decode(String.self, forKey: .command)
        symbol = container.value(.symbol, default: "play")
        runOnWorktreeCreate = container.value(.runOnWorktreeCreate, default: false)
    }
}

enum ThreadAffiliation: Equatable, Sendable, Codable {
    case project(UUID)
    case standalone

    var projectID: UUID? {
        if case .project(let id) = self { return id }
        return nil
    }
}

enum NewThreadAffiliation: Sendable {
    case project(UUID)
    case standalone
    case current
}

struct ChatThread: Codable, Identifiable, Hashable, Sendable {
    static let untitled = "New thread"

    var id: UUID
    var projectID: UUID?
    var hasStartedTurn = false

    var affiliation: ThreadAffiliation { projectID.map(ThreadAffiliation.project) ?? .standalone }
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var provider: ProviderKind {
        didSet {
            runtimeMode = Self.supportedMode(runtimeMode, on: provider)
            if provider != oldValue { dshMode = nil }
        }
    }
    var model: String?
    var effort: String?
    var fastMode: Bool
    var dshMode: DshAgentMode?
    var runtimeMode: RuntimeMode {
        didSet { runtimeMode = Self.supportedMode(runtimeMode, on: provider) }
    }
    var interactionMode: InteractionMode
    var worktreePath: String?
    var branch: String?
    /// External creation records readiness durably; failure never falls back to a project.
    var controlWorkspace: ControlWorkspace?
    var providerSessionID: String?
    var providerResumeAt: String?
    var isPinned: Bool
    var isArchived: Bool
    var hasUnread: Bool
    var unreadStatus: TurnStatus?
    var unreadRevision: UUID?
    var lastAttentionTurnID: UUID?
    var pendingResultTurnID: UUID?
    var hasCustomTitle: Bool
    /// The thread's place once its project has been reordered by dragging; nil keeps newest first.
    var sortOrder: Double?
    /// The thread's place within its group in the activity layout once dragged there.
    var activityOrder: Double?
    /// The day that place was given; a thread active on a later day is newest first again.
    var activityOrderDay: Date?
    var lastStatus: TurnStatus?
    /// The thread this one was spawned from, for a helper (a merge, for now). A helper opens
    /// in its parent's floating panel and, once that closes, sits under its parent in the
    /// sidebar as a smaller row for as long as the parent is there.
    var parentThreadID: UUID?
    /// Whether the helper is showing in its parent's floating panel. While it is, it is kept
    /// out of the sidebar, the palette, the recent picks and the unread count.
    var isInPanel = false
    /// A voice orchestrator keeps its brief and disables native Codex sub-agents on resume.
    var isVoiceSession = false
    /// Whether this thread's helpers are shown one by one under it in the sidebar. Off
    /// until the user opens them: folded, one line under the chat names the team, and a
    /// click on it unfolds them. Saved under its own key, so chats from before the fold
    /// was the default fold too.
    var expandsHelpers = false
    var foldsHelpers: Bool {
        get { !expandsHelpers }
        set { expandsHelpers = !newValue }
    }
    /// Per-chat Hydra switch: off kills heads for this chat only, on restores them
    /// (with the app-wide switch on). New threads start on the saved default
    /// (see `hydraDefaultEnabled()`); flipping a chat's switch saves there too.
    var hydraEnabled = true
    /// Whether `hydraEnabled` above was saved by a build that has the per-chat switch.
    /// Saves from before it carried an ignored false under the same key, so a thread
    /// without this flag decodes as on whatever its stored value says; every save from
    /// here on writes the flag, and its stored value is then the user's own choice.
    var hydraEnabledIsExplicit = true
    /// The pair an old thread picked while Hydra had per-chat switches. Kept for
    /// decoding; new threads use the best fit for their provider and model.
    var hydraPairID: UUID?
    /// A pair made for this chat alone in the model picker, never saved to Settings › Hydra.
    /// It leads while `hydraPairID` names it.
    var temporaryHydraPair: HydraPair?
    /// How many heads this chat has sent out so far: the next one's place in the roster.
    var hydraSpawnCount = 0
    /// Set on a head: the thread is one of its parent's team.
    var hydra: HydraHeadInfo?
    /// Hydra 2 (Labs): one record per user request a lead ran on v2, for scoring.
    /// Append-only; see `HydraJobRecord`.
    var hydraJobs: [HydraJobRecord] = []

    /// Spawned from another thread, whichever side of the panel it is on.
    var isHelper: Bool { parentThreadID != nil }

    /// A Hydra head, whichever side of the panel it is on.
    var isHydraHead: Bool { hydra != nil }

    /// Where this thread's tools and git calls run. The head's own copy wins while it
    /// exists. An explicit Hydra checkout is next, and it stays after that copy is
    /// released, so a head sent to a worktree does not fall back to the project folder.
    /// Older heads leave the checkout nil and use the project folder once their copy is gone.
    func executionDirectory(projectPath: String) -> String {
        if let worktreePath, !worktreePath.isEmpty { return worktreePath }
        if let checkout = hydra?.targetCheckout, !checkout.isEmpty { return checkout }
        return projectPath
    }

    /// Eligible for a standalone sidebar or palette entry. Hydra heads never stand alone,
    /// even after leaving their panel or when their lead is missing or archived.
    /// Sidebar layouts separately nest ordinary helpers under their visible parents.
    var isStandaloneListCandidate: Bool { !isArchived && !isInPanel && !isHydraHead }

    static func orderedByActivity(_ threads: [ChatThread]) -> [ChatThread] {
        let calendar = Calendar.current
        func order(_ thread: ChatThread) -> Double? {
            guard let order = thread.activityOrder, let day = thread.activityOrderDay,
                  calendar.isDate(day, inSameDayAs: thread.updatedAt) else { return nil }
            return order
        }
        return threads.sorted { lhs, rhs in
            switch (order(lhs), order(rhs)) {
            case let (left?, right?) where left != right: return left < right
            case (nil, .some): return true
            case (.some, nil): return false
            default: return lhs.updatedAt > rhs.updatedAt
            }
        }
    }

    /// Defaults key holding the per-chat Hydra default; `AppSettings` reads it from here.
    static let hydraDefaultKey = "hydraDefaultEnabled"

    /// The per-chat Hydra default new threads start with: the last per-chat switch
    /// flip, or on until the user first switches a chat off.
    static func hydraDefaultEnabled() -> Bool {
        let defaults = CaptureRun.defaults ?? .standard
        return defaults.object(forKey: hydraDefaultKey) as? Bool ?? true
    }

    private static func supportedMode(_ mode: RuntimeMode, on provider: ProviderKind) -> RuntimeMode {
        let supported = provider.supported(mode)
        if supported != mode { PermissionLowering.note(provider: provider, from: mode, to: supported) }
        return supported
    }

    init(projectID: UUID?, provider: ProviderKind, model: String?, effort: String?, runtimeMode: RuntimeMode, fastMode: Bool = false) {
        id = UUID()
        self.projectID = projectID
        title = Self.untitled
        createdAt = .now
        updatedAt = .now
        self.provider = provider
        self.model = model
        self.effort = effort
        self.fastMode = fastMode
        self.runtimeMode = Self.supportedMode(runtimeMode, on: provider)
        interactionMode = .build
        isPinned = false
        isArchived = false
        hasUnread = false
        hasCustomTitle = false
        hydraEnabled = Self.hydraDefaultEnabled()
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        projectID = try container.decodeIfPresent(UUID.self, forKey: .projectID)
        // Old records cannot prove that an unloaded history has never been sent.
        hasStartedTurn = try container.decodeIfPresent(Bool.self, forKey: .hasStartedTurn) ?? true
        title = container.value(.title, default: Self.untitled)
        createdAt = container.value(.createdAt, default: .now)
        updatedAt = container.value(.updatedAt, default: createdAt)
        provider = container.value(.provider, default: .codex)
        model = container.value(.model, default: nil)
        effort = container.value(.effort, default: nil)
        fastMode = container.value(.fastMode, default: false)
        dshMode = container.value(.dshMode, default: nil)
        // `value` swallows a type mismatch as well as a missing key, so a mode that
        // cannot be read falls back to the one that asks before it acts: a thread must
        // never quietly come back from disk with full access to the machine.
        runtimeMode = Self.supportedMode(container.value(.runtimeMode, default: .supervised), on: provider)
        interactionMode = container.value(.interactionMode, default: .build)
        worktreePath = container.value(.worktreePath, default: nil)
        branch = container.value(.branch, default: nil)
        controlWorkspace = try container.decodeIfPresent(ControlWorkspace.self, forKey: .controlWorkspace)
        if let workspace = controlWorkspace, workspace.mode == .worktree, workspace.phase == .ready,
           worktreePath?.isEmpty != false {
            // Enter backup-before-write recovery instead of falling back to a default directory.
            throw DecodingError.dataCorruptedError(forKey: .controlWorkspace, in: container, debugDescription: "Ready worktree has no checkout")
        }
        providerSessionID = container.value(.providerSessionID, default: nil)
        providerResumeAt = container.value(.providerResumeAt, default: nil)
        isPinned = container.value(.isPinned, default: false)
        isArchived = container.value(.isArchived, default: false)
        hasUnread = container.value(.hasUnread, default: false)
        unreadStatus = container.value(.unreadStatus, default: nil)
        unreadRevision = container.value(.unreadRevision, default: nil)
        lastAttentionTurnID = container.value(.lastAttentionTurnID, default: nil)
        pendingResultTurnID = container.value(.pendingResultTurnID, default: nil)
        hasCustomTitle = container.value(.hasCustomTitle, default: false)
        sortOrder = container.value(.sortOrder, default: nil)
        activityOrder = container.value(.activityOrder, default: nil)
        activityOrderDay = container.value(.activityOrderDay, default: nil)
        lastStatus = container.value(.lastStatus, default: nil)
        parentThreadID = container.value(.parentThreadID, default: nil)
        isInPanel = container.value(.isInPanel, default: false)
        isVoiceSession = container.value(.isVoiceSession, default: false)
        expandsHelpers = container.value(.expandsHelpers, default: false)
        // Threads saved while Hydra was app-wide only carry an ignored false and no
        // explicit flag: they come back on. A save that wrote the flag holds a real choice.
        let explicit = container.value(.hydraEnabledIsExplicit, default: false)
        hydraEnabled = explicit ? container.value(.hydraEnabled, default: true) : true
        hydraEnabledIsExplicit = true
        hydraPairID = container.value(.hydraPairID, default: nil)
        temporaryHydraPair = container.value(.temporaryHydraPair, default: nil)
        hydraSpawnCount = container.value(.hydraSpawnCount, default: 0)
        hydra = container.value(.hydra, default: nil)
        hydraJobs = container.value(.hydraJobs, default: [])
    }
}

struct Library: Codable, Sendable {
    var projects: [Project] = []
    var threads: [ChatThread] = []

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        projects = try container.decode([Project].self, forKey: .projects)
        threads = try container.decode([ChatThread].self, forKey: .threads)
    }
}
