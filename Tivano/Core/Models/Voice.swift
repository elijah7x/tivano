import Foundation

// Voice agent mode: the call's states, its live caption and the words it shows.
// Ported from Zeron (https://github.com/zeronsh/zeron, MIT): `crates/proto/src/voice.rs`,
// `crates/voice-session/src/view.rs` and `crates/ui/src/voice.rs`. See THIRD_PARTY_NOTICES.md.

/// Where a voice call is in its life.
enum VoicePhase: String, Sendable {
    case closed
    case checking
    case starting
    case active
    case stopping
    case failed

    /// A call underway: from its preparation to its native stop.
    var isLive: Bool { self == .checking || self == .starting || self == .active || self == .stopping }
}

/// What the orchestrator's chat is doing while the call runs.
enum VoiceWork: Sendable {
    case idle
    case working
    /// The chat waits on the user: an approval or a question.
    case awaitingInput
}

enum VoiceRole: Sendable {
    case user
    case assistant
}

/// Why a call could not start or ended.
enum VoiceRejection: Error, Sendable, Equatable {
    case unsupported
    case wrongProvider
    case chatgptRequired
    case busy
    case invalidLease
    case overflow
    case deviceUnavailable
    case microphonePermissionDenied
    case microphoneMetadataMissing
    case `protocol`
    case nativeRuntimeUnavailable
    case noProject

    /// The line the sidebar trigger explains a failed start with.
    var text: String {
        switch self {
        case .unsupported: "Voice requires Codex 0.159 or later with realtime voice support. Update Codex and try again."
        case .wrongProvider: "Install and enable Codex in Providers to use voice."
        case .chatgptRequired: "Sign in to Codex with ChatGPT to use voice."
        case .nativeRuntimeUnavailable:
            "Install or update Codex on this device to use voice. Its voice runtime ships with Codex 0.159 or later."
        case .deviceUnavailable: "Check microphone permission and your audio devices."
        case .microphonePermissionDenied:
            "Allow Tivano to use the microphone in System Settings → Privacy & Security → Microphone."
        case .microphoneMetadataMissing: "Microphone setup is missing. Rebuild or reinstall Tivano, then restart it."
        case .protocol: "Voice could not connect or was disconnected. Check your network and Codex, then try again."
        case .busy: "Another window already owns the voice session."
        case .noProject: "Add a project first: the voice session works in it."
        default: "Voice could not connect. Try again in a moment."
        }
    }
}

/// The small context shared by the realtime and work orchestrators.
struct VoiceOrchestratorContext: Sendable, Equatable {
    var hydra: Bool
    var projectName: String
    var hydraPolicy: String? = nil
}

/// The voice styles offered before a session reports its own list.
enum VoiceCatalog {
    static let defaultVoices = ["juniper", "maple", "spruce", "ember", "vale", "breeze", "arbor", "sol", "cove"]
    /// Title of every orchestrator chat; transcripts never name it.
    static let orchestratorTitle = "Voice session"
    /// A transcript segment longer than this is cut to its tail.
    static let maxTranscriptBytes = 32_768

    /// Given to both the realtime voice model and the Codex model that runs its work. With
    /// Hydra on, larger work goes to Tivano's heads through the hydra delegation block,
    /// never to the provider's own sub-agents.
    static func orchestratorInstructions(context: VoiceOrchestratorContext) -> String {
        let delegation = context.hydra
            ? "Hand larger or parallel pieces to Tivano's Hydra heads with the hydra delegation block, exactly as your Hydra policy describes; that block is the only way to delegate."
            : "Do the work yourself in this chat."
        let brief = "This is a Tivano voice session and you are the user's orchestrator. The project name is \(JSONValue.string(context.projectName).compactString). Do the work the user asks for in this project: read the code, run commands, and make changes. \(delegation) Never use Codex's own sub-agent tools (spawn_agent or any other native agent tool). Report back what you did and what you found. Keep spoken replies short and conversational."
        return [brief, context.hydra ? context.hydraPolicy : nil].compactMap { $0 }.joined(separator: "\n\n")
    }

