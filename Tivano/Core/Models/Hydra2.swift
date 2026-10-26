import Foundation

// Hydra 2.0 (Labs): the shared vocabulary of the v2 decision layer. See docs/hydra2.md.
// Worktrees, landing, merge and the watchdog are v1's and unchanged; everything here is
// read only for a job stamped `.v2`, and a record without these fields reads as v1.

/// Which decision layer a job runs on. Stamped once when the user's request starts a
/// lead turn, so flipping the Labs switch mid-job never mixes the two.
enum HydraMode: String, Codable, Hashable, Sendable {
    case v1
    case v2
}

/// The three lines every v2 head ends its report with. Nil fields mean the head wrote
/// "none"; a report without the lines parses to nil and the raw reply stands alone.
struct HydraReportNotes: Codable, Hashable, Sendable {
    var deviations: String?
    var unfinished: String?
    var uncertain: String?

    /// Whether the head flagged anything the lead should look at first.
    var flagsSomething: Bool { deviations != nil || unfinished != nil || uncertain != nil }

    static let labels = ["Deviations", "Unfinished", "Uncertain"]

    /// Reads the `Deviations:` / `Unfinished:` / `Uncertain:` lines anywhere in a reply,
    /// case-insensitive, markdown bullets and bold allowed; a value runs until the next
    /// label or the end. Nil unless all three labels are present.
    static func parse(_ reply: String) -> HydraReportNotes? {
        var found: [String: [String]] = [:]
        var current: String?
        for raw in reply.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "-*• "))
                .replacingOccurrences(of: "**", with: "")
            if let label = labels.first(where: { line.lowercased().hasPrefix($0.lowercased() + ":") }) {
                current = label
                found[label] = [String(line.dropFirst(label.count + 1)).trimmed]
            } else if let label = current {
                if line.isEmpty { current = nil } else { found[label, default: []].append(line) }
            }
        }
        guard labels.allSatisfy({ found[$0] != nil }) else { return nil }
        func value(_ label: String) -> String? {
            let text = (found[label] ?? []).joined(separator: "\n").trimmed
            let lowered = text.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ". "))
            return text.isEmpty || ["none", "n/a", "无", "没有"].contains(lowered) ? nil : text
        }
        return HydraReportNotes(deviations: value("Deviations"), unfinished: value("Unfinished"), uncertain: value("Uncertain"))
    }
}

/// One head's part in a v2 job, for scoring. Written when the head is sent out and
/// updated as it reports; never rewritten by a later job.
struct HydraJobHeadRecord: Codable, Hashable, Sendable {
    var headID: UUID
    var name: String
    var provider: String?
    var model: String?
    var effort: String?
    var briefChars = 0
    /// The paths the lead's entry said this head owns.
    var files: [String] = []
    var status: HydraHeadInfo.Status = .running
    var seconds: Double?
    var landedFiles = 0
    var conflicts = 0
    var notes: HydraReportNotes?
    /// Whether the report carried the three lines.
    var followedReportFormat: Bool?
    /// How many times the lead sent this head back to rework its part.
    var continuations = 0
}

/// One v2 job: a user request in a lead chat and everything Hydra did for it. Appended
/// to `ChatThread.hydraJobs` when the request starts, closed when the job settles.
struct HydraJobRecord: Codable, Hashable, Identifiable, Sendable {
    enum MergeOutcome: String, Codable, Sendable {
        case merged
        case failed
        case nothing
    }

    var id = UUID()
    var mode: HydraMode = .v2
    /// The lead turn the user's request started.
    var turnID: UUID?
    var startedAt = Date.now
    var finishedAt: Date?
    /// The user's request, verbatim, as the heads' handoff packet carries it.
    var request = ""
    var leadProvider: String?
    var leadModel: String?
    var leadEffort: String?
    var pairID: UUID?
    var headsProvider: String?
    var headsModel: String?
    var headsEffort: String?
    var headsNote: String?
    /// The lead checkout's HEAD when the request started, and whether it had
    /// uncommitted work: the base a replay of this job starts from.
    var baseCommit: String?
    var baseDirty: Bool?
    var rounds = 0
    var heads: [HydraJobHeadRecord] = []
    /// File-editing tool calls the lead made after the first report came back.
    var leadEditsAfterReports = 0
    var leadBuilt = false
    /// The cross-vendor review: who ran it, how many findings, how many the lead took.
    /// `reviewSkipped` says why none ran when one should have.
    var reviewEngine: String?
    var reviewFindings: Int?
    var reviewAccepted: Int?
    var reviewSkipped: String?
    var merge: MergeOutcome?

    var isOpen: Bool { finishedAt == nil }
}

/// What Tivano attaches to every v2 head's brief, outside the lead's own words: the
/// user's request verbatim and who on the team owns what.
struct HydraHandoffPacket: Hashable, Sendable {
    struct Member: Hashable, Sendable {
        var name: String
        var task: String
        var files: [String]
    }

    /// The user's request as they wrote it, capped at `requestLimit` characters.
    var request: String
    /// Paths of the images and files the user attached to that request.
    var attachments: [String] = []
    /// Every head of the block, this one included.
    var team: [Member] = []

    static let requestLimit = 6_000
}
