import Darwin
import Foundation
import OSLog

/// Codex's packaged WebRTC voice helper (`codex-voice-host`), driven over its bounded
/// stdio protocol: a big-endian `u32` length, then that many bytes of JSON, one reply per
/// request. Audio, echo cancellation, interruption and encrypted media stay inside that
/// native process; only SDP signalling, controls and level meters cross the pipe.
///
/// Ported from Zeron (https://github.com/zeronsh/zeron, MIT), `crates/voice-media/src/lib.rs`,
/// whose protocol and runtime environment are adapted from OpenAI Codex
/// (`codex-rs/realtime-webrtc`, Apache-2.0). See THIRD_PARTY_NOTICES.md. Tivano never
/// ships this runtime: it runs the helper of the user's own Codex installation.
/// Tivano adaptation: cancellation closes the bounded pipe; shutdown kills stuck helpers;
/// device selection also resolves the version from Codex's package manifest.
final class CodexVoiceHost: @unchecked Sendable {
    private static let log = Logger(subsystem: "dev.tivano.Tivano", category: "voice-host")
    private static let maxFrame = 128 * 1024
    private static let replyTypes: Set<String> = [
        "ready", "runtimeReady", "offer", "transportReady", "transportTimedOut",
        "deviceList", "devicesOpened", "audioControlsApplied", "audioState", "closed",
    ]

    private let process: Process
    private let input: FileHandle
    private let output: FileHandle
    /// One exchange at a time: a request and its reply never interleave with another's.
    private let queue = DispatchQueue(label: "tivano.voice-host")
    private let lock = NSLock()
    private var closed = false
    /// Whether `openDevices` takes a device selection (Codex 0.161 and later).
    private let deviceSelection: Bool

    private init(process: Process, input: FileHandle, output: FileHandle, deviceSelection: Bool) {
        self.process = process
        self.input = input
        self.output = output
        self.deviceSelection = deviceSelection
    }

    deinit { close(force: true) }

    var isClosed: Bool { lock.withLock { closed } }

    // MARK: - Locating the helper

