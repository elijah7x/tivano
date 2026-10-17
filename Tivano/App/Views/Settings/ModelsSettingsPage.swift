import SwiftUI

/// Chooses the models the composer's picker offers, and each one's effort and fast mode for new chats.
struct ModelsSettingsPage: View {
    @Environment(AppModel.self) private var model
    var query = ""

    /// The live grip reorder of a chosen model within its card (see `RowDrag`).
    @State private var drag = RowDrag<ModelListItem>()
    /// Each row's height including its divider: one row's slot in the card.
    @State private var rowHeights: [ModelListItem: CGFloat] = [:]
    @State private var sectionToFocus: UUID?
    /// Each card's frame in the window, so a model dragged out of its card can land in another.
    @State private var cardFrames: [DropCard: CGRect] = [:]
    /// Each chosen model's vertical centre in the window: where a drop into a card lands.
    @State private var rowMids: [ModelPin: CGFloat] = [:]
    /// The other card a dragged model is over, highlighted until the drop.
    @State private var dropTarget: DropCard?
    /// The live grip reorder of a whole group card among the groups.
    @State private var groupDrag = RowDrag<UUID>()
    @AppStorage("performanceMode", store: CaptureRun.defaults ?? .standard) private var performanceMode = false
    /// Each provider section's expansion, keyed on the page so typing in the search
    /// field — which rebuilds the sections — doesn't reset it. Absent means expanded.
    @State private var providerExpansion: [ProviderKind: Bool] = [:]

    /// The stack of model cards, which drag locations and drop frames are measured in.
    static let cardsSpace = "modelCards"

    /// Neighbours sliding out of the grabbed row's way.
    private static let slide = Animation.spring(response: 0.28, dampingFraction: 0.82)

