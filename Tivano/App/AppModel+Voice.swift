import Foundation

extension AppModel {
    /// The only place that chooses the project and creates the call's home chat.
    func voiceHomeThread() -> ChatThread? {
        guard let project = currentProject else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: project.path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
        let current = selectedThread?.provider == .codex ? selectedThread : nil
        var thread = ChatThread(
            projectID: project.id,
            provider: .codex,
            model: current?.model ?? providers.defaultModel(for: .codex)?.id,
            effort: current?.effort ?? settings.lastEffort(for: .codex),
            runtimeMode: settings.defaultRuntimeMode,
            fastMode: current?.fastMode ?? false
        )
        thread.title = NSLocalizedString(VoiceCatalog.orchestratorTitle, comment: "")
        thread.isVoiceSession = true
        thread.hasCustomTitle = true
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
        guard let thread = thread(threadID), let project = project(thread.projectID) else { return nil }
        let hydra = hydraLaunch(for: thread)
        return VoiceOrchestratorContext(
            hydra: hydra != nil,
            projectName: project.name,
            hydraPolicy: hydra.map { HydraPrompts.fallbackPolicy($0) }
        )
    }
}
