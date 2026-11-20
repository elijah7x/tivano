import SwiftUI

/// Switches sub-agents on for the app and configures the three sub-agent modes,
/// execution, delegation, completion review, and Codex sub-agent history.
struct HydraSettingsPage: View {
    @Environment(AppModel.self) private var model
    var query = ""

    private static let maxHeadsOptions = [ChromeSegmentedOption(value: Int?.none, title: "No cap", symbol: "infinity")]
        + HydraPair.maxHeadsRange.map { ChromeSegmentedOption(value: Optional($0), title: String($0)) }
    private static let checkoutOptions = [(true, "Own copy"), (false, "Shared")]
    private static let detailOptions = [(false, "Progress bar"), (true, "Live steps")]
    private enum PanelLayout: Hashable {
        case single, independent, off

        var symbol: String {
            switch self {
            case .single: "rectangle"
            case .independent: "square.grid.2x2"
            case .off: "rectangle.slash"
            }
        }
    }
    private static let panelOptions = [(PanelLayout.single, "Single panel"), (.independent, "One per sub-agent"), (.off, "Off")]
    private static let historyOptions = [(false, "Keep visible"), (true, "Auto-archive")]

    private var trimmedQuery: String { query.trimmed }

    private var panelLayoutBinding: Binding<PanelLayout> {
        Binding(
            get: {
                if !model.settings.hydraAutoOpensPanels { return .off }
                return model.settings.hydraAutoPopsHeads ? .independent : .single
            },
            set: { layout in
                switch layout {
                case .single:
                    model.settings.hydraAutoOpensPanels = true
                    model.settings.hydraAutoPopsHeads = false
                case .independent:
                    model.settings.hydraAutoOpensPanels = true
                    model.settings.hydraAutoPopsHeads = true
                case .off:
                    model.settings.hydraAutoOpensPanels = false
                }
            }
        )
    }

    private var panelLayoutDetail: String {
        if !model.settings.hydraAutoOpensPanels {
            return "Does not open floating panels automatically. The chat still shows which sub-agents are running, and you can open a panel yourself."
        }
        return model.settings.hydraAutoPopsHeads
            ? "When multiple sub-agents run, each sub-agent after the first automatically opens its own floating panel: on both sides of the chat when wide enough, or stacked on one side when narrow."
            : "Keeps all running sub-agents in one floating panel; switch between them from its top-left menu, or pop individual sub-agents out manually."
    }

    private func shows(_ keys: [String]) -> Bool {
        guard !trimmedQuery.isEmpty else { return true }
        return keys.contains { key in
            [key, Chrome.localized(key)].contains {
                $0.localizedCaseInsensitiveContains(trimmedQuery)
            }
        }
    }

