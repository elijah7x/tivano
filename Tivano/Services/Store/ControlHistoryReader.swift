import Foundation
import CryptoKit
import Darwin

/// Strict, read-only projection of the Store format. It intentionally does not use
/// runtime loading, lenient recovery, prefetch, directory getters, or provider types.
/// The head and at most four turn files (8 MiB each) are read per page. Legacy documents
/// over the bound fail explicitly; querying never migrates or repairs them.
struct ControlHistoryReader {
    let threadsDirectory: URL
    static let fileLimit = 8 * 1_024 * 1_024

    private struct Reference: Decodable { var id: UUID; var revision: UInt64 }
    private struct Turn: Decodable { var id: UUID; var index: Int; var status: String }
    private struct Text: Decodable { var text: String }
    private struct Tool: Decodable { var title: String; var output: String }
    private struct Plan: Decodable { var markdown: String }
    private struct Notice: Decodable { var message: String }
    private struct End: Decodable { var status: String }
    private enum Content: Decodable {
        case user(Text), assistant(Text), reasoning(Text), tool(Tool), plan(Plan)
        case todos([Text]), notice(Notice), turnEnd(End)
        var projection: (kind: String, text: String) {
            switch self {
            case .user(let value): ("user", value.text)
            case .assistant(let value): ("assistant", value.text)
            case .reasoning(let value): ("reasoning", value.text)
            case .tool(let value): ("tool", value.title + "\n" + value.output)
            case .plan(let value): ("plan", value.markdown)
            case .todos(let value): ("todos", value.map(\.text).joined(separator: "\n"))
            case .notice(let value): ("notice", value.message)
            case .turnEnd(let value): ("turnEnd", value.status)
            }
        }
    }
    private struct Item: Decodable {
        var id: String
        var turnID: UUID?
        var date: Date
        var content: Content
    }
    private struct Head: Decodable {
        var threadID: UUID
        var turnIndex: [Reference]?
        var itemPositions: [String: Double]?
        var items: [Item]
        var turns: [Turn]
    }
    private struct Stored: Decodable { var turn: Turn; var items: [Item]; var itemPositions: [String: Double] }
    private struct File: Decodable { var revisions: [String: Stored] }
    private struct Cursor: Codable { var snapshot: String; var group: Int; var item: Int }
    private struct Group { var id: UUID?; var reference: Reference? }