    var body: some View {
        let settings = model.settings
        let registry = model.providers
        let pins = settings.modelList
        let items = settings.modelListItems
        let trimmed = query.trimmed
        let blocks = modelBlocks(query: trimmed)
        let sections = blocks.groups.map(\.section)
        let visiblePins = blocks.ungrouped + blocks.groups.flatMap(\.pins)
        let available = Set(registry.availableProviders)
        let providers = ProviderKind.alphabetical.filter { provider in
            available.contains(provider) && (trimmed.isEmpty || registry.models(for: provider).contains { Self.matches($0, id: $0.id, provider: provider, query: trimmed) })
        }
        // Filtering is instant with no transitions: animating dozens of rows with blur on every
        // keystroke (and all of them again when clearing) is what made entries overlap and jump.
        // Lazy all the way down: expanded catalogues run to hundreds of rows, and the
        // settings scroll view builds and measures every row of an eager stack.
        LazyVStack(alignment: .leading, spacing: Chrome.sectionSpacing) {
            if trimmed.isEmpty || !visiblePins.isEmpty {
                ChromeSection(
                    title: "Your models",
                    accessory: AnyView(
                        Text(verbatim: "\(pins.count) / \(AppSettings.modelListLimit)")
                            .font(.ui(size: 11))
                            .foregroundStyle(Chrome.secondaryText)
                    ),
                    trailing: trimmed.isEmpty ? AnyView(newGroupButton) : nil
                ) {
                    VStack(alignment: .leading, spacing: 10) {
                        if !blocks.ungrouped.isEmpty || blocks.groups.isEmpty {
                            ChromeCard {
                                VStack(spacing: 0) {
                                    if trimmed.isEmpty, blocks.groups.isEmpty, pins.count > 8, !settings.dismissedModelGroupsTip {
                                        HStack(spacing: 10) {
                                            Image(systemName: "square.stack")
                                                .font(.ui(size: 12))
                                            Text("Lots of models? Group them, and fold the ones you rarely use in the picker.")
                                                .fixedSize(horizontal: false, vertical: true)
                                            Spacer(minLength: 8)
                                            newGroupButton
                                            RowControl(symbol: "xmark", help: "Dismiss", isEnabled: true) {
                                                settings.dismissedModelGroupsTip = true
                                            }
                                        }
                                        .font(.ui(size: 11))
                                        .foregroundStyle(Chrome.secondaryText)
                                        .padding(.leading, 10)
                                        .padding(.trailing, Chrome.rowControlTrailingPadding)
                                        .padding(.vertical, 6)
                                        ChromeRowDivider()
                                    }
                                    if pins.isEmpty {
                                        ChromeRow(
                                            title: "No models chosen yet",
                                            detail: "Until you add some below, the picker shows every model from your providers."
                                        ) {
                                            EmptyView()
                                        }
                                    } else if visiblePins.isEmpty, trimmed.isEmpty {
                                        ChromeRow(
                                            title: "No models from active providers",
                                            detail: "Enable a provider to restore its chosen models, or add models below."
                                        ) {
                                            EmptyView()
                                        }
                                    }
                                    pinnedRows(blocks.ungrouped, in: nil, sections: sections)
                                }
                            }
                            .modifier(DropCardChrome(card: .ungrouped, frames: $cardFrames, isTarget: dropTarget == .ungrouped, holdsDrag: holdsDrag(blocks.ungrouped)))
                        }
                        ForEach(blocks.groups) { block in
                            if trimmed.isEmpty || !block.pins.isEmpty {
                                let isCollapsed = trimmed.isEmpty && settings.isModelSectionCollapsed(block.section.id)
                                ChromeCard {
                                    VStack(spacing: 0) {
                                        ModelGroupHeader(
                                            section: block.section,
                                            pins: block.pins,
                                            isCollapsed: isCollapsed,
                                            canMoveUp: block.id != blocks.groups.first?.id,
                                            canMoveDown: block.id != blocks.groups.last?.id,
                                            canDrag: trimmed.isEmpty,
                                            isDragged: groupDrag.id == block.id,
                                            sectionToFocus: $sectionToFocus,
                                            onDragChanged: { translation in groupDragChanged(block.id, translation: translation) },
                                            onDragEnded: { groupDragEnded() }
                                        )
                                        if !isCollapsed {
                                            ChromeRowDivider()
                                            if block.pins.isEmpty {
                                                HStack {
                                                    Text("Empty. Right-click a model and choose Move to Group.")
                                                        .font(.ui(size: 11))
                                                        .foregroundStyle(Chrome.secondaryText)
                                                    Spacer(minLength: 8)
                                                }
                                                .padding(.leading, 10)
                                                .padding(.trailing, Chrome.rowControlTrailingPadding)
                                                .padding(.vertical, 6)
                                            } else {
                                                pinnedRows(block.pins, in: block.id, sections: sections)
                                            }
                                        }
                                    }
                                }
                                .modifier(LiftedGroupCard(isLifted: groupDrag.id == block.id, offset: groupDrag.id == block.id ? groupDrag.visualOffset : 0, performanceMode: performanceMode))
                                .modifier(DropCardChrome(card: .group(block.id), frames: $cardFrames, isTarget: dropTarget == .group(block.id), holdsDrag: holdsDrag(block.pins) || groupDrag.id == block.id))
                            }
                        }
                    }
                    // Rows and cards measure themselves against this stack rather than the
                    // window, so scrolling the page does not report new frames every frame.
                    .coordinateSpace(.named(Self.cardsSpace))
                    if trimmed.isEmpty {
                        Text("Click a model to set its reasoning effort and fast mode for every new chat. Right-click it to move it to another group.")
                            .font(.ui(size: 11))
                            .foregroundStyle(Chrome.secondaryText)
                            .padding(.horizontal, 4)
                    }
                }
            }

            ForEach(providers) { provider in
                ProviderModelsSection(
                    provider: provider,
                    query: trimmed,
                    isExpanded: Binding(
                        get: { providerExpansion[provider] ?? true },
                        set: { providerExpansion[provider] = $0 }
                    )
                )
            }

            if !trimmed.isEmpty, visiblePins.isEmpty, providers.isEmpty {
                Text(verbatim: String(format: Chrome.localized("No models match “%@”."), trimmed))
                    .font(.ui(size: 13))
                    .foregroundStyle(Chrome.secondaryText)
                    .padding(.horizontal, 4)
            }
        }
        .onChange(of: items) { _, items in
            // Heading values change when renamed or moved; keep measurements by stable ID.
            let heightsByID = rowHeights.reduce(into: [String: CGFloat]()) { heights, entry in
                heights[entry.key.id] = entry.value
            }
            rowHeights = Dictionary(uniqueKeysWithValues: items.compactMap { item in
                heightsByID[item.id].map { (item, $0) }
            })
        }
    }

    // MARK: - Reorder

    private struct ModelGroupBlock: Identifiable {
        let section: ModelSection
        var pins: [ModelPin] = []
        var id: UUID { section.id }
    }

    private func modelBlocks(query: String) -> (ungrouped: [ModelPin], groups: [ModelGroupBlock]) {
        let registry = model.providers
        var ungrouped: [ModelPin] = []
        var groups: [ModelGroupBlock] = []
        for item in model.settings.modelListItems {
            switch item {
            case .section(let section):
                groups.append(ModelGroupBlock(section: section))
            case .pin(let pin):
                guard model.settings.isEnabled(pin.provider),
                      Self.matches(registry.model(pin.modelID, for: pin.provider), id: pin.modelID, provider: pin.provider, query: query) else { continue }
                if groups.isEmpty {
                    ungrouped.append(pin)
                } else {
                    groups[groups.count - 1].pins.append(pin)
                }
            }
        }
        return (ungrouped, groups)
    }

    private var newGroupButton: some View {
        Button {
            withAnimation(Chrome.panelSlide) {
                let id = model.settings.addModelSection(named: Chrome.localized("New group"))
                if model.settings.isModelSectionCollapsed(id) {
                    model.settings.toggleModelSectionCollapsed(id)
                }
                sectionToFocus = id
            }
        } label: {
            Label("New group", systemImage: "plus")
        }
        .buttonStyle(.plain)
        .font(.ui(size: 11))
        .foregroundStyle(Chrome.secondaryText)
        .fixedSize()
    }

