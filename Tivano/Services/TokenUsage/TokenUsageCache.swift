import Foundation

enum TokenUsageCache {
    static var fileURL: URL {
        StoragePaths.root.appendingPathComponent("token-usage", isDirectory: true)
            .appendingPathComponent("snapshot.json")
    }

    @concurrent
    static func load() async -> TokenUsageSnapshot? {
        guard let data = try? Data(contentsOf: fileURL),
              let snapshot = try? JSONDecoder.storage.decode(TokenUsageSnapshot.self, from: data),
              snapshot.schemaVersion == TokenUsageSnapshot.currentSchemaVersion,
              snapshot.source.id == TokenTakenSource.sourceID else { return nil }
        return snapshot
    }

    @concurrent
    static func save(_ snapshot: TokenUsageSnapshot) async throws {
        let url = fileURL
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(snapshot)
        try data.write(to: url, options: .atomic)
    }
}
