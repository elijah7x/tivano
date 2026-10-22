import Foundation
import Darwin
import Synchronization

private enum Checks {
    static let results = Mutex<[String]>([])
    static func check(_ value: @autoclosure () throws -> Bool, _ name: String) throws {
        guard try value() else { throw CheckFailure(name: name) }
        results.withLock { $0.append(name) }
        print("PASS \(name)")
    }
    static func rejects(_ code: ControlFailure.Code, _ name: String, _ action: () throws -> Void) throws {
        do { try action() } catch let failure as ControlFailure {
            try check(failure.code == code, name)
            return
        }
        throw CheckFailure(name: "Expected \(code): \(name)")
    }
    struct CheckFailure: Error { var name: String }
}

private actor SyntheticService {
    let instance: UUID
    private var ledger: ControlLedger
    private var writes = 0
    private var queries = 0
    init(instance: UUID) { self.instance = instance; ledger = ControlLedger(instance: instance) }
    func request(_ request: ControlRequest) -> ControlResponse {
        do {
            if request.command.ticket != nil {
                let receipt = try ledger.accept(request.command)
                if receipt.isNew { writes += 1 }
                return ControlResponse(id: request.id, result: .operation(receipt.outcome))
            }
            if case .operation(let ticket) = request.command { return ControlResponse(id: request.id, result: .operation(ledger.outcome(ticket))) }
            queries += 1
            return ControlResponse(id: request.id, result: .info(ControlWelcome(edition: .dev, instance: instance)))
        } catch { return ControlResponse(id: request.id, error: error as? ControlFailure ?? ControlFailure(code: .internalError)) }
    }
    func counts() -> (writes: Int, queries: Int) { (writes, queries) }
}

private final class RawClient {
    let fd: Int32
    init(directory: URL) throws {
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ControlFailure(code: .unavailable) }
        try ControlSocket.configure(fd, nonblocking: false)
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        try ControlSocket.withAddress(directory.appendingPathComponent("control.sock").path) { address, size in
            guard connect(fd, address, size) == 0 else { throw ControlFailure(code: .unavailable) }
        }
    }
    deinit { Darwin.close(fd) }
    func write(_ data: Data, split: Bool = false) throws {
        var offset = 0
        while offset < data.count {
            let count = data.withUnsafeBytes { bytes in send(fd, bytes.baseAddress!.advanced(by: offset), split ? 1 : bytes.count - offset, 0) }
            guard count > 0 else { throw ControlFailure(code: .unavailable) }
            offset += count
        }
    }
    func response() throws -> ControlResponse {
        var buffer = Data()
        var bytes = [UInt8](repeating: 0, count: 16_384)
        while true {
            if let data = try ControlSocket.takeFrame(&buffer, limit: LocalControl.maxFrame) {
                return try LocalControl.decoder().decode(ControlResponse.self, from: data)
            }
            let count = recv(fd, &bytes, bytes.count, 0)
            guard count > 0 else { throw ControlFailure(code: .unavailable) }
            buffer.append(contentsOf: bytes.prefix(count))
        }
    }
    func hello(_ hello: ControlHello, split: Bool = false) throws -> ControlResponse {
        try write(ControlSocket.frame(LocalControl.encoder().encode(hello)), split: split)
        return try response()
    }
    func eof() -> Bool { var byte: UInt8 = 0; return recv(fd, &byte, 1, 0) == 0 }
}

