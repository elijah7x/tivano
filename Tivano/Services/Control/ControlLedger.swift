import Foundation
import CryptoKit

/// Actor confinement is supplied by the App controller. This value type is also used by
/// isolated tests. It retains no input text, only its canonical SHA-256 and a receipt.
struct ControlLedger {
    struct Receipt {
        var fingerprint: String
        var outcome: ControlOutcome
    }
    let instance: UUID
    private(set) var receipts: [UUID: Receipt] = [:]

    var hasPending: Bool { receipts.values.contains { !$0.outcome.terminal } }

    /// Returns the existing outcome for a duplicate. Capacity never evicts a receipt
    /// inside its advertised window. A first delivery more than 30 seconds after ticket
    /// issuance is unknown, not permission to execute a possibly-evicted operation.
    mutating func accept(_ command: ControlCommand, now: Date = .now) throws -> (outcome: ControlOutcome, isNew: Bool) {
        guard let ticket = command.ticket else { throw ControlFailure(code: .invalidRequest) }
        guard ticket.instance == instance else { throw ControlFailure(code: .instanceMismatch) }
        let fingerprint = try Self.digest(command)
        if let receipt = receipts[ticket.id] {
            if receipt.outcome.terminal, (receipt.outcome.expiresAt ?? .distantPast) <= now {
                return (ControlOutcome(ticket: ticket, state: .unknown), false)
            }
            guard receipt.fingerprint == fingerprint else { throw ControlFailure(code: .conflict) }
            return (receipt.outcome, false)
        }
        guard abs(now.timeIntervalSince(ticket.issuedAt)) <= 30 else {
            return (ControlOutcome(ticket: ticket, state: .unknown), false)
        }
        receipts = receipts.filter { !$0.value.outcome.terminal || ($0.value.outcome.expiresAt ?? .distantFuture) > now }
        guard receipts.count < LocalControl.maxOperations,
              receipts.values.filter({ !$0.outcome.terminal }).count < LocalControl.maxPendingOperations else {
            throw ControlFailure(code: .busy)
        }
        let outcome = ControlOutcome(ticket: ticket, state: .accepted, updatedAt: now,
                                     expiresAt: ticket.issuedAt.addingTimeInterval(LocalControl.retention))
        receipts[ticket.id] = Receipt(fingerprint: fingerprint, outcome: outcome)
        return (outcome, true)
    }

    func outcome(_ ticket: ControlTicket, now: Date = .now) -> ControlOutcome {
        guard ticket.instance == instance, let receipt = receipts[ticket.id], receipt.outcome.ticket == ticket,
              !receipt.outcome.terminal || (receipt.outcome.expiresAt ?? .distantPast) > now else {
            return ControlOutcome(ticket: ticket, state: .unknown)
        }
        return receipt.outcome
    }

    mutating func update(_ ticket: ControlTicket, _ change: (inout ControlOutcome) -> Void) {
        guard var receipt = receipts[ticket.id], receipt.outcome.ticket == ticket else { return }
        change(&receipt.outcome)
        receipt.outcome.updatedAt = .now
        receipts[ticket.id] = receipt
    }

    static func digest<T: Encodable>(_ value: T) throws -> String {
        SHA256.hash(data: try LocalControl.encoder().encode(value)).map { String(format: "%02x", $0) }.joined()
    }
}

/// Stateless metadata pagination. Every cursor binds the filter, instance and exact
/// metadata revision. Any mutation invalidates it instead of silently skipping rows.
enum ControlPagination {
    private struct Cursor: Codable { var snapshot: String; var offset: Int }

    static func page<T: Codable & Sendable>(_ items: [T], request: ControlPage, scope: String) throws -> ControlListPage<T> {
        guard (1...100).contains(request.limit) else { throw ControlFailure(code: .bounds) }
        let snapshot = try ControlLedger.digest(Snapshot(scope: scope, items: items))
        return try boundedPage(count: items.count, request: request, snapshot: snapshot) { Array(items[$0]) }
    }

    /// App metadata uses index revisions and projects only the requested window. It
    /// must not serialize every thread's DTO merely to return a small page.
    static func boundedPage<T: Codable & Sendable>(count: Int, request: ControlPage, snapshot: String,
                                                  load: (Range<Int>) -> [T]) throws -> ControlListPage<T> {
        guard (1...100).contains(request.limit) else { throw ControlFailure(code: .bounds) }
        var offset = 0
        if let token = request.cursor {
            guard token.utf8.count <= 1_024, let data = Data(base64Encoded: token),
                  let cursor = try? LocalControl.decoder().decode(Cursor.self, from: data),
                  cursor.snapshot == snapshot, cursor.offset >= 0, cursor.offset <= count else { throw ControlFailure(code: .cursorInvalid) }
            offset = cursor.offset
        }
        let end = min(count, offset + request.limit)
        let next = end < count ? try LocalControl.encoder().encode(Cursor(snapshot: snapshot, offset: end)).base64EncodedString() : nil
        let projected = load(offset..<end)
        guard projected.count == end - offset else { throw ControlFailure(code: .internalError) }
        return ControlListPage(items: projected, nextCursor: next, snapshot: snapshot)
    }

    private struct Snapshot<T: Codable & Sendable>: Codable { var scope: String; var items: [T] }
}
