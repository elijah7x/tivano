import Foundation

/// Best-effort local evidence; a logging failure never interrupts a Hydra job.
actor DecisionLedger {
    static let shared = DecisionLedger()
    nonisolated static var directory: URL { StoragePaths.directory("decisions") }
    nonisolated static var fileURL: URL { directory.appendingPathComponent("ledger.jsonl") }

    func append(_ record: JSONValue) {
        do {
            let manager = FileManager.default
            let file = Self.fileURL
            if manager.fileExists(atPath: file.path) {
                let attributes = try manager.attributesOfItem(atPath: file.path)
                if let size = attributes[.size] as? NSNumber, size.int64Value > 20 * 1_024 * 1_024 {
                    let previous = Self.directory.appendingPathComponent("ledger.1.jsonl")
                    if manager.fileExists(atPath: previous.path) { try manager.removeItem(at: previous) }
                    try manager.moveItem(at: file, to: previous)
                }
            }
            if !manager.fileExists(atPath: file.path) {
                guard manager.createFile(atPath: file.path, contents: nil) else { return }
            }
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data((record.compactString + "\n").utf8))
        } catch {}
    }
}
