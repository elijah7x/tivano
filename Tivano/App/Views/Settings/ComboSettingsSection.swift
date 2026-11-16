import SwiftUI

/// Lists and edits the user's sub-agent combos, and opens the preset cookbook.
struct ComboSettingsSection: View {
    @Environment(AppModel.self) private var model
    let pairs: [HydraPair]
    var isFiltering = false

    /// The live grip reorder of a combo (see `RowDrag`).
    @State private var drag = RowDrag<UUID>()
    /// Each combo row's height including its divider: one row's slot in the card.
    @State private var rowHeights: [UUID: CGFloat] = [:]

    /// Neighbours sliding out of the grabbed row's way.
    private static let slide = Animation.spring(response: 0.28, dampingFraction: 0.82)

    var body: some View {
        // The cookbook opens from the section's header, at its far right: the card
        // below keeps its width for the words.
        ChromeSection(title: "Preset sub-agents", trailing: isFiltering ? nil : AnyView(HydraCookbookButton())) {
            Text("Save a lead model with a sub-agent model or provider, then pick it in the model picker.")
                .font(.ui(.subheadline))
                .foregroundStyle(Chrome.secondaryText)
                .padding(.horizontal, 4)
                .fixedSize(horizontal: false, vertical: true)
            ChromeCard {
                if pairs.isEmpty {
                    ChromeRow(title: "No combos yet", detail: "Sub-agents run on the chat's own model until a chat joins a combo.") {
                        HydraAddPairButton()
                    }
                } else {
                    // A plain stack, not a lazy one: a lazy stack rebuilds a row that
                    // changes slot and animates it in from the container's origin, and
                    // it ignores zIndex, which the lifted row needs. The add row stays
                    // outside, so a drag only reorders combos that already exist.
                    VStack(spacing: 0) {
                        ForEach(pairs) { pair in
                            let isDragged = drag.id == pair.id
                            VStack(spacing: 0) {
                                ChromeRowDivider().opacity(pair.id == pairs.first?.id || isDragged ? 0 : 1)
                                HydraPairRow(
                                    pair: pair,
                                    canDrag: !isFiltering,
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
                    if !isFiltering {
                        ChromeRowDivider()
                        ChromeRow(title: "Another combo", detail: "One per provider is enough.") {
                            HydraAddPairButton()
                        }
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
            if !isFiltering {
                Text("Combos sit at the top of the model picker: a click puts the chat in one. A combo can use lead and sub-agent models from different providers. Right-click a project in the sidebar to start each of its new chats on one combo.")
                    .font(.ui(.subheadline))
                    .foregroundStyle(Chrome.secondaryText)
                    .padding(.horizontal, 4)
            }
        }
    }

    /// Whether a combo matches the settings search query by its display name or model names.
    @MainActor
    static func matches(_ pair: HydraPair, registry: ProviderRegistry, query: String) -> Bool {
        guard !query.isEmpty else { return true }
        return HydraPairSummary.title(pair, registry: registry).localizedCaseInsensitiveContains(query)
            || HydraPairSummary.modelsTitle(pair, registry: registry).localizedCaseInsensitiveContains(query)
    }

    // MARK: - Reorder

    /// The grabbed row follows the pointer and swaps past every combo whose centre it has
    /// crossed. The order is read fresh on every move, and a combo that has already been
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
}

/// Opens the cookbook: the best combos for the providers set up here, added with a click.
private struct HydraCookbookButton: View {
    @State private var isOpen = false

    var body: some View {
        Button {
            isOpen = true
        } label: {
            Label("Suggested combos", systemImage: "book")
        }
        .chromeGlassButtonStyle()
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
            Label("Add combo", systemImage: "plus")
        }
        .chromeGlassButtonStyle()
    }
}

/// One combo: who leads whom, on what effort, with the editor behind a click.
private struct HydraPairRow: View {
    @Environment(AppModel.self) private var model
    let pair: HydraPair
    let canDrag: Bool
    /// Lifted and following the pointer.
    let isDragged: Bool
    let onDragChanged: (CGFloat) -> Void
    let onDragEnded: () -> Void

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
                .opacity(canDrag ? 1 : 0)
                .allowsHitTesting(canDrag)
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
            .help(Text(verbatim: Chrome.localized("Remove this combo")))
            .accessibilityLabel(Text("Remove this combo"))
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
                    .shadow(color: .black.opacity(0.28), radius: 10, y: 4)
            }
        }
        .scaleEffect(isDragged ? 1.02 : 1)
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isDragged)
        .task(id: pair.headsProvider) {
            await registry.loadCatalog(pair.provider)
            await registry.loadCatalog(pair.headsProvider)
        }
    }

    /// `Lead: model - effort | Sub-agent: model - effort - cap`. A nil model or effort stays
    /// the inherit or default the combo actually uses, never a catalog model's current
    /// name or a fixed effort. A chosen id with no catalog entry stays the raw id.
    private func summary(registry: ProviderRegistry) -> String {
        let leadModel = SubagentEditor.namedModel(pair.orchestratorModel, provider: pair.provider, registry: registry) ?? Chrome.localized("Any model")
        let leadEffort = SubagentEditor.namedEffort(pair.orchestratorEffort) ?? Chrome.localized("Default")
        let headModel = SubagentEditor.namedModel(pair.workerModel, provider: pair.headsProvider, registry: registry)
            ?? (pair.sendsHeadsElsewhere
                ? String(format: Chrome.localized("%@'s default"), pair.headsProvider.displayName)
                : Chrome.localized("Same as the chat"))
        let headEffort = SubagentEditor.namedEffort(pair.workerEffort) ?? Chrome.localized("Automatic")
        let effectiveCap = [pair.maxHeads, model.settings.hydraMaxHeads].compactMap { $0 }.min()
        let cap = effectiveCap.map { String(format: Chrome.localized("Up to %lld"), $0) } ?? Chrome.localized("No cap")
        var line = String(format: Chrome.localized("Lead: %@ - %@ | Sub-agent: %@ - %@ - %@"), leadModel, leadEffort, headModel, headEffort, cap)
        // Sub-agents on a provider this Mac cannot run stay on the lead's (see
        // `AppModel.hydraHeadsProvider`); the row says so rather than promising that team.
        if pair.sendsHeadsElsewhere, model.hydraHeadsProvider(of: pair) == pair.provider {
            line += " · " + String(format: Chrome.localized("%@ is not set up, sub-agents stay on %@"), pair.headsProvider.displayName, pair.provider.displayName)
        }
        return line
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

/// A combo's provider marks: the lead's larger and the sub-agents' smaller after an arrow,
/// the same mark wherever a combo is drawn, so a same-provider combo shows
/// provider → provider too and a row reads the same everywhere.
private struct HydraPairIcons: View {
    let pair: HydraPair

    var body: some View {
        HydraPairMark(lead: pair.provider, heads: pair.headsProvider)
            .frame(minWidth: 22, alignment: .leading)
    }
}

/// The combo's settings: provider, lead model and effort, the sub-agents' provider, model and
/// effort, and how many sub-agents go out at once. Every choice writes straight to the combo.
struct HydraPairEditor: View {
    @Environment(AppModel.self) private var model
    let pair: HydraPair
    var showsName = true
    let update: ((inout HydraPair) -> Void) -> Void

    /// The name field: a popover hands its first field the focus as it opens, and the
    /// caret landing there read as a prompt to rename the combo. The field is given back
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
        let leadEfforts = SubagentEditor.efforts(of: leadOption, fallback: SubagentEditor.allEfforts(options))
        // Sub-agents with no model chosen inherit the chat's, and its efforts; on another
        // provider they run its default model, so its efforts are the ones on offer.
        let workerEfforts = SubagentEditor.efforts(of: workerOption, fallback: pair.sendsHeadsElsewhere ? SubagentEditor.efforts(of: registry.defaultModel(for: pair.headsProvider), fallback: SubagentEditor.allEfforts(headsOptions)) : leadEfforts)
        VStack(alignment: .leading, spacing: 0) {
            if showsName {
                // The name is the header: the combo's own word for itself, over what it
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
            VStack(alignment: .leading, spacing: 4) {
                TextField("", text: Binding(
                    get: { pair.headsNote ?? "" },
                    set: { text in update { $0.headsNote = text.isEmpty ? nil : text } }
                ), prompt: Text("What the sub-agents are good at"))
                .textFieldStyle(.plain)
                .font(.ui(.title3, weight: .semibold))
                .foregroundStyle(Chrome.primaryText)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Chrome.overlay(0.06), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                Text("The lead is told this, so it sends this kind of work to the sub-agents. For example: fast, for mechanical edits; or front-end.")
                    .font(.ui(.subheadline))
                    .foregroundStyle(Chrome.secondaryText)
                    .padding(.horizontal, 2)
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            SubagentEditor.sectionLabel("Lead")
            SubagentEditor.row("Provider") {
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
                                // Sub-agents on the old lead provider go with it; sub-agents on a
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
            SubagentEditor.row("Model") {
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
                SubagentEditor.row("Effort") {
                    SubagentEditor.effortPicker(
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
                SubagentEditor.row("Agent mode") {
                    GlassPickerButton(
                        options: DshAgentMode.allCases.map { ($0, $0.title) },
                        selection: Binding(
                            get: { pair.orchestratorDshMode ?? .standard },
                            set: { mode in update { $0.orchestratorDshMode = mode == .standard ? nil : mode } }
                        )
                    )
                }
            }
            SubagentEditor.sectionLabel("Sub-agents")
            SubagentEditor.row("Provider") {
                GlassPickerButton(
                    options: [(ProviderKind?.none, "Same as the lead")] + headsProviders.filter { $0 != pair.provider }.map { (Optional($0), $0.displayName) },
                    selection: Binding(
                        get: { pair.sendsHeadsElsewhere ? pair.workerProvider : nil },
                        set: { provider in
                            update {
                                let chosen = provider == $0.provider ? nil : provider
                                guard $0.workerProvider != chosen else { return }
                                // The sub-agents' model and effort were the old provider's.
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
            SubagentEditor.row("Model") {
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
                SubagentEditor.row("Effort") {
                    SubagentEditor.effortPicker(
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
                SubagentEditor.row("Agent mode") {
                    GlassPickerButton(
                        options: DshAgentMode.allCases.map { ($0, $0.title) },
                        selection: Binding(
                            get: { pair.workerDshMode ?? .standard },
                            set: { mode in update { $0.workerDshMode = mode == .standard ? nil : mode } }
                        )
                    )
                }
            }
            SubagentEditor.row("Sub-agents at once per chat") {
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

    /// The providers whose catalogs the editor shows: the lead's and the sub-agents', each once
    /// and in that order, so the pickers and the loading notes cover both.
    private static func catalogProviders(_ pair: HydraPair) -> [ProviderKind] {
        pair.sendsHeadsElsewhere ? [pair.provider, pair.headsProvider] : [pair.provider]
    }
}

/// Shared layout and model-effort helpers for sub-agent and combo popovers.
enum SubagentEditor {
    @MainActor
    static func row<Control: View>(_ title: String, detail: String? = nil, @ViewBuilder control: () -> Control) -> some View {
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
    @MainActor
    static func sectionLabel(_ title: String, divided: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if divided {
                Divider()
                    .padding(.horizontal, 14)
                    .padding(.top, 12)
            }
            Text(verbatim: Chrome.localized(title))
                .font(.ui(.subheadline, weight: .semibold))
                .foregroundStyle(Chrome.secondaryText)
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 4)
        }
    }

    @MainActor
    static func effortPicker(efforts: [String], inherit: String, selection: Binding<String?>) -> some View {
        GlassPickerButton(
            options: [(String?.none, inherit)] + efforts.map { (Optional($0), ModelOption.effortTitle($0)) },
            selection: selection
        )
    }

    /// Every effort any of the provider's models offers, in the order the first lists them.
    static func allEfforts(_ options: [ModelOption]) -> [String] {
        var seen: [String] = []
        for option in options {
            for effort in option.efforts where !seen.contains(effort) { seen.append(effort) }
        }
        return seen
    }

    /// A model's efforts for the picker: its declared scale, or the fallback when the
    /// declaration is empty — a catalog that has not walked the model's scale yet would
    /// otherwise take the effort row away from a model that does reason.
    static func efforts(of option: ModelOption?, fallback: @autoclosure () -> [String]) -> [String] {
        guard let option, !option.efforts.isEmpty else { return fallback() }
        return option.efforts
    }

    /// A chosen model's short name, or its id while the catalog has not listed it.
    @MainActor
    static func namedModel(_ id: String?, provider: ProviderKind, registry: ProviderRegistry) -> String? {
        guard let id else { return nil }
        return registry.model(id, for: provider)?.shortName ?? id
    }

    /// A chosen effort in the words the rest of the app uses. Nil stays nil.
    @MainActor
    static func namedEffort(_ effort: String?) -> String? {
        guard let effort, !effort.isEmpty else { return nil }
        return Chrome.localized(ModelOption.effortTitle(effort))
    }
}
