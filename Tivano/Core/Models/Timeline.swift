import Foundation
import ImageIO

struct TimelineItem: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var turnID: UUID?
    var date: Date
    var content: Content

    init(id: String = UUID().uuidString, turnID: UUID?, date: Date = .now, content: Content) {
        self.id = id
        self.turnID = turnID
        self.date = date
        self.content = content
    }

    enum Content: Codable, Hashable, Sendable {
        case user(UserMessage)
        case assistant(AssistantMessage)
        case reasoning(ReasoningBlock)
        case tool(ToolCall)
        case plan(ProposedPlan)
        case todos([TodoStep])
        case notice(Notice)
        case turnEnd(TurnSummary)
    }

    /// A thinking block with nothing to read, as a redacted stream leaves behind.
    var isEmptyReasoning: Bool {
        guard case .reasoning(let block) = content else { return false }
        return block.text.trimmed.isEmpty
    }
}

extension TimelineItem {
    /// Model-written prose with its long dashes flattened, for threads stored by a
    /// build that cleaned text only as it arrived. The user's own words, tool output
    /// and notices are not the model's writing and are left exactly as they were.
    var cleanedOfEmDashes: TimelineItem {
        var item = self
        switch item.content {
        case .assistant(var message):
            message.text = TextCleanup.withoutEmDashes(message.text)
            item.content = .assistant(message)
        case .reasoning(var block):
            block.text = TextCleanup.withoutEmDashes(block.text)
            item.content = .reasoning(block)
        case .plan(var plan):
            plan.markdown = TextCleanup.withoutEmDashes(plan.markdown)
            item.content = .plan(plan)
        default:
            break
        }
        return item
    }
}

struct UserMessage: Codable, Hashable, Sendable {
    var text: String
    var attachments: [Attachment] = []
    /// Set when the message is Hydra's rather than the user's own words: the roster
    /// places of the heads reporting back, or empty for a note from Hydra itself.
    var hydraHeads: [Int]?
    /// Set when the message is the lead's brief to a head, shown as a pill rather
    /// than a plain bubble. Optional, so threads stored before it still decode.
    var hydraBrief: Bool?

    var isFromHydra: Bool { hydraHeads != nil }
    var isHydraBrief: Bool { hydraBrief == true }
}

/// One queued follow-up prompt. Sent as a direct user chat message once the
/// running turn finishes, so the user can steer the chat while it works and
/// stack several follow-ups that run one after another.
struct FollowUpPrompt: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var text: String
    var attachments: [Attachment] = []
    var createdAt = Date.now
    /// Prompts sharing a bundle sit together, show one number and go out as one
    /// message (see `ThreadRuntime.bundleFollowUp`).
    var bundleID: UUID? = nil

    var isEmpty: Bool {
        attachments.isEmpty && !text.contains { !$0.isWhitespace }
    }
}

