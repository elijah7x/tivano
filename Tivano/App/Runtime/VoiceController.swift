import AppKit
import AVFoundation
import OSLog
import SystemConfiguration

/// Voice agent mode: a spoken call with a Codex orchestrator.
///
/// The call runs in a Codex chat of its own ("Voice session") in the current project, or
/// joins an existing Codex chat from its composer; either way it
/// survives moving between threads; only an explicit end, a provider failure or quitting
/// closes it. No automatic reconnect and no microphone resume. Speech goes through Codex's
/// realtime voice (`thread/realtime/*` on the chat's own app-server), whose audio runs in
/// the native helper of the user's Codex installation (`CodexVoiceHost`); what the voice
/// hands to Codex runs as turns of the chat, and the finished transcript lands in it too.
///
/// Ported from Zeron (https://github.com/zeronsh/zeron, MIT): `crates/ui/src/voice.rs`,
/// `crates/voice-session` and `crates/harness/src/codex/realtime.rs`. See THIRD_PARTY_NOTICES.md.
@MainActor
@Observable
final class VoiceController {
    private static let log = Logger(subsystem: "dev.tivano.Tivano", category: "voice")

    private(set) var phase: VoicePhase = .closed
    /// The orchestrator chat, once the call has made it.
    private(set) var threadID: UUID?
    private(set) var reason: VoiceRejection?
    private(set) var muted = false
    /// The assistant is audibly speaking (speaker peaks, with hysteresis).
    private(set) var playing = false
    /// The newest speaker turn's live text, then its final.
    private(set) var caption = VoiceCaption()
    private(set) var microphoneLevel: UInt16 = 0
    private(set) var speakerLevel: UInt16 = 0
    /// The full-window stage is presented over the chat.
    private(set) var stageOpen = false
    /// When the call first became active; drives the stage's call timer.
    private(set) var activeSince: Date?
    /// The voice styles Codex offers, refreshed by each call.
    private(set) var voices: [String] = VoiceCatalog.defaultVoices
    /// The Mac the call's audio runs on, shown beside the call timer.
    let hostName = (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? "This Mac"

    @ObservationIgnored private weak var app: AppModel?
    @ObservationIgnored private var epoch = 0
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var levelsTask: Task<Void, Never>?
    /// Fails a start still connecting `startTimeout` seconds after the microphone opened.
    @ObservationIgnored private var startDeadline: Task<Void, Never>?
    private static let startTimeout: Double = 90
    @ObservationIgnored private var session: CodexSession?
    @ObservationIgnored private var host: CodexVoiceHost?
    /// The provider side of the call is live and owes a `thread/realtime/stop`.
    @ObservationIgnored private var serverLive = false
    @ObservationIgnored private var speakerActivity = SpeakerActivity()
    /// This call played its start sound and owes its end sound.
    @ObservationIgnored private var cued = false
    /// The realtime session this call asked for, and the signals its start waits on.
    @ObservationIgnored private var realtimeSessionID: String?
    @ObservationIgnored private var startSignals: AsyncStream<StartSignal>.Continuation?
    @ObservationIgnored private var terminationObserver: NSObjectProtocol?

    private enum StartSignal {
        case accepted
        case unsupported
        case answer(String)
        case failed(VoiceRejection)
    }

    init(app: AppModel) {
        self.app = app
        terminationObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.shutdown() }
        }
    }

    // MARK: - What the call shows

    /// A call is underway (including its preparation and native stop).
    var isLive: Bool { phase.isLive }

    /// Keep the entry available so missing Codex is explained on an attempted call.
    var isOffered: Bool {
        guard let app, app.settings.isVoiceEnabled else { return false }
        return app.isLibraryLoaded || isLive || reason != nil
    }

    /// What the orchestrator's chat is doing.
    var work: VoiceWork {
        guard let threadID, let runtime = app?.existingRuntime(for: threadID) else { return .idle }
        if !runtime.approvals.isEmpty || !runtime.questions.isEmpty { return .awaitingInput }
        return runtime.isRunning ? .working : .idle
    }

    /// The orb for the call. Speaking wins over work and mute, so a muted user still
    /// sees the assistant answer.
    var orbState: OrbState {
        switch phase {
        case .checking, .starting, .stopping: return .connecting
        case .closed, .failed: return .breathing
        case .active: break
        }
        if playing { return .composing }
        switch work {
        case .awaitingInput: return .solving
        case .working: return .working
        case .idle: return muted ? .breathing : .listening
        }
    }

    /// Normalized 0…1 microphone loudness; zero while muted.
    var microphone: Float { muted ? 0 : Float(microphoneLevel) / Float(UInt16.max) }
    /// Normalized 0…1 speaker peak.
    var speaker: Float { Float(speakerLevel) / Float(UInt16.max) }

    var statusText: String {
        switch phase {
        case .checking: return "Preparing voice…"
        case .starting: return "Connecting…"
        case .stopping: return "Ending voice…"
        case .failed: return reason?.text ?? "Voice could not connect. Try again in a moment."
        case .closed: return "Voice ended"
        case .active:
            if let threadID, app?.existingRuntime(for: threadID)?.isWaitingForLimit == true {
                return "Codex is waiting for your usage limit to reset."
            }
            if work == .awaitingInput { return "Codex is asking you something" }
            if playing { return "Speaking…" }
            if work == .working { return "Working…" }
            return muted ? "Microphone muted" : "Listening…"
        }
    }

    var failureText: String? {
        guard phase == .failed else { return nil }
        return reason?.text
    }

    // MARK: - Controls

    /// Places the call: on the given Codex chat, or a new orchestrator chat on Codex in
    /// the current project. A live call only raises or hides its stage.
    func start(in threadID: UUID? = nil) {
        if isLive {
            if threadID == nil || threadID == self.threadID { setStageOpen(!stageOpen) }
            return
        }
        cancel()
        guard let app, app.settings.isVoiceEnabled else { return }
        // The call sounds as it is placed, well before the microphone opens.
        VoiceSound.play(start: true, enabled: app.settings.chimeWhenFinished)
        cued = true
        phase = .checking
        reason = nil
        muted = false
        setStageOpen(true)
        let epoch = epoch
        let voice = app.settings.codexVoice
        task = Task { [weak self] in
            do {
                try await self?.run(epoch: epoch, voice: voice, in: threadID)
            } catch {
                self?.fail(epoch: epoch, (error as? VoiceRejection) ?? .protocol)
            }
        }
    }

    /// Ends the call, in any phase. The provider stop runs in the background.
    func end() {
        cancel()
    }

    func shutdown() {
        host?.close(force: true)
        cancel()
    }

    func setStageOpen(_ open: Bool) {
        let open = open && isLive
        guard stageOpen != open else { return }
        stageOpen = open
        if open { WindowManager.shared.hideSettings() }
    }

    /// Forgets a failure once it has been seen.
    func dismissReason() {
        guard reason != nil else { return }
        reason = nil
        if phase == .failed { phase = .closed }
    }

    func toggleMute() {
        guard phase == .active else { return }
        muted.toggle()
        let muted = muted
        let epoch = epoch
        guard let host else { return }
        Task { [weak self] in
            do {
                try await host.setControls(microphoneMuted: muted)
            } catch {
                guard let self else { return }
                self.fail(epoch: epoch, (error as? VoiceRejection) ?? .protocol)
            }
        }
    }

    /// Opens the call's chat, the transcript of everything said and done.
    func openTranscript() {
        guard let threadID, let app else { return }
        setStageOpen(false)
        app.selectedThreadID = threadID
    }

    // MARK: - The call

    private func run(epoch: Int, voice: String?, in target: UUID?) async throws {
        guard let app else { return }
        await app.providers.waitWhileCLIUpdating(.codex)
        try requireCurrent(epoch)
        guard app.providers.status(.codex).isInstalled, app.settings.isEnabled(.codex),
              let executable = app.providers.executable(for: .codex) else { throw VoiceRejection.wrongProvider }
        let helper = try CodexVoiceHost.installedHelper(codexExecutable: executable)
        try await Self.requestMicrophone()
        try requireCurrent(epoch)
        // Past the permission prompt, nothing the start waits on should take this long.
        startDeadline = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.startTimeout))
            guard !Task.isCancelled, let self, self.phase != .active else { return }
            Self.log.notice("voice start timed out")
            self.fail(epoch: epoch, .protocol)
        }
        let home: ChatThread
        if let target {
            guard let existing = app.thread(target), existing.provider == .codex, !existing.isHydraHead else { throw VoiceRejection.wrongProvider }
            home = existing
        } else {
            guard let created = app.voiceHomeThread() else { throw VoiceRejection.noProject }
            home = created
        }
        threadID = home.id
        let runtime = app.runtime(for: home.id)
        let session = try await runtime.codexSessionForVoice()
        try requireCurrent(epoch)
        // Sent with every start, so a chat that began without voice gets the same brief.
        guard let instructions = app.voiceInstructions(for: home.id) else { throw VoiceRejection.noProject }
        guard let thread = session.voiceThreadID else { throw VoiceRejection.protocol }
        self.session = session
        session.onVoiceClosed = { [weak self] in self?.fail(epoch: epoch, .protocol) }
        let (signals, continuation) = AsyncStream.makeStream(of: StartSignal.self)
        startSignals = continuation
        session.onVoiceNotification = { [weak self] method, params in
            self?.handle(method, params, thread: thread, epoch: epoch)
        }

        // Eligibility: a ChatGPT-signed-in Codex with realtime voice.
        let account = try await session.voiceRequest("account/read", ["refreshToken": false], seconds: 15)
        try requireCurrent(epoch)
        guard account["account"]?["type"]?.string == "chatgpt" else { throw VoiceRejection.chatgptRequired }
        let listed = try? await session.voiceRequest("thread/realtime/listVoices", .object([:]), seconds: 15)
        try requireCurrent(epoch)
        guard let catalog = listed?["voices"]?["v1"]?.array?.compactMap(\.string) else { throw VoiceRejection.unsupported }
        if !catalog.isEmpty { voices = catalog }
        let voice = voice.flatMap { catalog.contains($0) ? $0 : nil }
        guard epoch == self.epoch else { return }

        let host = try await CodexVoiceHost.open(helper: helper)
        guard epoch == self.epoch else {
            host.close()
            return
        }
        self.host = host
        phase = .starting

        let offer = try await host.startTransport()
        try requireCurrent(epoch)
        let sessionID = UUID().uuidString
        realtimeSessionID = sessionID
        var params: [String: JSONValue] = [
            "threadId": .string(thread),
            "transport": ["type": "webrtc", "sdp": .string(offer)],
            "version": "v3",
            "outputModality": "audio",
            "realtimeSessionId": .string(sessionID),
            "clientManagedHandoffs": false,
            "includeStartupContext": true,
            "realtimeStartInstructions": .string(instructions),
            "initialItems": [["role": "developer", "text": .string(instructions)]],
        ]
        if let voice { params["voice"] = .string(voice) }
        serverLive = true
        _ = try await session.voiceRequest("thread/realtime/start", .object(params), seconds: 30)
        try requireCurrent(epoch)
        let answer = try await Self.awaitAnswer(signals, seconds: 30)
        guard epoch == self.epoch else { return }
        startSignals = nil

        try await host.applyAnswer(answer)
        try requireCurrent(epoch)
        try await host.openDevices()
        try requireCurrent(epoch)
        try await host.setControls(microphoneMuted: muted)
        guard epoch == self.epoch else { return }
        startDeadline?.cancel()
        startDeadline = nil
        phase = .active
        activeSince = .now
        // Only a connected call counts as the chat's work. With Hydra on, the voice
        // delegates through Tivano's heads; never Codex's own.
        runtime.isVoiceOrchestrator = true
        pollLevels(epoch: epoch, host: host)
    }

    /// Waits for the server to accept the realtime session and hand back its SDP answer.
    private static func awaitAnswer(_ signals: AsyncStream<StartSignal>, seconds: Double) async throws -> String {
        try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                var accepted = false
                var answer: String?
                for await signal in signals {
                    switch signal {
                    case .accepted: accepted = true
                    case .unsupported: throw VoiceRejection.unsupported
                    case .failed(let reason): throw reason
                    case .answer(let sdp):
                        answer = sdp
                    }
                    if accepted, let answer { return answer }
                }
                throw VoiceRejection.protocol
            }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw VoiceRejection.protocol
            }
            defer { group.cancelAll() }
            guard let answer = try await group.next() else { throw VoiceRejection.protocol }
            return answer
        }
    }

    /// Microphone and speaker meters, ten times a second, for the orb.
    private func pollLevels(epoch: Int, host: CodexVoiceHost) {
        levelsTask?.cancel()
        levelsTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled else { return }
                do {
                    let levels = try await host.levels()
                    guard let self, epoch == self.epoch else { return }
                    self.microphoneLevel = levels.microphone
                    self.speakerLevel = levels.speaker
                    let playing = self.speakerActivity.update(peak: levels.speaker)
                    if self.playing != playing { self.playing = playing }
                } catch {
                    guard let self, epoch == self.epoch else { return }
                    self.fail(epoch: epoch, (error as? VoiceRejection) ?? .protocol)
                    return
                }
            }
        }
    }

    /// One realtime notification from the chat's app-server.
    private func handle(_ method: String, _ params: JSONValue, thread: String, epoch: Int) {
        guard epoch == self.epoch else { return }
        if method == "account/updated" {
            // Codex announces its current auth on its own shortly after starting; only a
            // switch away from ChatGPT (or a sign-out, a null mode) ends the call.
            let mode = params["authMode"]?.string
            if mode != "chatgpt", mode != "chatgptAuthTokens" { fail(epoch: epoch, .chatgptRequired) }
            return
        }
        guard params["threadId"]?.string == thread else { return }
        switch method {
        case "thread/realtime/started":
            guard startSignals != nil else { return }
            if params["version"]?.string == "v3", params["realtimeSessionId"]?.string == realtimeSessionID {
                startSignals?.yield(.accepted)
            } else {
                startSignals?.yield(.unsupported)
            }
        case "thread/realtime/sdp":
            if let sdp = params["sdp"]?.string, !sdp.isEmpty, sdp.utf8.count <= 65_536 {
                startSignals?.yield(.answer(sdp))
            }
        case "thread/realtime/item/transcript/delta":
            guard let delta = params["delta"]?.string, delta.utf8.count <= VoiceCatalog.maxTranscriptBytes else { return }
            caption.partial(item: params["itemId"]?.string, delta: delta)
        case "thread/realtime/item/completed":
            // Canonical completed items only: the legacy transcript/done has no stable identity.
            guard let item = params["item"], item["type"]?.string == "transcriptSegment",
                  let id = item["id"]?.string, let text = item["text"]?.string,
                  text.utf8.count <= VoiceCatalog.maxTranscriptBytes else { return }
            let role: VoiceRole
            switch item["role"]?.string {
            case "user": role = .user
            case "assistant": role = .assistant
            default: return
            }
            // The final keeps showing as the caption until the next turn starts; the
            // canonical copy goes into the chat.
            caption.complete(item: id, role: role, text: text)
            if let threadID { app?.existingRuntime(for: threadID)?.recordVoiceTranscript(itemID: id, role: role, text: text) }
        case "thread/realtime/closed":
            serverLive = false
            if startSignals != nil {
                startSignals?.yield(.failed(.protocol))
            } else {
                close(epoch: epoch, reason: nil)
            }
        case "thread/realtime/error":
            Self.log.notice("realtime voice failed")
            if startSignals != nil {
                startSignals?.yield(.failed(.protocol))
            } else {
                close(epoch: epoch, reason: .protocol)
            }
        default:
            break
        }
    }

    private func requireCurrent(_ epoch: Int) throws {
        guard epoch == self.epoch, !Task.isCancelled else { throw CancellationError() }
    }

    func sessionEnded(for threadID: UUID) {
        guard self.threadID == threadID, isLive else { return }
        fail(epoch: epoch, .protocol)
    }

    private func fail(epoch: Int, _ reason: VoiceRejection) {
        guard epoch == self.epoch else { return }
        Self.log.notice("voice call failed: \(String(describing: reason), privacy: .public)")
        close(epoch: epoch, reason: reason)
    }

    /// The call ended, by the provider or by a failure: the stage closes and a failure
    /// keeps its reason for the trigger to explain.
    private func close(epoch: Int, reason: VoiceRejection?) {
        guard epoch == self.epoch else { return }
        let failed = reason != nil
        teardown()
        self.reason = reason
        phase = failed ? .failed : .closed
        resetSession()
    }

    /// Ends whatever is underway and forgets the call.
    private func cancel() {
        teardown()
        resetSession()
        phase = .closed
        reason = nil
    }

    /// Stops the provider side and the helper, and invalidates every pending step.
    private func teardown() {
        epoch &+= 1
        task?.cancel()
        task = nil
        startDeadline?.cancel()
        startDeadline = nil
        levelsTask?.cancel()
        levelsTask = nil
        startSignals?.finish()
        startSignals = nil
        realtimeSessionID = nil
        host?.close()
        host = nil
        if let session {
            session.onVoiceNotification = nil
            session.onVoiceClosed = nil
            if serverLive, let thread = session.voiceThreadID {
                Task { _ = try? await session.voiceRequest("thread/realtime/stop", ["threadId": .string(thread)], seconds: 2) }
            }
        }
        serverLive = false
        session = nil
        if let threadID { app?.existingRuntime(for: threadID)?.isVoiceOrchestrator = false }
    }

    private func resetSession() {
        // Ending sounds for a hang-up or a connected call ending; a failure to connect
        // only explains itself.
        if cued, activeSince != nil || reason == nil { VoiceSound.play(start: false, enabled: app?.settings.chimeWhenFinished == true) }
        cued = false
        caption.clear()
        microphoneLevel = 0
        speakerLevel = 0
        playing = false
        speakerActivity = SpeakerActivity()
        stageOpen = false
        activeSince = nil
        threadID = nil
    }

    /// Asks for the microphone in Tivano's own identity before the helper opens the
    /// devices: CoreAudio can otherwise yield silence without ever showing a prompt.
    private static func requestMicrophone() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return
        case .denied, .restricted: throw VoiceRejection.microphonePermissionDenied
        case .notDetermined: break
        @unknown default: throw VoiceRejection.deviceUnavailable
        }
        // Asking without a purpose string terminates the process.
        guard Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") != nil else {
            throw VoiceRejection.microphoneMetadataMissing
        }
        guard await AVCaptureDevice.requestAccess(for: .audio) else { throw VoiceRejection.microphonePermissionDenied }
    }
}

