import Foundation

extension AppModel {
    /// The only place that chooses the project and creates the call's home chat.
    func voiceHomeThread() -> ChatThread? {
        let affiliation: ThreadAffiliation = currentAffiliation
        if let id: UUID = affiliation.projectID, project(id) == nil { return nil }
        let current: ChatThread? = selectedThread?.provider == .codex ? selectedThread : nil
        let modelID: String? = current?.model ?? providers.defaultModel(for: .codex)?.id
        let effort: String? = current?.effort ?? settings.lastEffort(for: .codex)
        let runtimeMode: RuntimeMode = settings.defaultRuntimeMode
        let fastMode: Bool = current?.fastMode ?? false
        var thread = ChatThread(
            projectID: affiliation.projectID,
            provider: .codex,
            model: modelID,
            effort: effort,
            runtimeMode: runtimeMode,
            fastMode: fastMode
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
        let hydra = hydraLaunch(for: thread)
        return VoiceOrchestratorContext(
            hydra: hydra != nil,
            projectName: project(thread.projectID)?.name ?? Chrome.localized("Task"),
            hydraPolicy: hydra.map { HydraPrompts.fallbackPolicy($0) }
        )
    }
}