struct Attachment: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    var path: String
    var mimeType: String

    var url: URL { URL(fileURLWithPath: path) }
    var isImage: Bool { mimeType.hasPrefix("image/") }

    /// The images among the attachments with their bytes as base64, read and encoded off
    /// the main actor: a photo is megabytes, and its string a third larger again. A photo
    /// past `maxPixelSize` on its longest side is downscaled to a JPEG here, once, so
    /// every provider and every token count gets the smaller copy.
    @concurrent
    static func base64Images(_ attachments: [Attachment]) async -> [(image: Attachment, base64: String)] {
        attachments.compactMap { attachment in
            guard attachment.isImage, let data = try? Data(contentsOf: attachment.url) else { return nil }
            let downscaled = downscaledJPEG(data)
            var sent = attachment
            if downscaled != nil { sent.mimeType = "image/jpeg" }
            return (sent, (downscaled ?? data).base64EncodedString())
        }
    }

    /// The longest side a photo may keep on its way to a provider.
    private static let maxPixelSize = 2000

    /// A JPEG of the image at no more than `maxPixelSize` on its longest side, or nil for
    /// an image already that small or one ImageIO cannot read, which keeps its own bytes.
    /// The thumbnail is generated with its transform applied, so an orientation flag does
    /// not reach the provider as a sideways photo.
    private static func downscaledJPEG(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              max(width, height) > maxPixelSize else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              let output = CFDataCreateMutable(nil, 0),
              let destination = CGImageDestinationCreateWithData(output, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, thumbnail, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}

struct AssistantMessage: Codable, Hashable, Sendable {
    var text: String
    var isStreaming = false
}

struct ReasoningBlock: Codable, Hashable, Sendable {
    var text: String
    var isStreaming = false
}

struct ToolCall: Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable {
        case command
        case read
        case edit
        case search
        case web
        case mcp
        case agent
        case other
    }

    enum Status: String, Codable, Sendable {
        case running
        case completed
        case failed
        case declined
    }

    static let outputLimit = 60_000

    var kind: Kind
    var title: String
    var detail: String?
    var output = ""
    var status: Status = .running
    var exitCode: Int?
    var edits: [FileEdit] = []
    var startedAt = Date.now
    var finishedAt: Date?

    mutating func appendOutput(_ text: String) {
        output += text
        trimOutput()
    }

    mutating func setOutput(_ text: String) {
        output = text
        trimOutput()
    }

    mutating func finish(_ status: Status) {
        self.status = status
        if finishedAt == nil { finishedAt = .now }
    }

    private mutating func trimOutput() {
        guard output.utf8.count > Self.outputLimit else { return }
        output = "…" + String(output.suffix(Self.outputLimit / 2))
    }
}

struct FileEdit: Codable, Hashable, Sendable {
    var path: String
    var diff: String?
    var additions = 0
    var deletions = 0
}

struct ProposedPlan: Codable, Hashable, Sendable {
    enum State: String, Codable, Sendable {
        case drafting
        case proposed
        case accepted
        case dismissed
    }

    var markdown: String
    var state: State
}

struct TodoStep: Codable, Hashable, Sendable {
    enum Status: String, Codable, Sendable {
        case pending
        case active
        case done
    }

    var text: String
    var status: Status
}

struct Notice: Codable, Hashable, Sendable {
    enum Level: String, Codable, Sendable {
        case info
        case warning
        case error
    }

    var level: Level
    var message: String
    /// Set on the usage-limit notice alone: the chat whose auto-continue it belongs to.
    /// Its row draws the badge with the two controls while that chat waits (see `AutoContinue`).
    var limit: LimitNotice? = nil
}

/// The chat a usage-limit notice belongs to. `AutoContinue` marks its notice with this,
/// and the notice's row reads that chat's wait and outcome from it.
struct LimitNotice: Codable, Hashable, Sendable {
    var threadID: UUID
}

enum TurnStatus: String, Codable, Sendable {
    case running
    case completed
    case interrupted
    case failed
}

struct TurnSummary: Codable, Hashable, Sendable {
    var turnID: UUID
    var status: TurnStatus
    var duration: TimeInterval
    var filesChanged: Int
    var additions: Int
    var deletions: Int
    var changes: FileChangeSummary?
}

/// One outcome of the Hydra auto-merge for this thread, kept so the lead can be told the true merge state at the front of its next message.
struct HydraMergeRecord: Codable, Hashable, Sendable {
    /// `held` is no longer written: a merge never waits on another chat's files now. It
    /// stays so records written by earlier versions still decode.
    enum Outcome: String, Codable, Sendable { case merged, failed, stray, held, settled }
    var at: Date
    var outcome: Outcome
    var project: String?
    var label: String?
    var url: URL?
    var files: Int
    var detail: String?
    /// A failure that clears by itself and is retried quietly (the forge still checking,
    /// a remote that moved); nil on the ones that need the user.
    var retryable: Bool? = nil
}

