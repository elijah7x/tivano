import SwiftUI

/// Switches Hydra on for the app and sets up its heads: how they work, which messages go
/// to them, what happens when the team is done, and which model leads which, per provider.
struct HydraSettingsPage: View {
    @Environment(AppModel.self) private var model

    /// The live grip reorder of a pair (see `RowDrag`).
    @State private var drag = RowDrag<UUID>()
    /// Each pair row's height including its divider: one row's slot in the card.
    @State private var rowHeights: [UUID: CGFloat] = [:]

    /// Neighbours sliding out of the grabbed row's way.
    private static let slide = Animation.spring(response: 0.28, dampingFraction: 0.82)
    private static let maxHeadsOptions = [ChromeSegmentedOption(value: Int?.none, title: "No cap", symbol: "infinity")]
        + HydraPair.maxHeadsRange.map { ChromeSegmentedOption(value: Optional($0), title: String($0)) }
    private static let checkoutOptions = [(true, "Own copy"), (false, "Shared")]
    private static let detailOptions = [(false, "Progress"), (true, "Every step")]
    private static let panelOptions = [(false, "One panel"), (true, "A panel each")]
    private static let historyOptions = [(false, "Keep visible"), (true, "Auto-archive")]

    var body: some View {
        @Bindable var settings = model.settings
        let pairs = settings.hydraPairs
        VStack(alignment: .leading, spacing: Chrome.sectionHeaderSpacing) {
            ChromeCard {
                HStack(spacing: 14) {
                    HStack(spacing: -9) {
                        ForEach(0..<5, id: \.self) { index in
                            HydraGlyph(persona: HydraRoster.persona(at: index), size: 26)
                        }
                    }
                    .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Text("Hydra")
                                .font(.ui(.title3, weight: .semibold))
                                .foregroundStyle(Chrome.primaryText)
                            InfoHoverButton(help: "How Hydra works") { HydraInfoPopover(topic: .hydra) }
                        }
                        Text("One chat leads a team of heads on big jobs.")
                            .font(.ui(.subheadline))
                            .foregroundStyle(Chrome.secondaryText)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 12)
                    SettingsSwitch(isOn: $settings.hydraEnabled)
                }
                .padding(.leading, 16)
                .padding(.trailing, Chrome.rowControlTrailingPadding)
                .padding(.vertical, 14)
            }
            // One note for the whole page: the sections below dim together rather than
            // each row repeating why it is off.
            if !settings.hydraEnabled {
                Text("Switch Hydra on to set up its heads.")
                    .font(.ui(.subheadline))
                    .foregroundStyle(Chrome.secondaryText)
                    .padding(.horizontal, 4)
            }
        }
        Group {
            // The cookbook opens from the section's header, at its far right: the card
            // below keeps its width for the words.
            ChromeSection(title: "Pairs", trailing: AnyView(HydraCookbookButton())) {
                ChromeCard {
                    HStack(alignment: .center, spacing: 14) {
                        // A lead and the heads it sends out: the pair, drawn with the roster.
                        HStack(spacing: 6) {
                            HydraGlyph(persona: HydraRoster.persona(at: 0), size: 30)
                            Image(systemName: "arrow.right")
                                .font(.ui(.footnote, weight: .semibold))
                                .foregroundStyle(Chrome.secondaryText)
                            HStack(spacing: -8) {
                                ForEach(1..<4, id: \.self) { index in
                                    HydraGlyph(persona: HydraRoster.persona(at: index), size: 22)
                                }
                            }
                        }
                        .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("One leads, the others build")
                                .font(.ui(.body, weight: .semibold))
                                .foregroundStyle(Chrome.primaryText)
                            Text("Choose a lead model and a model for the heads.")
                                .font(.ui(.subheadline))
                                .foregroundStyle(Chrome.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                }
                ChromeCard {
                    if pairs.isEmpty {
                        ChromeRow(title: "No pairs yet", detail: "Heads run on the chat's own model until a chat joins a pair.") {
                            HydraAddPairButton()
                        }
                    } else {
                        // A plain stack, not a lazy one: a lazy stack rebuilds a row that
                        // changes slot and animates it in from the container's origin, and
                        // it ignores zIndex, which the lifted row needs. The add row stays
                        // outside, so a drag only reorders pairs that already exist.
                        VStack(spacing: 0) {
                            ForEach(pairs) { pair in
                                let isDragged = drag.id == pair.id
                                VStack(spacing: 0) {
                                    ChromeRowDivider().opacity(pair.id == pairs.first?.id || isDragged ? 0 : 1)
                                    HydraPairRow(
                                        pair: pair,
                                        isDragged: isDragged,
                                        onDragChanged: { translation in dragChanged(pair.id, translation: translation) },
                                        onDragEnded: { dragEnded() }
                                    )
                                }
                                .modifier(HydraPairRowHeightReporter(id: pair.id, heights: $rowHeights))
                                .offset(y: isDragged ? drag.visualOffset : 0)
                                .zIndex(isDragged ? 1 : 0)
                            }
                        }
                        .zIndex(drag.id == nil ? 0 : 1)
                        ChromeRowDivider()
                        ChromeRow(title: "Another pair", detail: "One per provider is enough.") {
                            HydraAddPairButton()
                        }
                    }
                }
                .onChange(of: pairs.map(\.id)) { _, ids in
                    let kept = Set(ids)
                    if rowHeights.contains(where: { !kept.contains($0.key) }) {
                        rowHeights = rowHeights.filter { kept.contains($0.key) }
                    }
                    if let dragged = drag.id, !kept.contains(dragged) {
                        drag = RowDrag()
                    }
                }
                Text("Pairs sit at the top of the model picker: a tap puts the chat in one. A pair can use lead and head models from different providers. Right-click a project in the sidebar to start each of its new chats on one pair.")
                    .font(.ui(.subheadline))
                    .foregroundStyle(Chrome.secondaryText)
                    .padding(.horizontal, 4)
            }
            ChromeSection(title: "Heads", accessory: AnyView(InfoHoverButton(help: "How heads work") { HydraInfoPopover(topic: .heads) })) {
                ChromeCard {
                    ChromeRow(
                        title: "Checkout",
                        detail: settings.hydraIsolateHeads
                            ? "Each head works in a copy of its own; its changes land in the chat's checkout when it reports."
                            : "Heads work in the chat's checkout itself."
                    ) {
                        ChromeVisualPicker(options: Self.checkoutOptions, selection: $settings.hydraIsolateHeads) { isolated in
                            Image(systemName: isolated ? "doc.on.doc" : "folder")
                        }
                    }
                    ChromeRowDivider()
                    ChromeRow(
                        title: "Heads at once per chat",
                        detail: "The lower of this limit and the preset's limit applies. No cap adds no limit here."
                    ) {
                        ChromeSegmentedPicker(
                            options: Self.maxHeadsOptions,
                            selection: $settings.hydraMaxHeads
                        )
                    }
                    ChromeRowDivider()
                    ChromeRow(title: "Head panel", detail: "The head's progress bar, or each of its steps as it goes.") {
                        ChromeVisualPicker(options: Self.detailOptions, selection: $settings.hydraShowsHeadDetails) { showsSteps in
                            Image(systemName: showsSteps ? "list.number" : "chart.bar")
                        }
                    }
                    ChromeRowDivider()
                    ChromeRow(
                        title: "Heads' panels",
                        detail: settings.hydraAutoPopsHeads ? "Each head after the first gets a panel of its own beside the chat while there is room, left and right until each side is full." : "One panel over the chat lists every head."
                    ) {
                        ChromeVisualPicker(options: Self.panelOptions, selection: $settings.hydraAutoPopsHeads) { popped in
                            Image(systemName: popped ? "square.grid.2x2" : "rectangle")
                        }
                    }
                    ChromeRowDivider()
                    toggleRow("Lower the default reasoning effort for heads", detail: "Effort set in a pair is unaffected. When no effort is specified and the head uses the same provider as the lead, the head stays at the standard effort (usually medium); if the lead uses a lower effort, the head inherits it.", isOn: $settings.hydraTempersHeadEffort)
                }
            }
            if settings.isHydra2Enabled {
                // Hydra 2.0 replaces v1's message-routing switches with one tilt: every
                // message goes to the lead, which decides what the heads take.
                ChromeSection(title: "Delegation") {
                    ChromeCard {
                        ChromeRow(
                            title: "How much heads take on",
                            detail: settings.hydraTilt == .active
                                ? "The lead prefers to hand heads what it can brief on its own, single edits included, and splits larger work to run in parallel. It keeps judgement, design, integration and small or delicate pieces."
                                : "Heads take parallel pieces, heavy reading and larger self-contained pieces as the job calls for them; the lead keeps small edits and coupled work."
                        ) {
                            GlassPickerButton(
                                options: [(HydraTilt.restrained, "Restrained"), (HydraTilt.active, "Proactive")],
                                selection: $settings.hydraTilt
                            )
                            .accessibilityLabel(Text("How much heads take on"))
                        }
                    }
                }
            } else {
                ChromeSection(title: "Messages") {
                    ChromeCard {
                        toggleRow("Send queued follow-ups to heads", detail: "Each one goes to a head as soon as there is room, instead of waiting for the lead.", isOn: $settings.hydraQueueHeads, blockedBy: settings.hydraAlwaysHeads ? "Heads are already preferred for messages." : nil)
                        ChromeRowDivider()
                        toggleRow("Prefer heads for messages", detail: "Use heads when there is room. Commands and messages that cannot be delegated stay with the lead.", isOn: $settings.hydraAlwaysHeads)
                    }
                }
            }
            ChromeSection(title: "When the team is done") {
                ChromeCard {
                    toggleRow("Ask the lead to review heads' changes", detail: "Adds a review step before the lead finishes. This uses additional time and tokens.", isOn: $settings.hydraReviewHeads)
                    ChromeRowDivider()
                    toggleRow("Automatically publish and merge team changes", detail: "Commits and pushes the team's changes, opens a pull/merge request, and attempts to merge it. Requires a configured remote and access.", isOn: $settings.hydraAutoMerge)
                }
            }
        }
        .disabled(!settings.hydraEnabled)
        .opacity(settings.hydraEnabled ? 1 : 0.5)
        .animation(.smooth(duration: 0.2), value: settings.hydraEnabled)
        ChromeSection(title: "Codex head history", accessory: AnyView(InfoHoverButton(help: "About Codex head history") { HydraInfoPopover(topic: .history) })) {
            ChromeCard {
                ChromeRow(title: "After completion", detail: nil) {
                    ChromeVisualPicker(options: Self.historyOptions, selection: $settings.hydraArchivesCodexHeads) { archive in
                        Image(systemName: archive ? "archivebox" : "eye")
                    }
                }
            }
            Text("Automatically archive head sessions that finish successfully, and restore them when you need to continue. This only affects Codex's local history; it does not clean up existing records or delete sessions.")
                .font(.ui(.subheadline))
                .foregroundStyle(Chrome.secondaryText)
                .padding(.horizontal, 4)
            HydraProviderHistoryIssues()
        }
    }

    // MARK: - Reorder

    /// The grabbed row follows the pointer and swaps past every pair whose centre it has
    /// crossed. The order is read fresh on every move, and a pair that has already been
    /// removed cannot be grabbed again.
    private func dragChanged(_ id: UUID, translation: CGFloat) {
        guard model.settings.hydraPairs.contains(where: { $0.id == id }) else {
            if drag.id == id { drag = RowDrag() }
            return
        }
        if drag.id != id {
            drag = RowDrag(id: id)
        }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { drag.translation = translation }

        let order = model.settings.hydraPairs.map(\.id)
        let moved = withAnimation(Self.slide) {
            drag.settle(order: order, heights: rowHeights, fallbackHeight: 54) { neighbour, placeAfter in
                model.settings.moveHydraPair(id, to: neighbour, placeAfter: placeAfter)
            }
        }
        if moved {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
    }

    private func dragEnded() {
        guard drag.id != nil else { return }
        withAnimation(.spring(response: 0.32, dampingFraction: 0.8)) { drag = RowDrag() }
    }

    private struct HydraPairRowHeightReporter: ViewModifier {
        let id: UUID
        @Binding var heights: [UUID: CGFloat]

        func body(content: Content) -> some View {
            content.onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { height in
                if heights[id].map({ abs($0 - height) > 0.5 }) ?? true { heights[id] = height }
            }
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
            Text("\(head.title): \(head.hydra?.providerHistoryIssue ?? "")")
                .font(.ui(.subheadline))
                .foregroundStyle(Chrome.secondaryText)
                .padding(.horizontal, 4)
        }
    }
}

/// Opens the cookbook: the best pairs for the providers set up here, added with a click.
private struct HydraCookbookButton: View {
    @State private var isOpen = false

    var body: some View {
        Button {
            isOpen = true
        } label: {
            Label("Pair presets", systemImage: "book")
        }
        .buttonStyle(.glass)
        .controlSize(.small)
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            HydraCookbookPanel()
                .presentedChrome()
        }
    }
}