    var body: some View {
        @Bindable var settings = model.settings
        let searchQuery = trimmedQuery.lowercased(with: .current)
        let matchingCombos = searchQuery.isEmpty
            ? settings.hydraPairs
            : settings.hydraPairs.filter { ComboSettingsSection.matches($0, registry: model.providers, query: searchQuery) }
        let matchesPresetSection = shows([
            "Preset sub-agents",
            "Save a lead model with a sub-agent model or provider, then pick it in the model picker.",
            "Suggested combos",
            "Combos",
            "Add combo",
            "Another combo",
        ])
        let isFilteringCombos = !trimmedQuery.isEmpty && !matchingCombos.isEmpty
        let showsHeader = shows([
            "Sub-agents",
            "Let the lead model split independent work across parallel sub-agents.",
        ])
        let showsSameModel = shows([
            "Same-model sub-agents",
            "The current model splits the work and sends sub-agents on the same model.",
            "Lower the default reasoning effort for sub-agents",
        ])
        let showsPreset = trimmedQuery.isEmpty || !matchingCombos.isEmpty || matchesPresetSection
        let matchesIdentityItem = !trimmedQuery.isEmpty && settings.chimeraPresets.contains { preset in
            preset.name.localizedCaseInsensitiveContains(trimmedQuery)
                || preset.effectivePrompt.localizedCaseInsensitiveContains(trimmedQuery)
                || (preset.builtin.map {
                    $0.title.localizedCaseInsensitiveContains(trimmedQuery)
                        || Chrome.localized($0.title).localizedCaseInsensitiveContains(trimmedQuery)
                        || Chrome.localized($0.defaultPrompt).localizedCaseInsensitiveContains(trimmedQuery)
                } ?? false)
                || (preset.pick?.provider.displayName.localizedCaseInsensitiveContains(trimmedQuery) ?? false)
                || (preset.pick?.model?.localizedCaseInsensitiveContains(trimmedQuery) ?? false)
        }
        let showsAdaptive = matchesIdentityItem || shows([
            "Adaptive sub-agents",
            "The lead splits the work into roles, picks an identity and model for each, and you confirm before they start.",
            "Auto-dispatch",
            "Send sub-agents out as soon as the lead picks them, without waiting for you.",
            "Built-in identities",
            "My identities",
            "Add identity",
        ])
        let showsExecution = shows([
            "Execution & panels",
            "Working directory",
            "Sub-agents at once per chat",
            "Floating panel content",
            "Floating panel layout",
            "Off",
            "Does not open floating panels automatically. The chat still shows which sub-agents are running, and you can open a panel yourself.",
        ])
        let showsDelegation = shows([
            "Delegation",
            "How much sub-agents take on",
            "Restrained",
            "Proactive",
            "Aggressive",
        ])
        let showsFinish = shows([
            "When sub-agents finish",
            "Independent review",
            "Review models",
            "Commit and merge automatically when done",
        ])
        let showsHistory = shows([
            "Codex sub-agent history",
            "After completion",
            "Keep visible",
            "Auto-archive",
            "Codex",
        ])

        if showsHeader {
            VStack(alignment: .leading, spacing: Chrome.sectionHeaderSpacing) {
                ChromeCard {
                    ChromeRow(
                        title: "Sub-agents",
                        detail: "Let the lead model split independent work across parallel sub-agents."
                    ) {
                        HStack(spacing: 8) {
                            InfoHoverButton(help: "How sub-agent teams work") { HydraInfoPopover(topic: .hydra) }
                            SettingsSwitch(isOn: $settings.hydraEnabled)
                                .accessibilityLabel(Text("Sub-agents"))
                        }
                    }
                }
                // One note for the mode and execution sections: they dim together rather than
                // each row repeating why it is off.
                if !settings.hydraEnabled {
                    Text("Turn on sub-agents to configure modes and execution.")
                        .font(.ui(.subheadline))
                        .foregroundStyle(Chrome.secondaryText)
                        .padding(.horizontal, 4)
                }
            }
        }
        Group {
            if showsSameModel {
                ChromeSection(title: "Same-model sub-agents") {
                    sectionDetail("The current model splits the work and sends sub-agents on the same model.")
                    ChromeCard {
                        toggleRow(
                            "Lower the default reasoning effort for sub-agents",
                            detail: "Effort set in a combo is unaffected. When no effort is specified and the sub-agent uses the same provider as the lead, the sub-agent stays at the standard effort (usually medium); if the lead uses a lower effort, the sub-agent inherits it.",
                            isOn: $settings.hydraTempersHeadEffort
                        )
                    }
                }
            }
            if showsPreset {
                ComboSettingsSection(
                    pairs: isFilteringCombos ? matchingCombos : settings.hydraPairs,
                    isFiltering: isFilteringCombos
                )
            }
            if showsAdaptive {
                ChromeSection(title: "Adaptive sub-agents") {
                    sectionDetail("The lead splits the work into roles, picks an identity and model for each, and you confirm before they start.")
                    ChromeCard {
                        ChromeRow(title: "Adaptive sub-agents", detail: nil) {
                            SettingsSwitch(isOn: $settings.alphaChimeraEnabled)
                                .accessibilityLabel(Text("Adaptive sub-agents"))
                        }
                        ChromeRowDivider()
                        ChromeRow(
                            title: "Auto-dispatch",
                            detail: "Send sub-agents out as soon as the lead picks them, without waiting for you."
                        ) {
                            SettingsSwitch(isOn: $settings.chimeraAutoDispatch)
                                .accessibilityLabel(Text("Auto-dispatch"))
                        }
                        .disabled(!settings.isChimeraEnabled)
                        .opacity(settings.isChimeraEnabled ? 1 : 0.5)
                        .animation(.smooth(duration: 0.2), value: settings.isChimeraEnabled)
                    }
                    ChimeraPresetsSection()
                        .disabled(!settings.isChimeraEnabled)
                        .opacity(settings.isChimeraEnabled ? 1 : 0.5)
                        .animation(.smooth(duration: 0.2), value: settings.isChimeraEnabled)
                }
            }
            if showsExecution {
                ChromeSection(title: "Execution & panels", accessory: AnyView(InfoHoverButton(help: "How sub-agents work") { HydraInfoPopover(topic: .heads) })) {
                    ChromeCard {
                        ChromeRow(
                            title: "Working directory",
                            detail: settings.hydraIsolateHeads
                                ? "Each sub-agent works in a copy of its own; its changes land in the chat's checkout when it reports."
                                : "Sub-agents work in the chat's checkout itself."
                        ) {
                            ChromeVisualPicker(options: Self.checkoutOptions, selection: $settings.hydraIsolateHeads) { isolated in
                                Image(systemName: isolated ? "doc.on.doc" : "folder")
                            }
                        }
                        ChromeRowDivider()
                        ChromeRow(
                            title: "Sub-agents at once per chat",
                            detail: "The lower of this limit and the combo's limit applies. No cap adds no limit here."
                        ) {
                            ChromeSegmentedPicker(
                                options: Self.maxHeadsOptions,
                                selection: $settings.hydraMaxHeads
                            )
                        }
                        ChromeRowDivider()
                        ChromeRow(
                            title: "Floating panel content",
                            detail: settings.hydraShowsHeadDetails ? "Expands the floating panel over the chat into a scrollable live timeline of tool calls, file edits, and output. Chat messages and the sidebar are unchanged." : "Shows a compact floating card over the chat with the task title, step bar, and edit/command/read counts. Chat messages and the sidebar are unchanged."
                        ) {
                            ChromeVisualPicker(options: Self.detailOptions, selection: $settings.hydraShowsHeadDetails) { showsSteps in
                                Image(systemName: showsSteps ? "list.number" : "chart.bar")
                            }
                        }
                        ChromeRowDivider()
                        ChromeRow(
                            title: "Floating panel layout",
                            detail: panelLayoutDetail
                        ) {
                            ChromeVisualPicker(options: Self.panelOptions, selection: panelLayoutBinding) { layout in
                                Image(systemName: layout.symbol)
                            }
                        }
                    }
                }
            }
            if showsDelegation {
                ChromeSection(title: "Delegation") {
                    ChromeCard {
                        ChromeRow(
                            title: "How much sub-agents take on",
                            detail: Self.tiltDetail(settings.hydraTilt)
                        ) {
                            GlassPickerButton(
                                options: [(HydraTilt.restrained, "Restrained"), (HydraTilt.active, "Proactive"), (HydraTilt.aggressive, "Aggressive")],
                                selection: $settings.hydraTilt
                            )
                            .accessibilityLabel(Text("How much sub-agents take on"))
                        }
                    }
                }
            }
            if showsFinish {
                ChromeSection(title: "When sub-agents finish") {
                    ChromeCard {
                        toggleRow("Independent review", detail: "Once the lead and sub-agents finish, the model you choose reviews the team's changes and sends any findings to the lead, before auto-merge when that is on.", isOn: $settings.hydraReviewEnabled)
                        ChromeRowDivider()
                        HydraReviewRow()
                            .disabled(!settings.hydraReviewEnabled)
                            .opacity(settings.hydraReviewEnabled ? 1 : 0.5)
                        ChromeRowDivider()
                        toggleRow("Commit and merge automatically when done", detail: "Off: the team's changes stay in your working copy for you to handle. On: Tivano commits them, pushes to the remote, opens a pull or merge request and tries to merge it; needs a configured remote and access.", isOn: $settings.hydraAutoMerge)
                    }
                    Text("If the first choice can't run (not signed in, or its CLI isn't found), the second is used; if neither can, the review is skipped. A provider other than the lead's gives a more independent review.")
                        .font(.ui(.subheadline))
                        .foregroundStyle(Chrome.secondaryText)
                        .padding(.horizontal, 4)
                }
            }
        }
        .disabled(!settings.hydraEnabled)
        .opacity(settings.hydraEnabled ? 1 : 0.5)
        .animation(.smooth(duration: 0.2), value: settings.hydraEnabled)
        // Off for the app, Adaptive sub-agents hands every chat it held back to its sub-agent mode.
        .onChange(of: settings.isChimeraEnabled) { _, on in
            if !on { model.leaveChimeraEverywhere() }
        }
        if showsHistory {
            ChromeSection(title: "Codex sub-agent history", accessory: AnyView(InfoHoverButton(help: "About Codex sub-agent history") { HydraInfoPopover(topic: .history) })) {
                ChromeCard {
                    ChromeRow(title: "After completion", detail: nil) {
                        ChromeVisualPicker(options: Self.historyOptions, selection: $settings.hydraArchivesCodexHeads) { archive in
                            Image(systemName: archive ? "archivebox" : "eye")
                        }
                    }
                }
                Text("Automatically archive sub-agent sessions that finish successfully, and restore them when you need to continue. This only affects Codex's local history; it does not clean up existing records or delete sessions.")
                    .font(.ui(.subheadline))
                    .foregroundStyle(Chrome.secondaryText)
                    .padding(.horizontal, 4)
                HydraProviderHistoryIssues()
            }
        }
        if !trimmedQuery.isEmpty,
           !showsHeader,
           !showsSameModel,
           !showsPreset,
           !showsAdaptive,
           !showsExecution,
           !showsDelegation,
           !showsFinish,
           !showsHistory {
            Text(verbatim: String(format: Chrome.localized("No sub-agent settings or combos match “%@”."), trimmedQuery))
                .font(.ui(size: 13))
                .foregroundStyle(Chrome.secondaryText)
                .padding(.horizontal, 4)
        }
    }

