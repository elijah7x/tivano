import Foundation

extension AppModel {
    func modelLabel(provider: ProviderKind, model: String?) -> String {
        guard model != nil else { return provider.displayName }
        return "\(provider.displayName) · \(modelName(provider: provider, model: model))"
    }

    /// The model alone, as its chip names it; the provider when the chat has no model yet.
    func modelName(provider: ProviderKind, model: String?) -> String {
        guard let model else { return provider.displayName }
        return providers.model(model, for: provider).map { $0.label(among: pinnedOptions(for: provider)) }
            ?? ModelPin(provider: provider, modelID: model).displayName
    }

    func stageProviderSwitch(_ threadID: UUID, apply: (inout ChatThread) -> Void) {
        var undoneSessionLost: Bool?
        updateThread(threadID) { thread in
            if thread.pendingProviderSwitch == nil {
                thread.pendingProviderSwitch = ProviderSwitchOrigin(provider: thread.provider, model: thread.model, effort: thread.effort, fastMode: thread.fastMode, dshMode: thread.dshMode, runtimeMode: thread.runtimeMode, interactionMode: thread.interactionMode, hydraEnabled: thread.hydraEnabled, hydraEnabledIsExplicit: thread.hydraEnabledIsExplicit, hydraPairID: thread.hydraPairID, temporaryHydraPair: thread.temporaryHydraPair, providerSessionID: thread.providerSessionID, providerResumeAt: thread.providerResumeAt)
            }
            guard let origin = thread.pendingProviderSwitch else { return }
            apply(&thread)
            thread.providerSessionID = nil
            thread.providerResumeAt = nil
            if thread.provider == origin.provider {
                // Back on the old provider: its session returns and the new selection holds,
                // including any Hydra pair, as an ordinary same-provider choice would.
                let applied = thread
                Self.restoreProviderSwitch(&thread, origin: origin)
                thread.model = applied.model
                thread.effort = applied.effort
                thread.fastMode = applied.fastMode
                thread.dshMode = applied.dshMode
                thread.hydraEnabled = applied.hydraEnabled
                thread.hydraEnabledIsExplicit = applied.hydraEnabledIsExplicit
                thread.hydraPairID = applied.hydraPairID
                thread.temporaryHydraPair = applied.temporaryHydraPair
                undoneSessionLost = origin.providerSessionID == nil && !origin.provider.restoresFromTextTranscript
            }
        }
        // Picking the old provider again is an undo: the failed send's handoff snapshot must
        // not reach the session the switch went back to.
        if let undoneSessionLost { existingRuntime(for: threadID)?.providerSwitchUndone(sessionLost: undoneSessionLost) }
    }

    private static func restoreProviderSwitch(_ thread: inout ChatThread, origin: ProviderSwitchOrigin) {
        thread.provider = origin.provider
        thread.runtimeMode = origin.runtimeMode
        thread.model = origin.model
        thread.effort = origin.effort
        thread.fastMode = origin.fastMode
        thread.dshMode = origin.dshMode
        thread.interactionMode = origin.interactionMode
        thread.hydraEnabled = origin.hydraEnabled
        thread.hydraEnabledIsExplicit = origin.hydraEnabledIsExplicit
        thread.hydraPairID = origin.hydraPairID
        thread.temporaryHydraPair = origin.temporaryHydraPair
        thread.providerSessionID = origin.providerSessionID
        thread.providerResumeAt = origin.providerResumeAt
        thread.pendingProviderSwitch = nil
    }

    func undoProviderSwitch(_ threadID: UUID) {
        let runtime = runtime(for: threadID)
        // Restore and settle the snapshot in one step after loading, so a send or another
        // switch made meanwhile is never overwritten by a late undo.
        Task { @MainActor in
            await runtime.ensureLoaded()
            guard runtime.phase == .idle, !runtime.isReverting,
                  let origin = thread(threadID)?.pendingProviderSwitch else { return }
            let sessionLost = origin.providerSessionID == nil && !origin.provider.restoresFromTextTranscript
            updateThread(threadID) { Self.restoreProviderSwitch(&$0, origin: origin) }
            runtime.providerSwitchUndone(sessionLost: sessionLost)
        }
    }

    func completeProviderSwitch(_ threadID: UUID) {
        guard let thread = thread(threadID), thread.pendingProviderSwitch != nil else { return }
        updateThread(threadID) { $0.pendingProviderSwitch = nil }
        settings.remember(model: thread.model, effort: thread.effort, for: thread.provider)
        settings.defaultProvider = thread.provider
        settings.lastHydraPairID = thread.temporaryHydraPair == nil ? thread.hydraPairID : nil
        if thread.hydraEnabled, thread.hydraPairID != nil {
            settings.hydraEnabled = true
            settings.hydraDefaultEnabled = true
        }
    }
}