private struct HydraAddPairButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button {
            let installed = ProviderKind.allCases.filter { model.providers.status($0).isInstalled && model.settings.isEnabled($0) }
            let taken = Set(model.settings.hydraPairs.map(\.provider))
            let provider = installed.first { !taken.contains($0) } ?? installed.first ?? model.settings.defaultProvider
            withAnimation(Chrome.panelSlide) { model.settings.addHydraPair(HydraPair(provider: provider)) }
        } label: {
            Label("Add pair", systemImage: "plus")
        }
        .buttonStyle(.glass)
    }
}

/// One pair: who leads whom, on what effort, with the editor behind a click.
private struct HydraPairRow: View {
    @Environment(AppModel.self) private var model
    let pair: HydraPair
    /// Lifted and following the pointer.
    let isDragged: Bool
    let onDragChanged: (CGFloat) -> Void
    let onDragEnded: () -> Void

    @AppStorage("performanceMode", store: CaptureRun.defaults ?? .standard) private var performanceMode = false
    @State private var isEditing = false

    var body: some View {
        let registry = model.providers
        HStack(spacing: 10) {
            HydraPairGrip()
                .pointerStyle(isDragged ? .grabActive : .grabIdle)
                .gesture(
                    DragGesture(minimumDistance: 1, coordinateSpace: .global)
                        .onChanged { value in onDragChanged(value.translation.height) }
                        .onEnded { _ in onDragEnded() }
                )
                .help(Text(verbatim: Chrome.localized("Drag to reorder")))
                .accessibilityLabel(Text("Drag to reorder"))
            Button {
                isEditing = true
            } label: {
                HydraPairEditLabel(pair: pair, title: HydraPairSummary.title(pair, registry: registry), summary: summary(registry: registry))
            }
            .buttonStyle(.plain)
            .popover(isPresented: $isEditing, arrowEdge: .trailing) {
                HydraPairEditor(pair: pair, update: { change in model.updateHydraPair(pair.id, change) })
                    .frame(width: 360)
                    .presentedChrome()
            }
            Button {
                withAnimation(Chrome.panelSlide) { model.removeHydraPair(pair.id) }
            } label: {
                Image(systemName: "minus.circle")
                    .font(.ui(.callout, weight: .medium))
                    .foregroundStyle(Chrome.secondaryText)
                    .frame(width: 24, height: 24)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help(Text(verbatim: Chrome.localized("Remove this pair")))
            .accessibilityLabel(Text("Remove this pair"))
        }
        .padding(.leading, 10)
        .padding(.trailing, Chrome.rowControlTrailingPadding)
        .padding(.vertical, 9)
        // Lifted: a touch larger with a shadow over an opaque fill, so the rows
        // sliding underneath never show through.
        .background {
            if isDragged {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Chrome.overlay(0.12))
                    .shadow(color: .black.opacity(performanceMode ? 0 : 0.28), radius: performanceMode ? 0 : 10, y: performanceMode ? 0 : 4)
            }
        }
        .scaleEffect(isDragged ? 1.02 : 1)
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isDragged)
        .task(id: pair.headsProvider) {
            await registry.loadCatalog(pair.provider)
            await registry.loadCatalog(pair.headsProvider)
        }
    }

    /// `Lead: model - effort | Head: model - effort - cap`. A nil model or effort stays
    /// the inherit or default the pair actually uses, never a catalog model's current
    /// name or a fixed effort. A chosen id with no catalog entry stays the raw id.
    private func summary(registry: ProviderRegistry) -> String {
        let leadModel = namedModel(pair.orchestratorModel, provider: pair.provider, registry: registry) ?? Chrome.localized("Any model")
        let leadEffort = namedEffort(pair.orchestratorEffort) ?? Chrome.localized("Default")
        let headModel = namedModel(pair.workerModel, provider: pair.headsProvider, registry: registry)
            ?? (pair.sendsHeadsElsewhere
                ? String(format: Chrome.localized("%@'s default"), pair.headsProvider.displayName)
                : Chrome.localized("Same as the chat"))
        let headEffort = namedEffort(pair.workerEffort) ?? Chrome.localized("Automatic")
        let effectiveCap = [pair.maxHeads, model.settings.hydraMaxHeads].compactMap { $0 }.min()
        let cap = effectiveCap.map { String(format: Chrome.localized("Up to %lld"), $0) } ?? Chrome.localized("No cap")
        var line = String(format: Chrome.localized("Lead: %@ - %@ | Head: %@ - %@ - %@"), leadModel, leadEffort, headModel, headEffort, cap)
        // Heads on a provider this Mac cannot run stay on the lead's (see
        // `AppModel.hydraHeadsProvider`); the row says so rather than promising that team.
        if pair.sendsHeadsElsewhere, model.hydraHeadsProvider(of: pair) == pair.provider {
            line += " · " + String(format: Chrome.localized("%@ is not set up, heads stay on %@"), pair.headsProvider.displayName, pair.provider.displayName)
        }
        return line
    }

    /// A chosen model's short name, or its id while the catalog has not listed it.
    private func namedModel(_ id: String?, provider: ProviderKind, registry: ProviderRegistry) -> String? {
        guard let id else { return nil }
        return registry.model(id, for: provider)?.shortName ?? id
    }

    /// A chosen effort in the words the rest of the app uses. Nil stays nil.
    private func namedEffort(_ effort: String?) -> String? {
        guard let effort, !effort.isEmpty else { return nil }
        return Chrome.localized(ModelOption.effortTitle(effort))
    }
}

