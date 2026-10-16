import AppKit
import CryptoKit
import Foundation
import Security
import Synchronization

/// Where the update story's slider is between its phases. The phase boundaries are the
/// milestones the slider ticks past: download done, verified, handed off, installed.
enum UpdateProgressMilestones {
    /// What the head creeps toward while the connection is being made.
    static let preparingCeiling = 0.05
    static let downloadEnd = 0.55
    static let verifyEnd = 0.70
    /// What the head creeps toward while the image is mounted and the app staged.
    static let stagingCeiling = 0.82
    /// The installer has the update; the app quits.
    static let handoffEnd = 0.86
    /// Crossed by the post-relaunch sweep to 100%.
    static let installDot = 0.96
    static let dots = [downloadEnd, verifyEnd, handoffEnd, installDot]
}

/// The one source of truth for the update story the About page tells: the installer reports
/// real phases and byte progress here, and the version pill renders it as the slider.
///
/// The track only ever moves forward. Phases without byte progress (connecting, staging) creep
/// toward their ceiling so the head never freezes, and never reach the next milestone on their own.
@MainActor
@Observable
final class UpdateInstallProgress {
    static let shared = UpdateInstallProgress()

    /// The raw target, in its own observable so a download's many reports a second re-render
    /// only the slider that chases it, not the page around it.
    @MainActor
    @Observable
    final class FractionTarget {
        fileprivate(set) var value = 0.0
    }

    enum Phase: Equatable {
        case idle
        /// Connecting; no bytes yet.
        case preparing
        case downloading
        /// The image is mounted and the app in it checked.
        case verifying
        /// The verified app is copied next to the installed one.
        case staging
        /// The verified update stays here until the team's merges finish; cancellation is safe.
        case waitingForMerge
        /// The installer owns the update; the app is about to quit.
        case handoff
        /// After the relaunch: the sweep to 100%.
        case celebrating
        /// Briefly, before the pill returns to its ready face.
        case failed
    }

    private(set) var phase: Phase = .idle
    let fractionTarget = FractionTarget()
    var fraction: Double { fractionTarget.value }

    /// Set at launch when this process is the relaunch after an install; the About page
    /// consumes it and plays the finishing sweep.
    private(set) var hasPendingCelebration = false

    @ObservationIgnored private var creepTask: Task<Void, Never>?
    @ObservationIgnored private var creepCeiling = 0.0
    @ObservationIgnored private var creepRate = 0.0
    @ObservationIgnored private var failureReset: Task<Void, Never>?

    private init() {}

    /// While the pill shows the slider rather than a face.
    var showsProgressUI: Bool {
        switch phase {
        case .idle, .failed: false
        default: true
        }
    }

    var isInstallRunning: Bool {
        switch phase {
        case .preparing, .downloading, .verifying, .staging, .waitingForMerge, .handoff: true
        default: false
        }
    }

    // MARK: - Reported by the installer

    func begin() {
        cancelFailureReset()
        phase = .preparing
        fractionTarget.value = 0.004
        Haptics.perform(.generic)
        startCreep(toward: UpdateProgressMilestones.preparingCeiling, rate: 0.05)
    }

    /// Byte progress in 0...1. Zero or less means the size is unknown; the head then creeps
    /// toward mid-download so it keeps visibly moving.
    func noteDownloadProgress(_ downloadFraction: Double) {
        if phase == .preparing {
            phase = .downloading
        } else if phase != .downloading {
            return
        }
        guard downloadFraction > 0 else {
            startCreep(toward: 0.50, rate: 0.012)
            return
        }
        stopCreep()
        let start = UpdateProgressMilestones.preparingCeiling
        let end = UpdateProgressMilestones.downloadEnd
        apply(start + (end - start) * min(downloadFraction, 1))
    }

    func beginVerification() {
        guard isInstallRunning else { return }
        stopCreep()
        phase = .verifying
        apply(UpdateProgressMilestones.downloadEnd)
        startCreep(toward: UpdateProgressMilestones.verifyEnd - 0.02, rate: 0.12)
    }

    func beginStaging() {
        guard isInstallRunning else { return }
        stopCreep()
        phase = .staging
        apply(UpdateProgressMilestones.verifyEnd)
        startCreep(toward: UpdateProgressMilestones.stagingCeiling, rate: 0.10)
    }

