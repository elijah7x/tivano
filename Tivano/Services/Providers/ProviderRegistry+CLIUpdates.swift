import Foundation

/// `--version` and the install command. A fake run replaces this struct.
/// `cliProbe` still owns ownership lookups and release feeds, which do not install.
struct CLICommandRunner: Sendable {
    var readVersion: @Sendable (URL, [String: String]) async -> String?
    var runUpdate: @Sendable (String, [String], [String: String]) async throws -> ShellResult

    static let live = CLICommandRunner(
        readVersion: { executable, environment in
            guard let result = try? await Shell.run(executable, ["--version"], environment: environment, timeout: 30),
                  result.succeeded else { return nil }
            return result.output
        },
        runUpdate: { tool, arguments, environment in
            guard let executable = LoginEnvironment.which(tool, in: environment) else {
                let name = (tool as NSString).lastPathComponent
                throw ShellError(String(format: String(localized: "%@ was not found on your PATH."), name))
            }
            return try await Shell.run(executable, arguments, in: FileManager.default.temporaryDirectory, environment: environment, timeout: ProviderRegistry.cliUpdateTimeout)
        }
    )
}

struct CLITrackedTask<Success: Sendable> {
    let id: UUID
    let task: Task<Success, Never>
}

struct CLICheckCache: Equatable {
    var executable: String
    var channelIdentity: String
    var releaseIdentity: String
    var checkedAt: Date
}

extension ProviderRegistry {
    /// A check this fresh is kept when the app opens or monitoring is switched back on.
    nonisolated static let cliCheckFreshnessOnOpen: TimeInterval = 15 * 60
    /// How often the open app reads versions again. This does not install.
    nonisolated static let cliCheckInterval: TimeInterval = 6 * 3600
    /// Every single check and every batch shares this many runs at once.
    nonisolated static let cliCheckConcurrency = 3
    nonisolated static let cliUpdateTimeout: TimeInterval = 900

    func monitorsCLIUpdates(_ provider: ProviderKind) -> Bool {
        settings.monitorsUpdates(provider)
    }

    /// Monitoring off cancels a check and a wait. An install that has already started keeps its result.
    func cliMonitoringChanged(_ provider: ProviderKind) {
        guard !provider.isAPIKeyBased else { return }
        cliCheckTasks[provider]?.task.cancel()
        cliCheckGeneration[provider] = UUID()
        cliCheckCache[provider] = nil
        if ![.waiting, .updating].contains(cliUpdates[provider]?.phase) {
            setCLIUpdateStatus(nil, for: provider)
        }
        guard !monitorsCLIUpdates(provider) else {
            Task { @MainActor [weak self] in
                await self?.checkCLIUpdate(provider, freshness: Self.cliCheckFreshnessOnOpen)
            }
            return
        }
        cliCheckTasks[provider]?.task.cancel()
        guard cliUpdates[provider]?.phase == .waiting, let executable = executable(for: provider) else { return }
        let lock = cliInstallLock(for: executable)
        guard cliUpdateRequesters[lock] == provider, !cliRecoveryLocks.contains(lock),
              providersSharingCLIInstall(lock).allSatisfy({ cliUpdates[$0]?.phase != .updating }) else { return }
        cliUpdateTasks[lock]?.task.cancel()
    }