private struct HydraPairGrip: View {
    @State private var isHovering = false

    var body: some View {
        Image(systemName: "line.3.horizontal")
            .font(.ui(size: 11, weight: .medium))
            .foregroundStyle(Chrome.secondaryText.opacity(isHovering ? 1 : 0.7))
            .frame(width: 24, height: 24)
            .contentShape(.rect)
            .onHover { if isHovering != $0 { isHovering = $0 } }
    }
}

private struct HydraPairEditLabel: View {
    let pair: HydraPair
    let title: String
    let summary: String
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 12) {
            HydraPairIcons(pair: pair)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title)
                    .font(.ui(.body))
                    .foregroundStyle(Chrome.primaryText)
                Text(verbatim: summary)
                    .font(.ui(.subheadline))
                    .foregroundStyle(Chrome.secondaryText)
            }
            Spacer(minLength: 8)
            Image(systemName: "slider.horizontal.3")
                .font(.ui(.callout))
                .foregroundStyle(Chrome.secondaryText)
                .opacity(isHovering ? 1 : 0)
        }
        .contentShape(.rect)
        .onHover { if isHovering != $0 { isHovering = $0 } }
    }
}

/// A pair's provider marks: the lead's larger and the heads' smaller after an arrow,
/// the same mark wherever a pair is drawn, so a same-provider pair shows
/// provider → provider too and a row reads the same everywhere.
private struct HydraPairIcons: View {
    let pair: HydraPair

