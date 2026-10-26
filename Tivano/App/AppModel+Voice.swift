import Foundation

extension AppModel {
    /// The only place that chooses the project and creates the call's home chat.
    func voiceHomeThread() -> ChatThread? {
        let affiliation = currentAffiliation
        if let id = affiliation.projectID, project(id) == nil { return nil }
        let current = selectedThread?.provider == .codex ? selectedThread : nil
        var thread = ChatThread(
            projectID: affiliation.projectID,
            provider: .codex,
            model: current?.model ?? providers.defaultModel(for: .codex)?.id,
            effort: current?.effort ?? settings.lastEffort(for: .codex),
            runtimeMode: settings.defaultRuntimeMode,
            fastMode: current?.fastMode ?? false
        )
        thread.title = NSLocalizedString(VoiceCatalog.orchestratorTitle, comment: "")
        thread.isVoiceSession = true
        thread.hasCustomTitle = true
        do {
            let directory = try ensureExecutionDirectory(for: thread)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
        } catch {
            alert = AppAlert(title: "Could not open task workspace", message: error.localizedDescription)
            return nil
        }
        insertVoiceHomeThread(thread)
        return thread
    }

    /// The session-level brief, only for chats made for voice.
    func voiceContext(for threadID: UUID) -> VoiceOrchestratorContext? {
        guard thread(threadID)?.isVoiceSession == true else { return nil }
        return voiceCallContext(for: threadID)
    }

    /// What every call's realtime start carries, whichever Codex chat it joins.
    func voiceInstructions(for threadID: UUID) -> String? {
        voiceCallContext(for: threadID).map(VoiceCatalog.orchestratorInstructions(context:))
    }

    private func voiceCallContext(for threadID: UUID) -> VoiceOrchestratorContext? {
        guard let thread = thread(threadID), (try? executionDirectory(for: thread)) != nil else { return nil }
        var hydra = hydraLaunch(for: thread)
        if openHydraJob(of: threadID) != nil,
           let mode = existingRuntime(for: threadID)?.hydraJobMode, mode == .v2 {
            hydra?.mode = mode
        } else {
            hydra?.mode = settings.isHydra2Enabled ? .v2 : .v1
        }
        return VoiceOrchestratorContext(
            hydra: hydra != nil,
            projectName: project(thread.projectID)?.name ?? Chrome.localized("Task"),
            hydraPolicy: hydra.map { HydraPrompts.fallbackPolicy($0) }
        )
    }
}
