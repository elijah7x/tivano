import Foundation

struct SSEByteFramer: Sendable {
    enum NewlineMode: Sendable {
        case lf
        case sse
    }

    enum Error: Swift.Error, Equatable, Sendable {
        case lineTooLarge
    }

    enum LineTerminator: Sendable {
        case lf
        case cr
    }

    struct Line: Sendable {
        let content: Data
        let raw: Data
        let terminator: LineTerminator?
    }

    enum Frame: Sendable {
        case line(Line)
        case pairedLineFeed(Data)
    }

    let byteLimit: Int
    private let newlineMode: NewlineMode
    private var buffer = Data()
    private var scanned = 0
    private var afterCR = false

    init(byteLimit: Int, newlineMode: NewlineMode = .sse) {
        precondition(byteLimit >= 0)
        self.byteLimit = byteLimit
        self.newlineMode = newlineMode
    }

    var bufferedByteCount: Int { buffer.count }

    mutating func append(_ chunk: Data) throws -> [Frame] {
        buffer.append(chunk)
        var frames: [Frame] = []
        var start = buffer.startIndex
        var search = buffer.index(start, offsetBy: scanned)

        while true {
            if afterCR {
                guard search < buffer.endIndex else { break }
                afterCR = false
                if buffer[search] == 0x0A {
                    let end = buffer.index(after: search)
                    frames.append(.pairedLineFeed(buffer[search..<end]))
                    start = end
                    search = start
                    continue
                }
            }

            // One pass per line: searching for CR and LF separately would rescan the whole
            // remaining buffer for a CR that LF-only streams never send.
            let delimiter = newlineMode == .sse
                ? buffer[search...].firstIndex { $0 == 0x0A || $0 == 0x0D }
                : buffer[search...].firstIndex(of: 0x0A)
            guard let delimiter else {
                search = buffer.endIndex
                break
            }
            guard delimiter - start <= byteLimit else { throw Error.lineTooLarge }

            let byte = buffer[delimiter]
            let end = buffer.index(after: delimiter)
            let terminator: LineTerminator = byte == 0x0D ? .cr : .lf
            frames.append(.line(Line(
                content: buffer[start..<delimiter],
                raw: buffer[start..<end],
                terminator: terminator
            )))
            start = end
            search = start
            afterCR = newlineMode == .sse && byte == 0x0D
        }

        guard buffer.endIndex - start <= byteLimit else { throw Error.lineTooLarge }
        scanned = search - start
        if start != buffer.startIndex {
            buffer = Data(buffer[start...])
        }
        return frames
    }

    mutating func finish() throws -> Line? {
        defer {
            buffer = Data()
            scanned = 0
            afterCR = false
        }
        guard !buffer.isEmpty else { return nil }
        guard buffer.count <= byteLimit else { throw Error.lineTooLarge }
        return Line(content: buffer, raw: buffer, terminator: nil)
    }
}

struct SSEChunkedResponse: Sendable {
    let chunks: AsyncThrowingStream<Data, Error>
    let response: URLResponse
    let task: URLSessionDataTask
}

enum SSEChunkReader {
    static func read(for request: URLRequest, session: URLSession = .shared) async throws -> SSEChunkedResponse {
        let (chunks, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        let delegate = Delegate(continuation: continuation)
        // A task delegate on the caller's session keeps its connection pool (HTTP/2 and TLS
        // reuse) and its own session delegate; a session per request would lose both.
        let task = session.dataTask(with: request)
        task.delegate = delegate
        delegate.attach(task)
        continuation.onTermination = { _ in delegate.cancel() }

        do {
            let response = try await withTaskCancellationHandler {
                try Task.checkCancellation()
                return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URLResponse, Error>) in
                    delegate.start(continuation)
                }
            } onCancel: {
                delegate.cancel()
            }
            try Task.checkCancellation()
            return SSEChunkedResponse(chunks: chunks, response: response, task: task)
        } catch {
            task.cancel()
            throw error
        }
    }

    private final class Delegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private let chunks: AsyncThrowingStream<Data, Error>.Continuation
        private var responseContinuation: CheckedContinuation<URLResponse, Error>?
        private var task: URLSessionDataTask?
        private var cancelled = false

        init(continuation: AsyncThrowingStream<Data, Error>.Continuation) {
            chunks = continuation
        }

        func attach(_ task: URLSessionDataTask) {
            lock.lock()
            self.task = task
            let cancelled = cancelled
            lock.unlock()
            if cancelled { task.cancel() }
        }

        func start(_ continuation: CheckedContinuation<URLResponse, Error>) {
            lock.lock()
            if cancelled {
                lock.unlock()
                continuation.resume(throwing: CancellationError())
                return
            }
            responseContinuation = continuation
            let task = self.task
            lock.unlock()
            task?.resume()
        }

        func cancel() {
            lock.lock()
            if cancelled {
                lock.unlock()
                return
            }
            cancelled = true
            let task = self.task
            let responseContinuation = self.responseContinuation
            self.responseContinuation = nil
            lock.unlock()
            task?.cancel()
            responseContinuation?.resume(throwing: CancellationError())
            chunks.finish(throwing: CancellationError())
        }

        func urlSession(
            _ session: URLSession,
            dataTask: URLSessionDataTask,
            didReceive response: URLResponse,
            completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
        ) {
            lock.lock()
            let continuation = responseContinuation
            responseContinuation = nil
            let cancelled = cancelled
            lock.unlock()
            if cancelled {
                completionHandler(.cancel)
                continuation?.resume(throwing: CancellationError())
            } else {
                completionHandler(.allow)
                continuation?.resume(returning: response)
            }
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            lock.lock()
            let cancelled = cancelled
            lock.unlock()
            if !cancelled && !data.isEmpty {
                chunks.yield(data)
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            lock.lock()
            let continuation = responseContinuation
            responseContinuation = nil
            self.task = nil
            let cancelled = cancelled
            lock.unlock()
            if let continuation {
                continuation.resume(throwing: error ?? URLError(.badServerResponse))
            }
            if !cancelled {
                chunks.finish(throwing: error)
            }
        }
    }
}