    private func sectionDetail(_ key: String) -> some View {
        Text(verbatim: Chrome.localized(key))
            .font(.ui(.subheadline))
            .foregroundStyle(Chrome.secondaryText)
            .padding(.horizontal, 4)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// What a tilt does and what it trades, so the choice can be weighed.
    private static func tiltDetail(_ tilt: HydraTilt) -> String {
        switch tilt {
        case .restrained:
            "The lead does most of the work and sends sub-agents only the parts too big for one context: audits, broad research, several parallel pieces. Steadiest quality; the lead model does the most work."
        case .active:
            "The lead hands sub-agents any self-contained part that takes more than a few steps and keeps short or judgement-heavy work. A balance between quality and how much the lead model does."
        case .aggressive:
            "Sub-agents take nearly every part the lead can brief; the lead plans, integrates and checks. The least work for the lead model; with weaker sub-agent models, quality can drop slightly."
        }
    }

    /// A toggle row. A reason it is blocked stands in for its detail, and the row is dimmed
    /// and inert while there is one.
    private func toggleRow(_ title: String, detail: String, isOn: Binding<Bool>, blockedBy reason: String? = nil) -> some View {
        ChromeRow(title: title, detail: reason ?? detail) {
            SettingsSwitch(isOn: isOn)
        }
        .disabled(reason != nil)
        .opacity(reason == nil ? 1 : 0.5)
    }
}

private struct HydraProviderHistoryIssues: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ForEach(model.threads.filter { $0.provider == .codex && $0.hydra?.providerHistoryIssue != nil }) { head in
            Text("\(head.displayTitle): \(head.hydra?.providerHistoryIssue ?? "")")
                .font(.ui(.subheadline))
                .foregroundStyle(Chrome.secondaryText)
                .padding(.horizontal, 4)
        }
    }
}

