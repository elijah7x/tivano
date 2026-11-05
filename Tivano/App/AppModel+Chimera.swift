import Foundation

extension AppModel {
    func chimeraAvailable(_ thread: ChatThread) -> Bool {
        settings.isChimeraEnabled && !thread.isHelper
    }

    func chimeraIsOn(_ thread: ChatThread) -> Bool {
        settings.isChimeraEnabled && thread.chimeraEnabled && !thread.isHelper
    }

    /// Hydra's own switch for display, unlike hydraIsOn which also covers Chimera's heads.
    func hydraModeIsOn(_ thread: ChatThread) -> Bool {
        settings.hydraEnabled && thread.hydraEnabled && !thread.isHelper && !chimeraIsOn(thread)
    }

    /// Whether a cast pick can run on this Mac now: a remembered or preset pick may name a
    /// provider since switched off or uninstalled.
    func chimeraCanRun(_ pick: ChimeraPick) -> Bool {
        settings.isEnabled(pick.provider) && providers.status(pick.provider).isInstalled
            && pick.model.map { providers.model($0, for: pick.provider) != nil } ?? true
    }

    func canSwitchChimeraMode(_ id: UUID) -> Bool {
        guard thread(id) != nil else { return false }
        let runtime = existingRuntime(for: id)
        return (runtime == nil || runtime?.phase == .idle)
            && !hydraTeam(of: id).contains { $0.hydra?.isFinished == false }
            && (runtime?.hydraWaitingCount ?? 0) == 0
            && runtime?.chimeraCasting == nil
    }

    func setChimera(_ on: Bool, for id: UUID) {
        guard canSwitchChimeraMode(id), let thread = thread(id),
              thread.chimeraEnabled != on else { return }
        guard !on || chimeraAvailable(thread) else { return }
        if openHydraJob(of: id) != nil {
            Task { await endHydraJobsForHydraOff(of: id) }
        }
        if on {
            let snapshot = ChimeraHydraSnapshot(
                hydraEnabled: thread.hydraEnabled,
                hydraPairID: thread.hydraPairID,
                temporaryHydraPair: thread.temporaryHydraPair
            )
            leaveHydraPair(for: id)
            updateThread(id) {
                $0.chimeraHydraSnapshot = snapshot
                $0.chimeraEnabled = true
                $0.hydraEnabled = false
            }
        } else {
            restoreHydra(fromChimera: id)
        }
    }

    /// Chimera switched off for the app: every chat lit with it goes back to its Hydra, any
    /// casting or heads of its job ended, so no chat is left with neither mode on.
    func leaveChimeraEverywhere() {
        for thread in threads where thread.chimeraEnabled {
            if openHydraJob(of: thread.id) != nil {
                Task { await endHydraJobsForHydraOff(of: thread.id) }
            }
            restoreHydra(fromChimera: thread.id)
        }
    }

    private func restoreHydra(fromChimera id: UUID) {
        guard let thread = thread(id) else { return }
        // A chat lit before snapshots existed keeps its Hydra fields as they are.
        guard let snapshot = thread.chimeraHydraSnapshot else {
            updateThread(id) { $0.chimeraEnabled = false }
            return
        }
        // The pair comes back as the chat had it, written back as stored: entering it
        // anew would also switch the chat to the pair's lead model, which the chat may
        // never have been on. A pair since deleted or on another provider stays gone.
        let temporary = snapshot.temporaryHydraPair.flatMap {
            $0.id == snapshot.hydraPairID ? $0 : nil
        }
        let pair = (temporary ?? settings.hydraPair(snapshot.hydraPairID))
            .flatMap { $0.provider == thread.provider ? $0 : nil }
        updateThread(id) {
            $0.chimeraEnabled = false
            $0.chimeraHydraSnapshot = nil
            $0.hydraEnabled = snapshot.hydraEnabled
            $0.hydraPairID = pair?.id
            $0.temporaryHydraPair = pair == nil ? nil : temporary
        }
    }
}