    private func pinnedRows(_ pins: [ModelPin], in sectionID: UUID?, sections: [ModelSection]) -> some View {
        // An eager stack preserves the lifted row's position and zIndex.
        VStack(spacing: 0) {
            ForEach(pins, id: \.self) { pin in
                let item = ModelListItem.pin(pin)
                let isDragged = drag.id?.id == item.id
                VStack(spacing: 0) {
                    ChromeRowDivider().opacity(pin == pins.first || isDragged ? 0 : 1)
                    PinnedModelRow(
                        pin: pin,
                        sectionID: sectionID,
                        sections: sections,
                        isDragged: isDragged,
                        onDragChanged: { translation, pointerY in dragChanged(item, in: sectionID, translation: translation, pointerY: pointerY) },
                        onDragEnded: { pointerY in dragEnded(item, pointerY: pointerY) }
                    )
                }
                .modifier(PinnedRowHeightReporter(item: item, heights: $rowHeights))
                .onGeometryChange(for: CGFloat.self, of: { $0.frame(in: .named(Self.cardsSpace)).midY }) { mid in
                    if !isDragged, rowMids[pin] != mid { rowMids[pin] = mid }
                }
                .offset(y: isDragged ? drag.visualOffset : 0)
                .zIndex(isDragged ? 1 : 0)
            }
        }
    }

    /// Read the card's filtered order fresh on each move, keeping hidden pins in place.
    /// Over another card the row stops reordering its own and marks that card for the drop.
    private func dragChanged(_ item: ModelListItem, in sectionID: UUID?, translation: CGFloat, pointerY: CGFloat) {
        let own: DropCard = sectionID.map { .group($0) } ?? .ungrouped
        let hovered = cardFrames.first { $0.value.minY - 5 <= pointerY && pointerY <= $0.value.maxY + 5 }?.key
        if let hovered, hovered != own {
            if drag.id?.id != item.id { drag = RowDrag(id: item) }
            if dropTarget != hovered {
                dropTarget = hovered
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { drag.translation = translation }
            return
        }
        dropTarget = nil
        let blocks = modelBlocks(query: query.trimmed)
        let pins = sectionID.map { id in blocks.groups.first(where: { $0.id == id })?.pins ?? [] } ?? blocks.ungrouped
        let order = pins.map { ModelListItem.pin($0) }
        guard let current = order.first(where: { $0.id == item.id }) else { return }
        if drag.id?.id != current.id {
            drag = RowDrag(id: current)
        } else {
            drag.id = current
        }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { drag.translation = translation }

        let moved = withAnimation(Self.slide) {
            drag.settle(order: order, heights: rowHeights, fallbackHeight: 38) { neighbour, placeAfter in
                model.settings.moveModelListItem(current, to: neighbour, placeAfter: placeAfter)
            }
        }
        drag.id = model.settings.modelListItems.first(where: { $0.id == current.id })
        if moved {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
    }

    private func dragEnded(_ item: ModelListItem, pointerY: CGFloat) {
        guard let target = dropTarget, case .pin(let pin) = item else { return dragEnded() }
        let blocks = modelBlocks(query: query.trimmed)
        let pins = target.sectionID.map { id in blocks.groups.first { $0.id == id }?.pins ?? [] } ?? blocks.ungrouped
        // A folded group takes the model at its end; an open one where the pointer lets go.
        let isFolded = target.sectionID.map { query.trimmed.isEmpty && model.settings.isModelSectionCollapsed($0) } ?? false
        let before = isFolded ? nil : pins.first { $0 != pin && (rowMids[$0] ?? .infinity) > pointerY }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            drag = RowDrag()
            dropTarget = nil
        }
        withAnimation(Chrome.panelSlide) { model.settings.moveModel(pin, toSection: target.sectionID, before: before) }
    }

    /// A group card follows its grip and swaps past every neighbouring group whose centre
    /// it crosses; the ungrouped models stay on top.
    private func groupDragChanged(_ id: UUID, translation: CGFloat) {
        if groupDrag.id != id { groupDrag = RowDrag(id: id) }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { groupDrag.translation = translation }

        let order = modelBlocks(query: "").groups.map(\.id)
        // A card's slot is its height plus the gap between cards.
        let heights = Dictionary(uniqueKeysWithValues: order.compactMap { id in cardFrames[.group(id)].map { (id, $0.height + 10) } })
        let moved = withAnimation(Self.slide) {
            groupDrag.settle(order: order, heights: heights, fallbackHeight: 60) { _, placeAfter in
                model.settings.moveModelSection(id, by: placeAfter ? 1 : -1)
                return true
            }
        }
        if moved {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
    }

    private func groupDragEnded() {
        guard groupDrag.id != nil else { return }
        withAnimation(.spring(response: 0.32, dampingFraction: 0.8)) { groupDrag = RowDrag() }
    }

    private func holdsDrag(_ pins: [ModelPin]) -> Bool {
        guard case .pin(let pin) = drag.id else { return false }
        return pins.contains(pin)
    }

    private func dragEnded() {
        guard drag.id != nil else { return }
        withAnimation(.spring(response: 0.32, dampingFraction: 0.8)) { drag = RowDrag() }
    }

    private enum DropCard: Hashable {
        case ungrouped
        case group(UUID)

        var sectionID: UUID? {
            if case .group(let id) = self { id } else { nil }
        }
    }

    /// A group card lifted by its grip: it follows the pointer, a touch larger with a shadow.
    private struct LiftedGroupCard: ViewModifier {
        let isLifted: Bool
        let offset: CGFloat
        let performanceMode: Bool

        func body(content: Content) -> some View {
            content
                .background {
                    if isLifted {
                        RoundedRectangle(cornerRadius: Chrome.cardCornerRadius, style: .continuous)
                            .fill(Chrome.overlay(0.12))
                            .shadow(color: .black.opacity(performanceMode ? 0 : 0.28), radius: performanceMode ? 0 : 10, y: performanceMode ? 0 : 4)
                    }
                }
                .scaleEffect(isLifted ? 1.01 : 1)
                .offset(y: offset)
                .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isLifted)
        }
    }

    /// Reports a card's frame, highlights it as a drop target, and lifts the card holding
    /// the dragged row above its neighbours so the row draws over them.
    private struct DropCardChrome: ViewModifier {
        let card: DropCard
        @Binding var frames: [DropCard: CGRect]
        let isTarget: Bool
        let holdsDrag: Bool

        func body(content: Content) -> some View {
            content
                .overlay {
                    if isTarget {
                        RoundedRectangle(cornerRadius: Chrome.cardCornerRadius, style: .continuous)
                            .fill(Chrome.overlay(0.06))
                            .strokeBorder(Chrome.secondaryText.opacity(0.45), lineWidth: 1.5)
                            .allowsHitTesting(false)
                    }
                }
                .animation(.easeOut(duration: 0.12), value: isTarget)
                .zIndex(holdsDrag ? 1 : 0)
                .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named(ModelsSettingsPage.cardsSpace)) }) { frame in
                    if frames[card] != frame { frames[card] = frame }
                }
                .onDisappear { frames[card] = nil }
        }
    }

    private struct PinnedRowHeightReporter: ViewModifier {
        let item: ModelListItem
        @Binding var heights: [ModelListItem: CGFloat]

        func body(content: Content) -> some View {
            content.onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { height in
                if heights[item] != height { heights[item] = height }
            }
        }
    }

    /// Whether a model matches the search by name, description or provider.
    static func matches(_ option: ModelOption?, id: String, provider: ProviderKind, query: String) -> Bool {
        guard !query.isEmpty else { return true }
        let fields = [option?.shortName, option?.name, option?.detail, id, provider.displayName]
        return fields.contains { $0?.localizedCaseInsensitiveContains(query) == true }
    }
}