private struct HydraReviewRow: View {
    @Environment(AppModel.self) private var model
    @State private var isEditing = false

    var body: some View {
        let settings = model.settings
        ChromeRow(title: "Review models", detail: String(
            format: Chrome.localized("First: %@ | Second: %@"),
            summary(settings.hydraReviewFirst),
            summary(settings.hydraReviewSecond)
        )) {
            Button {
                isEditing = true
            } label: {
                // Drawn like GlassPickerButton, so it reads as one of the page's pickers.
                HStack(spacing: 6) {
                    HydraPairMark(lead: settings.hydraReviewFirst.provider, heads: settings.hydraReviewSecond.provider, leadSize: 14)
                    Image(systemName: "chevron.down")
                        .font(Chrome.chevronFont)
                        .foregroundStyle(Chrome.secondaryText)
                }
                .padding(.horizontal, Chrome.capsuleHorizontalPadding)
                .frame(height: Chrome.capsuleContentHeight)
                .contentShape(Capsule(style: .continuous))
            }
            .buttonStyle(.plain)
            .fixedSize()
            .chromeGlassCapsule()
            .accessibilityLabel(Text("Review models"))
            .popover(isPresented: $isEditing, arrowEdge: .trailing) {
                HydraReviewEditor()
                    .frame(width: 360)
                    .presentedChrome()
            }
        }
    }

