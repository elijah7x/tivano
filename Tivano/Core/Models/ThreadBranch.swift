import Foundation

/// The turn boundary at which a branch splits from a conversation.
enum ThreadBranchPoint: Equatable, Sendable {
    case before(turnID: UUID)
    case through(turnID: UUID)
}

enum ThreadBranchFailure: Error, Equatable, Sendable {
    case notFound
    case busy
    case unavailablePoint
    case directoryUnavailable
}

struct ThreadBranchSlice: Equatable, Sendable {
    var document: ThreadDocument
    var lastTurn: TurnRecord? = nil
    var draft: String? = nil
    var draftAttachments: [Attachment] = []
}

enum ThreadBranch {
    static func slice(_ document: ThreadDocument, at point: ThreadBranchPoint) -> ThreadBranchSlice? {
        let targetTurnID: UUID
        let includeTarget: Bool
        switch point {
        case .before(let turnID):
            targetTurnID = turnID
            includeTarget = false
        case .through(let turnID):
            targetTurnID = turnID
            includeTarget = true
        }

        guard let targetIndex = document.turns.firstIndex(where: { $0.id == targetTurnID }) else {
            return nil
        }
        let splitIndex = includeTarget ? targetIndex + 1 : targetIndex
        let keptTurns = Array(document.turns[..<splitIndex])
        let droppedTurns = Array(document.turns[splitIndex...])

        // A turn still in flight is no place to split from, in either direction.
        guard document.turns[targetIndex].status != .running,
              !keptTurns.contains(where: { $0.status == .running }),
              !document.items.contains(where: { $0.turnID == targetTurnID && isStreaming($0) }) else {
            return nil
        }

        let keptTurnIDs = Set(keptTurns.map(\.id))
        let droppedTurnIDs = Set(droppedTurns.map(\.id))
        let firstDroppedItemIndex = document.items.firstIndex { item in
            guard let turnID = item.turnID else { return false }
            return droppedTurnIDs.contains(turnID)
        }

        var keptItems: [TimelineItem] = []
        keptItems.reserveCapacity(document.items.count)
        for (index, item) in document.items.enumerated() {
            if let turnID = item.turnID {
                guard keptTurnIDs.contains(turnID) else { continue }
            } else if let firstDroppedItemIndex, index >= firstDroppedItemIndex {
                continue
            }
            guard !isStreaming(item) else { return nil }
            keptItems.append(item)
        }

        let keptItemIDs = Set(keptItems.map(\.id))
        var sliced = document
        sliced.turns = keptTurns
        sliced.items = keptItems
        sliced.turnIndex = document.turnIndex?.filter { keptTurnIDs.contains($0.id) }
        sliced.itemPositions = document.itemPositions?.filter { keptItemIDs.contains($0.key) }
        sliced.usage = nil
        sliced.followUps = []
        sliced.hydraMerges = []
        sliced.continuation = nil
        sliced.forwardedContinuation = preservedForwardedContinuation(from: document)

        let draft: String?
        var draftAttachments: [Attachment] = []
        if includeTarget {
            draft = nil
        } else {
            let targetTurn = document.turns[targetIndex]
            if let itemID = targetTurn.userItemID,
               let item = document.items.first(where: { $0.id == itemID }),
               case .user(let message) = item.content {
                draft = message.text
                draftAttachments = message.attachments
            } else {
                draft = nil
            }
        }

        return ThreadBranchSlice(document: sliced, lastTurn: keptTurns.last, draft: draft, draftAttachments: draftAttachments)
    }

    private static func isStreaming(_ item: TimelineItem) -> Bool {
        switch item.content {
        case .assistant(let message): message.isStreaming
        case .reasoning(let block): block.isStreaming
        case .plan(let plan): plan.state == .drafting
        default: false
        }
    }

    private static func preservedForwardedContinuation(from document: ThreadDocument) -> ThreadContinuation? {
        if let forwarded = document.forwardedContinuation, forwarded.isProviderHandoff != true {
            return forwarded
        }
        if let continuation = document.continuation, continuation.isProviderHandoff != true {
            return continuation
        }
        return nil
    }
}