private struct PinnedModelRow: View {
    @Environment(AppModel.self) private var model
    let pin: ModelPin
    let sectionID: UUID?
    let sections: [ModelSection]
    /// Lifted and following the pointer.
    let isDragged: Bool
    let onDragChanged: (_ translation: CGFloat, _ pointerY: CGFloat) -> Void
    let onDragEnded: (_ pointerY: CGFloat) -> Void

    @AppStorage("performanceMode", store: CaptureRun.defaults ?? .standard) private var performanceMode = false
    @State private var isPresented = false
    @State private var isHovering = false
    /// Whether the pointer is over the reorder grip, which brightens its icon.
    @State private var isHoveringGrip = false

    var body: some View {
        let settings = model.settings
        let option = model.providers.model(pin.modelID, for: pin.provider)
        let preference = settings.preference(for: pin.provider, model: pin.modelID)
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal")
                .font(.ui(size: 11, weight: .medium))
                .foregroundStyle(Chrome.secondaryText.opacity(isHoveringGrip ? 1 : 0.7))
                .frame(width: 24, height: 24)
                .contentShape(.rect)
                .onHover { hovering in isHoveringGrip = hovering }
                .pointerStyle(isDragged ? .grabActive : .grabIdle)
                .gesture(
                    DragGesture(minimumDistance: 1, coordinateSpace: .named(ModelsSettingsPage.cardsSpace))
                        .onChanged { value in onDragChanged(value.translation.height, value.location.y) }
                        .onEnded { value in onDragEnded(value.location.y) }
                )
                .help(Text(verbatim: Chrome.localized("Drag to reorder or into another group")))
                .accessibilityLabel(Text("Drag to reorder"))
            Button {
                isPresented = true
            } label: {
                HStack(spacing: 12) {
                    ProviderIcon(provider: pin.provider, size: 16)
                        .foregroundStyle(Chrome.primaryText)
                        .frame(width: 22)
                    Text(verbatim: option?.shortName ?? pin.modelID)
                        .font(.ui(size: 13))
                        .foregroundStyle(Chrome.primaryText)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(verbatim: summary(option: option, preference: preference))
                        .font(.ui(size: 11))
                        .foregroundStyle(Chrome.secondaryText)
                        .lineLimit(1)
                    Image(systemName: "slider.horizontal.3")
                        .font(.ui(size: 12))
                        .foregroundStyle(Chrome.secondaryText)
                        .opacity(isHovering ? 1 : 0)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .onHover { isHovering = $0 }
            .popover(isPresented: $isPresented, arrowEdge: .trailing) {
                EffortSliderCard(
                    modelName: option?.shortName ?? pin.modelID,
                    provider: pin.provider,
                    efforts: option?.efforts ?? [],
                    defaultEffort: option?.defaultEffort,
                    supportsFast: option?.supportsFast ?? false,
                    effort: Binding(
                        get: { settings.preference(for: pin.provider, model: pin.modelID).effort },
                        set: { effort in
                            var updated = settings.preference(for: pin.provider, model: pin.modelID)
                            updated.effort = effort
                            settings.setPreference(updated, for: pin.provider, model: pin.modelID)
                        }
                    ),
                    fastMode: Binding(
                        get: { settings.preference(for: pin.provider, model: pin.modelID).fastMode },
                        set: { isOn in
                            var updated = settings.preference(for: pin.provider, model: pin.modelID)
                            updated.fastMode = isOn
                            settings.setPreference(updated, for: pin.provider, model: pin.modelID)
                        }
                    ),
                    onReset: { settings.setPreference(ModelPreference(), for: pin.provider, model: pin.modelID) }
                )
                .frame(width: 330)
                .presentedChrome()
            }

            RowControl(symbol: "minus.circle", help: "Remove from the picker", isEnabled: true) {
                withAnimation(Chrome.panelSlide) { settings.removeFromModelList(pin) }
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, Chrome.rowControlTrailingPadding)
        .padding(.vertical, 6)
        .contextMenu {
            Menu("Move to Group") {
                if sectionID != nil {
                    Button("No Group") {
                        withAnimation(Chrome.panelSlide) { settings.moveModel(pin, toSection: nil) }
                    }
                }
                ForEach(sections.filter { $0.id != sectionID }) { section in
                    Button {
                        withAnimation(Chrome.panelSlide) { settings.moveModel(pin, toSection: section.id) }
                    } label: {
                        Text(verbatim: section.name)
                    }
                }
            }
            Divider()
            Button("Remove from the picker") {
                withAnimation(Chrome.panelSlide) { settings.removeFromModelList(pin) }
            }
        }
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
    }

    private func summary(option: ModelOption?, preference: ModelPreference) -> String {
        var parts = [pin.provider.displayName]
        if let option, !option.efforts.isEmpty {
            parts.append(String(format: Chrome.localized("%@ effort"), Chrome.localized(ModelOption.effortTitle(preference.effort ?? option.defaultEffort ?? ""))))
        }
        if preference.fastMode, option?.supportsFast == true { parts.append(Chrome.localized("Fast")) }
        return parts.joined(separator: " · ")
    }
}

private struct ModelGroupHeader: View {
    @Environment(AppModel.self) private var model
    let section: ModelSection
    let pins: [ModelPin]
    let isCollapsed: Bool
    let canMoveUp: Bool
    let canMoveDown: Bool
    let canDrag: Bool
    let isDragged: Bool
    @Binding var sectionToFocus: UUID?
    let onDragChanged: (CGFloat) -> Void
    let onDragEnded: () -> Void

    @State private var draft = ""
    @State private var isEditing = false
    @State private var isHovering = false
    @State private var isHoveringGrip = false
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 10) {
            // Lines up with the models' grips below it.
            Image(systemName: "line.3.horizontal")
                .font(.ui(size: 11, weight: .medium))
                .foregroundStyle(Chrome.secondaryText.opacity(isHoveringGrip ? 1 : 0.7))
                .frame(width: 24, height: 24)
                .contentShape(.rect)
                .onHover { hovering in isHoveringGrip = hovering }
                .pointerStyle(isDragged ? .grabActive : .grabIdle)
                .gesture(
                    DragGesture(minimumDistance: 1, coordinateSpace: .global)
                        .onChanged { value in onDragChanged(value.translation.height) }
                        .onEnded { _ in onDragEnded() }
                )
                .opacity(canDrag ? 1 : 0)
                .allowsHitTesting(canDrag)
                .help(Text(verbatim: Chrome.localized("Drag to reorder groups")))
                .accessibilityLabel(Text("Drag to reorder groups"))
            Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                .font(Chrome.chevronFont)
                .foregroundStyle(Chrome.secondaryText)
                .frame(width: 24, height: 24)
            if isEditing {
                TextField("New group", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.ui(size: 13, weight: .semibold))
                    .foregroundStyle(Chrome.primaryText)
                    .focused($isFocused)
                    .onAppear { isFocused = true }
                    .onSubmit { commitName() }
                    .onChange(of: isFocused) { _, focused in
                        if !focused { commitName() }
                    }
                    .onTapGesture { }
                    .accessibilityLabel(Text("Group name"))
            } else {
                Text(verbatim: section.name)
                    .font(.ui(size: 13, weight: .semibold))
                    .foregroundStyle(Chrome.primaryText)
                    .lineLimit(1)
                    .gesture(
                        TapGesture(count: 2).onEnded { beginEditing() }
                            .exclusively(before: TapGesture().onEnded { toggleCollapse() })
                    )
            }
            Text(verbatim: "\(pins.count)")
                .font(.ui(size: 11))
                .foregroundStyle(Chrome.secondaryText)
            if isCollapsed {
                HStack(spacing: 4) {
                    ForEach(Array(pins.prefix(8)), id: \.self) { pin in
                        ProviderIcon(provider: pin.provider, size: 12)
                            .foregroundStyle(Chrome.secondaryText)
                    }
                }
            }
            Spacer(minLength: 8)
            HStack(spacing: 4) {
                RowControl(symbol: "pencil", help: "Rename group", isEnabled: true) { beginEditing() }
                RowControl(symbol: "trash", help: "Delete group", isEnabled: true) {
                    withAnimation(Chrome.panelSlide) { model.settings.removeModelSection(section.id) }
                }
            }
            .opacity(isHovering ? 1 : 0)
            .allowsHitTesting(isHovering)
        }
        .padding(.leading, 10)
        .padding(.trailing, Chrome.rowControlTrailingPadding)
        .padding(.vertical, 6)
        .contentShape(.rect)
        .onTapGesture { toggleCollapse() }
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("Rename") { beginEditing() }
            Button("Move Up") {
                withAnimation(Chrome.panelSlide) { model.settings.moveModelSection(section.id, by: -1) }
            }
            .disabled(!canMoveUp)
            Button("Move Down") {
                withAnimation(Chrome.panelSlide) { model.settings.moveModelSection(section.id, by: 1) }
            }
            .disabled(!canMoveDown)
            Divider()
            Button("Delete Group") {
                withAnimation(Chrome.panelSlide) { model.settings.removeModelSection(section.id) }
            }
        }
        .onAppear { focusNewGroup() }
        .onChange(of: sectionToFocus) { _, _ in focusNewGroup() }
        .onChange(of: section.name) { _, name in
            if !isEditing { draft = name }
        }
    }

    private func toggleCollapse() {
        withAnimation(Chrome.panelSlide) { model.settings.toggleModelSectionCollapsed(section.id) }
    }

    private func beginEditing() {
        draft = section.name
        isEditing = true
        isFocused = true
    }

    private func focusNewGroup() {
        guard sectionToFocus == section.id else { return }
        draft = ""
        isEditing = true
        isFocused = true
        sectionToFocus = nil
    }

    private func commitName() {
        let name = draft.trimmed
        draft = name.isEmpty ? section.name : name
        if draft != section.name {
            model.settings.renameModelSection(section.id, to: draft)
        }
        isEditing = false
        isFocused = false
    }
}