    func startCLIUpdateChecks() {
        guard !CaptureRun.isEnabled else { return }
        guard cliCheckLoop == nil else { return }
        cliCheckLoop = Task { @MainActor [weak self] in
            await self?.checkCLIUpdates(freshness: Self.cliCheckFreshnessOnOpen)
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.cliCheckInterval))
                if Task.isCancelled { return }
                await self?.checkCLIUpdates(freshness: Self.cliCheckInterval)
            }
        }
    }

    func checkCLIUpdates(freshness: TimeInterval = 0) async {
        guard !CaptureRun.isEnabled else { return }
        await withTaskGroup(of: Void.self) { group in
            for provider in ProviderKind.allCases {
                group.addTask { await self.checkCLIUpdate(provider, freshness: freshness) }
            }
        }
    }

    /// One check per provider. A second call waits for the first unless `force`, which cancels it
    /// and skips the freshness cache. `freshness` of zero always reads again. A cached error is never reused.
    /// The cache key is the executable, the install channel's identity, and Claude's release-channel
    /// setting, so a new path or a stable/latest switch cannot reuse the previous answer.
    func checkCLIUpdate(_ provider: ProviderKind, force: Bool = false, freshness: TimeInterval = 0) async {
        guard cliCheckAllowed(provider) else { return }
        if !force, let existing = cliCheckTasks[provider] {
            await existing.task.value
            return
        }
        if cliCheckBlocked(provider, force: force) { return }
        let previous = cliCheckTasks[provider]?.task
        let generation = UUID()
        cliCheckGeneration[provider] = generation
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.cliCheckTasks[provider]?.id == generation { self.cliCheckTasks[provider] = nil }
            }
            await self.performCLICheck(provider, force: force, freshness: freshness, generation: generation)
        }
        cliCheckTasks[provider] = CLITrackedTask(id: generation, task: task)
        previous?.cancel()
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// Asks for an install. Callers that share an install await the one already running.
    /// A custom binary path, an unknown channel, and a provider that is off or unmonitored do not install.
    func updateCLI(_ provider: ProviderKind, recovery: Bool = false) async -> Bool {
        // MiniMax Code needs its official installer/npm flags for native optional dependencies.
        // Until that update transaction is integrated, offer read-only version checks only.
        guard !recovery, !CaptureRun.isEnabled, !provider.isAPIKeyBased, provider != .minimaxCode else { return false }
        guard let executable = executable(for: provider) else { return false }
        guard settings.isEnabled(provider), monitorsCLIUpdates(provider), settings.binaryPath(for: provider).isEmpty else { return false }
        let lock = cliInstallLock(for: executable)
        if let existing = cliUpdateTasks[lock] {
            return await existing.task.value
        }
        let sharers = providersSharingCLIInstall(lock)
        var snapshot: [ProviderKind: CLIUpdateStatus] = [:]
        for sharer in sharers {
            if let status = cliUpdates[sharer] { snapshot[sharer] = status }
        }
        markCLIWaiting(sharers)
        let id = UUID()
        cliUpdateRequesters[lock] = provider
        let task = Task { @MainActor [weak self] in
            guard let self else { return false }
            defer {
                if self.cliUpdateTasks[lock]?.id == id {
                    self.cliUpdateTasks[lock] = nil
                    self.cliUpdateRequesters[lock] = nil
                    self.cliRecoveryLocks.remove(lock)
                }
            }
            return await self.performCLIUpdate(provider, lock: lock, sharers: sharers, snapshot: snapshot)
        }
        cliUpdateTasks[lock] = CLITrackedTask(id: id, task: task)
        return await task.value
    }

    /// True while this binary is queued for an install or being installed. Warmup must not start a process then.
    func cliUpdateBlocksWarmup(_ provider: ProviderKind) -> Bool {
        sharesCLIPhase(provider, phases: [.waiting, .updating])
    }

    func cliInstallIsUpdating(_ provider: ProviderKind) -> Bool {
        sharesCLIPhase(provider, phases: [.updating])
    }

    /// Keeps a newly requested turn or session start behind an active binary replacement.
    func waitWhileCLIUpdating(_ provider: ProviderKind) async {
        guard cliInstallIsUpdating(provider) else { return }
        while cliInstallIsUpdating(provider) {
            if Task.isCancelled { return }
            try? await Task.sleep(for: .milliseconds(200))
        }
    }

    nonisolated static func readableCLIVersion(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let stripped = TextCleanup.stripANSI(raw)
        let line = stripped.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        guard let line, CLIUpdates.compare(line, with: line) == .equal else { return nil }
        return line
    }

    // MARK: - Checks

    private func performCLICheck(_ provider: ProviderKind, force: Bool, freshness: TimeInterval, generation: UUID) async {
        await acquireCLICheckPermit()
        defer { releaseCLICheckPermit() }
        guard cliCheckGeneration[provider] == generation, !Task.isCancelled else { return }
        guard !cliCheckBlocked(provider, force: force), cliCheckAllowed(provider) else { return }
        let epoch = cliStatusEpoch[provider] ?? 0
        let snapshot = cliUpdates[provider]
        defer {
            if Task.isCancelled || !cliCheckAllowed(provider) { abandonCLICheck(provider, generation: generation, snapshot: snapshot) }
        }
        if force { beginCLIChecking(provider) }
        await LoginEnvironment.load()
        guard cliCheckGeneration[provider] == generation, !Task.isCancelled else { return }
        guard let executable = executable(for: provider) else { return }
        let environment = CLIInstallEnvironment.current
        var channel: CLIInstallChannel?
        do {
            channel = try await CLIUpdates.channel(for: provider, executable: executable, environment: environment, probe: cliProbe)
        } catch is CancellationError {
            return
        } catch {
            publishCLICheckFailure(provider, generation: generation, epoch: epoch, snapshot: snapshot, message: error.localizedDescription)
            return
        }
        guard cliCheckStillCurrent(provider, generation: generation, epoch: epoch) else { return }
        let path = cliProbe.standardize(executable.path)
        let key = CLICheckCache(
            executable: path,
            channelIdentity: channel?.identity ?? "",
            releaseIdentity: cliReleaseIdentity(for: provider),
            checkedAt: .now
        )
        if !force, cliCheckIsFresh(provider, key: key, freshness: freshness) { return }
        beginCLIChecking(provider)
        let raw = await cliCommandRunner.readVersion(executable, environment)
        guard cliCheckStillCurrent(provider, generation: generation, epoch: epoch) else { return }
        if Task.isCancelled {
            abandonCLICheck(provider, generation: generation, snapshot: snapshot)
            return
        }
        guard let installed = Self.readableCLIVersion(raw) else {
            publishCLICheckFailure(provider, generation: generation, epoch: epoch, snapshot: snapshot, message: cliText("The installed version could not be read."))
            return
        }
        guard channel != nil else {
            var status = CLIUpdateStatus(phase: .current, installed: installed)
            status.error = CLIUpdates.unmanagedReason(provider, executable: executable)
            status.checkedAt = .now
            setCLIUpdateStatus(status, for: provider)
            cliCheckCache[provider] = nil
            return
        }
        var latest: String?
        do {
            latest = try await CLIUpdates.latestVersion(provider, installed: installed, channel: channel, executable: executable, environment: environment, probe: cliProbe)
        } catch is CancellationError {
            abandonCLICheck(provider, generation: generation, snapshot: snapshot)
            return
        } catch {
            publishCLICheckFailure(provider, generation: generation, epoch: epoch, snapshot: snapshot, message: error.localizedDescription)
            return
        }
        guard cliCheckStillCurrent(provider, generation: generation, epoch: epoch), !Task.isCancelled else {
            abandonCLICheck(provider, generation: generation, snapshot: snapshot)
            return
        }
        guard monitorsCLIUpdates(provider), settings.isEnabled(provider),
              self.executable(for: provider).map({ cliProbe.standardize($0.path) }) == path,
              cliReleaseIdentity(for: provider) == key.releaseIdentity else {
            abandonCLICheck(provider, generation: generation, snapshot: snapshot)
            return
        }
        let phase: CLIUpdateStatus.Phase
        if let latest {
            switch CLIUpdates.compare(latest, with: installed) {
            case .newer:
                phase = .available
            case .older, .equal:
                phase = .current
            case .unparsed:
                publishCLICheckFailure(provider, generation: generation, epoch: epoch, snapshot: snapshot, message: cliText("The versions could not be compared, so the update was not kept as successful."))
                return
            }
        } else {
            phase = .current
        }
        var status = cliUpdates[provider] ?? CLIUpdateStatus(phase: phase)
        status.phase = phase
        status.installed = installed
        status.latest = latest
        status.channel = channel
        status.error = latest == nil ? cliText("No verified release feed is available for this installation. Its update status is unknown.") : nil
        status.updateFailed = false
        status.checkedAt = key.checkedAt
        guard cliCheckStillCurrent(provider, generation: generation, epoch: epoch) else { return }
        setCLIUpdateStatus(status, for: provider)
        cliCheckCache[provider] = latest == nil ? nil : key
    }

    private func cliCheckAllowed(_ provider: ProviderKind) -> Bool {
        guard !CaptureRun.isEnabled, !provider.isAPIKeyBased else { return false }
        guard settings.isEnabled(provider), monitorsCLIUpdates(provider) else { return false }
        return executable(for: provider) != nil
    }

    /// Waiting and installing are left alone. A failed install stays until a forced check or another install.
    private func cliCheckBlocked(_ provider: ProviderKind, force: Bool) -> Bool {
        guard let status = cliUpdates[provider] else { return false }
        switch status.phase {
        case .waiting, .updating:
            return true
        case .failed where status.updateFailed && !force:
            return true
        default:
            return false
        }
    }

    private func cliCheckStillCurrent(_ provider: ProviderKind, generation: UUID, epoch: UInt) -> Bool {
        guard cliCheckGeneration[provider] == generation else { return false }
        guard cliStatusEpoch[provider] ?? 0 == epoch else { return false }
        return ![.waiting, .updating].contains(cliUpdates[provider]?.phase)
    }

    private func cliCheckIsFresh(_ provider: ProviderKind, key: CLICheckCache, freshness: TimeInterval) -> Bool {
        guard freshness > 0, let cache = cliCheckCache[provider] else { return false }
        guard cache.executable == key.executable,
              cache.channelIdentity == key.channelIdentity,
              cache.releaseIdentity == key.releaseIdentity else { return false }
        return Date.now.timeIntervalSince(cache.checkedAt) < freshness
    }

    /// Claude's `autoUpdatesChannel` is not part of the native install identity. The same file
    /// decides which feed `CLIUpdates` reads, so the cache has to name it too.
    private func cliReleaseIdentity(for provider: ProviderKind) -> String {
        guard provider == .claude else { return "none" }
        let config = CLIInstallEnvironment.current["CLAUDE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : $0 }
            ?? (cliProbe.home() as NSString).appendingPathComponent(".claude")
        let path = cliProbe.standardize((config as NSString).appendingPathComponent("settings.json"))
        guard let data = cliProbe.readFile(path) else { return "claude:latest" }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "claude:unreadable" }
        guard json.keys.contains("autoUpdatesChannel") else { return "claude:latest" }
        switch json["autoUpdatesChannel"] as? String {
        case "stable": return "claude:stable"
        case "latest": return "claude:latest"
        default: return "claude:unreadable"
        }
    }

    private func beginCLIChecking(_ provider: ProviderKind) {
        var status = cliUpdates[provider] ?? CLIUpdateStatus(phase: .checking)
        status.phase = .checking
        status.error = nil
        status.updateFailed = false
        setCLIUpdateStatus(status, for: provider)
    }

    private func abandonCLICheck(_ provider: ProviderKind, generation: UUID, snapshot: CLIUpdateStatus?) {
        guard cliCheckGeneration[provider] == generation else { return }
        guard cliUpdates[provider]?.phase == .checking else { return }
        setCLIUpdateStatus(snapshot, for: provider)
    }

    private func publishCLICheckFailure(
        _ provider: ProviderKind,
        generation: UUID,
        epoch: UInt,
        snapshot: CLIUpdateStatus?,
        message: String
    ) {
        guard cliCheckGeneration[provider] == generation else { return }
        guard cliStatusEpoch[provider] ?? 0 == epoch, ![.waiting, .updating].contains(cliUpdates[provider]?.phase) else { return }
        var status = snapshot ?? CLIUpdateStatus(phase: .failed)
        status.phase = .failed
        status.error = cliReason(message)
        status.updateFailed = false
        status.checkedAt = .now
        setCLIUpdateStatus(status, for: provider)
        cliCheckCache[provider] = nil
    }

    private func acquireCLICheckPermit() async {
        if cliCheckPermits > 0 {
            cliCheckPermits -= 1
            return
        }
        await withCheckedContinuation { continuation in
            cliCheckWaiters.append(continuation)
        }
    }

    private func releaseCLICheckPermit() {
        if cliCheckWaiters.isEmpty {
            cliCheckPermits += 1
        } else {
            cliCheckWaiters.removeFirst().resume()
        }
    }

    // MARK: - Updates

    private func performCLIUpdate(
        _ requester: ProviderKind,
        lock: String,
        sharers: [ProviderKind],
        snapshot: [ProviderKind: CLIUpdateStatus]
    ) async -> Bool {
        var target: String?
        while providersSharingCLIInstall(lock).contains(where: { isProviderBusy($0) }) {
            if stopCLIUpdateWait(requester, lock: lock, sharers: sharers, snapshot: snapshot) { return false }
            try? await Task.sleep(for: .milliseconds(200))
        }
        await LoginEnvironment.load()
        guard let executable = preparedCLIExecutable(requester, lock: lock) else {
            endCLIUpdateWait(requester, lock: lock, sharers: sharers, snapshot: snapshot)
            return false
        }
        let environment = CLIInstallEnvironment.current
        var resolvedChannel: CLIInstallChannel?
        do {
            resolvedChannel = try await CLIUpdates.channel(for: requester, executable: executable, environment: environment, probe: cliProbe)
        } catch is CancellationError {
            restoreCLIWait(sharers, snapshot: snapshot)
            return false
        } catch {
            restoreCLIWait(sharers, snapshot: snapshot, requester: requester, failure: cliUpdateRefusal(requester, error.localizedDescription, channel: nil, keeping: snapshot[requester]))
            return false
        }
        guard preparedCLIExecutable(requester, lock: lock) != nil else {
            endCLIUpdateWait(requester, lock: lock, sharers: sharers, snapshot: snapshot)
            return false
        }
        guard let channel = resolvedChannel else {
            restoreCLIWait(sharers, snapshot: snapshot, requester: requester, failure: cliUpdateRefusal(requester, CLIUpdates.unmanagedReason(requester, executable: executable), channel: nil, keeping: snapshot[requester]))
            return false
        }
        guard let versionURL = preparedCLIExecutable(requester, lock: lock) else {
            endCLIUpdateWait(requester, lock: lock, sharers: sharers, snapshot: snapshot)
            return false
        }
        let readBefore = Self.readableCLIVersion(await cliCommandRunner.readVersion(versionURL, environment))
        guard preparedCLIExecutable(requester, lock: lock) != nil else {
            endCLIUpdateWait(requester, lock: lock, sharers: sharers, snapshot: snapshot)
            return false
        }
        guard let before = readBefore else {
            restoreCLIWait(sharers, snapshot: snapshot, requester: requester, failure: cliUpdateRefusal(requester, cliText("The installed version could not be read, so Tivano did not run the update."), channel: channel, keeping: snapshot[requester]))
            return false
        }
        // Read the current feed before executing: an old cached target must not hide
        // a failed or malformed release document.
        do {
            target = try await CLIUpdates.latestVersion(requester, installed: before, channel: channel, executable: executable, environment: environment, probe: cliProbe)
        } catch {
            restoreCLIWait(sharers, snapshot: snapshot, requester: requester, failure: cliUpdateRefusal(requester, error.localizedDescription, channel: channel, keeping: snapshot[requester]))
            return false
        }
        let verifiedChannel: CLIInstallChannel?
        do {
            verifiedChannel = try await CLIUpdates.channel(for: requester, executable: executable, environment: CLIInstallEnvironment.current, probe: cliProbe)
        } catch {
            restoreCLIWait(sharers, snapshot: snapshot, requester: requester, failure: cliUpdateRefusal(requester, error.localizedDescription, channel: nil, keeping: snapshot[requester]))
            return false
        }
        guard verifiedChannel == channel else {
            restoreCLIWait(sharers, snapshot: snapshot, requester: requester, failure: cliUpdateRefusal(requester, cliText("The binary changed before the update ran, so Tivano did not update it."), channel: nil, keeping: snapshot[requester]))
            return false
        }
        while providersSharingCLIInstall(lock).contains(where: { isProviderBusy($0) }) {
            if stopCLIUpdateWait(requester, lock: lock, sharers: sharers, snapshot: snapshot) { return false }
            try? await Task.sleep(for: .milliseconds(200))
        }
        guard preparedCLIExecutable(requester, lock: lock) != nil else {
            endCLIUpdateWait(requester, lock: lock, sharers: sharers, snapshot: snapshot)
            return false
        }
        // Waiting can outlive a login-environment refresh or an external installer.
        // Recheck against the exact environment that will be passed to the command.
        do {
            guard CLIInstallEnvironment.current == environment,
                  try await CLIUpdates.channel(for: requester, executable: executable, environment: environment, probe: cliProbe) == channel else {
                restoreCLIWait(sharers, snapshot: snapshot, requester: requester, failure: cliUpdateRefusal(requester, cliText("The binary changed before the update ran, so Tivano did not update it."), channel: nil, keeping: snapshot[requester]))
                return false
            }
        } catch {
            restoreCLIWait(sharers, snapshot: snapshot, requester: requester, failure: cliUpdateRefusal(requester, error.localizedDescription, channel: nil, keeping: snapshot[requester]))
            return false
        }
        guard preparedCLIExecutable(requester, lock: lock) != nil else {
            endCLIUpdateWait(requester, lock: lock, sharers: sharers, snapshot: snapshot)
            return false
        }
        if let target, CLIUpdates.compare(target, with: before) == .older {
            restoreCLIWait(sharers, snapshot: snapshot, requester: requester, failure: cliUpdateRefusal(requester, cliText("The release feed offers an older version, so Tivano did not run the update."), channel: channel, keeping: snapshot[requester]))
            return false
        }
        markCLIUpdating(sharers, channel: channel, installed: before, latest: target)
        if let pending = cliRefreshPending[lock], CLIUpdates.compare(before, with: pending) == .equal {
            if let reason = await confirmCLIRefresh(sharers, expected: pending) {
                writeCLIUpdateResult(cliFinishedUpdate(phase: .failed, installed: pending, latest: target, channel: channel, error: reason, updateFailed: true), sharers: sharers)
                return false
            }
            cliRefreshPending[lock] = nil
            writeCLIUpdateResult(cliFinishedUpdate(phase: .updated, installed: pending, latest: target, channel: channel, error: nil, updateFailed: false), sharers: sharers)
            return true
        }
        let invocation = channel.invocation
        let updateEnvironment = CLIInstallEnvironment.applying(invocation.environment, to: environment)
        let outcome: Result<ShellResult, Error>
        do {
            outcome = .success(try await cliCommandRunner.runUpdate(invocation.tool, invocation.arguments, updateEnvironment))
        } catch {
            outcome = .failure(error)
        }
        let afterURL = executable
        let afterEnvironment = CLIInstallEnvironment.current
        let readAfter = Self.readableCLIVersion(await cliCommandRunner.readVersion(afterURL, afterEnvironment))
        let commandFailure: String?
        switch outcome {
        case .success(let result) where result.succeeded:
            commandFailure = nil
        case .success(let result):
            let detail = cliReason(result.failureMessage)
            commandFailure = detail.isEmpty
                ? cliText("The update command failed.")
                : cliFormat("The update command failed: %@.", detail)
        case .failure(let error):
            if error is CancellationError {
                commandFailure = cliText("The update was cancelled before it finished.")
            } else {
                commandFailure = cliFormat("The update command failed: %@.", cliReason(error.localizedDescription))
            }
        }
        if let reason = cliUpdateRejection(before: before, after: readAfter, latest: target, commandFailure: commandFailure) {
            writeCLIUpdateResult(cliFinishedUpdate(phase: .failed, installed: readAfter ?? before, latest: target, channel: channel, error: reason, updateFailed: true), sharers: sharers)
            return false
        }
        guard let after = readAfter else {
            writeCLIUpdateResult(cliFinishedUpdate(phase: .failed, installed: before, latest: target, channel: channel, error: cliText("The update command finished, but the installed version could not be read."), updateFailed: true), sharers: sharers)
            return false
        }
        cliRefreshPending[lock] = after
        if let reason = await confirmCLIRefresh(sharers, expected: after) {
            writeCLIUpdateResult(cliFinishedUpdate(phase: .failed, installed: after, latest: target, channel: channel, error: reason, updateFailed: true), sharers: sharers)
            return false
        }
        cliRefreshPending[lock] = nil
        writeCLIUpdateResult(cliFinishedUpdate(phase: .updated, installed: after, latest: target, channel: channel, error: nil, updateFailed: false), sharers: sharers)
        return true
    }

    /// The executable still on this install, or nil when the wait should stop.
    /// A custom path, a disabled provider, and monitoring switched off are nil as well.
    private func preparedCLIExecutable(_ provider: ProviderKind, lock: String) -> URL? {
        guard !Task.isCancelled, settings.isEnabled(provider), (cliRecoveryLocks.contains(lock) || monitorsCLIUpdates(provider)),
              settings.binaryPath(for: provider).isEmpty,
              let executable = executable(for: provider), cliInstallLock(for: executable) == lock else { return nil }
        return executable
    }

    private func endCLIUpdateWait(
        _ requester: ProviderKind,
        lock: String,
        sharers: [ProviderKind],
        snapshot: [ProviderKind: CLIUpdateStatus]
    ) {
        if !stopCLIUpdateWait(requester, lock: lock, sharers: sharers, snapshot: snapshot) {
            restoreCLIWait(sharers, snapshot: snapshot)
        }
    }

    /// Restores the pre-wait status and reports whether the wait has to stop.
    /// A path that moved to another install keeps a visible reason. Switching monitoring off does not.
    private func stopCLIUpdateWait(
        _ requester: ProviderKind,
        lock: String,
        sharers: [ProviderKind],
        snapshot: [ProviderKind: CLIUpdateStatus]
    ) -> Bool {
        if Task.isCancelled || !settings.isEnabled(requester) || (!cliRecoveryLocks.contains(lock) && !monitorsCLIUpdates(requester))
            || !settings.binaryPath(for: requester).isEmpty {
            restoreCLIWait(sharers, snapshot: snapshot)
            return true
        }
        guard let executable = executable(for: requester), cliInstallLock(for: executable) == lock else {
            restoreCLIWait(sharers, snapshot: snapshot, requester: requester, failure: cliUpdateRefusal(requester, cliText("The binary changed before the update ran, so Tivano did not update it."), channel: nil, keeping: snapshot[requester]))
            return true
        }
        return false
    }

    /// Nil when the install is proved: the command's exit status is not enough. `after` has to be
    /// newer than `before`, and at least the feed's version when that feed had one.
    private func cliUpdateRejection(before: String, after: String?, latest: String?, commandFailure: String?) -> String? {
        if let commandFailure { return commandFailure }
        guard let after else {
            return cliText("The update command finished, but the installed version could not be read.")
        }
        switch CLIUpdates.compare(after, with: before) {
        case .newer:
            break
        case .equal:
            return cliText("The update command finished, but the version did not change.")
        case .older:
            return cliFormat("The update command finished, but the version went from %1$@ to %2$@.", before, after)
        case .unparsed:
            return cliText("The versions could not be compared, so the update was not kept as successful.")
        }
        guard let latest else { return nil }
        guard CLIUpdates.compare(latest, with: latest) == .equal else {
            return cliText("The versions could not be compared, so the update was not kept as successful.")
        }
        switch CLIUpdates.compare(after, with: latest) {
        case .newer, .equal:
            return nil
        case .older:
            return cliFormat("The update command finished at %1$@, which is older than %2$@.", after, latest)
        case .unparsed:
            return cliText("The versions could not be compared, so the update was not kept as successful.")
        }
    }

    /// Nil when every sharer's version and catalog reloaded. A failure here is not a successful update.
    private func confirmCLIRefresh(_ sharers: [ProviderKind], expected: String) async -> String? {
        guard !sharers.isEmpty else {
            return cliText("The CLI was updated, but the provider status could not be refreshed.")
        }
        var providerFailed = false
        var catalogFailed = false
        for provider in sharers {
            if await reloadCLIProvider(provider, expected: expected) == false { providerFailed = true }
            if await reloadCLICatalog(provider) == false { catalogFailed = true }
        }
        if providerFailed {
            return cliText("The CLI was updated, but the provider status could not be refreshed.")
        }
        if catalogFailed {
            return cliText("The CLI was updated, but the model catalog could not be reloaded.")
        }
        return nil
    }

    private func reloadCLIProvider(_ provider: ProviderKind, expected: String) async -> Bool {
        if let cliProviderReloader {
            return await cliProviderReloader(provider)
        }
        await refresh(provider)
        guard let version = status(provider).version else { return false }
        switch CLIUpdates.compare(version, with: expected) {
        case .equal, .newer: return true
        case .older, .unparsed: return false
        }
    }

    private func reloadCLICatalog(_ provider: ProviderKind) async -> Bool {
        if let cliCatalogReloader {
            return await cliCatalogReloader(provider)
        }
        while loadingCatalogs.contains(provider) {
            if Task.isCancelled { return false }
            try? await Task.sleep(for: .milliseconds(100))
        }
        let before = catalogFetchedAt[provider]
        await loadCatalog(provider, force: true)
        return catalogFetchedAt[provider] != before && !models(for: provider).isEmpty
    }

    private func setCLIUpdateStatus(_ status: CLIUpdateStatus?, for provider: ProviderKind) {
        guard cliUpdates[provider] != status else { return }
        cliUpdates[provider] = status
    }

    private func markCLIWaiting(_ providers: [ProviderKind]) {
        var updates = cliUpdates
        for provider in providers {
            var status = updates[provider] ?? CLIUpdateStatus(phase: .waiting)
            status.phase = .waiting
            status.error = nil
            status.updateFailed = false
            updates[provider] = status
            cliStatusEpoch[provider, default: 0] &+= 1
        }
        if cliUpdates != updates { cliUpdates = updates }
    }

    private func markCLIUpdating(_ providers: [ProviderKind], channel: CLIInstallChannel, installed: String, latest: String?) {
        var updates = cliUpdates
        for provider in providers {
            var status = updates[provider] ?? CLIUpdateStatus(phase: .updating)
            status.phase = .updating
            status.installed = installed
            status.latest = latest
            status.channel = channel
            status.error = nil
            status.updateFailed = false
            updates[provider] = status
            cliStatusEpoch[provider, default: 0] &+= 1
        }
        if cliUpdates != updates { cliUpdates = updates }
    }

    private func restoreCLIWait(
        _ sharers: [ProviderKind],
        snapshot: [ProviderKind: CLIUpdateStatus],
        requester: ProviderKind? = nil,
        failure: CLIUpdateStatus? = nil
    ) {
        var updates = cliUpdates
        for provider in sharers where updates[provider]?.phase != .updating {
            if provider == requester, let failure {
                updates[provider] = failure
            } else {
                updates[provider] = snapshot[provider]
            }
        }
        if cliUpdates != updates { cliUpdates = updates }
    }

    private func cliUpdateRefusal(_ provider: ProviderKind, _ reason: String, channel: CLIInstallChannel?, keeping previous: CLIUpdateStatus?) -> CLIUpdateStatus {
        var status = previous ?? cliUpdates[provider] ?? CLIUpdateStatus(phase: .failed)
        status.phase = .failed
        status.error = cliReason(reason)
        status.updateFailed = true
        status.channel = channel
        status.checkedAt = .now
        return status
    }

    private func cliFinishedUpdate(
        phase: CLIUpdateStatus.Phase,
        installed: String?,
        latest: String?,
        channel: CLIInstallChannel?,
        error: String?,
        updateFailed: Bool
    ) -> CLIUpdateStatus {
        return CLIUpdateStatus(
            phase: phase,
            installed: installed,
            latest: latest,
            channel: channel,
            error: error.map { cliReason($0) },
            updateFailed: updateFailed,
            checkedAt: .now
        )
    }

    private func writeCLIUpdateResult(_ status: CLIUpdateStatus, sharers: [ProviderKind]) {
        var updates = cliUpdates
        for provider in sharers {
            updates[provider] = status
            cliCheckCache[provider] = nil
        }
        if cliUpdates != updates { cliUpdates = updates }
    }

    // MARK: - Install identity

    /// Version directories and pnpm's content hash change when the install does. The lock is the
    /// install root, so the request that arrives while an update is running awaits that same run.
    /// Native Claude collapses to `~/.local/share/claude` whether `which` returned the launcher or a version.
    private func cliInstallLock(for executable: URL) -> String {
        let path = cliProbe.standardize(executable.path)
        let resolved = cliProbe.standardize((cliProbe.installLayout?(executable) ?? cliProbe.resolve(executable)).path)
        let revealed = normalizedCLIInstallLock(resolved)
        return revealed.hasPrefix("path:") ? normalizedCLIInstallLock(path) : revealed
    }

    private func normalizedCLIInstallLock(_ path: String) -> String {
        if let claude = claudeInstallLock(path) { return claude }
        let home = cliProbe.standardize(cliProbe.home())
        let dataHome = CLIInstallEnvironment.current["XDG_DATA_HOME"].flatMap { $0.isEmpty ? nil : cliProbe.standardize($0) } ?? home + "/.local/share"
        for (name, root, launchers) in [
            ("cursor", home + "/.local/share/cursor-agent", [home + "/.local/bin/cursor-agent", home + "/.local/bin/agent"]),
            ("grok", home + "/.grok", [home + "/.grok/bin/grok"]),
            ("devin", dataHome + "/devin/cli", [home + "/.local/bin/devin"]),
        ] {
            if path.hasPrefix(root + "/") || launchers.contains(path) { return name + ":" + root }
        }
        if let pnpm = pnpmInstallLock(path) { return pnpm }
        let parts = (path as NSString).pathComponents
        if let modules = parts.firstIndex(of: "node_modules"), modules + 2 < parts.count {
            let end = modules + (parts[modules + 1].hasPrefix("@") ? 3 : 2)
            if end <= parts.count { return "package:" + NSString.path(withComponents: Array(parts[..<end])) }
        }
        if let brew = homebrewInstallLock(path) { return brew }
        if let pnpm = pnpmInstallLock(path) { return pnpm }
        return "path:" + path
    }

    private func claudeInstallLock(_ path: String) -> String? {
        let home = cliProbe.standardize(cliProbe.home())
        let root = cliProbe.standardize((home as NSString).appendingPathComponent(".local/share/claude"))
        let launcher = cliProbe.standardize((home as NSString).appendingPathComponent(".local/bin/claude"))
        let versions = (root as NSString).appendingPathComponent("versions")
        guard path == launcher || path == root || path == versions || path.hasPrefix(versions + "/") else { return nil }
        return "claude:" + root
    }

    private func homebrewInstallLock(_ path: String) -> String? {
        let parts = (path as NSString).pathComponents
        guard let index = parts.lastIndex(where: { $0 == "Cellar" || $0 == "Caskroom" }),
              index >= 1, index + 1 < parts.count else { return nil }
        let token = parts[index + 1]
        guard token != ".", token != ".." else { return nil }
        let kind = parts[index] == "Caskroom" ? "cask" : "formula"
        let prefix = NSString.path(withComponents: Array(parts[..<index]))
        return "homebrew:\(kind):\(token):\(prefix)"
    }

    private func pnpmInstallLock(_ path: String) -> String? {
        let parts = (path as NSString).pathComponents
        guard let global = parts.lastIndex(of: "global"),
              global >= 1, global + 1 < parts.count, parts[global + 1] == "v11" else { return nil }
        return "pnpm:" + NSString.path(withComponents: Array(parts[..<global]))
    }

    private func providersSharingCLIInstall(_ lock: String) -> [ProviderKind] {
        ProviderKind.allCases.filter { provider in
            guard !provider.isAPIKeyBased, let executable = executable(for: provider) else { return false }
            return cliInstallLock(for: executable) == lock
        }
    }

    private func sharesCLIPhase(_ provider: ProviderKind, phases: Set<CLIUpdateStatus.Phase>) -> Bool {
        guard cliUpdates.contains(where: { phases.contains($0.value.phase) }) else { return false }
        guard let executable = executable(for: provider) else { return false }
        let lock = cliInstallLock(for: executable)
        return providersSharingCLIInstall(lock).contains { provider in
            guard let phase = cliUpdates[provider]?.phase else { return false }
            return phases.contains(phase)
        }
    }

    private func cliText(_ key: String.LocalizationValue) -> String {
        String(localized: key)
    }

    private func cliFormat(_ key: String.LocalizationValue, _ arguments: CVarArg...) -> String {
        String(format: String(localized: key), arguments: arguments)
    }

    private func cliReason(_ text: String) -> String {
        let line = TextCleanup.singleLine(TextCleanup.stripANSI(text), limit: 180)
        if !line.isEmpty { return line }
        return cliText("The update check failed.")
    }
}
