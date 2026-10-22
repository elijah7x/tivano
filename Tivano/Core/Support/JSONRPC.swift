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
    private let strictResponses: Bool
    private var protocolFailure: String?
    private var nextID = 1
    private var pending: [RPCID: CheckedContinuation<JSONValue, Error>] = [:]
    private var readTask: Task<Void, Never>?

    init(process: StdioProcess, sendsVersion: Bool, strictResponses: Bool = false) {
        self.process = process
        self.sendsVersion = sendsVersion
        self.strictResponses = strictResponses
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
            throw RPCError(code: -32000, message: AppText.localized("The agent process is not running."))
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
        if strictResponses, !Self.isValidEnvelope(message) {
            protocolFailure = AppText.localized("The agent sent an invalid JSON-RPC message.")
            process.terminate()
            didClose()
            return
        }
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
        guard let rawID = object["id"] else { return }
        if rawID == .null {
            // A server that never read the request's id answers an error with `"id":
            // null`. With one request in flight it can only be that request's answer.
            guard let error = object["error"], !error.isNull else { return }
            let failure = Self.rpcError(error)
            if pending.count == 1, let only = pending.first {
                pending.removeValue(forKey: only.key)
                only.value.resume(throwing: failure)
            } else {
                NSLog("Tivano ignored a JSON-RPC error with a null response id (code %d): %@", failure.code, failure.message)
            }
            return
        }
        guard let id = RPCID(rawID), let continuation = pending.removeValue(forKey: id) else { return }
        if let error = object["error"], !error.isNull {
            continuation.resume(throwing: Self.rpcError(error))
        } else {
            continuation.resume(returning: object["result"] ?? .null)
        }
    }

    /// Opt-in validation leaves legacy CLI dialects unchanged. Unknown methods and late
    /// responses remain forward-compatible; malformed envelopes do not become null results.
    private static func isValidEnvelope(_ message: JSONValue) -> Bool {
        guard let object = message.object, object["jsonrpc"]?.string == "2.0" else { return false }
        if let method = object["method"]?.string {
            guard !method.isEmpty, object["result"] == nil, object["error"] == nil else { return false }
            return object["id"].map { RPCID($0) != nil } ?? true
        }
        let hasResult = object["result"] != nil
        let error = object["error"]
        let hasError = error != nil && error != .null
        // An error may answer with `"id": null` when the request's own id was never read.
        guard let id = object["id"], RPCID(id) != nil || (id == .null && hasError) else { return false }
        guard hasResult != hasError else { return false }
        return !hasError || (error?["code"]?.int != nil && error?["message"]?.string != nil)
    }

    private static func rpcError(_ error: JSONValue) -> RPCError {
        RPCError(
            code: error["code"]?.int ?? -32603,
            message: error["message"]?.string ?? "The agent returned an error.",
            data: error["data"]
        )
    }

    private func didClose() {
        guard !isClosed else { return }
        isClosed = true
        var tail = protocolFailure ?? process.failureReason ?? process.errorTail.trimmed
        if strictResponses, tail.isEmpty, let status = process.exitStatus, status != 0 {
            tail = String(format: AppText.localized("The agent exited with status %d."), status)
        }
        let failure = RPCError(code: -32000, message: tail.isEmpty ? AppText.localized("The agent process exited.") : tail)
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