    func noteHandoff() {
        guard isInstallRunning else { return }
        stopCreep()
        phase = .handoff
        apply(UpdateProgressMilestones.handoffEnd)
    }

    func waitForMerge() {
        guard isInstallRunning else { return }
        stopCreep()
        phase = .waitingForMerge
    }

    /// A step failed. The pill goes back to its ready face; the installer explains why.
    func fail() {
        guard isInstallRunning else { return }
        stopCreep()
        phase = .failed
        Haptics.perform(.levelChange)
        failureReset = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard let self, !Task.isCancelled, phase == .failed else { return }
            resetToIdle()
        }
    }

    // MARK: - After the relaunch

    func armCelebration() {
        hasPendingCelebration = true
    }

    /// Mounts the slider at the handoff position; the page then sweeps it home.
    func consumePendingCelebration() -> Bool {
        guard hasPendingCelebration else { return false }
        hasPendingCelebration = false
        stopCreep()
        cancelFailureReset()
        phase = .celebrating
        fractionTarget.value = UpdateProgressMilestones.handoffEnd
        return true
    }

    func finishCelebrationSweep() {
        guard phase == .celebrating else { return }
        apply(1, firesHaptics: false)
    }

    func completeCelebration() {
        guard phase == .celebrating else { return }
        resetToIdle()
    }

    // MARK: - Internals

    private func resetToIdle() {
        stopCreep()
        cancelFailureReset()
        phase = .idle
        fractionTarget.value = 0
    }

    private func cancelFailureReset() {
        failureReset?.cancel()
        failureReset = nil
    }

    /// Moves the head forward, never back, and ticks once per milestone crossed.
    private func apply(_ newValue: Double, firesHaptics: Bool = true) {
        let clamped = min(max(newValue, 0), 1)
        guard clamped > fraction else { return }
        let previous = fraction
        fractionTarget.value = clamped
        guard firesHaptics else { return }
        for dot in UpdateProgressMilestones.dots where previous < dot && clamped >= dot {
            Haptics.perform(dot == UpdateProgressMilestones.handoffEnd ? .levelChange : .alignment)
        }
    }

    private func startCreep(toward ceiling: Double, rate: Double) {
        creepCeiling = ceiling
        creepRate = rate
        guard creepTask == nil else { return }
        creepTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(125))
                guard let self, !Task.isCancelled else { return }
                let remaining = creepCeiling - fraction
                guard remaining > 0.0005 else {
                    creepTask = nil
                    return
                }
                apply(fraction + remaining * creepRate)
            }
        }
    }

    private func stopCreep() {
        creepTask?.cancel()
        creepTask = nil
    }
}

/// Downloads a release, checks it is this app's, and hands it to a small installer that swaps
/// it in once the app has quit and relaunches it.
///
/// The image is mounted and its app copied out; the copy is what gets checked (its Developer
/// ID signature must be the team's and its identifier this app's, its version the one the
/// user accepted, and Gatekeeper must accept it) and what gets installed. The running app
/// cannot replace itself, so a shell script waits for it to quit, moves the old bundle aside,
/// moves the new one into its place, clears the quarantine the check already covered, and
/// opens it. A marker in the defaults lets the relaunched build finish the story.
@MainActor
final class AppUpdater {
    static let shared = AppUpdater()

    nonisolated static let teamID = "5WF7HRPLRX"
    private static let relaunchVersionKey = "appUpdater_pendingRelaunchVersion"
    /// How long the app may stay alive after the handoff before the installer is called off.
    private static let handoffTimeout: TimeInterval = 25

    private var installTask: Task<Void, Never>?
    private var progress: UpdateInstallProgress { .shared }

    private init() {}

    /// The relaunch after an install: true once, when the running version is the one the
    /// install promised. A stale marker (the swap failed) is dropped silently; the About page
    /// then simply offers the update again.
    func consumeRelaunchMarker() -> Bool {
        let defaults = UserDefaults.standard
        guard let pending = defaults.string(forKey: Self.relaunchVersionKey) else { return false }
        defaults.removeObject(forKey: Self.relaunchVersionKey)
        return pending == AppInfo.version
    }