private struct RowControl: View {
    let symbol: String
    let help: String
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.ui(size: 12, weight: .medium))
                .foregroundStyle(Chrome.secondaryText)
                .frame(width: 24, height: 24)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.35)
        .help(Text(verbatim: Chrome.localized(help)))
        .accessibilityLabel(Text(verbatim: Chrome.localized(help)))
    }
}

private struct ProviderModelsSection: View {
    @Environment(AppModel.self) private var model
    let provider: ProviderKind
    var query = ""

    /// Lives on the page (`providerExpansion`), so typing in the search field — which
    /// rebuilds this section — doesn't reset it. Absent there means expanded.
    @Binding var isExpanded: Bool

    /// The lines showing their earlier versions, and whether the free and preview models show.
    @State private var openLineages: Set<String> = []
    @State private var showsTrials = false
    @State private var lineages = LineageCache()

    /// A catalogue longer than this folds each line to its newest version and sets the
    /// free and preview models aside; a shorter one reads at a glance as it is.
    private static let foldingThreshold = 12

    private enum Row: Identifiable {
        /// A model; `earlier` counts the versions folded under it, `lineage` names its line.
        case model(ModelOption, earlier: Int = 0, lineage: String? = nil)
        case trials(count: Int)

        var id: String {
            switch self {
            case .model(let option, _, _): "model/" + option.id
            case .trials: "trials"
            }
        }
    }

