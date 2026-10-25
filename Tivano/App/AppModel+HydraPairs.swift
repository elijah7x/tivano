import Foundation

// A pair set up in Settings is somewhere a chat goes, not a rule it falls under: with Hydra
// on, the composer's model picker lists every pair that is ready to run, and one tap puts
// the chat in it. Entering a pair is the same move as choosing a model, with the pair's
// lead model and effort instead of a single model and the pair pinned to the chat; a chat
// made from it carries the pair along. Choosing a model from the rows below the pairs is
// the move back out: the chat is on that model alone, its heads on it too, Hydra as it was.

extension AppModel {
    /// The pairs the model picker offers: the ones whose provider is installed and
    /// switched on, in the order they were set up. A provider no check has looked at yet
    /// counts as installed (`countsAsInstalled`): the chat a launch opens is built before
    /// the providers are probed, and it must still find the pair it was last worked in.
    var hydraPickerPairs: [HydraPair] {
        settings.hydraPairs.filter { providers.countsAsInstalled($0.provider) && settings.isEnabled($0.provider) }
    }

    /// Whether a chat leads with this pair right now: Hydra on, and the pair the one picked
    /// for the chat, which is still on its provider. Exactly one pair, or none, at a time.
    func leadsWithHydraPair(_ pair: HydraPair, thread: ChatThread) -> Bool {
        hydraIsOn(thread) && thread.hydraPairID == pair.id && thread.provider == pair.provider
    }

    /// The chat's temporary pair while it leads with it.
    func temporaryHydraPair(for thread: ChatThread) -> HydraPair? {
        guard let pair = thread.temporaryHydraPair, leadsWithHydraPair(pair, thread: thread) else { return nil }
        return pair
    }

    /// Puts a chat in a pair of its own, made in the picker and never saved: it starts on
    /// the chat's provider, model and effort, and the picker's editor shapes it from there.
    func startTemporaryHydraPair(for threadID: UUID) {
        guard let thread = thread(threadID) else { return }
        var pair = HydraPair(provider: thread.provider)
        pair.orchestratorModel = thread.model
        pair.orchestratorEffort = thread.effort
        enterHydraPair(pair, for: threadID, temporary: true)
    }

    /// Edits the chat's temporary pair and moves the chat along with it, provider, lead
    /// model and effort, the way entering it did.
    func updateTemporaryHydraPair(for threadID: UUID, _ change: (inout HydraPair) -> Void) {
        guard var pair = thread(threadID)?.temporaryHydraPair else { return }
        let before = pair
        change(&pair)
        guard pair != before else { return }
        enterHydraPair(pair, for: threadID, temporary: true)
    }

    /// Puts a chat in a pair from the model picker: it switches to the pair's provider and
    /// lead model and effort, pins the pair so it keeps leading with this one, and Hydra
    /// goes on for the app. The session is left to restart itself: the runtime launches the
    /// next turn with the pair's head definitions on its own.
    /// A temporary pair rides on the chat itself and is not remembered for new chats.
    func enterHydraPair(_ pair: HydraPair, for threadID: UUID, temporary: Bool = false) {
        guard let thread = thread(threadID) else { return }
        let provider = pair.provider
        let switchesProvider = provider != thread.provider
        let lead = hydraLead(of: pair, for: thread)
        updateThread(threadID) { thread in
            if switchesProvider {
                thread.provider = provider
                thread.providerSessionID = nil
            }
            thread.model = lead.model
            thread.effort = lead.effort
            thread.fastMode = lead.fastMode
            thread.dshMode = lead.dshMode
            thread.hydraPairID = pair.id
            thread.temporaryHydraPair = temporary ? pair : nil
            thread.hydraEnabled = true
        }
        // A chat that changes provider leaves its old session behind, as a model choice does.
        if switchesProvider { existingRuntime(for: threadID)?.stopSession() }
        settings.remember(model: lead.model, effort: lead.effort, for: provider)
        settings.defaultProvider = provider
        settings.lastHydraPairID = temporary ? nil : pair.id
        settings.hydraEnabled = true
        settings.hydraDefaultEnabled = true
    }