    private func summary(_ choice: HydraReviewChoice) -> String {
        let name = SubagentEditor.namedModel(choice.model, provider: choice.provider, registry: model.providers)
            ?? String(format: Chrome.localized("%@'s default"), choice.provider.displayName)
        let effort = SubagentEditor.namedEffort(choice.effort) ?? Chrome.localized("Default")
        return "\(name) · \(effort)"
    }
}

private struct HydraReviewEditor: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        let registry = model.providers
        let providers = settings.hydraReviewFirst.provider == settings.hydraReviewSecond.provider
            ? [settings.hydraReviewFirst.provider]
            : [settings.hydraReviewFirst.provider, settings.hydraReviewSecond.provider]
        VStack(alignment: .leading, spacing: 0) {
            SubagentEditor.sectionLabel("First choice", divided: false)
            choiceRows($settings.hydraReviewFirst)
            SubagentEditor.sectionLabel("Second choice")
            choiceRows($settings.hydraReviewSecond)
            ForEach(providers, id: \.self) { provider in
                if registry.models(for: provider).isEmpty {
                    Text(verbatim: String(format: Chrome.localized(registry.loadingCatalogs.contains(provider) ? "Loading %@'s models…" : "No models loaded for %@ yet."), provider.displayName))
                        .font(.ui(.subheadline))
                        .foregroundStyle(Chrome.secondaryText)
                        .padding(.horizontal, 14)
                        .padding(.top, 8)
                }
            }
        }
        // The first label has no hairline: its own top inset matches the bottom.
        .padding(.top, 4)
        .padding(.bottom, 14)
        .task {
            for provider in providers {
                await registry.loadCatalog(provider)
            }
        }
    }

    @ViewBuilder
    private func choiceRows(_ choice: Binding<HydraReviewChoice>) -> some View {
        let registry = model.providers
        let provider = choice.wrappedValue.provider
        let options = registry.models(for: provider).filter { $0.id != "default" }
        // No model chosen runs the provider's default, so its efforts are the ones on offer.
        let reviewEfforts = { (model: String?, provider: ProviderKind) -> [String] in
            SubagentEditor.efforts(of: registry.model(model, for: provider) ?? registry.defaultModel(for: provider), fallback: SubagentEditor.allEfforts(registry.models(for: provider)))
        }
        let availableEfforts = reviewEfforts(choice.wrappedValue.model, provider)
        SubagentEditor.row("Provider") {
            GlassPickerButton(
                options: HydraReviewChoice.providers.map { ($0, $0.displayName) },
                selection: Binding(
                    get: { choice.wrappedValue.provider },
                    set: { provider in
                        guard choice.wrappedValue.provider != provider else { return }
                        var updated = choice.wrappedValue
                        updated.provider = provider
                        updated.model = nil
                        if let effort = updated.effort, !reviewEfforts(nil, provider).contains(effort) {
                            updated.effort = nil
                        }
                        choice.wrappedValue = updated
                        Task { await registry.loadCatalog(provider) }
                    }
                ),
                asset: { $0.iconName }
            )
        }
        SubagentEditor.row("Model") {
            GlassPickerButton(
                options: [(String?.none, String(format: Chrome.localized("%@'s default"), provider.displayName))]
                    + options.map { (Optional($0.id), $0.label(among: options)) },
                selection: Binding(
                    get: { choice.wrappedValue.model },
                    set: { id in
                        var updated = choice.wrappedValue
                        updated.model = id
                        if let effort = updated.effort, !reviewEfforts(id, updated.provider).contains(effort) {
                            updated.effort = nil
                        }
                        choice.wrappedValue = updated
                    }
                ),
                maxWidth: 190
            )
        }
        if !availableEfforts.isEmpty {
            SubagentEditor.row("Effort") {
                SubagentEditor.effortPicker(efforts: availableEfforts, inherit: "Default", selection: choice.effort)
            }
        }
    }
}