    var body: some View {
        let settings = model.settings
        let registry = model.providers
        let catalogue = registry.sortedModels(for: provider)
        let isFull = settings.modelList.count >= AppSettings.modelListLimit
        let isFiltering = !query.isEmpty
        let pinned = Set(settings.modelList)
        let rows = rows(catalogue, pinned: pinned, isFiltering: isFiltering)
        // Collapsed with nothing chosen closes the card outright.
        let cardVisible = isExpanded || isFiltering || !rows.isEmpty
        VStack(alignment: .leading, spacing: Chrome.sectionHeaderSpacing) {
            CollapsibleProviderHeader(provider: provider, isExpanded: $isExpanded, subject: "model list")
            // Lazy, so only the rows on screen are built. Same fill and shape as ChromeCard.
            LazyVStack(spacing: 0) {
                if catalogue.isEmpty {
                    // The loading/empty row is the expanded state; collapsed closes it.
                    ChromeRevealLayout(fraction: cardVisible ? 1 : 0) {
                        ChromeRow(title: registry.loadingCatalogs.contains(provider) ? "Loading models…" : "No models loaded") {
                            Button("Load models") {
                                Task { await registry.loadCatalog(provider, force: true) }
                            }
                            .buttonStyle(.glass)
                            .disabled(registry.loadingCatalogs.contains(provider))
                        }
                    }
                    .clipped()
                    .disabled(!cardVisible)
                    .allowsHitTesting(cardVisible)
                    .accessibilityHidden(!cardVisible)
                } else {
                    // Only visible rows are built: catalogues run to hundreds of models, and
                    // mounting every hidden one (each with its own tooltip tracking area)
                    // made the page re-measure them all on every hover, keystroke and resize.
                    ForEach(rows) { row in
                        if row.id != rows.first?.id {
                            ChromeRowDivider()
                        }
                        switch row {
                        case .model(let option, let earlier, let lineage):
                            modelRow(option, earlier: earlier, lineage: lineage, pinned: pinned, isFull: isFull, isFiltering: isFiltering)
                        case .trials(let count):
                            ChromeRow(title: "Free and preview models", detail: String(format: Chrome.localized("%lld models"), count)) {
                                disclosure(isOpen: showsTrials, label: nil, show: "Show free and preview models", hide: "Hide free and preview models") {
                                    showsTrials.toggle()
                                }
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Chrome.cardCornerRadius, style: .continuous)
                    .fill(Chrome.overlay(0.03))
            )
            .clipShape(RoundedRectangle(cornerRadius: Chrome.cardCornerRadius, style: .continuous))
            // Search re-filters instantly, typing and clearing alike; header toggles
            // still animate (their transaction never touches `query`).
            .animation(nil, value: query)
            // Collapsed rows are neither tappable nor in the accessibility tree.
            .allowsHitTesting(cardVisible)
            .accessibilityHidden(!cardVisible)
        }
        .task { await registry.loadCatalog(provider) }
    }

    /// Search shows only matches and collapsed only the chosen models, all in catalogue
    /// order. Expanded shows everything; a long catalogue (see `foldingThreshold`) shows
    /// each line's newest version with the earlier ones folded under it, and the free
    /// and preview models as one row. A chosen model always shows.
    private func rows(_ catalogue: [ModelOption], pinned: Set<ModelPin>, isFiltering: Bool) -> [Row] {
        let isPinned = { (option: ModelOption) in pinned.contains(ModelPin(provider: provider, modelID: option.id)) }
        if isFiltering {
            return catalogue.filter { ModelsSettingsPage.matches($0, id: $0.id, provider: provider, query: query) }.map { .model($0) }
        }
        guard isExpanded else { return catalogue.filter(isPinned).map { .model($0) } }
        guard catalogue.count > Self.foldingThreshold else { return catalogue.map { .model($0) } }
        let layout = lineages.layout(of: catalogue)
        var rows: [Row] = []
        for lineage in layout.lineages {
            rows.append(.model(lineage.newest, earlier: lineage.earlier.count, lineage: lineage.key))
            let isOpen = openLineages.contains(lineage.key)
            rows += lineage.earlier.filter { isOpen || isPinned($0) }.map { .model($0) }
        }
        if !layout.trials.isEmpty {
            rows.append(.trials(count: layout.trials.count))
            rows += layout.trials.filter { showsTrials || isPinned($0) }.map { .model($0) }
        }
        return rows
    }

    private func modelRow(_ option: ModelOption, earlier: Int, lineage: String?, pinned: Set<ModelPin>, isFull: Bool, isFiltering: Bool) -> some View {
        let settings = model.settings
        let pin = ModelPin(provider: provider, modelID: option.id)
        let isAdded = pinned.contains(pin)
        return ChromeRow(title: option.shortName, detail: option.detail) {
            HStack(spacing: 10) {
                if let lineage, earlier > 0 {
                    disclosure(
                        isOpen: openLineages.contains(lineage),
                        label: String(format: Chrome.localized("Earlier versions (%lld)"), earlier),
                        show: "Show earlier versions",
                        hide: "Hide earlier versions"
                    ) {
                        if openLineages.contains(lineage) { openLineages.remove(lineage) } else { openLineages.insert(lineage) }
                    }
                }
                if option.supportsFast {
                    Image(systemName: "bolt")
                        .font(.ui(size: 11))
                        .foregroundStyle(Chrome.secondaryText)
                        .help(Text(verbatim: Chrome.localized("Supports fast mode")))
                }
                Button {
                    // Re-filtering mid-search is instant, like the
                    // rest of the page; otherwise rows slide.
                    if isFiltering {
                        if isAdded { settings.removeFromModelList(pin) } else { settings.addToModelList(pin) }
                    } else {
                        withAnimation(Chrome.panelSlide) {
                            if isAdded { settings.removeFromModelList(pin) } else { settings.addToModelList(pin) }
                        }
                    }
                } label: {
                    Image(systemName: isAdded ? "checkmark.circle.fill" : "plus.circle")
                        .font(.ui(size: 17))
                        .foregroundStyle(isAdded ? Chrome.accent : Chrome.secondaryText)
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
                .disabled(!isAdded && isFull)
                // A plain button does not dim itself; the same 0.35 as
                // every other disabled control on this page.
                .opacity(!isAdded && isFull ? 0.35 : 1)
                .help(Text(verbatim: isAdded ? Chrome.localized("Remove from the picker") : (isFull ? String(format: Chrome.localized("The picker holds up to %lld models"), AppSettings.modelListLimit) : Chrome.localized("Add to the picker"))))
                .accessibilityLabel(Text(verbatim: String(format: Chrome.localized(isAdded ? "Remove %@ from the picker" : "Add %@ to the picker"), option.shortName)))
            }
        }
    }

    /// The quiet chevron that opens what a row folds, like the provider header's.
    private func disclosure(isOpen: Bool, label: String?, show: String, hide: String, action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(Chrome.panelSlide) { action() }
        } label: {
            HStack(spacing: 6) {
                if let label {
                    Text(verbatim: label)
                        .font(.ui(size: 11))
                        .foregroundStyle(Chrome.secondaryText)
                }
                Image(systemName: "chevron.right")
                    .font(.ui(size: 11, weight: .semibold))
                    .foregroundStyle(Chrome.secondaryText)
                    .rotationEffect(.degrees(isOpen ? 90 : 0))
            }
            .contentShape(.rect)
        }
        .buttonStyle(ChromeQuietButtonStyle())
        .help(Text(verbatim: Chrome.localized(isOpen ? hide : show)))
        .accessibilityLabel(Text(verbatim: Chrome.localized(isOpen ? hide : show)))
    }
}

/// The last catalogue folded into lines and its folding, so a page redrawn on every
/// hover and keystroke reads the names once per catalogue rather than once per draw.
@MainActor
private final class LineageCache {
    private var catalogue: [ModelOption] = []
    private var cached = ModelFamilies.Layout(lineages: [], trials: [])

    func layout(of catalogue: [ModelOption]) -> ModelFamilies.Layout {
        if catalogue != self.catalogue {
            self.catalogue = catalogue
            cached = ModelFamilies.lineages(catalogue)
        }
        return cached
    }
}

/// The disclosure header over one provider's settings or model card.
struct CollapsibleProviderHeader: View {
    let provider: ProviderKind
    @Binding var isExpanded: Bool
    /// What the disclosure shows, named in the help and the accessibility hint.
    let subject: String
    var detail: String? = nil

    var body: some View {
        Button {
            withAnimation(Chrome.panelSlide) { isExpanded.toggle() }
        } label: {
            HStack(spacing: 8) {
                ProviderIcon(provider: provider, size: 16)
                    .foregroundStyle(Chrome.primaryText)
                Text(verbatim: provider.displayName)
                    .font(.ui(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: detail == nil ? 0 : 8)
                if let detail {
                    Text(verbatim: detail)
                        .font(.ui(size: 11))
                        .foregroundStyle(Chrome.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .layoutPriority(-1)
                }
                Image(systemName: "chevron.right")
                    .font(.ui(size: 11, weight: .semibold))
                    .foregroundStyle(Chrome.secondaryText)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
            }
            .contentShape(.rect)
        }
        .buttonStyle(ChromeQuietButtonStyle())
        .frame(height: 22)
        .help(Text(verbatim: String(format: Chrome.localized(isExpanded ? "Hide the %@" : "Show the %@"), Chrome.localized(subject))))
        .accessibilityLabel(Text(verbatim: detail.map { provider.displayName + ", " + $0 } ?? provider.displayName))
        .accessibilityValue(Text(verbatim: Chrome.localized(isExpanded ? "Expanded" : "Collapsed")))
        .accessibilityHint(Text(verbatim: String(format: Chrome.localized("Shows or hides the %@"), Chrome.localized(subject))))
        .accessibilityAddTraits(.isHeader)
    }
}
