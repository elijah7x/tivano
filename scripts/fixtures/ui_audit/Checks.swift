// Compiled only by scripts/ui_audit_checks.py, after extracted production declarations.
// Scheduling gates and dependency fakes belong to this executable, never to Tivano.
actor AuditGate {
    static let decode = AuditGate()
    static let parse = AuditGate()
    static let index = AuditGate()
    private var armed: Set<String> = []
    private var reached: Set<String> = []
    private var pending: [String: CheckedContinuation<Void, Never>] = [:]
    private var counts: [String: Int] = [:]

    func arm(_ key: String) { armed.insert(key); reached.remove(key) }
    func arrive(_ key: String) async {
        counts[key, default: 0] += 1
        guard armed.remove(key) != nil else { return }
        reached.insert(key)
        await withCheckedContinuation { pending[key] = $0 }
    }
    func release(_ key: String) { pending.removeValue(forKey: key)?.resume() }
    func hasReached(_ key: String) -> Bool { reached.contains(key) }
    func count(_ key: String) -> Int { counts[key, default: 0] }
}

// The filesystem enumeration/scoring remains FileIndex's real implementation.
// Only repository detection is fake: no Git process, repository or provider access.
struct Git: Sendable {
    let directory: String
    init(_ directory: String) { self.directory = directory }
    func isRepository() async -> Bool { await AuditGate.index.arrive(directory); return false }
    func listFiles() async -> [String] { preconditionFailure("Git branch is outside this harness") }
}

@MainActor enum MarkdownView {
    // The coordinator publishes to a cache sink; shared-cache eviction is not tested here.
    static func rememberStreamingParse(_ text: String, _ parse: MarkdownParser.Parse) {}
}

@MainActor final class AuditSession {
    var sends: [(id: String, answers: [String: [String]])] = []
    private var completions: [@MainActor (Bool) -> Void] = []
    func answerQuestion(_ id: String, answers: [String: [String]], delivered: @escaping @MainActor (Bool) -> Void) {
        sends.append((id, answers))
        completions.append(delivered)
    }
    func complete(_ succeeded: Bool) { completions.removeFirst()(succeeded) }
}

// Rendering uses only visibility, not the unrelated display-link/paragraph subsystem.
@MainActor @Observable final class VeilRenderScope { var isVisible = true }
extension EnvironmentValues { @Entry var veilRenderScope: VeilRenderScope? = nil }

extension FileIndex {
    fileprivate func auditExpire() {
        builtAt = .distantPast
        if let directory, let cached = Self.built.value(for: directory) {
            Self.built.insert((cached.entries, .distantPast), for: directory)
        }
    }
}

extension StreamingParseCoordinator {
    var auditText: String? { result?.text }
    var auditRunning: Bool { running }
}

extension ThreadRuntime {
    fileprivate func auditRequests(_ requests: [QuestionRequest]) { questions = requests }
}

extension QuestionSheet {
    fileprivate func auditLateWrite() {
        selections.wrappedValue = ["format": ["Late selection"]]
        written.wrappedValue = ["detail": "Late field-editor commit"]
    }
}

struct AuditFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

@MainActor enum Audit {
    static var count = 0
    static var stamp = 0

    static func check(_ value: Bool, _ label: String) throws {
        guard value else { throw AuditFailure(label) }
        count += 1
        print("PASS \(label)")
    }

    static func require<T>(_ value: T?, _ label: String) throws -> T {
        guard let value else { throw AuditFailure(label) }
        return value
    }

