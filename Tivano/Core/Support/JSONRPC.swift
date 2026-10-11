import Foundation

enum RPCID: Hashable, Sendable {
    case int(Int)
    case string(String)

    init?(_ value: JSONValue) {
        switch value {
        case .int(let id): self = .int(id)
        case .double(let id):
            guard let integer = Int(exactly: id) else { return nil }
            self = .int(integer)
        case .string(let id): self = .string(id)
        default: return nil
        }
    }

    var json: JSONValue {
        switch self {
        case .int(let id): .int(id)
        case .string(let id): .string(id)
        }
    }

    var key: String {
        switch self {
        case .int(let id): String(id)
        case .string(let id): id
        }
    }
}

struct RPCError: LocalizedError, Sendable {
    var code: Int
    var message: String
    var data: JSONValue?

    var errorDescription: String? { message }
}

/// JSON-RPC 2.0 over a stdio process. Codex omits the `jsonrpc` member, ACP agents require it.
@MainActor
final class JSONRPCConnection {
    var onNotification: ((String, JSONValue) -> Void)?
    var onRequest: ((RPCID, String, JSONValue) -> Void)?
    var onClose: ((String) -> Void)?

    private(set) var isClosed = false
    private let process: StdioProcess
    private let sendsVersion: Bool
    private var nextID = 1
    private var pending: [RPCID: CheckedContinuation<JSONValue, Error>] = [:]
    private var readTask: Task<Void, Never>?

    init(process: StdioProcess, sendsVersion: Bool) {
        self.process = process
        self.sendsVersion = sendsVersion
    }

    func start() throws {
        try process.start()
        let messages = process.messages
        readTask = Task { [weak self] in
            for await message in messages {
                guard let self else { return }
                if self.process.failureReason != nil { break }
                self.handle(message)
            }
            self?.didClose()
        }
    }

    func request(_ method: String, _ params: JSONValue = .null) async throws -> JSONValue {
        if isClosed {
            throw RPCError(code: -32000, message: "The agent process is not running.")
        }
        let id = RPCID.int(nextID)
        nextID += 1
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                pending[id] = continuation
                write(["id": id.json, "method": .string(method), "params": params])
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.pending.removeValue(forKey: id)?.resume(throwing: CancellationError())
            }
        }
    }

    func notify(_ method: String, _ params: JSONValue = .null) {
        write(["method": .string(method), "params": params])
    }

    func respond(to id: RPCID, result: JSONValue, completion: (@MainActor (Bool) -> Void)? = nil) {
        write(["id": id.json, "result": result], completion: completion)
    }

    func respond(to id: RPCID, errorCode code: Int, message: String, completion: (@MainActor (Bool) -> Void)? = nil) {
        write(["id": id.json, "error": ["code": .int(code), "message": .string(message)]], completion: completion)
    }

    func close() {
        process.terminate()
        didClose()
    }

    func closeAndWait(timeout: TimeInterval) async {
        close()
        await process.terminateAndWait(timeout: timeout)
    }

    private func write(_ message: [String: JSONValue], completion: (@MainActor (Bool) -> Void)? = nil) {
        guard !isClosed else { completion?(false); return }
        var message = message
        if message["params"] == .null { message.removeValue(forKey: "params") }
        if sendsVersion { message["jsonrpc"] = "2.0" }
        process.send(.object(message)) { [weak self] succeeded in
            Task { @MainActor [weak self] in
                if !succeeded { self?.didClose() }
                completion?(succeeded)
            }
        }
    }

    private func handle(_ message: JSONValue) {
        guard let object = message.object else { return }
        if let method = object["method"]?.string {
            let params = object["params"] ?? .null
            if let rawID = object["id"], let id = RPCID(rawID) {
                if let onRequest {
                    onRequest(id, method, params)
                } else {
                    respond(to: id, errorCode: -32601, message: "Method not found")
                }
            } else {
                onNotification?(method, params)
            }
            return
        }
        guard let rawID = object["id"], let id = RPCID(rawID),
              let continuation = pending.removeValue(forKey: id) else { return }
        if let error = object["error"], !error.isNull {
            continuation.resume(throwing: RPCError(
                code: error["code"]?.int ?? -32603,
                message: error["message"]?.string ?? "The agent returned an error.",
                data: error["data"]
            ))
        } else {
            continuation.resume(returning: object["result"] ?? .null)
        }
    }

    private func didClose() {
        guard !isClosed else { return }
        isClosed = true
        let tail = process.failureReason ?? process.errorTail.trimmed
        let failure = RPCError(code: -32000, message: tail.isEmpty ? "The agent process exited." : tail)
        let waiting = Array(pending.values)
        pending.removeAll()
        for continuation in waiting { continuation.resume(throwing: failure) }
        onClose?(tail)
    }
}

extension RPCError {
    init(code: Int, message: String) {
        self.init(code: code, message: message, data: nil)
    }
}