    func install(_ update: AvailableUpdate) {
        guard installTask == nil, !AppInfo.isDevelopment else { return }
        installTask = Task { [self] in
            defer { installTask = nil }
            progress.begin()
            var downloadedImage: URL?
            defer {
                if let downloadedImage { try? FileManager.default.removeItem(at: downloadedImage) }
            }
            do {
                let image: URL
                do {
                    image = try await download(update.downloadURL)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    guard let fallback = update.fallbackDownloadURL else { throw error }
                    image = try await download(fallback)
                }
                downloadedImage = image
                try Task.checkCancellation()
                progress.beginVerification()
                if let expected = update.sha256 {
                    do {
                        guard try await Self.checksum(of: image) == expected else {
                            throw UpdateInstallError(Chrome.localized("The update download failed its checksum check."))
                        }
                    } catch {
                        try? FileManager.default.removeItem(at: image)
                        throw error
                    }
                }
                try Task.checkCancellation()
                let staged = try await stage(image: image, expectedVersion: update.version)
                do {
                    try Task.checkCancellation()
                    progress.beginStaging()
                    let model = WindowManager.shared.model
                    if model.isAnyHydraMergeRunning { progress.waitForMerge() }
                    while model.isAnyHydraMergeRunning {
                        try await Task.sleep(for: .milliseconds(250))
                    }
                    try Task.checkCancellation()
                    try handOff(staged: staged, version: update.version)
                } catch {
                    try? FileManager.default.removeItem(at: staged.deletingLastPathComponent())
                    throw error
                }
            } catch is CancellationError {
                progress.fail()
            } catch {
                progress.fail()
                await MainActor.run {
                    let alert = NSAlert()
                    alert.messageText = "Update Failed"
                    alert.informativeText = error.localizedDescription
                    alert.alertStyle = .warning
                    alert.runModal()
                }
            }
        }
    }

    func cancelInstall() {
        guard progress.phase == .waitingForMerge else { return }
        installTask?.cancel()
    }

    // MARK: - Download

    private func download(_ url: URL) async throws -> URL {
        let destination = FileManager.default.temporaryDirectory
            .appending(path: "TivanoUpdate-\(UUID().uuidString).dmg")
        let downloader = Downloader { fraction in
            Task { @MainActor in UpdateInstallProgress.shared.noteDownloadProgress(fraction) }
        }
        try await downloader.download(url, to: destination)
        return destination
    }

    // MARK: - Verify and stage

