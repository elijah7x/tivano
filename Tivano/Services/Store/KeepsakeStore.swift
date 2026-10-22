import Foundation
import Synchronization

/// Serializes recovery and writes so an older UI snapshot cannot erase a grant.
enum KeepsakeStore {
    struct Snapshot: Codable, Equatable, Sendable {
        var keepsakes: [Keepsake] = []
        var seen = false
    }

    private enum Copy {
        case missing, valid(Snapshot), corrupt(Data), unavailable
        var snapshot: Snapshot? { if case .valid(let value) = self { return value }; return nil }
        var isMissing: Bool { if case .missing = self { return true }; return false }
        var isUnavailable: Bool { if case .unavailable = self { return true }; return false }
    }
    private struct Copies {
        var file: Copy
        var keychain: Copy
        var known: Snapshot { merge(file.snapshot ?? Snapshot(), keychain.snapshot ?? Snapshot()) }
        var resolved: Snapshot? {
            guard !file.isUnavailable, !keychain.isUnavailable,
                  file.snapshot != nil || keychain.snapshot != nil || (file.isMissing && keychain.isMissing) else { return nil }
            return known
        }
    }
    private static let queue = DispatchQueue(label: "Tivano.KeepsakeStore", qos: .utility)
    // Accesses are serialized by queue; Mutex also expresses safety to Swift concurrency.
    // A failed save is retried/merged on the next load or save, never replaced with now.
    private static let deferred = Mutex<Snapshot?>(nil)
    private static var fileURL: URL { Storage.root.appendingPathComponent("keepsakes.json") }

    static func load(granting ids: [String] = []) -> Snapshot {
        if CaptureRun.isEnabled {
            var snapshot = Snapshot()
            grant(ids, to: &snapshot)
            return snapshot
        }
        return queue.sync {
            let copies = readCopies()
            let pending = deferred.withLock { $0 } ?? Snapshot()
            guard let recovered = copies.resolved else {
                NSLog("Keepsakes recovery deferred; an existing copy may still be recoverable")
                return merge(copies.known, pending)
            }
            var snapshot = merge(recovered, pending)
            grant(ids, to: &snapshot)
            let saved = write(snapshot, comparedTo: copies)
            deferred.withLock { $0 = saved ? nil : snapshot }
            return snapshot
        }
    }

    static func grant(_ ids: [String], to snapshot: inout Snapshot) {
        for id in ids where !snapshot.keepsakes.contains(where: { $0.id == id }) {
            snapshot.keepsakes.append(Keepsake(id: id, earnedAt: Date(), litAt: nil))
        }
        snapshot.keepsakes.sort { $0.earnedAt == $1.earnedAt ? $0.id < $1.id : $0.earnedAt < $1.earnedAt }
    }

    static func save(_ snapshot: Snapshot) {
        guard !CaptureRun.isEnabled else { return }
        queue.async {
            let copies = readCopies()
            let pending = merge(deferred.withLock { $0 } ?? Snapshot(), snapshot)
            guard let recovered = copies.resolved else {
                deferred.withLock { $0 = pending }
                NSLog("Keepsakes save deferred; source read failed")
                return
            }
            let merged = merge(recovered, pending)
            let saved = write(merged, comparedTo: copies)
            deferred.withLock { $0 = saved ? nil : merged }
        }
    }

    private static func merge(_ first: Snapshot, _ second: Snapshot) -> Snapshot {
        var byID: [String: Keepsake] = [:]
        for keepsake in first.keepsakes + second.keepsakes {
            if var existing = byID[keepsake.id] {
                existing.earnedAt = min(existing.earnedAt, keepsake.earnedAt)
                existing.litAt = [existing.litAt, keepsake.litAt].compactMap { $0 }.min()
                byID[keepsake.id] = existing
            } else {
                byID[keepsake.id] = keepsake
            }
        }
        return Snapshot(
            keepsakes: byID.values.sorted { $0.earnedAt == $1.earnedAt ? $0.id < $1.id : $0.earnedAt < $1.earnedAt },
            seen: first.seen || second.seen
        )
    }

    private static func decode(_ data: Data) -> Copy {
        if let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) { return .valid(snapshot) }
        return .corrupt(data)
    }

    private static func readCopies() -> Copies {
        let file: Copy
        do { file = decode(try Data(contentsOf: fileURL)) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { file = .missing }
        catch { file = .unavailable }
        let keychain: Copy
        switch APIKeychain.readResult("Keepsakes") {
        case .missing: keychain = .missing
        case .value(let value): keychain = decode(Data(value.utf8))
        case .invalid(let data): keychain = .corrupt(data)
        case .unavailable(let status):
            NSLog("Keepsakes Keychain read unavailable (%d)", status)
            keychain = .unavailable
        }
        return Copies(file: file, keychain: keychain)
    }

    /// Publish a non-overwriting recovery original before repairing either source.
    private static func preserve(_ copy: Copy, source: String) throws {
        guard case .corrupt(let data) = copy else { return }
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let id = UUID().uuidString
        let temporary = directory.appendingPathComponent(".keepsakes-\(id).tmp")
        let backup = directory.appendingPathComponent("keepsakes-recovery-\(source)-\(id).json")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try data.write(to: temporary, options: .atomic)
        try FileManager.default.linkItem(at: temporary, to: backup)
    }

    @discardableResult
    private static func write(_ snapshot: Snapshot, comparedTo copies: Copies) -> Bool {
        guard !CaptureRun.isEnabled, copies.resolved != nil, let data = try? JSONEncoder().encode(snapshot) else { return false }
        do {
            try preserve(copies.file, source: "file")
            try preserve(copies.keychain, source: "keychain")
        } catch {
            NSLog("Keepsakes recovery original could not be preserved: %@", error.localizedDescription)
            return false
        }
        var saved = true
        if copies.file.snapshot != snapshot {
            do {
                try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: fileURL, options: .atomic)
            } catch {
                saved = false
                NSLog("Keepsakes file could not be saved: %@", error.localizedDescription)
            }
        }
        if copies.keychain.snapshot != snapshot {
            if !APIKeychain.set(String(decoding: data, as: UTF8.self), account: "Keepsakes") {
                saved = false
                NSLog("Keepsakes Keychain copy could not be saved")
            }
        }
        return saved
    }
}
