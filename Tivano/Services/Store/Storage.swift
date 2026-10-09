import AppKit
import ImageIO
import Synchronization
import SwiftUI
import UniformTypeIdentifiers

/// Just enough of a stored thread to read the files a forwarded continuation points at:
/// the sweep runs over whole files as text, so only this key is ever decoded.
private struct StoredContinuation: Decodable {
    struct Continuation: Decodable {
        var attachments: [Attachment]?
    }

    var continuation: Continuation?
}

struct StoredTurn: Codable, Sendable {
    var turn: TurnRecord
    var items: [TimelineItem]
    var itemPositions: [String: Double]
}

private struct StoredTurnFile: Codable {
    // Keep the head's previous revision until the replacement head commits.
    var revisions: [String: StoredTurn] = [:]
}

struct ThreadSave: Sendable {
    var head: ThreadDocument
    var dirtyTurns: [UUID: StoredTurn]
}

/// Where the app keeps its library, thread histories and attachments.
enum Storage {
    static let root: URL = StoragePaths.root

    static let libraryURL: URL = root.appendingPathComponent("library.json")

    // Each directory is created on first use and its URL kept: the thread URL is taken on
    // every save, prefetch and delete, and a stat plus mkdir per call was pure waste.
    static let threadsDirectory: URL = directory("threads")

    static let attachmentsDirectory: URL = directory("attachments")

    static let worktreesDirectory: URL = stateDirectory("worktrees")

    /// Where a head's work is kept as a patch when it would not land in the checkout.
    static let patchesDirectory: URL = stateDirectory("patches")