    /// The helper shipped inside the device's Codex installation (layout 1, version 0.159
    /// or later), resolved from its `codex` executable: the standalone layout keeps it
    /// beside `bin/codex`, the npm package in its platform package's `vendor` folder.
    /// The helper only initializes from a `codex-resources/voice` directory.
    static func installedHelper(codexExecutable: URL?) throws -> URL {
        var roots: [URL] = []
        if let codexExecutable {
            let binary = codexExecutable.resolvingSymlinksInPath()
            let packageRoot = binary.deletingLastPathComponent().deletingLastPathComponent()
            roots.append(packageRoot)
            // `@openai/codex/bin/codex.js` dispatches to `@openai/codex-darwin-<arch>`, nested
            // under the package or hoisted beside it.
            let platform = "codex-darwin-arm64"
            let target = "aarch64-apple-darwin"
            for modules in [packageRoot.appendingPathComponent("node_modules/@openai"), packageRoot.deletingLastPathComponent()] {
                roots.append(modules.appendingPathComponent(platform).appendingPathComponent("vendor").appendingPathComponent(target))
            }
        }
        roots.append(URL(fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/codex-cli"))
        var sawOldLayout = false
        for root in roots {
            guard let data = try? Data(contentsOf: root.appendingPathComponent("codex-package.json")),
                  let manifest = JSONValue.parse(data) else { continue }
            guard manifest["layoutVersion"]?.int == 1, let version = manifest["version"]?.string,
                  Self.version(version, atLeast: [0, 159, 0]) else {
                sawOldLayout = true
                continue
            }
            let helper = root.appendingPathComponent("codex-resources/voice/bin/codex-voice-host")
            if FileManager.default.isExecutableFile(atPath: helper.path) { return helper }
        }
        throw sawOldLayout ? VoiceRejection.unsupported : VoiceRejection.nativeRuntimeUnavailable
    }

    private static func version(_ text: String, atLeast minimum: [Int]) -> Bool {
        let parts = text.split(separator: "-").first.map { $0.split(separator: ".").map { Int($0) ?? 0 } } ?? []
        for index in 0..<3 {
            let value = index < parts.count ? parts[index] : 0
            if value != minimum[index] { return value > minimum[index] }
        }
        return true
    }

    /// Codex 0.161 requires a device selection even for the default devices; older
    /// helpers reject the field despite sharing the protocol version.
    private static func takesDeviceSelection(_ helper: URL) -> Bool {
        let voiceRoot = helper.deletingLastPathComponent().deletingLastPathComponent()
        let manifest = (try? Data(contentsOf: voiceRoot.appendingPathComponent("manifest.json"))).flatMap { JSONValue.parse($0) }
        let packageRoot = voiceRoot.deletingLastPathComponent().deletingLastPathComponent()
        let package = (try? Data(contentsOf: packageRoot.appendingPathComponent("codex-package.json"))).flatMap { JSONValue.parse($0) }
        guard let version = manifest?["appVersion"]?.string ?? package?["version"]?.string else { return false }
        return Self.version(version, atLeast: [0, 161, 0])
    }

    // MARK: - Lifecycle

    /// A fixed environment allowlist, as Codex launches it: never API keys, dynamic loader
    /// or plugin overrides.
    private static func environment() -> [String: String] {
        let allowed: Set<String> = [
            "HOME", "TMPDIR", "XDG_RUNTIME_DIR", "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY",
            "SSL_CERT_FILE", "SSL_CERT_DIR", "REQUESTS_CA_BUNDLE", "CURL_CA_BUNDLE",
        ]
        var environment = ProcessInfo.processInfo.environment.filter { allowed.contains($0.key.uppercased()) }
        for key in ["GST_PLUGIN_PATH", "GST_PLUGIN_PATH_1_0", "GST_PLUGIN_SYSTEM_PATH", "GST_PLUGIN_SYSTEM_PATH_1_0"] {
            environment[key] = ""
        }
        environment["GST_REGISTRY"] = "/dev/null"
        environment["GST_REGISTRY_UPDATE"] = "no"
        environment["GST_REGISTRY_FORK"] = "no"
        return environment
    }

    private static func makeProcess(_ helper: URL, arguments: [String]) -> Process {
        let process = Process()
        process.executableURL = helper
        process.arguments = arguments
        process.environment = environment()
        process.currentDirectoryURL = helper.deletingLastPathComponent()
        process.standardError = FileHandle.nullDevice
        return process
    }

    private static func makeNonblocking(_ handle: FileHandle) throws {
        let flags = fcntl(handle.fileDescriptor, F_GETFL)
        guard flags >= 0, fcntl(handle.fileDescriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw VoiceRejection.nativeRuntimeUnavailable
        }
    }

    /// Poll in short slices so cancellation does not depend on the helper (or an
    /// inherited pipe in a descendant) exiting. The descriptors stay on their I/O queue.
    private static func waitForIO(_ handle: FileHandle, events: Int16, deadline: DispatchTime, stopped: () -> Bool) -> Bool {
        while !stopped(), DispatchTime.now() < deadline {
            var descriptor = pollfd(fd: handle.fileDescriptor, events: events, revents: 0)
            let result = poll(&descriptor, 1, 100)
            if result > 0 { return descriptor.revents & (events | Int16(POLLHUP | POLLERR)) != 0 }
            if result < 0, errno != EINTR { return false }
        }
        return false
    }

    /// Starts the helper and its runtime. A helper that cannot start its runtime (a
    /// library that no longer matches its `runtime.json`) exits here: that is the
    /// runtime, not the call.
    static func open(helper: URL) async throws -> CodexVoiceHost {
        let commit: String
        do {
            commit = try await buildCommit(helper)
        } catch {
            throw VoiceRejection.nativeRuntimeUnavailable
        }
        let process = makeProcess(helper, arguments: [])
        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        do {
            try makeNonblocking(stdin.fileHandleForWriting)
            try makeNonblocking(stdout.fileHandleForReading)
            try process.run()
        } catch {
            throw VoiceRejection.nativeRuntimeUnavailable
        }
        try? stdin.fileHandleForReading.close()
        try? stdout.fileHandleForWriting.close()
        let host = CodexVoiceHost(
            process: process,
            input: stdin.fileHandleForWriting,
            output: stdout.fileHandleForReading,
            deviceSelection: takesDeviceSelection(helper)
        )
        do {
            try await host.expect(["type": "hello", "protocol": 1, "buildCommit": .string(commit)], reply: "ready", seconds: 30)
            try await host.expect(["type": "initializeRuntime"], reply: "runtimeReady", seconds: 30)
        } catch {
            host.close()
            let reason = (error as? VoiceRejection) ?? .protocol
            throw reason == .protocol ? VoiceRejection.nativeRuntimeUnavailable : reason
        }
        return host
    }

    private static func buildCommit(_ helper: URL) async throws -> String {
        let process = makeProcess(helper, arguments: ["--build-commit"])
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardInput = FileHandle.nullDevice
        try makeNonblocking(stdout.fileHandleForReading)
        try process.run()
        try? stdout.fileHandleForWriting.close()
        let watchdog = Task.detached {
            try? await Task.sleep(for: .seconds(5))
            if !Task.isCancelled { Self.terminate(process) }
        }
        defer { watchdog.cancel() }
        let data = await withTaskCancellationHandler {
            await Task.detached {
                let output = stdout.fileHandleForReading
                defer { try? output.close() }
                let deadline = DispatchTime.now() + 5
                var data = Data()
                var buffer = [UInt8](repeating: 0, count: 129)
                while data.count < 129, Self.waitForIO(output, events: Int16(POLLIN), deadline: deadline, stopped: { false }) {
                    let count = Darwin.read(output.fileDescriptor, &buffer, 129 - data.count)
                    if count > 0 { data.append(contentsOf: buffer.prefix(count)) }
                    else if count == 0 { break }
                    else if errno != EINTR, errno != EAGAIN { break }
                }
                if data.count >= 129 || DispatchTime.now() >= deadline { Self.terminate(process) }
                process.waitUntilExit()
                return data
            }.value
        } onCancel: {
            // App termination cannot wait for the delayed force-kill.
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        guard !Task.isCancelled else { throw CancellationError() }
        guard let text = String(data: data, encoding: .utf8) else { throw VoiceRejection.nativeRuntimeUnavailable }
        let commit = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0, data.count < 129, !commit.isEmpty, commit.count <= 128 else {
            throw VoiceRejection.nativeRuntimeUnavailable
        }
        return commit
    }

    private static func terminate(_ process: Process) {
        guard process.isRunning else { return }
        kill(process.processIdentifier, SIGTERM)
        // A stuck native runtime must not survive hang-up or app exit.
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }

    /// Synchronous local shutdown, independent of any exchange still waiting on the pipe.
    func close(force: Bool = false) {
        let wasOpen = lock.withLock {
            defer { closed = true }
            return !closed
        }
        if force, process.isRunning { kill(process.processIdentifier, SIGKILL) }
        guard wasOpen else { return }
        Self.terminate(process)
        let input = input, output = output, process = process
        queue.async {
            try? input.close()
            try? output.close()
            process.waitUntilExit()
        }
    }

    // MARK: - Exchanges

    /// One request and its reply. A timed-out or failed exchange invalidates the pipe,
    /// so the helper is stopped rather than left half-read.
    func exchange(_ message: [String: JSONValue], seconds: Double) async throws -> JSONValue {
        guard !isClosed else { throw VoiceRejection.protocol }
        let payload = JSONValue.object(message).data()
        guard payload.count <= Self.maxFrame else { throw VoiceRejection.overflow }
        let deadline = DispatchTime.now() + seconds
        let timeout = Task.detached { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            if !Task.isCancelled { self?.close() }
        }
        defer { timeout.cancel() }
        let result: Result<JSONValue, VoiceRejection> = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                queue.async { [self] in
                    let result = roundTrip(payload, deadline: deadline)
                    if case .failure = result { close() }
                    continuation.resume(returning: result)
                }
            }
        } onCancel: {
            self.close(force: true)
        }
        switch result {
        case .success(let value): return value
        case .failure(let reason):
            close()
            throw reason
        }
    }

    private func roundTrip(_ payload: Data, deadline: DispatchTime) -> Result<JSONValue, VoiceRejection> {
        guard !isClosed else { return .failure(.protocol) }
        var length = UInt32(payload.count).bigEndian
        var frame = Data(bytes: &length, count: 4)
        frame.append(payload)
        // TivanoApp ignores SIGPIPE before any provider starts; Darwin.write reports
        // EPIPE and supports partial nonblocking writes without FileHandle exceptions.
        var written = 0
        while written < frame.count {
            guard Self.waitForIO(input, events: Int16(POLLOUT), deadline: deadline, stopped: { isClosed }) else { return .failure(.protocol) }
            let count = frame.withUnsafeBytes { bytes in
                Darwin.write(input.fileDescriptor, bytes.baseAddress?.advanced(by: written), bytes.count - written)
            }
            if count > 0 { written += count }
            else if count == 0 || (errno != EINTR && errno != EAGAIN) { return .failure(.protocol) }
        }
        while !isClosed, DispatchTime.now() < deadline {
            guard let header = readExactly(4, deadline: deadline) else { return .failure(.protocol) }
            let size = header.reduce(0) { $0 << 8 | Int($1) }
            guard size > 0, size <= Self.maxFrame else { return .failure(.overflow) }
            guard let body = readExactly(size, deadline: deadline), let value = JSONValue.parse(body) else { return .failure(.protocol) }
            guard let type = value["type"]?.string, Self.replyTypes.contains(type) else { continue }
            return .success(value)
        }
        return .failure(.protocol)
    }

    private func readExactly(_ count: Int, deadline: DispatchTime) -> Data? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: min(count, 8192))
        while data.count < count {
            guard Self.waitForIO(output, events: Int16(POLLIN), deadline: deadline, stopped: { isClosed }) else { return nil }
            let requested = min(buffer.count, count - data.count)
            let size = Darwin.read(output.fileDescriptor, &buffer, requested)
            if size > 0 { data.append(contentsOf: buffer.prefix(size)) }
            else if size == 0 || (errno != EINTR && errno != EAGAIN) { return nil }
        }
        return data
    }

    func expect(_ message: [String: JSONValue], reply: String, seconds: Double) async throws {
        let answer = try await exchange(message, seconds: seconds)
        guard answer["type"]?.string == reply else {
            Self.log.notice("voice helper answered \(answer["type"]?.string ?? "nothing", privacy: .public) to \(message["type"]?.string ?? "?", privacy: .public)")
            close()
            throw VoiceRejection.protocol
        }
    }

    /// The SDP offer for the call's WebRTC transport.
    func startTransport() async throws -> String {
        let offer = try await exchange(["type": "startTransport"], seconds: 20)
        guard offer["type"]?.string == "offer", let sdp = offer["sdp"]?.string, !sdp.isEmpty, sdp.utf8.count <= 65_536 else {
            throw VoiceRejection.protocol
        }
        return sdp
    }

    func applyAnswer(_ sdp: String) async throws {
        try await expect(["type": "applyAnswer", "sdp": .string(sdp)], reply: "transportReady", seconds: 20)
    }

    func openDevices() async throws {
        var message: [String: JSONValue] = ["type": "openDevices"]
        // Default selection is {} in Codex 0.161's bounded protocol:
        // https://github.com/openai/codex/blob/rust-v0.161.0/codex-rs/realtime-webrtc/src/protocol.rs
        if deviceSelection { message["selection"] = .object([:]) }
        do {
            try await expect(message, reply: "devicesOpened", seconds: 5)
        } catch {
            throw VoiceRejection.deviceUnavailable
        }
    }

    func setControls(microphoneMuted: Bool, speakerSuppressed: Bool = false) async throws {
        try await expect([
            "type": "setAudioControls",
            "controls": ["microphoneMuted": .bool(microphoneMuted), "speakerSuppressed": .bool(speakerSuppressed)],
        ], reply: "audioControlsApplied", seconds: 5)
    }

    /// Microphone and speaker peaks, 0…65535.
    func levels() async throws -> (microphone: UInt16, speaker: UInt16) {
        let state = try await exchange(["type": "inspectAudio"], seconds: 5)
        guard state["type"]?.string == "audioState",
              let microphone = state["state"]?["microphonePeak"]?.int, let speaker = state["state"]?["speakerPeak"]?.int else {
            throw VoiceRejection.protocol
        }
        return (UInt16(clamping: microphone), UInt16(clamping: speaker))
    }
}