    var body: some View {
        HydraPairMark(lead: pair.provider, heads: pair.headsProvider)
        .frame(minWidth: 22, alignment: .leading)
    }
}

/// The pair's settings: provider, lead model and effort, the heads' provider, model and
/// effort, and how many heads go out at once. Every choice writes straight to the pair.
/// The head profiles at the end are the pair's advanced mode: purpose-named overrides
/// of the shared heads' choices, so an empty list leaves the pair as it always was.
struct HydraPairEditor: View {
    @Environment(AppModel.self) private var model
    let pair: HydraPair
    var showsName = true
    let update: ((inout HydraPair) -> Void) -> Void

    /// The name field: a popover hands its first field the focus as it opens, and the
    /// caret landing there read as a prompt to rename the pair. The field is given back
    /// its focus only on a click.
    @FocusState private var isNameFocused: Bool
    private static let maxHeadsOptions = [(Int?.none, "As many as it takes")]
        + HydraPair.maxHeadsRange.map { (Optional($0), String($0)) }

    var body: some View {
        let registry = model.providers
        let providers = ProviderKind.alphabetical.filter { model.settings.isEnabled($0) && (registry.status($0).isInstalled || $0 == pair.provider) }
        let headsProviders = ProviderKind.alphabetical.filter { model.settings.isEnabled($0) && (registry.status($0).isInstalled || $0 == pair.headsProvider) }
        let sameProvider = pair.headsProvider == pair.provider
        let options = model.pickerModels(for: pair.provider, keeping: Set([pair.orchestratorModel, sameProvider ? pair.workerModel : nil].compactMap { $0 }))
        let headsOptions = sameProvider ? options : model.pickerModels(for: pair.headsProvider, keeping: Set([pair.workerModel].compactMap { $0 }))
        let catalogProviders = Self.catalogProviders(pair)
        let leadOption = registry.model(pair.orchestratorModel, for: pair.provider)
        let workerOption = registry.model(pair.workerModel, for: pair.headsProvider)
        // A lead that may be any model offers every effort the provider's models know.
        let leadEfforts = Self.efforts(of: leadOption, fallback: Self.allEfforts(options))
        // Heads with no model chosen inherit the chat's, and its efforts; on another
        // provider they run its default model, so its efforts are the ones on offer.
        let workerEfforts = Self.efforts(of: workerOption, fallback: pair.sendsHeadsElsewhere ? Self.efforts(of: registry.defaultModel(for: pair.headsProvider), fallback: Self.allEfforts(headsOptions)) : leadEfforts)
        VStack(alignment: .leading, spacing: 0) {
            if showsName {
                // The name is the header: the pair's own word for itself, over what it
                // stands for in the picker when it has none.
                VStack(alignment: .leading, spacing: 4) {
                    TextField("", text: Binding(
                        get: { pair.name ?? "" },
                        set: { text in update { $0.name = text.isEmpty ? nil : text } }
                    ), prompt: Text(HydraPairSummary.modelsTitle(pair, registry: registry)))
                    .textFieldStyle(.plain)
                    .focused($isNameFocused)
                    .focusEffectDisabled()
                    .font(.ui(.title3, weight: .semibold))
                    .foregroundStyle(Chrome.primaryText)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(Chrome.overlay(0.06), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    Text("Shown in the picker and the composer")
                        .font(.ui(.subheadline))
                        .foregroundStyle(Chrome.secondaryText)
                        .padding(.horizontal, 2)
                }
                .padding(.horizontal, 14)
                .padding(.top, 14)
            }
            if model.settings.isHydra2Enabled {
                VStack(alignment: .leading, spacing: 4) {
                    TextField("", text: Binding(
                        get: { pair.headsNote ?? "" },
                        set: { text in update { $0.headsNote = text.isEmpty ? nil : text } }
                    ), prompt: Text("What the heads are good at"))
                    .textFieldStyle(.plain)
                    .font(.ui(.title3, weight: .semibold))
                    .foregroundStyle(Chrome.primaryText)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(Chrome.overlay(0.06), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    Text("Hydra 2.0 tells the lead, so it sends this kind of work to the heads. For example: fast, for mechanical edits; or front-end.")
                        .font(.ui(.subheadline))
                        .foregroundStyle(Chrome.secondaryText)
                        .padding(.horizontal, 2)
                }
                .padding(.horizontal, 14)
                .padding(.top, 14)
            }
            sectionLabel("Lead")
            editorRow("Provider") {
                GlassPickerButton(
                    options: providers.map { ($0, $0.displayName) },
                    selection: Binding(
                        get: { pair.provider },
                        set: { provider in
                            update {
                                guard $0.provider != provider else { return }
                                $0.provider = provider
                                $0.orchestratorModel = nil
                                $0.orchestratorEffort = nil
                                $0.orchestratorDshMode = nil
                                // Heads on the old lead provider go with it; heads on a
                                // provider of their own keep their model and effort, and
                                // when that provider is the new lead's, they are simply
                                // on the lead's provider again.
                                if $0.workerProvider == nil {
                                    $0.workerModel = nil
                                    $0.workerEffort = nil
                                    $0.workerDshMode = nil
                                } else if $0.workerProvider == provider {
                                    $0.workerProvider = nil
                                }
                            }
                            Task { await registry.loadCatalog(provider) }
                        }
                    ),
                    asset: { $0.iconName }
                )
            }
            editorRow("Model") {
                GlassPickerButton(
                    options: [(String?.none, "Any model")] + options.map { (Optional($0.id), $0.label(among: options)) },
                    selection: Binding(
                        get: { pair.orchestratorModel },
                        set: { id in
                            update {
                                $0.orchestratorModel = id
                                if let effort = $0.orchestratorEffort, let option = registry.model(id, for: $0.provider), !option.efforts.contains(effort) {
                                    $0.orchestratorEffort = nil
                                }
                            }
                        }
                    ),
                    maxWidth: 190
                )
            }
            if !leadEfforts.isEmpty {
                editorRow("Effort") {
                    effortPicker(
                        efforts: leadEfforts,
                        inherit: "Chat's effort",
                        selection: Binding(
                            get: { pair.orchestratorEffort },
                            set: { effort in update { $0.orchestratorEffort = effort } }
                        )
                    )
                }
            }
            if pair.provider == .dsh {
                editorRow("Agent mode") {
                    GlassPickerButton(
                        options: DshAgentMode.allCases.map { ($0, $0.title) },
                        selection: Binding(
                            get: { pair.orchestratorDshMode ?? .standard },
                            set: { mode in update { $0.orchestratorDshMode = mode == .standard ? nil : mode } }
                        )
                    )
                }
            }
            sectionLabel("Heads")
            editorRow("Provider") {
                GlassPickerButton(
                    options: [(ProviderKind?.none, "Same as the lead")] + headsProviders.filter { $0 != pair.provider }.map { (Optional($0), $0.displayName) },
                    selection: Binding(
                        get: { pair.sendsHeadsElsewhere ? pair.workerProvider : nil },
                        set: { provider in
                            update {
                                let chosen = provider == $0.provider ? nil : provider
                                guard $0.workerProvider != chosen else { return }
                                // The heads' model and effort were the old provider's.
                                $0.workerProvider = chosen
                                $0.workerModel = nil
                                $0.workerEffort = nil
                                $0.workerDshMode = nil
                            }
                            if let provider { Task { await registry.loadCatalog(provider) } }
                        }
                    ),
                    asset: { ($0 ?? pair.provider).iconName }
                )
            }
            editorRow("Model") {
                GlassPickerButton(
                    options: [(String?.none, pair.sendsHeadsElsewhere ? String(format: Chrome.localized("%@'s default"), pair.headsProvider.displayName) : "Same as the chat")] + headsOptions.map { (Optional($0.id), $0.label(among: headsOptions)) },
                    selection: Binding(
                        get: { pair.workerModel },
                        set: { id in
                            update {
                                $0.workerModel = id
                                if let effort = $0.workerEffort, let option = registry.model(id, for: $0.headsProvider), !option.efforts.contains(effort) {
                                    $0.workerEffort = nil
                                }
                            }
                        }
                    ),
                    maxWidth: 190
                )
            }
            if !workerEfforts.isEmpty {
                editorRow("Effort") {
                    effortPicker(
                        efforts: workerEfforts,
                        inherit: "Automatic",
                        selection: Binding(
                            get: { pair.workerEffort },
                            set: { effort in update { $0.workerEffort = effort } }
                        )
                    )
                }
            }
            if pair.headsProvider == .dsh {
                editorRow("Agent mode") {
                    GlassPickerButton(
                        options: DshAgentMode.allCases.map { ($0, $0.title) },
                        selection: Binding(
                            get: { pair.workerDshMode ?? .standard },
                            set: { mode in update { $0.workerDshMode = mode == .standard ? nil : mode } }
                        )
                    )
                }
            }
            editorRow("Heads at once per chat") {
                GlassPickerButton(
                    options: Self.maxHeadsOptions,
                    selection: Binding(
                        get: { pair.maxHeads },
                        set: { count in update { $0.maxHeads = count } }
                    )
                )
            }
            ForEach(catalogProviders, id: \.self) { provider in
                if registry.models(for: provider).isEmpty {
                    Text(verbatim: String(format: Chrome.localized(registry.loadingCatalogs.contains(provider) ? "Loading %@'s models…" : "No models loaded for %@ yet."), provider.displayName))
                        .font(.ui(.subheadline))
                        .foregroundStyle(Chrome.secondaryText)
                        .padding(.horizontal, 14)
                        .padding(.top, 8)
                }
            }
        }
        .padding(.bottom, 14)
        .onAppear {
            // After the popover's own first-responder pass, which runs as it shows.
            DispatchQueue.main.async { isNameFocused = false }
        }
        .task(id: catalogProviders) {
            for provider in catalogProviders {
                await registry.loadCatalog(provider)
            }
        }
    }

    private func editorRow<Control: View>(_ title: String, detail: String? = nil, @ViewBuilder control: () -> Control) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: Chrome.localized(title))
                    .font(.ui(.body))
                    .foregroundStyle(Chrome.primaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let detail {
                    Text(verbatim: Chrome.localized(detail))
                        .font(.ui(.subheadline))
                        .foregroundStyle(Chrome.secondaryText)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            control()
                .layoutPriority(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
    }

    /// A section's word, small and quiet, with a hairline above: the rows under it need
    /// no sentence each once the section says what they are about.
    private func sectionLabel(_ title: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider()
                .padding(.horizontal, 14)
                .padding(.top, 12)
            Text(verbatim: Chrome.localized(title))
                .font(.ui(.subheadline, weight: .semibold))
                .foregroundStyle(Chrome.secondaryText)
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 4)
        }
    }

    private func effortPicker(efforts: [String], inherit: String, selection: Binding<String?>) -> some View {
        GlassPickerButton(
            options: [(String?.none, inherit)] + efforts.map { (Optional($0), ModelOption.effortTitle($0)) },
            selection: selection
        )
    }

    /// Every effort any of the provider's models offers, in the order the first lists them.
    private static func allEfforts(_ options: [ModelOption]) -> [String] {
        var seen: [String] = []
        for option in options {
            for effort in option.efforts where !seen.contains(effort) { seen.append(effort) }
        }
        return seen
    }

    /// A model's efforts for the picker: its declared scale, or the fallback when the
    /// declaration is empty — a catalog that has not walked the model's scale yet would
    /// otherwise take the effort row away from a model that does reason.
    private static func efforts(of option: ModelOption?, fallback: @autoclosure () -> [String]) -> [String] {
        guard let option, !option.efforts.isEmpty else { return fallback() }
        return option.efforts
    }

    /// The providers whose catalogs the editor shows: the lead's and the heads', each once
    /// and in that order, so the pickers and the loading notes cover both.
    private static func catalogProviders(_ pair: HydraPair) -> [ProviderKind] {
        pair.sendsHeadsElsewhere ? [pair.provider, pair.headsProvider] : [pair.provider]
    }
}