    private static func stateDirectory(_ name: String) -> URL {
        let base = CaptureRun.storageRoot?.appendingPathComponent("state", isDirectory: true)
            ?? URL(fileURLWithPath: LoginEnvironment.homeDirectory)
                .appendingPathComponent(AppInfo.stateDirectoryName, isDirectory: true)
        let url = base.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func threadURL(_ id: UUID) -> URL {
        threadsDirectory.appendingPathComponent("\(id.uuidString).json")
    }

    private static func directory(_ name: String) -> URL {
        StoragePaths.directory(name)
    }

    nonisolated static func loadLibrary() -> Library {
        guard let data = try? Data(contentsOf: libraryURL) else { return Library() }
        return (try? JSONDecoder.storage.decode(Library.self, from: data)) ?? Library()
    }

    /// Reads and decodes a thread file. Safe from any thread: the decoder is made here.
    nonisolated static func decodeDocument(_ id: UUID) -> ThreadDocument? {
        readDocument(id)?.document
    }

    /// The document as the runtime wants it: a save queued for it has landed first, blank
    /// thinking blocks are gone and model prose is clean of em dashes, so the prefetch
    /// worker does that work rather than the click that opens the thread.
    nonisolated static func turnsURL(_ id: UUID) -> URL {
        threadsDirectory.appendingPathComponent("\(id.uuidString).turns", isDirectory: true)
    }

    nonisolated static func turnURL(_ threadID: UUID, _ turnID: UUID) -> URL {
        turnsURL(threadID).appendingPathComponent("\(turnID.uuidString).json")
    }

    nonisolated static func readDocument(_ id: UUID) -> (document: ThreadDocument, cost: Int)? {
        readDocument(id, recentOnly: false)
    }

    nonisolated static func readRecentDocument(_ id: UUID) -> (document: ThreadDocument, cost: Int)? {
        readDocument(id, recentOnly: true)
    }

    private nonisolated static func readDocument(_ id: UUID, recentOnly: Bool) -> (document: ThreadDocument, cost: Int)? {
        DiskWriter.shared.readSynchronously {
            guard let data = try? Data(contentsOf: threadURL(id)),
                  var document = try? JSONDecoder.storage.decode(ThreadDocument.self, from: data) else { return nil }
            var cost = data.count
            if let index = document.turnIndex {
                let count = max(0, 6 - document.turns.count)
                let requested = recentOnly ? Array(index.suffix(count)) : index
                guard let stored = readTurnsUnlocked(id, references: requested) else { return nil }
                document.items = stored.document.items + document.items
                document.turns = stored.document.turns + document.turns
                document.itemPositions = (document.itemPositions ?? [:]).merging(stored.document.itemPositions ?? [:]) { _, new in new }
                cost += stored.cost
                sortItems(&document)
            }
            document.items = document.items.filter { !$0.isEmptyReasoning }.map(\.cleanedOfEmDashes)
            return (document, cost)
        }
    }

    nonisolated static func readTurns(_ id: UUID, references: [ThreadTurnReference]) -> (document: ThreadDocument, cost: Int)? {
        DiskWriter.shared.readSynchronously { readTurnsUnlocked(id, references: references) }
    }

    /// Puts a thread's files that would not read somewhere a save can never reach: moved
    /// when nothing of the thread could be read, copied when only older turns failed (the
    /// newer ones are in use, and the next save prunes what its head no longer lists).
    /// Returns the folder, or nil when there was nothing to keep or it could not be made.
    nonisolated static func setAside(_ id: UUID, moving: Bool) -> URL? {
        DiskWriter.shared.readSynchronously {
            let manager = FileManager.default
            let sources = [threadURL(id), turnsURL(id)].filter { manager.fileExists(atPath: $0.path) }
            guard !sources.isEmpty else { return nil }
            let stamp = ISO8601DateFormatter().string(from: .now).replacingOccurrences(of: ":", with: "-")
            let folder = threadsDirectory.appendingPathComponent("Unreadable", isDirectory: true)
                .appendingPathComponent("\(id.uuidString) \(stamp)", isDirectory: true)
            do {
                try manager.createDirectory(at: folder, withIntermediateDirectories: true)
                for source in sources {
                    let target = folder.appendingPathComponent(source.lastPathComponent)
                    if moving { try manager.moveItem(at: source, to: target) } else { try manager.copyItem(at: source, to: target) }
                }
                return folder
            } catch {
                NSLog("Tivano could not set aside %@: %@", id.uuidString, error.localizedDescription)
                return nil
            }
        }
    }

    private nonisolated static func readTurnsUnlocked(_ id: UUID, references: [ThreadTurnReference]) -> (document: ThreadDocument, cost: Int)? {
        var document = ThreadDocument(threadID: id)
        document.turnIndex = references
        document.itemPositions = [:]
        var cost = 0
        for reference in references {
            guard let data = try? Data(contentsOf: turnURL(id, reference.id)),
                  let file = try? JSONDecoder.storage.decode(StoredTurnFile.self, from: data),
                  let stored = file.revisions[String(reference.revision)], stored.turn.id == reference.id else { return nil }
            document.turns.append(stored.turn)
            document.items += stored.items.filter { !$0.isEmptyReasoning }.map(\.cleanedOfEmDashes)
            document.itemPositions?.merge(stored.itemPositions) { _, new in new }
            cost += data.count
        }
        sortItems(&document)
        return (document, cost)
    }

    private nonisolated static func sortItems(_ document: inout ThreadDocument) {
        let positions = document.itemPositions ?? [:]
        document.items.sort { (positions[$0.id] ?? 0) < (positions[$1.id] ?? 0) }
    }

    static func deleteDocument(_ id: UUID) {
        deleteDocuments([id])
    }

    /// Deletes several threads' files in one hop to the writer, so a bulk delete waits for
    /// the queued saves once rather than once per thread. A save of a thread may still be
    /// on its way to the writer; the removal takes its place, so the thread never comes back.
    static func deleteDocuments(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        for id in ids { DocumentPrefetch.shared.forget(id) }
        DiskWriter.shared.removeSynchronously(ids.flatMap { [threadURL($0), turnsURL($0)] })
    }

    /// Copies a file into app storage so a message keeps its attachment after the original moves.
    static func importAttachment(from source: URL) throws -> Attachment {
        let id = UUID()
        let ext = source.pathExtension.isEmpty ? "bin" : source.pathExtension.lowercased()
        let destination = attachmentsDirectory.appendingPathComponent("\(id.uuidString).\(ext)")
        try FileManager.default.copyItem(at: source, to: destination)
        return Attachment(id: id, name: source.lastPathComponent, path: destination.path, mimeType: MimeType.of(ext))
    }

    static func importAttachment(data: Data, name: String, fileExtension: String) throws -> Attachment {
        let id = UUID()
        let destination = attachmentsDirectory.appendingPathComponent("\(id.uuidString).\(fileExtension)")
        try data.write(to: destination, options: .atomic)
        return Attachment(id: id, name: name, path: destination.path, mimeType: MimeType.of(fileExtension))
    }

    /// Removes attachment files no thread refers to any more: the photos of a deleted
    /// thread, a draft's that was never sent, a follow-up's that was dropped. A file is
    /// only an orphan once it is a day old, so a draft still open when the app relaunches
    /// keeps its files, and only files named the way `importAttachment` names them go.
    /// Runs off the main actor; the thread files are scanned as text, never decoded.
    nonisolated static func sweepOrphanedAttachments() async {
        let attachments = attachmentsDirectory
        let threads = threadsDirectory
        await Task.detached(priority: .utility) {
            let fileManager = FileManager.default
            guard let names = try? fileManager.contentsOfDirectory(atPath: attachments.path), !names.isEmpty,
                  let documents = fileManager.enumerator(at: threads, includingPropertiesForKeys: nil)?.allObjects as? [URL] else { return }
            var referenced = Set<String>()
            for document in documents where document.pathExtension == "json" {
                guard let data = try? Data(contentsOf: document) else { continue }
                let text = String(decoding: data, as: UTF8.self)
                // The encoder writes the path's slashes as `\/`.
                for match in text.matches(of: #/attachments\\?\/([0-9A-Fa-f-]{36}\.[A-Za-z0-9]+)/#) {
                    referenced.insert(String(match.output.1))
                }
                // A forwarded continuation keeps its own copy of the metadata, and the
                // files it names stay referenced while the thread holding it is on disk.
                if text.contains("\"continuation\""),
                   let stored = try? JSONDecoder.storage.decode(StoredContinuation.self, from: data) {
                    for attachment in stored.continuation?.attachments ?? [] {
                        referenced.insert(attachment.url.lastPathComponent)
                    }
                }
            }
            let cutoff = Date.now.addingTimeInterval(-24 * 60 * 60)
            for name in names where !referenced.contains(name) {
                guard name.wholeMatch(of: #/[0-9A-Fa-f-]{36}\.[A-Za-z0-9]+/#) != nil else { continue }
                let url = attachments.appendingPathComponent(name)
                guard let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                      modified < cutoff else { continue }
                try? fileManager.removeItem(at: url)
            }
        }.value
    }

    /// How many files a message carries.
    static let attachmentLimit = 8

    /// Imports what a drop, paste, picker or downloads pick handed over and appends the
    /// results, in that order, to the attachments. The free slots are counted here, so the
    /// call returns before any byte is copied, and counted again when the copies land,
    /// since more may have been attached meanwhile: anything past the limit by then is
    /// removed again. The copies and transcodes run off the main actor; a dropped video
    /// or a pasted screenshot never stalls the composer.
    @MainActor @discardableResult
    static func attach(_ sources: [AttachmentSource], to attachments: Binding<[Attachment]>) -> Task<Void, Never>? {
        let batch = Array(sources.prefix(max(0, attachmentLimit - attachments.wrappedValue.count)))
        guard !batch.isEmpty else { return nil }
        return Task.detached(priority: .userInitiated) {
            let imported = batch.compactMap(importSource)
            let kept = await MainActor.run {
                let room = max(0, attachmentLimit - attachments.wrappedValue.count)
                attachments.wrappedValue.append(contentsOf: imported.prefix(room))
                return room
            }
            for orphan in imported.dropFirst(kept) { try? FileManager.default.removeItem(at: orphan.url) }
        }
    }

    /// A file the user picked, dropped or pasted, copied into app storage: folders are
    /// skipped, HEIC photos become JPEGs, which every provider can read, and pasted
    /// images are stored as PNGs. Runs off the main actor; ImageIO does the transcodes.
    static func importSource(_ source: AttachmentSource) -> Attachment? {
        switch source {
        case .file(let url):
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else { return nil }
            let fileExtension = url.pathExtension.lowercased()
            guard fileExtension == "heic" || fileExtension == "heif" else { return try? importAttachment(from: url) }
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let data = transcode(source, to: .jpeg) else { return nil }
            return try? importAttachment(data: data, name: url.deletingPathExtension().lastPathComponent + ".jpg", fileExtension: "jpg")
        case .image(let data, let type):
            let png: Data?
            if type == .png {
                png = data
            } else {
                png = CGImageSourceCreateWithData(data as CFData, nil).flatMap { transcode($0, to: .png) }
            }
            guard let png else { return nil }
            return try? importAttachment(data: png, name: "Pasted image.png", fileExtension: "png")
        }
    }

    /// The first image of the source re-encoded at full size with its orientation
    /// applied, the way the photo looked where it came from.
    private static func transcode(_ source: CGImageSource, to type: UTType) -> Data? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return nil }
        let encoding: [CFString: Any] = type == .jpeg ? [kCGImageDestinationLossyCompressionQuality: 0.88] : [:]
        CGImageDestinationAddImage(destination, image, encoding as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}

/// A file or image handed to a composer, imported by `Storage.attach`.
enum AttachmentSource: Sendable {
    case file(URL)
    /// Image bytes off the pasteboard, in the type they came as.
    case image(Data, UTType)
}

enum MimeType {
    static func of(_ fileExtension: String) -> String {
        switch fileExtension.lowercased() {
        case "png": "image/png"
        case "jpg", "jpeg": "image/jpeg"
        case "gif": "image/gif"
        case "webp": "image/webp"
        case "heic": "image/heic"
        case "pdf": "application/pdf"
        case "json": "application/json"
        case "md", "markdown": "text/markdown"
        default: "text/plain"
        }
    }
}

final class DocumentPrefetch: Sendable {
    static let shared = DocumentPrefetch()

    private struct Request {
        let id: UUID
        let token = UUID()
    }

    private struct State {
        var ready: RecentCache<UUID, ThreadDocument>
        var pending: [UUID: UUID] = [:]
        var queue: [Request] = []
        var worker: Task<Void, Never>?
    }

    private let state: Mutex<State>
    private let pendingLimit: Int
    private let load: @Sendable (UUID) -> (document: ThreadDocument, cost: Int)?

    init(
        limit: Int = 12,
        costLimit: Int = 16 * 1_024 * 1_024,
        pendingLimit: Int = 24,
        load: @escaping @Sendable (UUID) -> (document: ThreadDocument, cost: Int)? = Storage.readRecentDocument
    ) {
        state = Mutex(State(ready: RecentCache(limit: limit, costLimit: costLimit)))
        self.pendingLimit = max(1, pendingLimit)
        self.load = load
    }

    /// Queues documents to decode. `urgent` ones go to the front, ahead of what launch
    /// queued: they are the rows beside the selection and under the pointer, which the next
    /// click is likely to open, while launch's dozen can wait their turn.
    @discardableResult
    func warm(_ ids: [UUID], urgent: Bool = false) -> Task<Void, Never>? {
        state.withLock { state -> Task<Void, Never>? in
            for id in ids.reversed() where urgent {
                guard !state.ready.contains(id), let index = state.queue.firstIndex(where: { $0.id == id }) else { continue }
                state.queue.insert(state.queue.remove(at: index), at: 0)
            }
            for id in ids {
                guard !state.ready.contains(id), state.pending[id] == nil else { continue }
                guard state.queue.count < pendingLimit else { break }
                let request = Request(id: id)
                if urgent { state.queue.insert(request, at: 0) } else { state.queue.append(request) }
                state.pending[id] = request.token
            }
            guard state.worker == nil, !state.queue.isEmpty else { return state.worker }
            let task = Task.detached(priority: .utility) { [self] in
                while let request = next() {
                    let result = load(request.id)
                    self.state.withLock { state in
                        guard state.pending[request.id] == request.token else { return }
                        state.pending[request.id] = nil
                        if let result, !Task.isCancelled {
                            state.ready.insert(result.document, for: request.id, cost: result.cost)
                        }
                    }
                }
            }
            state.worker = task
            return task
        }
    }

    private func next() -> Request? {
        state.withLock { state in
            if Task.isCancelled {
                state.queue.removeAll(keepingCapacity: true)
                state.pending.removeAll(keepingCapacity: true)
            }
            guard !state.queue.isEmpty else {
                state.worker = nil
                return nil
            }
            return state.queue.removeFirst()
        }
    }

    func take(_ id: UUID) -> ThreadDocument? {
        state.withLock { state in
            state.pending[id] = nil
            state.queue.removeAll { $0.id == id }
            return state.ready.removeValue(for: id)
        }
    }

    func forget(_ id: UUID) {
        _ = take(id)
    }
}

final class DiskWriter: Sendable {
    static let shared = DiskWriter()
    private let queue = DispatchQueue(label: "tivano.storage.write", qos: .utility)
    /// The newest snapshot waiting per file. A save queued behind a slow write is replaced
    /// by the next one for the same file, so a backlog never encodes and writes documents
    /// that are already stale when their turn comes.
    private struct PendingWrite: Sendable {
        var value: any Encodable & Sendable
        var completions: [@Sendable (Bool) -> Void]
    }
    private let pending = Mutex<[URL: PendingWrite]>([:])
    private struct PendingThread: Sendable {
        var snapshot: ThreadSave
        var completions: [@Sendable (Bool) -> Void]
    }
    private let pendingThreads = Mutex<[URL: PendingThread]>([:])
    private let errors = Mutex<[URL: String]>([:])

    func lastWriteError(of url: URL) -> String? {
        errors.withLock { $0[url] }
    }
    /// The size of the last write per file, so a caller can space its saves by it.
    private let sizes = Mutex<[URL: Int]>([:])

    func lastWrittenSize(of url: URL) -> Int? {
        sizes.withLock { $0[url] }
    }

    func encodeAndWrite<Value: Encodable & Sendable>(_ value: Value, to url: URL) {
        encodeAndWrite(value, to: url, completion: { _ in })
    }

    func encodeAndWrite<Value: Encodable & Sendable>(_ value: Value, to url: URL, completion: @escaping @Sendable (Bool) -> Void) {
        let queued = pending.withLock { pending in
            let previous = pending[url]
            pending[url] = PendingWrite(value: value, completions: (previous?.completions ?? []) + [completion])
            return previous != nil
        }
        guard !queued else { return }
        queue.async { [self] in
            guard let write = pending.withLock({ $0.removeValue(forKey: url) }) else { return }
            let size = self.write(write.value, to: url)
            if let size { sizes.withLock { $0[url] = size } }
            for completion in write.completions { completion(size != nil) }
        }
    }

    func writeThread(_ snapshot: ThreadSave, completion: @escaping @Sendable (Bool) -> Void) {
        let url = Storage.threadURL(snapshot.head.threadID)
        DocumentPrefetch.shared.forget(snapshot.head.threadID)
        let queued = pendingThreads.withLock { pending in
            let previous = pending[url]
            var newest = snapshot
            newest.dirtyTurns = (previous?.snapshot.dirtyTurns ?? [:]).merging(snapshot.dirtyTurns) { _, new in new }
            pending[url] = PendingThread(snapshot: newest, completions: (previous?.completions ?? []) + [completion])
            return previous != nil
        }
        guard !queued else { return }
        queue.async { [self] in
            guard let pending = pendingThreads.withLock({ $0.removeValue(forKey: url) }) else { return }
            let success = writeThread(pending.snapshot)
            for completion in pending.completions { completion(success) }
        }
    }

    @discardableResult
    func writeThreadSynchronously(_ snapshot: ThreadSave) -> Bool {
        let url = Storage.threadURL(snapshot.head.threadID)
        let completions = pendingThreads.withLock { $0.removeValue(forKey: url)?.completions ?? [] }
        DocumentPrefetch.shared.forget(snapshot.head.threadID)
        return queue.sync {
            let success = writeThread(snapshot)
            for completion in completions { completion(success) }
            return success
        }
    }

    private func writeThread(_ snapshot: ThreadSave) -> Bool {
        let head = snapshot.head
        let url = Storage.threadURL(head.threadID)
        do {
            let directory = Storage.turnsURL(head.threadID)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let index = head.turnIndex ?? []
            var needsPruning = Set<UUID>()
            for reference in index {
                let turnURL = Storage.turnURL(head.threadID, reference.id)
                if let turn = snapshot.dirtyTurns[reference.id] {
                    var file = StoredTurnFile()
                    if FileManager.default.fileExists(atPath: turnURL.path) {
                        file = try JSONDecoder.storage.decode(StoredTurnFile.self, from: Data(contentsOf: turnURL))
                    }
                    file.revisions[String(reference.revision)] = turn
                    if file.revisions.count > 1 { needsPruning.insert(reference.id) }
                    try JSONEncoder.storage.encode(file).write(to: turnURL, options: .atomic)
                } else if !FileManager.default.fileExists(atPath: turnURL.path) {
                    throw CocoaError(.fileNoSuchFile)
                }
            }
            let data = try JSONEncoder.storage.encode(head)
            try data.write(to: url, options: .atomic)
            sizes.withLock { $0[url] = data.count }
            errors.withLock { $0[url] = nil }
            let live = Set(index.map { "\($0.id.uuidString).json" })
            for file in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] where !live.contains(file.lastPathComponent) {
                try? FileManager.default.removeItem(at: file)
            }
            // Cleanup is optional: failure leaves extra recovery revisions, never a broken head.
            for reference in index where needsPruning.contains(reference.id) {
                guard let turn = snapshot.dirtyTurns[reference.id] else { continue }
                let file = StoredTurnFile(revisions: [String(reference.revision): turn])
                if let data = try? JSONEncoder.storage.encode(file) {
                    try? data.write(to: Storage.turnURL(head.threadID, reference.id), options: .atomic)
                }
            }
            return true
        } catch {
            errors.withLock { $0[url] = error.localizedDescription }
            return false
        }
    }

    func writeSynchronously<Value: Encodable & Sendable>(_ value: Value, to url: URL) {
        let completions = pending.withLock { $0.removeValue(forKey: url)?.completions ?? [] }
        queue.sync {
            let size = write(value, to: url)
            if let size { sizes.withLock { $0[url] = size } }
            for completion in completions { completion(size != nil) }
        }
    }

    /// A provider-history action must not proceed if its recovery state cannot save.
    /// Awaited rather than run with `queue.sync`: the caller is the main actor, and a
    /// whole-library write queued behind other documents would hold the app still.
    func writeOrThrow<Value: Encodable & Sendable>(_ value: Value, to url: URL) async throws {
        let completions = pending.withLock { $0.removeValue(forKey: url)?.completions ?? [] }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                do {
                    let data = try JSONEncoder.storage.encode(value)
                    try data.write(to: url, options: .atomic)
                    sizes.withLock { $0[url] = data.count }
                    errors.withLock { $0[url] = nil }
                    for completion in completions { completion(true) }
                    continuation.resume()
                } catch {
                    errors.withLock { $0[url] = error.localizedDescription }
                    for completion in completions { completion(false) }
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func removeSynchronously(_ url: URL) {
        removeSynchronously([url])
    }

    func removeSynchronously(_ urls: [URL]) {
        let threadCompletions = pendingThreads.withLock { pending in
            urls.flatMap { pending.removeValue(forKey: $0)?.completions ?? [] }
        }
        let completions = pending.withLock { pending in
            urls.flatMap { pending.removeValue(forKey: $0)?.completions ?? [] }
        }
        queue.sync {
            for url in urls { try? FileManager.default.removeItem(at: url) }
            for completion in threadCompletions { completion(false) }
            for completion in completions { completion(false) }
        }
    }

    func readSynchronously<Value>(_ read: () -> Value) -> Value {
        queue.sync(execute: read)
    }

    /// Returns once every write queued so far has landed, so a read that follows sees them.
    func waitForQueuedWrites() {
        queue.sync {}
    }

    @discardableResult
    private func write(_ value: any Encodable, to url: URL) -> Int? {
        do {
            let data = try JSONEncoder.storage.encode(value)
            try data.write(to: url, options: .atomic)
            errors.withLock { $0[url] = nil }
            return data.count
        } catch {
            errors.withLock { $0[url] = error.localizedDescription }
            NSLog("Tivano could not save %@: %@", url.lastPathComponent, error.localizedDescription)
            return nil
        }
    }
}