    static func until(_ label: String, _ condition: @MainActor () async -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(8))
        while !(await condition()) {
            guard clock.now < deadline else { throw AuditFailure("timeout: \(label)") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    static func bmp(red: UInt8, green: UInt8 = 0, blue: UInt8) -> Data {
        let side: UInt32 = 64
        let pixels = side * side * 3
        var data = Data([0x42, 0x4D])
        func u16(_ value: UInt16) { var le = value.littleEndian; withUnsafeBytes(of: &le) { data.append(contentsOf: $0) } }
        func u32(_ value: UInt32) { var le = value.littleEndian; withUnsafeBytes(of: &le) { data.append(contentsOf: $0) } }
        u32(54 + pixels); u32(0); u32(54); u32(40); u32(side); u32(side)
        u16(1); u16(24); u32(0); u32(pixels); u32(0); u32(0); u32(0); u32(0)
        for _ in 0..<(side * side) { data.append(contentsOf: [blue, green, red]) }
        return data
    }

    static func overwrite(_ url: URL, with data: Data) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seek(toOffset: 0)
            try handle.write(contentsOf: data)
            try handle.truncate(atOffset: UInt64(data.count))
            try handle.synchronize()
        } else {
            try data.write(to: url)
        }
        stamp += 1
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_000 + Double(stamp))],
                                             ofItemAtPath: url.path)
    }

    static func pixel(_ image: CGImage) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try require(CGContext(data: buffer.baseAddress, width: 1, height: 1,
                bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue), "pixel context")
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return bytes
    }

    static func images(_ root: URL) async throws {
        let url = root.appendingPathComponent("same-size.bmp")
        let red = bmp(red: 255, blue: 0), blue = bmp(red: 0, blue: 255)
        try check(red.count == blue.count, "fixtures have identical file length and pixel dimensions")
        try overwrite(url, with: red)
        let cache = ThumbnailCache()
        let before = try require(await AttachmentFileVersion.read(url.path), "initial file version")
        let a = try require(await cache.thumbnail(for: url.path, pointSize: 16), "red thumbnail")
        ThumbnailMemory.store(a.image, for: before, pointSize: 16)
        try check(ThumbnailMemory.image(for: before, pointSize: 16) != nil, "main-actor cache hit for known version")
        try overwrite(url, with: blue)
        let after = try require(await AttachmentFileVersion.read(url.path), "overwritten version")
        try check(before.size == after.size && before != after, "same-path, same-size overwrite changes version")
        try check(ThumbnailMemory.image(for: after, pointSize: 16) == nil, "memory cache cannot reuse the earlier image")
        let b = try require(await cache.thumbnail(for: url.path, pointSize: 16), "blue thumbnail")
        let color = try pixel(b.image)
        try check(color[2] > 240 && color[0] < 15 && a.image.width == b.image.width, "cache decodes overwritten pixels at identical size")

        let replacement = root.appendingPathComponent("replacement.bmp")
        try overwrite(replacement, with: red)
        try FileManager.default.setAttributes([.modificationDate: after.modified], ofItemAtPath: replacement.path)
        guard rename(replacement.path, url.path) == 0 else { throw AuditFailure("fixture atomic rename") }
        let replaced = try require(await AttachmentFileVersion.read(url.path), "replacement version")
        try check(replaced.size == after.size && replaced.modified == after.modified && replaced != after,
                  "atomic replacement with preserved size/mtime changes inode identity")
        let c = try require(await cache.thumbnail(for: url.path, pointSize: 16), "replacement thumbnail")
        try check(try pixel(c.image)[0] > 240, "replacement image is red")
        try FileManager.default.removeItem(at: url)
        try check(await AttachmentFileVersion.read(url.path) == nil, "deleted file has no version")
        try check(await cache.thumbnail(for: url.path, pointSize: 16) == nil, "deletion never falls back to cached pixels")
        try overwrite(url, with: Data(repeating: 0, count: red.count))
        try check(await cache.thumbnail(for: url.path, pointSize: 16) == nil, "corrupt same-size file fails decoding")
        try overwrite(url, with: blue)
        try check(await cache.thumbnail(for: url.path, pointSize: 16) != nil, "repair after decoding failure can retry")

        let race = root.appendingPathComponent("decode-race.bmp")
        try overwrite(race, with: red)
        await AuditGate.decode.arm(race.path)
        let loading = Task { await cache.thumbnail(for: race.path, pointSize: 16) }
        try await until("decode reached publication gate") { await AuditGate.decode.hasReached(race.path) }
        try overwrite(race, with: blue)
        await AuditGate.decode.release(race.path)
        let landed = try require(await loading.value, "retry replaced decode")
        try check(try pixel(landed.image)[2] > 240, "overwrite after decode rejects old pixels and retries current version")
        try overwrite(race, with: red)
        let expected = try require(await AttachmentFileVersion.read(race.path), "expected version")
        await AuditGate.decode.arm(race.path)
        let expectedLoad = Task { await cache.thumbnail(for: race.path, pointSize: 17, version: expected) }
        try await until("expected-version decode reached gate") { await AuditGate.decode.hasReached(race.path) }
        try FileManager.default.removeItem(at: race)
        await AuditGate.decode.release(race.path)
        try check(await expectedLoad.value == nil, "deletion after decode suppresses publication")
        try overwrite(race, with: red)
        let pinned = try require(await AttachmentFileVersion.read(race.path), "pinned version")
        await AuditGate.decode.arm(race.path)
        let pinnedLoad = Task { await cache.thumbnail(for: race.path, pointSize: 18, version: pinned) }
        try await until("pinned decode reached gate") { await AuditGate.decode.hasReached(race.path) }
        try overwrite(race, with: blue)
        await AuditGate.decode.release(race.path)
        try check(await pinnedLoad.value == nil, "replacement cannot publish into a view still requesting the old version")
    }

    static func markdown() async throws {
        let coordinator = StreamingParseCoordinator()
        var text = String(repeating: "a", count: 5_000)
        await AuditGate.parse.arm(text)
        _ = coordinator.parse(text)
        try await until("initial parse gated") { await AuditGate.parse.hasReached(text) }
        for index in 0..<4 {
            let previous = text
            text += String(repeating: String(index), count: 200)
            await AuditGate.parse.arm(text)
            _ = coordinator.parse(text)
            await AuditGate.parse.release(previous)
            try await until("next appended parse gated") { await AuditGate.parse.hasReached(text) }
            try check(coordinator.auditText == previous, "stream advances intermediate prefix \(index + 1) before latest parse completes")
        }
        await AuditGate.parse.release(text)
        try await until("final append lands") { coordinator.auditText == text && !coordinator.auditRunning }
        try check(coordinator.parse(text).blocks == MarkdownParser.parse(text), "completed append matches full parser")

        let old = String(repeating: "old", count: 2_000), replacement = String(repeating: "NEW", count: 2_100)
        await AuditGate.parse.arm(old)
        _ = coordinator.parse(old)
        try await until("old generation gated") { await AuditGate.parse.hasReached(old) }
        await AuditGate.parse.arm(replacement)
        _ = coordinator.parse(replacement)
        await AuditGate.parse.release(old)
        try await until("replacement starts") { await AuditGate.parse.hasReached(replacement) }
        try check(coordinator.auditText == nil, "replacement discards old generation completion")
        await AuditGate.parse.release(replacement)
        try await until("replacement lands") { coordinator.auditText == replacement }
        let shrinking = replacement + " more"
        await AuditGate.parse.arm(shrinking)
        _ = coordinator.parse(shrinking)
        try await until("long parse before shortening") { await AuditGate.parse.hasReached(shrinking) }
        _ = coordinator.parse("short")
        await AuditGate.parse.release(shrinking)
        try await until("old long parse returns") { !coordinator.auditRunning }
        try check(coordinator.auditText == "short", "shortened synchronous result survives old completion")

        let stable = String(repeating: "p", count: 5_000) + "\n\nsecond\n\nthird\n\nfourth"
        let pending = stable + " pending", newer = pending + " newer"
        let synchronous = StreamingParseCoordinator()
        await AuditGate.parse.arm(stable)
        _ = synchronous.parse(stable)
        try await until("stable baseline gated") { await AuditGate.parse.hasReached(stable) }
        await AuditGate.parse.arm(pending)
        _ = synchronous.parse(pending)
        await AuditGate.parse.release(stable)
        try await until("pending parse gated after stable prefix lands") { await AuditGate.parse.hasReached(pending) }
        _ = synchronous.parse(newer)
        try check(synchronous.auditText == newer, "small tail parses synchronously while older parse is pending")
        await AuditGate.parse.release(pending)
        try await until("older same-generation parse returns") { !synchronous.auditRunning }
        try check(synchronous.auditText == newer, "same-generation completion never regresses a newer synchronous result")
        let oldBlock = MarkdownBlockView(block: .paragraph("old"), settled: true, generation: 0)
        let replacedBlock = MarkdownBlockView(block: .paragraph("new"), settled: true, generation: 1)
        try check(oldBlock != replacedBlock, "settled view equality cannot hide a text-generation replacement")
    }

    static func indexes(_ root: URL) async throws {
        let directory = root.appendingPathComponent("index")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data().write(to: directory.appendingPathComponent("initial.txt"))
        let index = FileIndex()
        await index.prepare(directory.path)
        try Data().write(to: directory.appendingPathComponent("new.txt"))
        try check(await index.search("new").isEmpty, "fresh index does not rescan per query")
        index.auditExpire()
        await AuditGate.index.arm(directory.path)
        let first = Task { await index.search("new") }
        try await until("expired index scan begins") { await AuditGate.index.hasReached(directory.path) }
        var secondEntered = false
        let second = Task { @MainActor in secondEntered = true; return await index.search("initial") }
        try await until("second search enters while rebuild is held") { secondEntered }
        await AuditGate.index.release(directory.path)
        let firstMatches = await first.value, secondMatches = await second.value
        try check(firstMatches == ["new.txt"] && secondMatches == ["initial.txt"], "expired searches join a shared rebuild: \(firstMatches), \(secondMatches)")
        for _ in 0..<5 { _ = await index.search("new") }
        try check(await AuditGate.index.count(directory.path) == 2, "one initial scan plus one expiry scan despite more keystrokes")

        let a = root.appendingPathComponent("directory-a"), b = root.appendingPathComponent("directory-b")
        for url in [a, b] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        try Data().write(to: a.appendingPathComponent("only-a.txt"))
        try Data().write(to: b.appendingPathComponent("only-b.txt"))
        await AuditGate.index.arm(a.path)
        let switching = FileIndex()
        let pendingA = Task { await switching.prepare(a.path) }
        try await until("directory A scan gated") { await AuditGate.index.hasReached(a.path) }
        await switching.prepare(b.path)
        await AuditGate.index.release(a.path)
        await pendingA.value
        try check(await switching.search("only") == ["only-b.txt"], "late A completion cannot replace directory B")
        await switching.prepare(a.path)
        try check(await switching.search("only") == ["only-a.txt"], "return to A reuses its completed shared index")
        switching.auditExpire()
        await AuditGate.index.arm(a.path)
        let cancelled = Task { await switching.search("only") }
        try await until("cancelled search joins scan") { await AuditGate.index.hasReached(a.path) }
        cancelled.cancel()
        await AuditGate.index.release(a.path)
        try check(await cancelled.value.isEmpty, "cancelled search cannot publish matches")
        try check(await switching.search("only") == ["only-a.txt"], "a later search can consume the completed shared scan")
        switching.auditExpire()
        await AuditGate.index.arm(a.path)
        let oldA = Task { await switching.prepare(a.path) }
        try await until("A scan held across A-B-A") { await AuditGate.index.hasReached(a.path) }
        await switching.prepare(b.path)
        var returnedToA = false
        let newA = Task { @MainActor in returnedToA = true; await switching.prepare(a.path) }
        try await until("return to A joins the pending scan") { returnedToA }
        await AuditGate.index.release(a.path)
        await oldA.value
        await newA.value
        try check(await switching.search("only") == ["only-a.txt"], "A-B-A preserves the latest directory generation")
    }

    static func request() -> QuestionRequest {
        QuestionRequest(id: "fixture-request", questions: [
            .init(id: "format", header: "Output", prompt: "Which format should the report use?",
                  choices: [.init(label: "Summary (Recommended)", detail: "Keep the findings concise."),
                            .init(label: "Detailed report", detail: nil)],
                  allowsMultiple: false, allowsOther: false, isSecret: false),
            .init(id: "detail", header: "Review notes", prompt: "What should the review include?",
                  choices: [.init(label: "Performance", detail: nil), .init(label: "Interaction", detail: nil)],
                  allowsMultiple: true, allowsOther: true, isSecret: false),
        ])
    }

    static func questions() throws {
        let request = request(), runtime = ThreadRuntime()
        runtime.auditRequests([request])
        let draft = runtime.questionDraft(for: request)
        draft.selections["detail"] = ["Performance", "Interaction"]
        draft.written["detail"] = "Keep this unfinished note."
        draft.page = 1
        let oldSheet = QuestionSheet(request: request, runtime: runtime)
        let reopened = runtime.questionDraft(for: request)
        try check(reopened === draft && reopened.page == 1 && reopened.written["detail"] == "Keep this unfinished note."
                  && reopened.selections["detail"] == ["Performance", "Interaction"], "reopening shares selections, free text and page")
        let session = try require(runtime.session, "synthetic session")
        runtime.answer(request, answers: ["detail": ["Performance"]], draft: draft)
        try check(session.sends.count == 1 && !draft.isActive && draft.written["detail"] == "Keep this unfinished note."
                  && draft.page == 1, "pending submission preserves draft and disables resubmission")
        oldSheet.auditLateWrite()
        runtime.answer(request, answers: [:], draft: draft)
        try check(draft.written["detail"] == "Keep this unfinished note." && session.sends.count == 1,
                  "pending sheet bindings cannot rewrite or resubmit")
        session.complete(false)
        let retry = runtime.questionDraft(for: request)
        try check(retry === draft && retry.isActive && retry.page == 1
                  && retry.selections["detail"] == ["Performance", "Interaction"]
                  && runtime.deliveryFailures == 1, "failed delivery preserves choices, text and page for retry")
        runtime.answer(request, answers: [:], draft: retry)
        session.complete(true)
        try check(runtime.questions.isEmpty && !runtime.questionDraft(for: request).isActive, "successful delivery removes request and draft")
        runtime.auditRequests([request])
        let ended = runtime.questionDraft(for: request)
        ended.written["detail"] = "unsent"
        runtime.auditRequests([])
        runtime.answer(request, answers: [:], draft: ended)
        try check(!ended.isActive && ended.written.isEmpty && session.sends.count == 2, "request removal clears and blocks the old draft")
        runtime.auditRequests([request])
        let original = runtime.questionDraft(for: request)
        var changed = request
        changed.questions[0].prompt = "A new question with the same request ID"
        runtime.auditRequests([changed])
        try check(!original.isActive && runtime.questionDraft(for: changed) !== original,
                  "same request ID with changed questions invalidates earlier draft")
        let changedDraft = runtime.questionDraft(for: changed)
        runtime.answer(changed, answers: [:], draft: changedDraft)
        runtime.auditRequests([])
        runtime.auditRequests([changed])
        let nextLifetime = runtime.questionDraft(for: changed)
        session.complete(true)
        try check(nextLifetime.isActive && runtime.questions.count == 1,
                  "late delivery callback cannot remove a new request lifetime with the same ID")
        runtime.auditInterruptDrafts()
        let survived = runtime.questionDraft(for: changed)
        try check(!nextLifetime.isActive && survived !== nextLifetime && survived.isActive,
                  "question surviving interruption receives an answerable draft")
        runtime.answer(changed, answers: [:], draft: survived)
        session.complete(true)
        try check(runtime.questions.isEmpty, "surviving question can deliver its answer")
    }
}

@main @MainActor enum UIAuditMain {
    static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        Task { @MainActor in
            do {
                let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
                try await Audit.images(root)
                try await Audit.markdown()
                try await Audit.indexes(root)
                try Audit.questions()
                if CommandLine.arguments.count > 2 {
                    try await AuditRender.run(data: root, output: URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true))
                }
                print("\(Audit.count) isolated checks passed; full app/provider lifecycle, popover geometry and visual acceptance remain separate.")
                exit(0)
            } catch {
                print("FAIL \(error)")
                exit(1)
            }
        }
        NSApp.run()
    }
}