struct TurnRecord: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var index: Int
    var providerTurnID: String?
    var startedAt = Date.now
    var completedAt: Date?
    var status: TurnStatus = .running
    var baseCheckpoint: String?
    var endCheckpoint: String?
    var userItemID: String?
    /// The provider's own diff, used when the workspace is not a git repository.
    var providerDiff: String?
    /// The provider's last message id in this turn, used to rewind a conversation.
    var providerAnchor: String?
    /// Repository-relative paths this turn's agent edited, so changes made elsewhere in the
    /// repository during the turn are never attributed to the thread. Nil on turns recorded before.
    var touchedPaths: [String]?
    /// What the providers' ledgers counted on this turn, one report per provider, model and
    /// head, so a run's spend is attributable after the app has moved on. Nil on turns
    /// recorded before, and on those no ledger reported for.
    var tokenSpends: [TokenSpend]?
    /// This turn's work has landed on the branch: the auto-merge took it, and the next one
    /// starts from what came after it.
    var hydraMerged = false
}

extension TurnRecord {
    /// Read field by field, so a turn stored by an earlier build, which knew nothing of
    /// the newest of them, still reads as the turn it was rather than being dropped.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = container.value(.id, default: UUID())
        index = container.value(.index, default: 0)
        providerTurnID = container.value(.providerTurnID, default: nil)
        startedAt = container.value(.startedAt, default: Date.now)
        completedAt = container.value(.completedAt, default: nil)
        status = container.value(.status, default: .running)
        baseCheckpoint = container.value(.baseCheckpoint, default: nil)
        endCheckpoint = container.value(.endCheckpoint, default: nil)
        userItemID = container.value(.userItemID, default: nil)
        providerDiff = container.value(.providerDiff, default: nil)
        providerAnchor = container.value(.providerAnchor, default: nil)
        touchedPaths = container.value(.touchedPaths, default: nil)
        tokenSpends = container.value(.tokenSpends, default: nil)
        hydraMerged = container.value(.hydraMerged, default: false)
    }
}

struct ContextUsage: Codable, Hashable, Sendable {
    var usedTokens: Int
    var windowTokens: Int?

    var fraction: Double? {
        guard let windowTokens, windowTokens > 0 else { return nil }
        return Double(usedTokens) / Double(windowTokens)
    }
}

struct ThreadTurnReference: Codable, Equatable, Sendable {
    var id: UUID
    var revision: UInt64
}

struct ThreadDocument: Codable, Equatable, Sendable {
    var threadID: UUID
    /// Nil identifies the legacy, self-contained document format.
    var turnIndex: [ThreadTurnReference]? = nil
    var itemPositions: [String: Double]? = nil
    var items: [TimelineItem] = []
    var turns: [TurnRecord] = []
    var usage: ContextUsage?
    var followUps: [FollowUpPrompt] = []
    var hydraMerges: [HydraMergeRecord] = []
    /// The forwarded chat this thread continues, when the user opened it with one. Nil for
    /// a thread that started here. Optional, so threads stored before it still decode.
    var continuation: ThreadContinuation? = nil

    init(threadID: UUID) {
        self.threadID = threadID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        threadID = try container.decode(UUID.self, forKey: .threadID)
        turnIndex = try container.decodeIfPresent([ThreadTurnReference].self, forKey: .turnIndex)
        itemPositions = try container.decodeIfPresent([String: Double].self, forKey: .itemPositions)
        items = container.value(.items, default: [Lenient<TimelineItem>]()).compactMap(\.value)
        turns = container.value(.turns, default: [Lenient<TurnRecord>]()).compactMap(\.value)
        usage = container.value(.usage, default: nil)
        followUps = container.value(.followUps, default: [Lenient<FollowUpPrompt>]()).compactMap(\.value)
        hydraMerges = container.value(.hydraMerges, default: [Lenient<HydraMergeRecord>]()).compactMap(\.value)
        continuation = container.value(.continuation, default: nil)
    }
}