    func page(threadID: UUID, request: ControlPage, scope: String, allowsMissing: Bool = true) throws -> ControlHistoryPage {
        guard (1...50).contains(request.limit) else { throw ControlFailure(code: .bounds) }
        let headURL = threadsDirectory.appendingPathComponent("\(threadID.uuidString).json")
        let headData: Data
        do { headData = try Self.readBounded(headURL) }
        catch let error as ControlFailure where error.code == .notFound {
            guard allowsMissing else { throw ControlFailure(code: .corruptHistory) }
            guard request.cursor == nil else { throw ControlFailure(code: .cursorInvalid) }
            return ControlHistoryPage(threadID: threadID, entries: [], nextCursor: nil, snapshot: Self.hash(Data((scope + threadID.uuidString).utf8)))
        }
        let snapshot = Self.hash(headData + Data((scope + threadID.uuidString).utf8))
        let head: Head
        do { head = try LocalControl.decoder().decode(Head.self, from: headData) }
        catch { throw ControlFailure(code: .corruptHistory) }
        guard head.threadID == threadID, (head.turnIndex?.count ?? 0) <= 100_000 else { throw ControlFailure(code: .corruptHistory) }
        let references = head.turnIndex ?? []
        let indexedIDs = Set(references.map(\.id))
        guard indexedIDs.count == references.count, Set(head.turns.map(\.id)).count == head.turns.count,
              indexedIDs.isDisjoint(with: head.turns.map(\.id)) else { throw ControlFailure(code: .corruptHistory) }
        var groups = references.map { Group(id: $0.id, reference: $0) }
        groups += head.turns.sorted { $0.index == $1.index ? $0.id.uuidString < $1.id.uuidString : $0.index < $1.index }
            .map { Group(id: $0.id, reference: nil) }
        groups.append(Group(id: nil, reference: nil))
        let knownIDs = indexedIDs.union(head.turns.map(\.id))
        guard head.items.allSatisfy({ $0.turnID == nil || knownIDs.contains($0.turnID!) }) else { throw ControlFailure(code: .corruptHistory) }
        var cursor = Cursor(snapshot: snapshot, group: 0, item: 0)
        if let token = request.cursor {
            guard token.utf8.count <= 1_024, let data = Data(base64Encoded: token),
                  let decoded = try? LocalControl.decoder().decode(Cursor.self, from: data), decoded.snapshot == snapshot,
                  decoded.group >= 0, decoded.group < groups.count, decoded.item >= 0 else { throw ControlFailure(code: .cursorInvalid) }
            cursor = decoded
        }
        var entries: [ControlHistoryEntry] = []
        var visited = 0
        while cursor.group < groups.count, entries.count < request.limit, visited < 4 {
            visited += 1
            let group = groups[cursor.group]
            let items: [Item]
            let positions: [String: Double]
            let status: String?
            if let reference = group.reference {
                let url = threadsDirectory.appendingPathComponent("\(threadID.uuidString).turns", isDirectory: true)
                    .appendingPathComponent("\(reference.id.uuidString).json")
                let stored: Stored
                do {
                    let file = try LocalControl.decoder().decode(File.self, from: Self.readBounded(url))
                    guard let revision = file.revisions[String(reference.revision)], revision.turn.id == reference.id else { throw ControlFailure(code: .corruptHistory) }
                    stored = revision
                } catch let error as ControlFailure { throw error.code == .notFound ? ControlFailure(code: .corruptHistory) : error }
                catch { throw ControlFailure(code: .corruptHistory) }
                guard stored.items.allSatisfy({ $0.turnID == reference.id }) else { throw ControlFailure(code: .corruptHistory) }
                items = stored.items
                positions = stored.itemPositions
                status = stored.turn.status
            } else {
                items = head.items.filter { $0.turnID == group.id }
                positions = head.itemPositions ?? [:]
                status = head.turns.first { $0.id == group.id }?.status
            }
            guard Set(items.map(\.id)).count == items.count, cursor.item <= items.count,
                  positions.values.allSatisfy(\.isFinite) else { throw ControlFailure(code: .corruptHistory) }
            let ordered = items.sorted { left, right in
                let lhs = positions[left.id] ?? 0, rhs = positions[right.id] ?? 0
                if lhs != rhs { return lhs < rhs }
                if left.date != right.date { return left.date < right.date }
                return left.id < right.id
            }
            while cursor.item < ordered.count, entries.count < request.limit {
                let item = ordered[cursor.item]
                let projection = item.content.projection
                let bytes = projection.text.utf8
                entries.append(ControlHistoryEntry(id: item.id, turnID: item.turnID, turnStatus: status, date: item.date,
                                                   kind: projection.kind, text: String(decoding: bytes.prefix(4_000), as: UTF8.self), truncated: bytes.count > 4_000))
                cursor.item += 1
            }
            if cursor.item == ordered.count { cursor.group += 1; cursor.item = 0 }
        }
        let next = cursor.group < groups.count ? try LocalControl.encoder().encode(cursor).base64EncodedString() : nil
        return ControlHistoryPage(threadID: threadID, entries: entries, nextCursor: next, snapshot: snapshot)
    }

    private static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// O_NOFOLLOW plus a descriptor-size bound, not a racy size check followed by an
    /// unbounded Data(contentsOf:). No file or directory is created on any read path.
    static func readBounded(_ url: URL) throws -> Data {
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw ControlFailure(code: errno == ENOENT ? .notFound : .corruptHistory) }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw ControlFailure(code: .corruptHistory) }
        guard info.st_size >= 0, info.st_size <= fileLimit else { throw ControlFailure(code: .bounds) }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw ControlFailure(code: .corruptHistory) }
            if count == 0 { return data }
            guard data.count + count <= fileLimit else { throw ControlFailure(code: .bounds) }
            data.append(contentsOf: buffer.prefix(count))
        }
    }
}