    /// `juniper` reads as `Juniper` in a picker.
    static func label(_ voice: String) -> String {
        voice.prefix(1).uppercased() + voice.dropFirst()
    }

    /// Call-timer text: `m:ss`, or `h:mm:ss` past the hour.
    static func formatElapsed(_ seconds: Int) -> String {
        let hours = seconds / 3600
        let minutes = seconds / 60 % 60
        let rest = seconds % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, rest)
            : String(format: "%d:%02d", minutes, rest)
    }
}

/// The live caption across speaker turns. Codex interleaves them: a user turn's final
/// often lands after the assistant has started answering. Each turn keeps its own text
/// and the caption stays on the newest one, so a late final never takes the caption
/// back and deltas never restart it.
struct VoiceCaption: Sendable {
    private struct Turn: Sendable {
        var item: String?
        var text: String
        /// Known once the turn's final arrives.
        var role: VoiceRole?
    }

    /// Speaker turns the caption remembers; older ones can no longer complete.
    private static let turnsKept = 8
    /// Oldest first; the last turn is the one shown.
    private var turns: [Turn] = []

    var text: String { turns.last?.text ?? "" }
    /// The shown turn's item: a change is a new speaker turn.
    var item: String? { turns.last?.item }
    var role: VoiceRole? { turns.last?.role }

    mutating func clear() { turns.removeAll() }

    private func position(_ item: String) -> Int? {
        turns.lastIndex { $0.item == item }
    }

    private mutating func push(_ turn: Turn) {
        turns.append(turn)
        let excess = turns.count - Self.turnsKept
        if excess > 0 { turns.removeFirst(excess) }
    }

    /// Appends a streamed delta to its turn; a new item starts a new turn. A delta
    /// without an item continues the shown turn while it streams. Returns false when the
    /// turn outgrew the transcript limit: it then restarts from this delta.
    @discardableResult
    mutating func partial(item: String?, delta: String) -> Bool {
        var index: Int?
        if let item {
            index = position(item)
        } else if let last = turns.indices.last, turns[last].role == nil {
            index = last
        }
        if index == nil {
            push(Turn(item: item, text: "", role: nil))
            index = turns.count - 1
        }
        guard let index else { return true }
        // The final already settled this turn.
        if turns[index].role != nil { return true }
        let fits = turns[index].text.utf8.count + delta.utf8.count <= VoiceCatalog.maxTranscriptBytes
        if !fits { turns[index].text = "" }
        turns[index].text += delta
        return fits
    }

    /// A turn's final text and speaker. An unseen turn that completes while another one
    /// streams is older than it, so it never takes the caption.
    mutating func complete(item: String, role: VoiceRole, text: String) {
        var found = position(item)
        if found == nil, let last = turns.indices.last, turns[last].item == nil, turns[last].role == nil {
            // Deltas without an item belong to the turn this final completes.
            found = last
        }
        if let index = found {
            turns[index].item = item
            turns[index].text = text
            turns[index].role = role
            return
        }
        let turn = Turn(item: item, text: text, role: role)
        if let last = turns.last, last.role == nil {
            turns.insert(turn, at: turns.count - 1)
            let excess = turns.count - Self.turnsKept
            if excess > 0 { turns.removeFirst(excess) }
        } else {
            push(turn)
        }
    }
}

/// Visual speaker activity from playout peaks: hysteresis and a short hold bridge
/// syllable gaps, so the orb does not flicker between words.
struct SpeakerActivity: Sendable {
    private var playing = false
    private var lastLoud: Date?

    mutating func update(peak: UInt16, now: Date = .now) -> Bool {
        let enter: UInt16 = 655
        let exit: UInt16 = 328
        if peak >= (playing ? exit : enter) {
            playing = true
            lastLoud = now
        } else if lastLoud.map({ now.timeIntervalSince($0) >= 0.25 }) ?? true {
            playing = false
        }
        return playing
    }
}