    /// The model, effort, fast mode and DeepSeek Harness agent mode a chat runs on as a pair's lead.
    func hydraLead(of pair: HydraPair, for thread: ChatThread) -> (model: String?, effort: String?, fastMode: Bool, dshMode: DshAgentMode?) {
        let provider = pair.provider
        let switchesProvider = provider != thread.provider
        // A pair with no lead model runs on any model, so the chat keeps the one it is on;
        // arriving from another provider there is nothing to keep and it takes that
        // provider's default.
        let option: ModelOption? = if let lead = pair.orchestratorModel {
            providers.model(lead, for: provider)
        } else if switchesProvider {
            providers.defaultModel(for: provider)
        } else {
            providers.model(thread.model, for: provider)
        }
        // The pair's lead model is the chat's even before the provider's catalog lists it:
        // the chip shows the id until the list arrives, rather than staying on the model
        // the chat had, with the pair's checkmark on a model it is not on.
        let modelID = option?.id ?? pair.orchestratorModel ?? (switchesProvider ? nil : thread.model)
        let preference = settings.preference(for: provider, model: modelID)
        // The pair's own effort wins. Without one the chat picks up what this model was
        // last left on, the way choosing the model by hand does.
        let effort: String? = if let chosen = pair.orchestratorEffort, option?.efforts.contains(chosen) ?? true {
            chosen
        } else {
            preference.effort.flatMap { (option?.efforts.contains($0) ?? false) ? $0 : nil }
        }
        // Like its effort, the pair's agent mode is the chat's on entering; the chat can change it after.
        let dshMode = provider == .dsh && pair.orchestratorDshMode != .standard ? pair.orchestratorDshMode : nil
        return (modelID, effort, (option?.supportsFast ?? false) && preference.fastMode, dshMode)
    }

    /// Edits a pair in Settings and moves the chats leading with it along: the pair is
    /// where those chats are, so a new lead model or effort is theirs at once, the way
    /// entering the pair set them, and the chip says so. A pair whose lead provider
    /// changes lets its chats go instead: a chat does not change provider under a
    /// conversation, so it stays on its own model, Hydra as it was, out of the pair.
    func updateHydraPair(_ id: UUID, _ change: (inout HydraPair) -> Void) {
        let before = settings.hydraPair(id)
        settings.updateHydraPair(id, change)
        guard let pair = settings.hydraPair(id), pair != before else { return }
        for thread in threads where thread.hydraPairID == id && hydraIsOn(thread) {
            guard pair.provider == thread.provider else {
                updateThread(thread.id) { $0.hydraPairID = nil }
                continue
            }
            let lead = hydraLead(of: pair, for: thread)
            guard lead.model != thread.model || lead.effort != thread.effort || lead.fastMode != thread.fastMode || lead.dshMode != thread.dshMode else { continue }
            updateThread(thread.id) {
                $0.model = lead.model
                $0.effort = lead.effort
                $0.fastMode = lead.fastMode
                $0.dshMode = lead.dshMode
            }
            settings.remember(model: lead.model, effort: lead.effort, for: pair.provider)
        }
    }

    /// Removes a pair and takes every chat out of it, so no chat keeps pointing at a pair
    /// that is gone: each stays on its own model, Hydra as it was.
    func removeHydraPair(_ id: UUID) {
        settings.removeHydraPair(id)
        if settings.lastHydraPairID == id { settings.lastHydraPairID = nil }
        for thread in threads where thread.hydraPairID == id {
            updateThread(thread.id) { $0.hydraPairID = nil }
        }
        // A project rule that names the removed pair is gone too. The project's new chats
        // start on the remembered pair again.
        for project in projects where project.hydraPairID == id {
            updateProject(project.id) { $0.hydraPairID = nil }
        }
    }

    func inheritableHydraPair(from current: ChatThread?, into project: Project?) -> UUID? {
        guard let current else { return nil }
        // A project-default pair must not become the default for unrelated tasks.
        if project == nil, let source = self.project(current.projectID), source.hydraPairID == current.hydraPairID {
            return nil
        }
        return current.hydraPairID
    }

    /// Sets the pair that each new chat in a project starts on. Nil removes the rule.
    /// Open chats do not change: the rule applies to new chats only.
    func setHydraPair(_ pairID: UUID?, forProject projectID: UUID) {
        updateProject(projectID) { $0.hydraPairID = pairID }
    }

    /// Takes a chat out of the pair it leads with, when a model is chosen from the picker's
    /// model rows: the reverse of `enterHydraPair`. The chat is on that model alone, with
    /// no pair's mark on its chip; Hydra stays as Settings has it, its heads on the chat's
    /// own model and effort until a pair is picked again.
    func leaveHydraPair(for threadID: UUID) {
        updateThread(threadID) {
            $0.hydraPairID = nil
            $0.temporaryHydraPair = nil
        }
        settings.lastHydraPairID = nil
    }
}