    @concurrent
    private static func checksum(of image: URL) async throws -> String {
        let stream = try FileHandle(forReadingFrom: image)
        defer { try? stream.close() }
        var hash = SHA256()
        while let chunk = try stream.read(upToCount: 1_048_576), !chunk.isEmpty {
            hash.update(data: chunk)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func stage(image: URL, expectedVersion: String) async throws -> URL {
        let staging = FileManager.default.temporaryDirectory
            .appending(path: "TivanoUpdate-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let mount = staging.appending(path: "image", directoryHint: .isDirectory)
        let attach = try await Shell.run(
            URL(filePath: "/usr/bin/hdiutil"),
            ["attach", "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path, image.path],
            timeout: 120
        )
        guard attach.succeeded else {
            throw UpdateInstallError("The downloaded disk image could not be opened. \(attach.failureMessage)")
        }
        // The copy is what gets checked and installed; the image is let go as soon as it is made.
        let staged = staging.appending(path: Bundle.main.bundleURL.lastPathComponent, directoryHint: .isDirectory)
        let copy: ShellResult
        do {
            let contents = (try? FileManager.default.contentsOfDirectory(at: mount, includingPropertiesForKeys: nil)) ?? []
            guard let source = contents.first(where: { $0.pathExtension == "app" }) else {
                throw UpdateInstallError("The disk image holds no app.")
            }
            copy = try await Shell.run(URL(filePath: "/usr/bin/ditto"), [source.path, staged.path], timeout: 300)
            _ = try? await Shell.run(URL(filePath: "/usr/bin/hdiutil"), ["detach", mount.path, "-force"], timeout: 60)
            try? FileManager.default.removeItem(at: image)
        } catch {
            _ = try? await Shell.run(URL(filePath: "/usr/bin/hdiutil"), ["detach", mount.path, "-force"], timeout: 60)
            try? FileManager.default.removeItem(at: image)
            throw error
        }
        guard copy.succeeded else {
            throw UpdateInstallError("The update could not be copied. \(copy.failureMessage)")
        }
        try await Task.detached(priority: .userInitiated) {
            try Self.verifySignature(of: staged)
        }.value
        let bundle = Bundle(url: staged)
        let version = bundle?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        guard let version, let actual = AppVersion(version), let expected = AppVersion(expectedVersion), actual == expected else {
            throw UpdateInstallError("The downloaded app is version \(version ?? "unknown"), not \(expectedVersion).")
        }
        let gatekeeper = try await Shell.run(URL(filePath: "/usr/sbin/spctl"), ["--assess", "--type", "execute", staged.path], timeout: 120)
        guard gatekeeper.succeeded else {
            throw UpdateInstallError("Gatekeeper did not accept the downloaded app. \(gatekeeper.failureMessage)")
        }
        return staged
    }

    /// The app must be signed with the team's Developer ID certificate and carry this app's
    /// identifier: anything else is not a Tivano release, whatever it is called.
    nonisolated static func verifySignature(of appURL: URL) throws {
        let bundleID = Bundle.main.bundleIdentifier ?? "dev.tivano.Tivano"
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(appURL as CFURL, [], &staticCode) == errSecSuccess, let code = staticCode else {
            throw UpdateInstallError("The downloaded app is not signed.")
        }
        let text = """
        anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] \
        and certificate leaf[field.1.2.840.113635.100.6.1.13] \
        and certificate leaf[subject.OU] = "\(teamID)" and identifier "\(bundleID)"
        """
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess, let requirement else {
            throw UpdateInstallError("The signature requirement could not be built.")
        }
        var error: Unmanaged<CFError>?
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        let status = SecStaticCodeCheckValidityWithErrors(code, flags, requirement, &error)
        guard status == errSecSuccess else {
            let reason = error?.takeRetainedValue().localizedDescription ?? "OSStatus \(status)"
            throw UpdateInstallError("The downloaded app is not signed for Tivano. \(reason)")
        }
    }

    // MARK: - Hand off

    /// Starts the installer and quits. The installer waits for this process to end before it
    /// touches the installed app.
    private func handOff(staged: URL, version: String) throws {
        let destination = Bundle.main.bundleURL
        let parent = destination.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parent.path) else {
            throw UpdateInstallError("Tivano cannot replace itself in \(parent.path). Move it to your Applications folder and try again.")
        }
        let script = staged.deletingLastPathComponent().appending(path: "install.sh")
        try Self.installerScript.write(to: script, atomically: true, encoding: .utf8)
        let log = staged.deletingLastPathComponent().appending(path: "install.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = [
            script.path,
            String(ProcessInfo.processInfo.processIdentifier),
            staged.path,
            destination.path,
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = try FileHandle(forWritingTo: log)
        process.standardError = process.standardOutput
        guard WindowManager.shared.model.flushForQuit() else {
            throw UpdateInstallError(Chrome.localized("Tivano couldn't save your chats. The update was not installed. Resolve the disk error and try again."))
        }
        try process.run()
        UserDefaults.standard.set(version, forKey: Self.relaunchVersionKey)
        progress.noteHandoff()
        // If the quit is refused the installer gives up on its own; the pill goes back too.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(Self.handoffTimeout))
            guard UpdateInstallProgress.shared.phase == .handoff else { return }
            UserDefaults.standard.removeObject(forKey: Self.relaunchVersionKey)
            UpdateInstallProgress.shared.fail()
        }
        // Do not yield after the merge check: a new merge must not start between
        // launching the installer and requesting termination.
        NSApp.terminate(nil)
    }

    /// Waits for the app to quit, swaps the bundles, and opens the new one. A swap that fails
    /// puts the old app back. Everything it was given is cleaned up at the end.
    private static let installerScript = """
    #!/bin/sh
    # Tivano update installer: waits for the app to quit, swaps in the update, relaunches.
    trap '' HUP
    PID="$1"; NEW="$2"; DEST="$3"
    STAGING="$(dirname "$NEW")"
    i=0
    while kill -0 "$PID" 2>/dev/null; do
      sleep 0.25
      i=$((i + 1))
      if [ "$i" -gt 240 ]; then echo "The app did not quit"; rm -rf "$STAGING"; exit 1; fi
    done
    BACKUP="$(dirname "$DEST")/.$(basename "$DEST").previous"
    rm -rf "$BACKUP"
    if [ -e "$DEST" ]; then
      mv "$DEST" "$BACKUP" || { echo "Could not move the installed app aside"; rm -rf "$STAGING"; exit 1; }
    fi
    if mv "$NEW" "$DEST"; then
      rm -rf "$BACKUP"
    else
      echo "Could not move the update into place"
      [ -e "$BACKUP" ] && mv "$BACKUP" "$DEST"
      rm -rf "$STAGING"
      exit 1
    fi
    xattr -dr com.apple.quarantine "$DEST" 2>/dev/null
    open "$DEST"
    rm -rf "$STAGING"
    """
}

struct UpdateInstallError: LocalizedError {
    var message: String
    var errorDescription: String? { message }

    init(_ message: String) {
        self.message = message
    }
}

/// One download to a file, with byte progress. Kept as a delegate so a large image streams
/// to disk instead of through memory.
///
/// The continuation and the destination share one mutex; the delegate callbacks arrive on
/// URLSession's own queue. The continuation is resumed outside `withLock`.
private final class Downloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private struct State {
        var continuation: CheckedContinuation<URL, Error>?
        var destination: URL?
        var task: URLSessionDownloadTask?
        var cancelled = false
    }

    private let onProgress: @Sendable (Double) -> Void
    private let state = Mutex(State())

    init(onProgress: @escaping @Sendable (Double) -> Void) {
        self.onProgress = onProgress
    }

    func download(_ url: URL, to destination: URL) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 1800
        configuration.waitsForConnectivity = false
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.setValue("Tivano/\(AppInfo.version)", forHTTPHeaderField: "User-Agent")
        do {
            try await withTaskCancellationHandler {
                try Task.checkCancellation()
                _ = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
                    let task = session.downloadTask(with: request)
                    let start = state.withLock { state in
                        guard !state.cancelled else { return false }
                        state.continuation = continuation
                        state.destination = destination
                        state.task = task
                        return true
                    }
                    if start {
                        task.resume()
                    } else {
                        task.cancel()
                        continuation.resume(throwing: CancellationError())
                    }
                }
                try Task.checkCancellation()
            } onCancel: {
                self.cancel()
            }
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    private func cancel() {
        let pending = state.withLock { state in
            state.cancelled = true
            let pending = (state.task, state.continuation)
            state.task = nil
            state.continuation = nil
            return pending
        }
        pending.0?.cancel()
        pending.1?.resume(throwing: CancellationError())
    }

    private func finish(_ result: Result<URL, Error>) {
        let continuation = state.withLock { state -> CheckedContinuation<URL, Error>? in
            defer { state.continuation = nil; state.task = nil }
            return state.continuation
        }
        continuation?.resume(with: result)
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        guard let original = task.originalRequest?.url, let redirected = request.url,
              redirected.scheme == "https", redirected.port == nil || redirected.port == 443 else {
            completionHandler(nil)
            return
        }
        if original.host == "elijah.ac.cn" {
            // The static mirror has no legitimate redirects; use the other origin instead.
            completionHandler(nil)
        } else if original.host == "github.com" {
            let hosts = ["github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com", "github-releases.githubusercontent.com"]
            completionHandler(hosts.contains(redirected.host ?? "") ? request : nil)
        } else {
            completionHandler(redirected.host == original.host ? request : nil)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard state.withLock({ !$0.cancelled && $0.continuation != nil }) else { return }
        guard totalBytesExpectedToWrite > 0 else {
            onProgress(0)
            return
        }
        onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // Serialize the file handoff with cancellation, but resume outside the lock.
        // Otherwise cancel could clean up before this callback moves the file into place.
        let completed = state.withLock { state -> (CheckedContinuation<URL, Error>, Result<URL, Error>)? in
            guard !state.cancelled, let continuation = state.continuation,
                  let destination = state.destination else { return nil }
            defer { state.continuation = nil; state.task = nil }
            if let http = downloadTask.response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                return (continuation, .failure(UpdateInstallError(String(format: Chrome.localized("The download failed with HTTP %d."), http.statusCode))))
            }
            do {
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: location, to: destination)
                return (continuation, .success(destination))
            } catch {
                return (continuation, .failure(error))
            }
        }
        if let (continuation, result) = completed { continuation.resume(with: result) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            if (error as NSError).code == NSURLErrorCancelled, (error as NSError).domain == NSURLErrorDomain {
                finish(.failure(CancellationError()))
            } else {
                finish(.failure(UpdateInstallError(String(format: Chrome.localized("The update could not be downloaded. %@"), error.localizedDescription))))
            }
        }
    }
}