@main private struct LocalControlChecks {
    static func main() async throws {
        guard CommandLine.arguments.count == 2 else { throw Checks.CheckFailure(name: "fixture root required") }
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try connection(root)
        try historyAndInstallation(root)
        try ledgerAndPagination()
        try await transportConcurrencyAndResources(root)
        let names = Checks.results.withLock { $0 }
        let report: [String: Any] = ["executed_checks": names, "count": names.count, "scope": "synthetic non-GUI only; no App launch, real library, account, install path or live updater", "owner_side_pending": ["GUI", "provider end-to-end", "signed build", "real performance regression"]]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: root.appendingPathComponent("results.json"))
        print("ISOLATED CHECKS COMPLETE: \(names.count)")
    }

    static func connection(_ root: URL) throws {
        print("ROUND 1: connection/isolation")
        let directory = root.appendingPathComponent("t", isDirectory: true)
        try Checks.rejects(.unavailable, "disabled endpoint is absent; no implicit directory creation") {
            _ = try ControlClient(edition: .dev, directory: directory, timeout: 1)
        }
        try Checks.check(!FileManager.default.fileExists(atPath: directory.path), "disabled client did not create socket directories")
        let permissive = root.appendingPathComponent("p", isDirectory: true)
        try FileManager.default.createDirectory(at: permissive, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: permissive.path)
        try Checks.rejects(.permission, "permissive endpoint directory is rejected, not silently chmodded") { try ControlSocket.prepareDirectory(permissive) }
        let symlink = root.appendingPathComponent("s")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: permissive)
        try Checks.rejects(.permission, "endpoint directory symlink is rejected") { try ControlSocket.prepareDirectory(symlink) }
        let instance = UUID()
        let service = SyntheticService(instance: instance)
        let server = ControlSocketServer(directory: directory, welcome: ControlWelcome(edition: .dev, instance: instance)) { await service.request($0) }
        try server.start()
        defer { server.stop() }
        var info = stat()
        try Checks.check(lstat(directory.path, &info) == 0 && info.st_mode & 0o777 == 0o700, "private directory 0700")
        let socketPath = directory.appendingPathComponent("control.sock").path
        try Checks.check(lstat(socketPath, &info) == 0 && info.st_mode & 0o777 == 0o600, "private socket 0600")
        do {
            let client = try RawClient(directory: directory)
            let response = try client.hello(ControlHello(edition: .dev), split: true)
            guard case .welcome(let welcome) = response.result else { throw Checks.CheckFailure(name: "handshake") }
            try Checks.check(welcome.instance == instance, "fragmented frame handshake pins instance")
            try ControlSocket.checkPeer(client.fd)
            try Checks.rejects(.permission, "peer UID mismatch rejects") { try ControlSocket.checkPeer(client.fd, expectedUID: getuid() + 1) }
        }
        try Checks.rejects(.editionMismatch, "edition mismatch rejects") { _ = try ControlClient(edition: .release, directory: directory) }
        try Checks.rejects(.instanceMismatch, "expected instance mismatch rejects") { _ = try ControlClient(edition: .dev, expectedInstance: UUID(), directory: directory) }
        do {
            let client = try RawClient(directory: directory)
            let response = try client.hello(ControlHello(version: 99, edition: .dev))
            try Checks.check(response.error?.code == .protocolMismatch, "protocol version mismatch rejects")
        }
        do {
            let client = try RawClient(directory: directory)
            var length = UInt32(LocalControl.maxRequest + 1).bigEndian
            try client.write(withUnsafeBytes(of: &length) { Data($0) })
            try Checks.check(try client.response().error?.code == .bounds, "oversize header rejects before allocation")
        }
        do {
            let client = try RawClient(directory: directory)
            _ = try client.hello(ControlHello(edition: .dev))
            let request = ControlRequest(instance: UUID(), command: .info)
            try client.write(ControlSocket.frame(LocalControl.encoder().encode(request)))
            try Checks.check(try client.response().error?.code == .instanceMismatch, "request instance mismatch rejects")
        }
        // Let cancellation handlers close previous FDs before the deterministic cap check.
        usleep(100_000)
        var peers: [RawClient] = []
        for _ in 0..<LocalControl.maxConnections {
            let peer = try RawClient(directory: directory)
            _ = try peer.hello(ControlHello(edition: .dev))
            peers.append(peer)
        }
        do {
            let extra = try RawClient(directory: directory)
            try Checks.check(extra.eof(), "connection count is bounded")
        }
        server.stop()
        try Checks.check(peers.allSatisfy { $0.eof() }, "revocation closes existing connections")
        peers.removeAll()
        try Checks.check(!FileManager.default.fileExists(atPath: socketPath), "stop removes only owned socket")
        try Checks.rejects(.unavailable, "disabled after revocation cannot reconnect") { _ = try ControlClient(edition: .dev, directory: directory) }
        try server.start()
        try Checks.check(try ControlClient(edition: .dev, directory: directory).welcome.instance == instance, "reenable uses fresh handshake")
        let competitor = ControlSocketServer(directory: directory, welcome: ControlWelcome(edition: .dev, instance: UUID())) { _ in ControlResponse(error: ControlFailure(code: .internalError)) }
        try Checks.rejects(.busy, "live edition lease is not stolen") { try competitor.start() }
        competitor.stop()
        try Checks.check(FileManager.default.fileExists(atPath: socketPath), "failed competing start does not unlink owner endpoint")
    }

    static func historyAndInstallation(_ root: URL) throws {
        print("ROUND 2: bounded history and user-action installation")
        let directory = root.appendingPathComponent("synthetic-store/threads", isDirectory: true)
        let reader = ControlHistoryReader(threadsDirectory: directory)
        let threadID = UUID()
        let empty = try reader.page(threadID: threadID, request: ControlPage(), scope: "instance")
        try Checks.check(empty.entries.isEmpty && !FileManager.default.fileExists(atPath: directory.path), "querying empty history never creates Store directories")
        try Checks.rejects(.corruptHistory, "missing sent-thread history is an error") {
            _ = try reader.page(threadID: threadID, request: ControlPage(), scope: "instance", allowsMissing: false)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let turns = directory.appendingPathComponent("\(threadID.uuidString).turns", isDirectory: true)
        try FileManager.default.createDirectory(at: turns, withIntermediateDirectories: true)
        var index: [[String: Any]] = []
        var expected: [String] = []
        for number in 0..<9 {
            let turnID = UUID()
            index.append(["id": turnID.uuidString, "revision": 1])
            var items: [[String: Any]] = []
            var positions: [String: Double] = [:]
            for itemNumber in 0..<3 {
                let id = "\(number)-\(itemNumber)"
                expected.append(id)
                items.append(["id": id, "turnID": turnID.uuidString, "date": "2026-01-01T00:00:00Z", "content": ["user": ["_0": ["text": itemNumber == 2 ? String(repeating: "界", count: 2_000) : "synthetic \(id)"]]]])
                positions[id] = Double(itemNumber)
            }
            let file: [String: Any] = ["revisions": ["1": ["turn": ["id": turnID.uuidString, "index": number, "status": "completed"], "items": items.reversed().map { $0 }, "itemPositions": positions]]]
            try JSONSerialization.data(withJSONObject: file).write(to: turns.appendingPathComponent("\(turnID.uuidString).json"))
        }
        let headURL = directory.appendingPathComponent("\(threadID.uuidString).json")
        let head: [String: Any] = ["threadID": threadID.uuidString, "turnIndex": index, "items": [], "turns": []]
        let original = try JSONSerialization.data(withJSONObject: head, options: [.sortedKeys])
        try original.write(to: headURL)
        var page = ControlPage(limit: 5)
        var ids: [String] = []
        var sawTruncation = false
        var firstCursor: String?
        repeat {
            let result = try reader.page(threadID: threadID, request: page, scope: "instance")
            ids += result.entries.map(\.id)
            sawTruncation = sawTruncation || result.entries.contains(where: \.truncated)
            if firstCursor == nil { firstCursor = result.nextCursor }
            page.cursor = result.nextCursor
        } while page.cursor != nil
        try Checks.check(ids == expected, "history pagination has deterministic positions and no gaps")
        try Checks.check(sawTruncation, "long history content explicitly marks excerpts")
        try Checks.check(try Data(contentsOf: headURL) == original, "history reads do not repair or mutate head")
        try Checks.rejects(.cursorInvalid, "history cursor cannot cross instances") {
            _ = try reader.page(threadID: threadID, request: ControlPage(limit: 5, cursor: firstCursor), scope: "other_instance")
        }
        try (original + Data([32])).write(to: headURL)
        try Checks.rejects(.cursorInvalid, "persisted head mutation invalidates history cursor") {
            _ = try reader.page(threadID: threadID, request: ControlPage(limit: 5, cursor: firstCursor), scope: "instance")
        }
        try Data("corrupt".utf8).write(to: headURL)
        try Checks.rejects(.corruptHistory, "corrupt history is explicit without recovery") { _ = try reader.page(threadID: threadID, request: ControlPage(), scope: "instance") }
        try Checks.check(try Data(contentsOf: headURL) == Data("corrupt".utf8), "corrupt document preserved byte for byte")
        let sparseID = UUID()
        let sparse = directory.appendingPathComponent("\(sparseID.uuidString).json")
        FileManager.default.createFile(atPath: sparse.path, contents: nil)
        let handle = try FileHandle(forWritingTo: sparse)
        try handle.truncate(atOffset: UInt64(ControlHistoryReader.fileLimit + 1))
        try handle.close()
        try Checks.rejects(.bounds, "legacy/file size bound is enforced before decode") { _ = try reader.page(threadID: sparseID, request: ControlPage(), scope: "instance") }

        let app = root.appendingPathComponent("An App With Spaces.app/Contents/Helpers", isDirectory: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let helper = app.appendingPathComponent("tivano-control")
        try Data("synthetic non-executable fixture, never run".utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        let bin = root.appendingPathComponent("synthetic home/.local/bin", isDirectory: true)
        try ControlCLIInstaller.install(directory: bin, helper: helper, name: "tivano-dev", previousTarget: nil)
        let link = bin.appendingPathComponent("tivano-dev")
        try Checks.check(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == helper.path, "CLI install handles spaces without a shell")
        let moved = root.appendingPathComponent("Moved App.app/Contents/Helpers/tivano-control")
        try FileManager.default.createDirectory(at: moved.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: helper, to: moved)
        try ControlCLIInstaller.install(directory: bin, helper: moved, name: "tivano-dev", previousTarget: helper.path)
        try Checks.check(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == moved.path, "moved App repair uses exact receipt")
        try Checks.rejects(.conflict, "uninstall refuses an unrecognized link") { try ControlCLIInstaller.uninstall(directory: bin, name: "tivano-dev", previousTarget: helper.path) }
        try ControlCLIInstaller.uninstall(directory: bin, name: "tivano-dev", previousTarget: moved.path)
        try Checks.check(!FileManager.default.fileExists(atPath: link.path), "uninstall removes only receipt-owned command")
        try Data("unrelated command".utf8).write(to: link)
        try Checks.rejects(.conflict, "install never overwrites a regular command") { try ControlCLIInstaller.install(directory: bin, helper: helper, name: "tivano-dev", previousTarget: nil) }
        try Checks.check(try String(contentsOf: link, encoding: .utf8) == "unrelated command", "collision leaves unrelated content intact")
        try Checks.check(ControlCLIInstaller.commandName(.dev) != ControlCLIInstaller.commandName(.release), "PATH names isolate editions")
    }

    static func ledgerAndPagination() throws {
        print("ROUND 3: idempotency/failure/recovery")
        let instance = UUID()
        let ticket = ControlTicket(instance: instance)
        let command = ControlCommand.submit(ControlSubmit(ticket: ticket, threadID: UUID(), text: "synthetic"))
        var ledger = ControlLedger(instance: instance)
        try Checks.check(try ledger.accept(command).isNew, "first operation is accepted")
        try Checks.check(try !ledger.accept(command).isNew, "identical retry returns receipt")
        guard case .submit(var changed) = command else { fatalError() }
        changed.text = "changed"
        try Checks.rejects(.conflict, "same operation ID with changed payload conflicts") { _ = try ledger.accept(.submit(changed)) }
        try Checks.check(ledger.outcome(ticket).state == .accepted, "accepted is not started or ended")
        ledger.update(ticket) { $0.state = .waiting }
        try Checks.check(ledger.outcome(ticket).state == .waiting, "waiting is observable separately")
        ledger.update(ticket) { $0.state = .ended; $0.turnStatus = "completed" }
        try Checks.check(ledger.outcome(ticket).state == .ended, "terminal receipt retained")
        let expired = ticket.issuedAt.addingTimeInterval(LocalControl.retention + 1)
        try Checks.check(ledger.outcome(ticket, now: expired).state == .unknown, "expired query is unknown")
        try Checks.check(try ledger.accept(command, now: expired).outcome.state == .unknown, "expired write is not replayed")
        let restarted = ControlLedger(instance: UUID())
        try Checks.check(restarted.outcome(ticket).state == .unknown, "restart cannot claim exactly-once outcome")
        var other = ControlLedger(instance: UUID())
        try Checks.rejects(.instanceMismatch, "old ticket never writes into new instance") { _ = try other.accept(command) }
        var full = ControlLedger(instance: instance)
        for _ in 0..<LocalControl.maxPendingOperations {
            _ = try full.accept(.settingsSet(ControlSettingsWrite(ticket: ControlTicket(instance: instance), key: .showsSkylight, value: .bool(true))))
        }
        try Checks.rejects(.busy, "pending write budget is bounded") { _ = try full.accept(.settingsSet(ControlSettingsWrite(ticket: ControlTicket(instance: instance), key: .showsSkylight, value: .bool(true)))) }
        let first = try ControlPagination.page(["a", "b", "c"], request: ControlPage(limit: 2), scope: "filter")
        let second = try ControlPagination.page(["a", "b", "c"], request: ControlPage(limit: 2, cursor: first.nextCursor), scope: "filter")
        try Checks.check(first.items + second.items == ["a", "b", "c"], "metadata pagination preserves order")
        try Checks.rejects(.cursorInvalid, "metadata mutation invalidates cursor") { _ = try ControlPagination.page(["a", "b", "d"], request: ControlPage(limit: 2, cursor: first.nextCursor), scope: "filter") }
        try Checks.rejects(.cursorInvalid, "filter mutation invalidates cursor") { _ = try ControlPagination.page(["a", "b", "c"], request: ControlPage(limit: 2, cursor: first.nextCursor), scope: "other") }
        let invalid = ControlSettingsWrite(ticket: ticket, key: .showsSkylight, value: .textGeneration(.off))
        let decoded = try LocalControl.decoder().decode(ControlSettingsWrite.self, from: LocalControl.encoder().encode(invalid))
        try Checks.check(decoded.key == .showsSkylight, "typed settings retain key for application-level pair validation")
    }

    static func transportConcurrencyAndResources(_ root: URL) async throws {
        print("ROUND 4: synthetic resource/regression envelope (not App performance)")
        let directory = root.appendingPathComponent("q", isDirectory: true)
        func cpuSeconds() -> Double {
            var time = timespec()
            clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &time)
            return Double(time.tv_sec) + Double(time.tv_nsec) / 1_000_000_000
        }
        let disabledFDs = try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count
        let disabledCPUStart = cpuSeconds()
        try await Task.sleep(for: .milliseconds(200))
        let disabledCPU = cpuSeconds() - disabledCPUStart
        let instance = UUID()
        let service = SyntheticService(instance: instance)
        let server = ControlSocketServer(directory: directory, welcome: ControlWelcome(edition: .dev, instance: instance)) { await service.request($0) }
        try server.start()
        defer { server.stop() }
        let enabledCPUStart = cpuSeconds()
        try await Task.sleep(for: .milliseconds(200))
        let enabledCPU = cpuSeconds() - enabledCPUStart
        let enabledFDs = try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count
        try Checks.check(enabledFDs <= disabledFDs + 3, "enabled-idle descriptor budget is listener plus lease")
        print("MEASURE synthetic 200ms idle phases: disabled CPU=\(disabledCPU)s, enabled CPU=\(enabledCPU)s; disabled fd=\(disabledFDs), enabled fd=\(enabledFDs). No App process measured.")
        let idle = await service.counts()
        try Checks.check(idle.queries == 0 && idle.writes == 0, "enabled-idle transport never polls handler")
        let ticket = ControlTicket(instance: instance)
        let write = ControlCommand.create(ControlCreate(ticket: ticket, projectID: nil, workspace: .local, provider: "synthetic"))
        let responses = try await withThrowingTaskGroup(of: ControlResponse.self, returning: [ControlResponse].self) { group in
            for _ in 0..<4 {
                group.addTask {
                    let client = try ControlClient(edition: .dev, directory: directory)
                    return try client.request(write)
                }
            }
            var responses: [ControlResponse] = []
            for try await response in group { responses.append(response) }
            return responses
        }
        try Checks.check(responses.allSatisfy { $0.error == nil }, "simultaneous duplicate writes receive receipts")
        let counts = await service.counts()
        try Checks.check(counts.writes == 1, "simultaneous duplicates execute synthetic write once")
        try await Task.sleep(for: .milliseconds(100))
        let before = try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count
        let started = ContinuousClock.now
        for _ in 0..<100 {
            let client = try ControlClient(edition: .dev, directory: directory)
            let response = try client.request(.info)
            guard response.error == nil else { throw Checks.CheckFailure(name: "controlled query") }
        }
        let elapsed = ContinuousClock.now - started
        try await Task.sleep(for: .milliseconds(200))
        let after = try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count
        try Checks.check(after <= before + 2, "controlled reconnect queries do not leak descriptors")
        print("MEASURE synthetic transport: 100 reconnect/handshake/info queries in \(elapsed); fd before=\(before), after=\(after). Not App performance evidence.")
        let final = await service.counts()
        try Checks.check(final.queries == 100 && final.writes == 1, "controlled queries cause no synthetic writes")
        // A dropped reply is not permission to repeat the mutation.
        let dropped = ControlTicket(instance: instance)
        do {
            let raw = try RawClient(directory: directory)
            _ = try raw.hello(ControlHello(edition: .dev))
            let request = ControlRequest(instance: instance, command: .settingsSet(ControlSettingsWrite(ticket: dropped, key: .showsSkylight, value: .bool(false))))
            try raw.write(ControlSocket.frame(LocalControl.encoder().encode(request)))
            usleep(30_000)
        }
        let client = try ControlClient(edition: .dev, directory: directory)
        let receipt = try client.request(.operation(dropped))
        guard case .operation(let outcome) = receipt.result else { throw Checks.CheckFailure(name: "disconnect query") }
        try Checks.check(outcome.state == .accepted, "disconnect preserves accepted synthetic operation outcome")
    }
}
