import Foundation

extension Storage {
    /// A query uses the writer's serialization lane but never its creation/repair APIs.
    /// In particular, do not use threadsDirectory here: that getter creates a directory.
    @concurrent
    static func controlHistory(_ query: ControlHistoryQuery, scope: String, allowsMissing: Bool) async throws -> ControlHistoryPage {
        try DiskWriter.shared.readSynchronously {
            try ControlHistoryReader(threadsDirectory: root.appendingPathComponent("threads", isDirectory: true))
                .page(threadID: query.threadID, request: query.page, scope: scope, allowsMissing: allowsMissing)
        }
    }
}
