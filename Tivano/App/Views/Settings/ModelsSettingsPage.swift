import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Chooses the models the composer's picker offers, and each one's effort and fast mode for new chats.
struct ModelsSettingsPage: View {
    @Environment(AppModel.self) private var model
    var query = ""

    @AppStorage("modelsSettingsSelectedGroup", store: CaptureRun.defaults ?? .standard)
    private var selectedGroupStorage = "all"

    @State private var searchSelectionOverride: GroupSelection?
    @State private var renameRequest: GroupRenameRequest?
    @State private var highlightedPin: ModelPin?
    @State private var scrollTargetPin: ModelPin?
    @State private var highlightTask: Task<Void, Never>?
    @State private var activeDrag: ModelPageDragPayload?
    @State private var hoveredRailTarget: RailDropTarget?
    @State private var hoveredModelCard: ModelPin?
    @State private var catalogueSelection: ProviderKind? = nil

    private static let railWidth: CGFloat = 200

    var body: some View {
        @Bindable var settings = model.settings
        let registry = model.providers
        let pins = settings.modelList
        let items = settings.modelListItems
        let trimmed = query.trimmed
        let searchQuery = trimmed.lowercased(with: .current)
        let allBlocks = modelBlocks(query: "", items: items)
        let blocks = searchQuery.isEmpty ? allBlocks : modelBlocks(query: searchQuery, items: items)
        let allSections = allBlocks.groups.map(\.section)
        let allVisiblePins = allBlocks.ungrouped + allBlocks.groups.flatMap(\.pins)
        let visiblePins = blocks.ungrouped + blocks.groups.flatMap(\.pins)
        let showsUngrouped = !allBlocks.ungrouped.isEmpty || allBlocks.groups.isEmpty
        let persistedSelection = resolvedSelection(allBlocks: allBlocks, showsUngrouped: showsUngrouped)
        let activeSelection = searchQuery.isEmpty
            ? persistedSelection
            : resolvedSelection(searchSelectionOverride ?? .all, allBlocks: allBlocks, showsUngrouped: showsUngrouped)
        let available = Set(registry.availableProviders)
        let availableProviders = ProviderKind.alphabetical.filter { available.contains($0) }
        let matchingCatalogues: [ProviderKind: [ModelOption]] = searchQuery.isEmpty ? [:] : Dictionary(
            uniqueKeysWithValues: availableProviders.compactMap { provider -> (ProviderKind, [ModelOption])? in
                let catalogue = registry.sortedModels(for: provider)
                let matches = provider.displayName.localizedCaseInsensitiveContains(searchQuery) ? catalogue : catalogue.filter {
                    Self.matches($0, id: $0.id, provider: provider, query: searchQuery)
                }
                return matches.isEmpty ? nil : (provider, matches)
            }
        )
        let providers = searchQuery.isEmpty ? availableProviders : availableProviders.filter { matchingCatalogues[$0] != nil }
        let selected = catalogueSelection.flatMap { providers.contains($0) ? $0 : nil }
        // Filtering is instant with no transitions: animating dozens of rows with blur on every
        // keystroke (and all of them again when clearing) is what made entries overlap and jump.
        // Lazy all the way down: expanded catalogues run to hundreds of rows, and the
        // settings scroll view builds and measures every row of an eager stack.
        ScrollViewReader { scrollProxy in
            LazyVStack(alignment: .leading, spacing: Chrome.pageSectionSpacing) {
                if trimmed.isEmpty || !visiblePins.isEmpty {
                    ChromeSection(
                        title: "Your models",
                        accessory: AnyView(
                            Text(verbatim: "\(pins.count) / \(AppSettings.modelListLimit)")
                                .font(.ui(size: 11).monospacedDigit())
                                .foregroundStyle(Chrome.secondaryText)
                        )
                    ) {
                        HStack(alignment: .top, spacing: Chrome.contentHorizontalPadding) {
                            masterGroupRail(
                                allBlocks: allBlocks,
                                filteredBlocks: blocks,
                                allVisiblePins: allVisiblePins,
                                visiblePins: visiblePins,
                                showsUngrouped: showsUngrouped,
                                isSearching: !searchQuery.isEmpty,
                                activeSelection: activeSelection
                            )
                            .frame(width: Self.railWidth)

                            ModelGroupDetailCard(
                                selection: activeSelection,
                                allBlocks: allBlocks,
                                filteredBlocks: blocks,
                                allSections: allSections,
                                totalPinnedCount: pins.count,
                                allVisiblePins: allVisiblePins,
                                visiblePins: visiblePins,
                                isSearching: !searchQuery.isEmpty,
                                highlightedPin: highlightedPin,
                                renameRequest: $renameRequest,
                                activeDrag: $activeDrag,
                                hoveredModelCard: $hoveredModelCard,
                                onSelectGroup: { target in selectGroup(target, isSearching: !searchQuery.isEmpty) },
                                onJumpToModel: { pin, sectionID in jumpToModel(pin, in: sectionID, isSearching: !searchQuery.isEmpty) }
                            )
                            // A short group still ends level with the rail's bottom edge.
                            .frame(maxHeight: .infinity, alignment: .top)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }

            if trimmed.isEmpty {
                ChromeSection(title: "Background models") {
                    ChromeCard {
                        TextGenerationModelRows()
                    }
                    Text("Used for thread titles, reply predictions, commit messages and other background work.")
                        .font(.ui(.subheadline))
                        .foregroundStyle(Chrome.secondaryText)
                        .padding(.horizontal, 4)
                }
            }

            if !providers.isEmpty {
                ChromeSection(title: "Browse all models") {
                    VStack(alignment: .leading, spacing: Chrome.unitSpacing) {
                        if trimmed.isEmpty {
                            ChromeCard {
                                ChromeRow(
                                    title: "Hide outdated models",
                                    detail: "Show the three newest versions of each model, one row per model instead of one per effort, and the newest Fusion pairings. Chosen and in-use models always show."
                                ) {
                                    SettingsSwitch(isOn: $settings.hidesOutdatedModels)
                                }
                            }
                        }

                        StickySidebarRow(
                            alignment: .modelCardTop,
                            spacing: Chrome.sectionSpacing,
                            sidebarWidth: ModelProviderListColumn.railWidth
                        ) { select in
                            ModelProviderListColumn(providers: providers, selected: selected, pins: pins) { provider in
                                select { catalogueSelection = provider }
                            }
                        } detail: {
                            Group {
                                if let selected {
                                    ProviderModelsSection(
                                        provider: selected,
                                        query: trimmed,
                                        matchingCatalogue: matchingCatalogues[selected],
                                        alignsCardTop: true
                                    )
                                    .id(selected)
                                } else {
                                    // The first section sits outside the lazy stack so its card's
                                    // alignment guide reaches the two-column row.
                                    VStack(alignment: .leading, spacing: Chrome.unitSpacing) {
                                        catalogueSection(providers[0], query: trimmed, matches: matchingCatalogues[providers[0]], alignsCardTop: true)
                                        LazyVStack(alignment: .leading, spacing: Chrome.unitSpacing) {
                                            ForEach(providers.dropFirst()) { provider in
                                                catalogueSection(provider, query: trimmed, matches: matchingCatalogues[provider], alignsCardTop: false)
                                            }
                                        }
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }

            if !trimmed.isEmpty, visiblePins.isEmpty, providers.isEmpty {
                Text(verbatim: String(format: Chrome.localized("No models match “%@”."), trimmed))
                    .font(.ui(size: 13))
                    .foregroundStyle(Chrome.secondaryText)
                    .padding(.horizontal, 4)
            }
            }
            .onChange(of: scrollTargetPin) { _, target in
                guard let target else { return }
                scrollTargetPin = nil
                Task { @MainActor in
                    withAnimation(Chrome.panelSlide) {
                        scrollProxy.scrollTo("model-card/\(target.id)", anchor: .center)
                    }
                }
            }
        }
        .task(id: availableProviders) {
            for provider in availableProviders {
                await model.providers.loadCatalog(provider)
            }
        }
        .onChange(of: searchQuery) { _, _ in
            searchSelectionOverride = nil
            hoveredRailTarget = nil
            hoveredModelCard = nil
        }
        .onChange(of: items) { _, _ in
            let current = allBlocks
            let validUngrouped = !current.ungrouped.isEmpty || current.groups.isEmpty
            let resolved = resolvedSelection(allBlocks: current, showsUngrouped: validUngrouped)
            if resolved == .all, selectedGroupStorage != GroupSelection.all.rawStorageValue {
                selectedGroupStorage = GroupSelection.all.rawStorageValue
            }
            if let override = searchSelectionOverride,
               resolvedSelection(override, allBlocks: current, showsUngrouped: validUngrouped) != override {
                searchSelectionOverride = .all
            }
        }
        .onDisappear {
            highlightTask?.cancel()
            highlightTask = nil
        }
    }

    private func catalogueSection(_ provider: ProviderKind, query: String, matches: [ModelOption]?, alignsCardTop: Bool) -> some View {
        ProviderModelsSection(
            provider: provider,
            query: query,
            matchingCatalogue: matches,
            alignsCardTop: alignsCardTop
        )
    }

    // MARK: - Master-Detail Selection & Rail

    private func resolvedSelection(allBlocks: (ungrouped: [ModelPin], groups: [ModelGroupBlock]), showsUngrouped: Bool) -> GroupSelection {
        switch selectedGroupStorage {
        case GroupSelection.all.rawStorageValue:
            return .all
        case GroupSelection.ungrouped.rawStorageValue:
            return showsUngrouped ? .ungrouped : .all
        default:
            if let id = UUID(uuidString: selectedGroupStorage),
               allBlocks.groups.contains(where: { $0.id == id }) {
                return .group(id)
            }
            return .all
        }
    }

    private func resolvedSelection(
        _ candidate: GroupSelection,
        allBlocks: (ungrouped: [ModelPin], groups: [ModelGroupBlock]),
        showsUngrouped: Bool
    ) -> GroupSelection {
        switch candidate {
        case .all:
            return .all
        case .ungrouped:
            return showsUngrouped ? .ungrouped : .all
        case .group(let id):
            return allBlocks.groups.contains(where: { $0.id == id }) ? .group(id) : .all
        }
    }

    private func selectGroup(_ selection: GroupSelection, isSearching: Bool) {
        if isSearching {
            searchSelectionOverride = selection
        } else {
            selectedGroupStorage = selection.rawStorageValue
        }
    }

    private func jumpToModel(_ pin: ModelPin, in sectionID: UUID?, isSearching: Bool) {
        let target: GroupSelection = sectionID.map { .group($0) } ?? .ungrouped
        selectedGroupStorage = target.rawStorageValue
        if isSearching {
            searchSelectionOverride = target
        }
        highlightedPin = pin
        scrollTargetPin = pin
        highlightTask?.cancel()
        highlightTask = Task {
            try? await Task.sleep(for: .milliseconds(1400))
            guard !Task.isCancelled else { return }
            withAnimation(Chrome.hover) {
                if highlightedPin == pin { highlightedPin = nil }
            }
        }
    }

    private func createAndSelectNewGroup() {
        withAnimation(Chrome.panelSlide) {
            let id = model.settings.addModelSection(named: Chrome.localized("Group"))
            selectedGroupStorage = GroupSelection.group(id).rawStorageValue
            renameRequest = .newGroup(id)
        }
    }

    private func masterGroupRail(
        allBlocks: (ungrouped: [ModelPin], groups: [ModelGroupBlock]),
        filteredBlocks: (ungrouped: [ModelPin], groups: [ModelGroupBlock]),
        allVisiblePins: [ModelPin],
        visiblePins: [ModelPin],
        showsUngrouped: Bool,
        isSearching: Bool,
        activeSelection: GroupSelection
    ) -> some View {
        let settings = model.settings
        let groupIDs = allBlocks.groups.map(\.id)
        let filteredMap = Dictionary(uniqueKeysWithValues: filteredBlocks.groups.map { ($0.id, $0.pins) })
        return VStack(alignment: .leading, spacing: Chrome.unitHeaderSpacing) {
            GroupRailCard(
                title: Chrome.localized("All"),
                count: isSearching ? visiblePins.count : allVisiblePins.count,
                pins: isSearching ? visiblePins : allVisiblePins,
                isSelected: activeSelection == .all,
                isDimmed: isSearching && visiblePins.isEmpty,
                action: { selectGroup(.all, isSearching: isSearching) }
            )

            Divider()
                .padding(.horizontal, 4)

            if showsUngrouped {
                let ungroupedPins = isSearching ? filteredBlocks.ungrouped : allBlocks.ungrouped
                GroupRailCard(
                    title: Chrome.localized("Ungrouped"),
                    count: ungroupedPins.count,
                    pins: ungroupedPins,
                    isSelected: activeSelection == .ungrouped,
                    isDropTarget: hoveredRailTarget == .ungrouped,
                    isDimmed: isSearching && ungroupedPins.isEmpty,
                    action: { selectGroup(.ungrouped, isSearching: isSearching) }
                )
                .onDrop(
                    of: [UTType.plainText],
                    delegate: RailCardDropDelegate(
                        target: .ungrouped,
                        groupOrder: groupIDs,
                        isSearching: isSearching,
                        activeDrag: $activeDrag,
                        hoveredTarget: $hoveredRailTarget,
                        settings: settings
                    )
                )
            }

            ForEach(allBlocks.groups) { block in
                let matchedPins = filteredMap[block.id] ?? []
                let displayPins = isSearching ? matchedPins : block.pins
                let canMoveUp = block.id != allBlocks.groups.first?.id
                let canMoveDown = block.id != allBlocks.groups.last?.id
                GroupRailCard(
                    title: block.section.name,
                    count: displayPins.count,
                    pins: displayPins,
                    isSelected: activeSelection == .group(block.id),
                    isDropTarget: hoveredRailTarget == .group(block.id),
                    isDimmed: isSearching && matchedPins.isEmpty,
                    action: { selectGroup(.group(block.id), isSearching: isSearching) }
                )
                .modifier(GroupRailCardDragModifier(enabled: !isSearching, sectionID: block.id, activeDrag: $activeDrag))
                .onDrop(
                    of: [UTType.plainText],
                    delegate: RailCardDropDelegate(
                        target: .group(block.id),
                        groupOrder: groupIDs,
                        isSearching: isSearching,
                        activeDrag: $activeDrag,
                        hoveredTarget: $hoveredRailTarget,
                        settings: settings
                    )
                )
                .contextMenu {
                    Button("Rename") {
                        selectGroup(.group(block.id), isSearching: isSearching)
                        renameRequest = .existing(block.id)
                    }
                    Button("Move up") {
                        withAnimation(Chrome.panelSlide) { settings.moveModelSection(block.id, by: -1) }
                    }
                    .disabled(!canMoveUp)
                    Button("Move down") {
                        withAnimation(Chrome.panelSlide) { settings.moveModelSection(block.id, by: 1) }
                    }
                    .disabled(!canMoveDown)
                    Divider()
                    Button("Ungroup") {
                        withAnimation(Chrome.panelSlide) { settings.removeModelSection(block.id) }
                    }
                    .help(Text("Models stay in the list."))
                }
            }

            if !isSearching {
                NewGroupRailButton(action: createAndSelectNewGroup)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Model groups"))
    }

    private func modelBlocks(query: String, items: [ModelListItem]? = nil) -> (ungrouped: [ModelPin], groups: [ModelGroupBlock]) {
        let registry = model.providers
        var ungrouped: [ModelPin] = []
        var groups: [ModelGroupBlock] = []
        for item in items ?? model.settings.modelListItems {
            switch item {
            case .section(let section):
                groups.append(ModelGroupBlock(section: section))
            case .pin(let pin):
                guard model.settings.isEnabled(pin.provider),
                      query.isEmpty || Self.matches(registry.model(pin.modelID, for: pin.provider), id: pin.modelID, provider: pin.provider, query: query) else { continue }
                if groups.isEmpty {
                    ungrouped.append(pin)
                } else {
                    groups[groups.count - 1].pins.append(pin)
                }
            }
        }
        return (ungrouped, groups)
    }

    /// Whether a model matches the search by name, description or provider.
    static func matches(_ option: ModelOption?, id: String, provider: ProviderKind, query: String) -> Bool {
        guard !query.isEmpty else { return true }
        let fields = [option?.shortName, option?.name, option?.detail, option?.group, id, provider.displayName]
        return fields.contains { $0?.localizedCaseInsensitiveContains(query) == true }
    }
}

// MARK: - Master-Detail Models & Views

private enum GroupSelection: Equatable {
    case all
    case ungrouped
    case group(UUID)

    var rawStorageValue: String {
        switch self {
        case .all: "all"
        case .ungrouped: "ungrouped"
        case .group(let id): id.uuidString
        }
    }
}

private enum GroupRenameRequest: Equatable {
    case newGroup(UUID)
    case existing(UUID)

    var sectionID: UUID {
        switch self {
        case .newGroup(let id), .existing(let id): id
        }
    }
}

private enum ModelPageDragPayload: Equatable {
    case model(ModelPin, fromSection: UUID?)
    case group(UUID)
}

private enum RailDropTarget: Equatable {
    case ungrouped
    case group(UUID)

    var sectionID: UUID? {
        if case .group(let id) = self { id } else { nil }
    }
}

private struct GroupRailCardDragModifier: ViewModifier {
    let enabled: Bool
    let sectionID: UUID
    @Binding var activeDrag: ModelPageDragPayload?

    func body(content: Content) -> some View {
        if enabled {
            content.onDrag {
                activeDrag = .group(sectionID)
                return NSItemProvider(object: "tivano-group:\(sectionID.uuidString)" as NSString)
            }
        } else {
            content
        }
    }
}

@MainActor
private struct RailCardDropDelegate: DropDelegate {
    let target: RailDropTarget
    let groupOrder: [UUID]
    let isSearching: Bool
    @Binding var activeDrag: ModelPageDragPayload?
    @Binding var hoveredTarget: RailDropTarget?
    let settings: AppSettings

    func validateDrop(info: DropInfo) -> Bool {
        switch activeDrag {
        case .model(_, let fromSection):
            return fromSection != target.sectionID
        case .group(let draggedID):
            guard !isSearching, case .group(let targetID) = target else { return false }
            return draggedID != targetID
        case nil:
            return false
        }
    }

    func dropEntered(info: DropInfo) {
        guard validateDrop(info: info) else { return }
        if hoveredTarget != target {
            hoveredTarget = target
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
    }

    func dropExited(info: DropInfo) {
        if hoveredTarget == target {
            hoveredTarget = nil
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: validateDrop(info: info) ? .move : .cancel)
    }

    func performDrop(info: DropInfo) -> Bool {
        defer {
            hoveredTarget = nil
            activeDrag = nil
        }
        guard validateDrop(info: info) else { return false }
        switch activeDrag {
        case .model(let pin, _):
            withAnimation(Chrome.panelSlide) {
                settings.moveModel(pin, toSection: target.sectionID)
            }
            return true
        case .group(let draggedID):
            guard case .group(let targetID) = target,
                  let fromIndex = groupOrder.firstIndex(of: draggedID),
                  let toIndex = groupOrder.firstIndex(of: targetID),
                  fromIndex != toIndex else { return false }
            let step = fromIndex < toIndex ? 1 : -1
            withAnimation(Chrome.panelSlide) {
                for _ in 0..<abs(toIndex - fromIndex) {
                    settings.moveModelSection(draggedID, by: step)
                }
            }
            return true
        case nil:
            return false
        }
    }
}

@MainActor
private struct ModelCardReorderDropDelegate: DropDelegate {
    let targetPin: ModelPin
    let sectionID: UUID?
    let groupPins: [ModelPin]
    let isSearching: Bool
    @Binding var activeDrag: ModelPageDragPayload?
    @Binding var hoveredPin: ModelPin?
    let settings: AppSettings

    func validateDrop(info: DropInfo) -> Bool {
        guard !isSearching,
              case .model(let draggedPin, let fromSection) = activeDrag else { return false }
        return fromSection == sectionID && draggedPin != targetPin
    }

    func dropEntered(info: DropInfo) {
        guard validateDrop(info: info) else { return }
        if hoveredPin != targetPin {
            hoveredPin = targetPin
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
    }

    func dropExited(info: DropInfo) {
        if hoveredPin == targetPin {
            hoveredPin = nil
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: validateDrop(info: info) ? .move : .cancel)
    }

    func performDrop(info: DropInfo) -> Bool {
        defer {
            hoveredPin = nil
            activeDrag = nil
        }
        guard validateDrop(info: info),
              case .model(let draggedPin, _) = activeDrag,
              let fromIndex = groupPins.firstIndex(of: draggedPin),
              let toIndex = groupPins.firstIndex(of: targetPin),
              fromIndex != toIndex else { return false }
        withAnimation(Chrome.panelSlide) {
            settings.moveModel(draggedPin, to: targetPin, placeAfter: fromIndex < toIndex)
        }
        return true
    }
}

private struct ModelGroupBlock: Identifiable {
    let section: ModelSection
    var pins: [ModelPin] = []
    var id: UUID { section.id }
}

private struct GroupRailCard: View {
    let title: String
    let count: Int
    let pins: [ModelPin]
    let isSelected: Bool
    var isDropTarget = false
    var isDimmed = false
    let action: () -> Void

    @State private var isHovering = false

    private var distinctProviders: [ProviderKind] {
        var seen: Set<ProviderKind> = []
        var list: [ProviderKind] = []
        for pin in pins where seen.insert(pin.provider).inserted {
            list.append(pin.provider)
        }
        return list
    }

    private var providerSummary: String {
        let providers = distinctProviders
        guard !providers.isEmpty else { return Chrome.localized("Empty") }
        let lead = providers.prefix(2).map(\.displayName).joined(separator: " · ")
        return providers.count > 2 ? "\(lead) +\(providers.count - 2)" : lead
    }

    private var fill: Color {
        if isDropTarget { return Chrome.accent.opacity(0.22) }
        if isSelected { return Chrome.accent.opacity(0.14) }
        if isHovering { return Chrome.overlay(0.07) }
        return Chrome.overlay(0.035)
    }

    private var strokeColor: Color {
        if isDropTarget { return Chrome.accent }
        if isSelected { return Chrome.accent.opacity(0.5) }
        if isHovering { return Chrome.overlay(0.12) }
        return Chrome.overlay(0.06)
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Chrome.trayCornerRadius, style: .continuous)
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(verbatim: title)
                        .font(.ui(.body, weight: isSelected ? .semibold : .medium))
                        .foregroundStyle(Chrome.primaryText)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    Text(verbatim: "\(count)")
                        .font(.ui(size: 11).monospacedDigit())
                        .foregroundStyle(Chrome.secondaryText)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Chrome.overlay(0.06), in: Capsule(style: .continuous))
                        .fixedSize()
                }

                Text(verbatim: providerSummary)
                    .font(.ui(size: 11))
                    .foregroundStyle(Chrome.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.horizontal, Chrome.listInset)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .opacity(isDimmed && !isSelected ? 0.55 : 1)
        .background(shape.fill(fill))
        .overlay {
            shape
                .strokeBorder(strokeColor, lineWidth: isSelected || isDropTarget ? 1.5 : 0.5)
                .allowsHitTesting(false)
        }
        .animation(Chrome.hover, value: isSelected)
        .animation(Chrome.hover, value: isDropTarget)
        .animation(Chrome.hover, value: isHovering)
        .onHover { hovering in
            guard isHovering != hovering else { return }
            isHovering = hovering
        }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct NewGroupRailButton: View {
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Chrome.trayCornerRadius, style: .continuous)
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "plus")
                    .font(Chrome.inlineIconFont)
                Text("New group")
                    .font(.ui(.callout, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(isHovering ? Chrome.primaryText : Chrome.secondaryText)
            .frame(maxWidth: .infinity)
            .frame(height: Chrome.capsuleHeight)
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .background(shape.fill(Chrome.overlay(isHovering ? 0.06 : 0.025)))
        .overlay {
            shape
                .strokeBorder(
                    isHovering ? Chrome.accent.opacity(0.45) : Chrome.overlay(0.14),
                    style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                )
                .allowsHitTesting(false)
        }
        .onHover { hovering in
            guard isHovering != hovering else { return }
            withAnimation(Chrome.hover) { isHovering = hovering }
        }
    }
}

private struct ModelGroupDetailCard: View {
    @Environment(AppModel.self) private var model
    let selection: GroupSelection
    let allBlocks: (ungrouped: [ModelPin], groups: [ModelGroupBlock])
    let filteredBlocks: (ungrouped: [ModelPin], groups: [ModelGroupBlock])
    let allSections: [ModelSection]
    let totalPinnedCount: Int
    let allVisiblePins: [ModelPin]
    let visiblePins: [ModelPin]
    let isSearching: Bool
    let highlightedPin: ModelPin?
    @Binding var renameRequest: GroupRenameRequest?
    @Binding var activeDrag: ModelPageDragPayload?
    @Binding var hoveredModelCard: ModelPin?
    let onSelectGroup: (GroupSelection) -> Void
    let onJumpToModel: (ModelPin, UUID?) -> Void

    @State private var showsHeaderAddPopover = false
    @State private var showsEmptyAddPopover = false
    @State private var draftName = ""
    @State private var editingSectionID: UUID?
    @State private var isHoveringHeader = false
    @FocusState private var nameFieldFocused: Bool

    private static let gridColumns = [
        GridItem(.flexible(minimum: 0), spacing: Chrome.pageSectionHeaderSpacing, alignment: .top),
        GridItem(.flexible(minimum: 0), spacing: Chrome.pageSectionHeaderSpacing, alignment: .top),
    ]

    private var activeSection: ModelSection? {
        guard case .group(let id) = selection else { return nil }
        return allSections.first { $0.id == id }
    }

    private var activeGroupPins: [ModelPin] {
        let source = isSearching ? filteredBlocks : allBlocks
        switch selection {
        case .all:
            return isSearching ? visiblePins : allVisiblePins
        case .ungrouped:
            return source.ungrouped
        case .group(let id):
            return source.groups.first { $0.id == id }?.pins ?? []
        }
    }

    private var headerTitle: String {
        switch selection {
        case .all: Chrome.localized("All")
        case .ungrouped: Chrome.localized("Ungrouped")
        case .group: activeSection?.name ?? Chrome.localized("Group")
        }
    }

    private var headerSubtitle: String {
        let countText = String(format: Chrome.localized("%lld models"), activeGroupPins.count)
        if isSearching {
            return countText
        }
        switch selection {
        case .all:
            return "\(countText) · \(Chrome.localized("Click a model to jump to its group"))"
        case .ungrouped, .group:
            return "\(countText) · \(Chrome.localized("Effort and fast mode apply immediately"))"
        }
    }

    var body: some View {
        ChromeCard {
            detailHeader
            ChromeRowDivider()
            detailBody
                .padding(Chrome.contentHorizontalPadding)
            Spacer(minLength: 0)
        }
        .onAppear { applyPendingRename() }
        .onChange(of: renameRequest) { _, _ in applyPendingRename() }
        .onChange(of: selection) { _, _ in
            if let editingSectionID, activeSection?.id != editingSectionID {
                commitRename()
            }
            showsHeaderAddPopover = false
            showsEmptyAddPopover = false
            applyPendingRename()
        }
    }

    private var detailHeader: some View {
        let settings = model.settings
        let section = activeSection
        let canMoveUp = section.map { $0.id != allSections.first?.id } ?? false
        let canMoveDown = section.map { $0.id != allSections.last?.id } ?? false
        return HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if let section, editingSectionID == section.id {
                        TextField("New group", text: $draftName)
                            .textFieldStyle(.plain)
                            .font(.ui(.title3, weight: .semibold))
                            .foregroundStyle(Chrome.primaryText)
                            .focused($nameFieldFocused)
                            .onAppear { nameFieldFocused = true }
                            .onSubmit { commitRename() }
                            .onChange(of: nameFieldFocused) { _, focused in
                                if !focused { commitRename() }
                            }
                            .accessibilityLabel(Text("Group name"))
                    } else if let section {
                        Text(verbatim: section.name)
                            .font(.ui(.title3, weight: .semibold))
                            .foregroundStyle(Chrome.primaryText)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .onTapGesture(count: 2) {
                                beginEditing(section, clearDraft: false)
                            }
                            .accessibilityAddTraits(.isHeader)
                        HStack(spacing: 2) {
                            RowControl(symbol: "pencil", help: "Rename group", isEnabled: true) {
                                beginEditing(section, clearDraft: false)
                            }
                            RowControl(symbol: "trash", help: "Ungroup. Models stay in the list.", isEnabled: true) {
                                withAnimation(Chrome.panelSlide) {
                                    settings.removeModelSection(section.id)
                                }
                            }
                        }
                        .opacity(isHoveringHeader ? 1 : 0)
                        .allowsHitTesting(isHoveringHeader)
                    } else {
                        Text(verbatim: headerTitle)
                            .font(.ui(.title3, weight: .semibold))
                            .foregroundStyle(Chrome.primaryText)
                            .lineLimit(1)
                            .accessibilityAddTraits(.isHeader)
                    }
                }
                Text(verbatim: headerSubtitle)
                    .font(.ui(.subheadline))
                    .foregroundStyle(Chrome.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 8)

            ChromeTextButton(
                symbol: "plus",
                title: "Add a model",
                help: "Add a model"
            ) {
                showsHeaderAddPopover = true
            }
            .popover(isPresented: $showsHeaderAddPopover, arrowEdge: .bottom) {
                ModelAddPopover(sectionID: section?.id, sectionName: section?.name)
            }
        }
        .padding(.leading, Chrome.contentHorizontalPadding)
        .padding(.trailing, Chrome.contentHorizontalPadding)
        .padding(.vertical, 12)
        .contentShape(.rect)
        .onHover { isHoveringHeader = $0 }
        .contextMenu {
            if let section {
                Button("Rename") { beginEditing(section, clearDraft: false) }
                Button("Move up") {
                    withAnimation(Chrome.panelSlide) { settings.moveModelSection(section.id, by: -1) }
                }
                .disabled(!canMoveUp)
                Button("Move down") {
                    withAnimation(Chrome.panelSlide) { settings.moveModelSection(section.id, by: 1) }
                }
                .disabled(!canMoveDown)
                Divider()
                Button("Ungroup") {
                    withAnimation(Chrome.panelSlide) { settings.removeModelSection(section.id) }
                }
                .help(Text("Models stay in the list."))
            }
        }
    }

    @ViewBuilder
    private var detailBody: some View {
        switch selection {
        case .all:
            let blocks = isSearching ? filteredBlocks : allBlocks
            if totalPinnedCount == 0 {
                emptyPane(
                    title: Chrome.localized("No models chosen yet"),
                    detail: Chrome.localized("Until you add some below, the picker shows every model from your providers."),
                    showsAddButton: true
                )
            } else if !isSearching, allVisiblePins.isEmpty {
                emptyPane(
                    title: Chrome.localized("No models from active providers"),
                    detail: Chrome.localized("Enable a provider to restore its chosen models, or add models below."),
                    showsAddButton: true
                )
            } else if activeGroupPins.isEmpty {
                emptyPane(
                    title: Chrome.localized("No matching models"),
                    detail: nil,
                    showsAddButton: false
                )
            } else {
                AllModelsAvatarWall(
                    blocks: blocks,
                    allSections: allSections,
                    onSelectGroup: onSelectGroup,
                    onJumpToModel: onJumpToModel
                )
            }

        case .ungrouped, .group:
            let pins = activeGroupPins
            if pins.isEmpty {
                if isSearching {
                    emptyPane(
                        title: Chrome.localized("No matching models"),
                        detail: nil,
                        showsAddButton: false
                    )
                } else {
                    emptyPane(
                        title: Chrome.localized("No models in this group"),
                        detail: nil,
                        showsAddButton: true
                    )
                }
            } else {
                let settings = model.settings
                let currentSectionID = activeSection?.id
                LazyVGrid(columns: Self.gridColumns, alignment: .leading, spacing: Chrome.pageSectionHeaderSpacing) {
                    ForEach(pins, id: \.self) { pin in
                        ModelDetailCard(
                            pin: pin,
                            sectionID: currentSectionID,
                            sections: allSections,
                            isHighlighted: highlightedPin == pin,
                            isDropTarget: hoveredModelCard == pin
                        )
                        .id("model-card/\(pin.id)")
                        .onDrag {
                            activeDrag = .model(pin, fromSection: currentSectionID)
                            return NSItemProvider(object: "tivano-pin:\(pin.id)" as NSString)
                        }
                        .onDrop(
                            of: [UTType.plainText],
                            delegate: ModelCardReorderDropDelegate(
                                targetPin: pin,
                                sectionID: currentSectionID,
                                groupPins: pins,
                                isSearching: isSearching,
                                activeDrag: $activeDrag,
                                hoveredPin: $hoveredModelCard,
                                settings: settings
                            )
                        )
                    }
                }
            }
        }
    }

    private func emptyPane(title: String, detail: String?, showsAddButton: Bool) -> some View {
        let section = activeSection
        return VStack(spacing: 10) {
            Text(verbatim: title)
                .font(.ui(.body, weight: .medium))
                .foregroundStyle(Chrome.primaryText)
                .multilineTextAlignment(.center)
            if let detail, !detail.isEmpty {
                Text(verbatim: detail)
                    .font(.ui(.subheadline))
                    .foregroundStyle(Chrome.secondaryText)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if showsAddButton {
                ChromeTextButton(
                    symbol: "plus",
                    title: "Add a model",
                    help: "Add a model"
                ) {
                    showsEmptyAddPopover = true
                }
                .padding(.top, 2)
                .popover(isPresented: $showsEmptyAddPopover, arrowEdge: .bottom) {
                    ModelAddPopover(sectionID: section?.id, sectionName: section?.name)
                }
            }
        }
        .padding(.vertical, 24)
        .padding(.horizontal, Chrome.contentHorizontalPadding)
        .frame(maxWidth: .infinity)
    }

    private func beginEditing(_ section: ModelSection, clearDraft: Bool) {
        draftName = clearDraft ? "" : section.name
        editingSectionID = section.id
        nameFieldFocused = true
    }

    private func applyPendingRename() {
        guard let request = renameRequest,
              let section = activeSection,
              request.sectionID == section.id else { return }
        switch request {
        case .newGroup:
            beginEditing(section, clearDraft: true)
        case .existing:
            beginEditing(section, clearDraft: false)
        }
        renameRequest = nil
    }

    private func commitRename() {
        guard let id = editingSectionID else { return }
        let currentName = allSections.first { $0.id == id }?.name ?? ""
        let trimmed = draftName.trimmed
        if !trimmed.isEmpty, trimmed != currentName {
            model.settings.renameModelSection(id, to: trimmed)
        }
        editingSectionID = nil
        nameFieldFocused = false
    }
}

private struct ModelDetailCard: View {
    @Environment(AppModel.self) private var model
    let pin: ModelPin
    let sectionID: UUID?
    let sections: [ModelSection]
    var isHighlighted = false
    var isDropTarget = false

    @State private var isHovering = false
    @State private var isHoveringRemove = false

    private var fill: Color {
        if isDropTarget { return Chrome.accent.opacity(0.18) }
        if isHighlighted { return Chrome.accent.opacity(0.12) }
        if isHovering { return Chrome.overlay(0.065) }
        return Chrome.overlay(0.04)
    }

    private var strokeColor: Color {
        if isDropTarget || isHighlighted { return Chrome.accent }
        if isHovering { return Chrome.overlay(0.13) }
        return Chrome.overlay(0.07)
    }

    var body: some View {
        let settings = model.settings
        let option = model.providers.model(pin.modelID, for: pin.provider)
        let preference = settings.preference(for: pin.provider, model: pin.modelID)
        let displayName = option.map { $0.label(among: model.pinnedOptions(for: pin.provider)) } ?? pin.displayName
        let efforts = option?.efforts ?? []
        let supportsFast = option?.supportsFast ?? false
        let shape = RoundedRectangle(cornerRadius: Chrome.trayCornerRadius, style: .continuous)

        VStack(alignment: .leading, spacing: Chrome.sectionHeaderSpacing) {
            HStack(alignment: .center, spacing: 10) {
                ProviderIcon(provider: pin.provider, size: 18)
                    .frame(width: 28, height: 28)
                    .background(Chrome.overlay(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: displayName)
                        .font(.ui(.body, weight: .semibold))
                        .foregroundStyle(Chrome.primaryText)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(verbatim: pin.provider.displayName)
                        .font(.ui(size: 11))
                        .foregroundStyle(Chrome.secondaryText)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                Button {
                    withAnimation(Chrome.panelSlide) {
                        settings.removeFromModelList(pin)
                    }
                } label: {
                    Image(systemName: "xmark")
                        .font(.ui(size: 10, weight: .semibold))
                        .foregroundStyle(isHoveringRemove ? Chrome.danger : Chrome.secondaryText)
                        .frame(width: 22, height: 22)
                        .background {
                            if isHoveringRemove {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(Chrome.danger.opacity(0.14))
                            }
                        }
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .opacity(isHovering || isHoveringRemove ? 1 : 0.4)
                .onHover { isHoveringRemove = $0 }
                .help(Text(verbatim: Chrome.localized("Remove from the picker")))
                .accessibilityLabel(Text(verbatim: Chrome.localized("Remove from the picker")))
            }

            HStack(spacing: 6) {
                if let option, !efforts.isEmpty {
                    let currentEffort = ModelAddPopover.resolvedEffort(for: option, preference: preference)
                    let effortBinding = Binding<String>(
                        get: { currentEffort },
                        set: { selectedEffort in
                            var updated = settings.preference(for: pin.provider, model: pin.modelID)
                            updated.effort = selectedEffort
                            settings.setPreference(updated, for: pin.provider, model: pin.modelID)
                        }
                    )
                    let effortOptions = efforts.map { (value: $0, title: ModelOption.effortTitle($0)) }
                    ViewThatFits(in: .horizontal) {
                        ChromeSegmentedPicker(options: effortOptions, selection: effortBinding)
                        GlassPickerButton(options: effortOptions, selection: effortBinding)
                    }
                } else {
                    Text("Default")
                        .font(.ui(.subheadline))
                        .foregroundStyle(Chrome.secondaryText)
                        .frame(height: Chrome.capsuleContentHeight, alignment: .leading)
                }

                Spacer(minLength: 0)

                if supportsFast {
                    ModelCardFastButton(
                        isOn: Binding(
                            get: { settings.preference(for: pin.provider, model: pin.modelID).fastMode },
                            set: { isOn in
                                var updated = settings.preference(for: pin.provider, model: pin.modelID)
                                updated.fastMode = isOn
                                settings.setPreference(updated, for: pin.provider, model: pin.modelID)
                            }
                        )
                    )
                }
            }
        }
        .padding(Chrome.pageSectionHeaderSpacing)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(shape.fill(fill))
        .overlay {
            shape
                .strokeBorder(strokeColor, lineWidth: isHighlighted || isDropTarget ? 1.5 : 0.5)
                .allowsHitTesting(false)
        }
        .animation(Chrome.hover, value: isHovering)
        .animation(Chrome.hover, value: isHighlighted)
        .animation(Chrome.hover, value: isDropTarget)
        .onHover { hovering in
            guard isHovering != hovering else { return }
            isHovering = hovering
        }
        .contextMenu {
            modelContextMenu(pin: pin, sectionID: sectionID, sections: sections, settings: settings)
        }
    }
}

private struct ModelCardFastButton: View {
    @Binding var isOn: Bool
    @State private var isHovering = false

    var body: some View {
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                isOn.toggle()
            }
        } label: {
            Image(systemName: isOn ? "bolt.fill" : "bolt")
                .font(.ui(.callout, weight: .semibold))
                .foregroundStyle(isOn ? EffortPalette.fast : Chrome.secondaryText)
                .symbolEffect(.bounce, value: isOn)
                .frame(width: Chrome.capsuleContentHeight, height: Chrome.capsuleContentHeight)
                .background {
                    Circle()
                        .fill(isOn ? EffortPalette.fast.opacity(0.18) : Chrome.overlay(isHovering ? 0.1 : 0.06))
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(Text(verbatim: isOn ? Chrome.localized("Fast mode is on") : Chrome.localized("Fast mode")))
        .accessibilityLabel(Text("Fast mode"))
        .accessibilityValue(Text(verbatim: isOn ? Chrome.localized("On") : Chrome.localized("Off")))
    }
}

private struct AllModelsAvatarWall: View {
    let blocks: (ungrouped: [ModelPin], groups: [ModelGroupBlock])
    let allSections: [ModelSection]
    let onSelectGroup: (GroupSelection) -> Void
    let onJumpToModel: (ModelPin, UUID?) -> Void

    private struct WallGroup: Identifiable {
        let id: String
        let title: String
        let selection: GroupSelection
        let sectionID: UUID?
        let pins: [ModelPin]
    }

    private var wallGroups: [WallGroup] {
        var result: [WallGroup] = []
        if !blocks.ungrouped.isEmpty {
            result.append(WallGroup(
                id: "ungrouped",
                title: Chrome.localized("Ungrouped"),
                selection: .ungrouped,
                sectionID: nil,
                pins: blocks.ungrouped
            ))
        }
        for block in blocks.groups where !block.pins.isEmpty {
            result.append(WallGroup(
                id: block.id.uuidString,
                title: block.section.name,
                selection: .group(block.id),
                sectionID: block.id,
                pins: block.pins
            ))
        }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Chrome.contentHorizontalPadding) {
            ForEach(wallGroups) { group in
                VStack(alignment: .leading, spacing: Chrome.unitHeaderSpacing) {
                    AvatarWallGroupHeader(title: group.title, count: group.pins.count) {
                        onSelectGroup(group.selection)
                    }
                    AvatarFlowLayout(spacing: 6) {
                        ForEach(group.pins, id: \.self) { pin in
                            AvatarModelChip(
                                pin: pin,
                                sectionID: group.sectionID,
                                sections: allSections
                            ) {
                                onJumpToModel(pin, group.sectionID)
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct AvatarWallGroupHeader: View {
    let title: String
    let count: Int
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(verbatim: title)
                    .font(.ui(.subheadline, weight: .semibold))
                    .foregroundStyle(isHovering ? Chrome.primaryText : Chrome.secondaryText)
                    .lineLimit(1)
                Text(verbatim: "\(count)")
                    .font(.ui(size: 11).monospacedDigit())
                    .foregroundStyle(Chrome.secondaryText.opacity(0.8))
                Image(systemName: "chevron.right")
                    .font(Chrome.chevronFont)
                    .foregroundStyle(Chrome.secondaryText)
                    .opacity(isHovering ? 1 : 0)
            }
            .contentShape(.rect)
        }
        .buttonStyle(ChromeQuietButtonStyle())
        .onHover { hovering in
            guard isHovering != hovering else { return }
            withAnimation(Chrome.hover) { isHovering = hovering }
        }
    }
}

private struct AvatarModelChip: View {
    @Environment(AppModel.self) private var model
    let pin: ModelPin
    let sectionID: UUID?
    let sections: [ModelSection]
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        let settings = model.settings
        let option = model.providers.model(pin.modelID, for: pin.provider)
        let preference = settings.preference(for: pin.provider, model: pin.modelID)
        let displayName = option.map { $0.label(among: model.pinnedOptions(for: pin.provider)) } ?? pin.displayName
        let showsFast = preference.fastMode && option?.supportsFast == true
        let shape = Capsule(style: .continuous)

        Button(action: action) {
            HStack(spacing: 6) {
                ProviderIcon(provider: pin.provider, size: 14)
                Text(verbatim: displayName)
                    .font(.ui(.callout, weight: .medium))
                    .foregroundStyle(Chrome.primaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 160, alignment: .leading)
                if showsFast {
                    Image(systemName: "bolt.fill")
                        .font(.ui(size: 10, weight: .semibold))
                        .foregroundStyle(EffortPalette.fast)
                }
            }
            .padding(.leading, 8)
            .padding(.trailing, 10)
            .frame(height: Chrome.rowHeight)
            .background(shape.fill(Chrome.overlay(isHovering ? 0.09 : 0.05)))
            .overlay {
                shape
                    .strokeBorder(isHovering ? Chrome.accent.opacity(0.4) : Chrome.overlay(0.08), lineWidth: 0.5)
                    .allowsHitTesting(false)
            }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            guard isHovering != hovering else { return }
            withAnimation(Chrome.hover) { isHovering = hovering }
        }
        .help(Text(verbatim: "\(displayName) · \(pin.provider.displayName)"))
        .contextMenu {
            modelContextMenu(pin: pin, sectionID: sectionID, sections: sections, settings: settings)
        }
    }
}

@MainActor
@ViewBuilder
private func modelContextMenu(
    pin: ModelPin,
    sectionID: UUID?,
    sections: [ModelSection],
    settings: AppSettings
) -> some View {
    let otherSections = sections.filter { $0.id != sectionID }
    if sectionID != nil || !otherSections.isEmpty {
        Menu("Move to group") {
            if sectionID != nil {
                Button("No group") {
                    withAnimation(Chrome.panelSlide) { settings.moveModel(pin, toSection: nil) }
                }
            }
            ForEach(otherSections) { section in
                Button {
                    withAnimation(Chrome.panelSlide) { settings.moveModel(pin, toSection: section.id) }
                } label: {
                    Text(verbatim: section.name)
                }
            }
        }
        Divider()
    }
    Button("Remove from the picker") {
        withAnimation(Chrome.panelSlide) { settings.removeFromModelList(pin) }
    }
}

private struct AvatarFlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            maxX = max(maxX, x - spacing)
        }
        return CGSize(width: proposal.width ?? maxX, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x: CGFloat = bounds.minX, y: CGFloat = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
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

private extension VerticalAlignment {
    enum ModelCardTop: AlignmentID {
        static func defaultValue(in context: ViewDimensions) -> CGFloat { context[.top] }
    }

    static let modelCardTop = VerticalAlignment(ModelCardTop.self)
}

private struct ModelCardTopAlignment: ViewModifier {
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            content.alignmentGuide(.modelCardTop) { $0[.top] }
        } else {
            content
        }
    }
}

private struct ModelProviderListColumn: View {
    static let railWidth: CGFloat = SettingsIconRail.railWidth

    let providers: [ProviderKind]
    let selected: ProviderKind?
    let pins: [ModelPin]
    let select: (ProviderKind?) -> Void

    var body: some View {
        let allRow = SettingsIconRailRow(
            id: "all",
            title: "All models",
            titleIsVerbatim: false,
            railHelp: label(Chrome.localized("All models"), count: pins.count),
            isSelected: selected == nil,
            action: { select(nil) }
        ) {
            SidebarSymbol("square.grid.2x2")
                .foregroundStyle(Chrome.primaryText.opacity(selected == nil ? 1 : 0.92))
        }
        var sections = [SettingsIconRailSection(id: "all", rows: [allRow])]
        if !providers.isEmpty {
            sections.append(SettingsIconRailSection(id: "providers", rows: providers.map(row)))
        }
        return SettingsIconRail(sections: sections)
            .alignmentGuide(.modelCardTop) { $0[.top] }
    }

    private func row(_ provider: ProviderKind) -> SettingsIconRailRow {
        let count = pins.filter { $0.provider == provider }.count
        return SettingsIconRailRow(
            id: provider.id,
            title: provider.displayName,
            titleIsVerbatim: true,
            railHelp: label(provider.displayName, count: count),
            accessoryWidth: count > 0 ? 22 : 0,
            isSelected: selected == provider,
            action: { select(provider) }
        ) {
            ProviderIcon(provider: provider, size: Chrome.symbolSize)
        } accessory: {
            if count > 0 {
                Text(verbatim: "\(count)")
                    .font(.ui(size: 11).monospacedDigit())
                    .foregroundStyle(Chrome.secondaryText)
                    .padding(.trailing, 2)
            }
        }
    }

    private func label(_ title: String, count: Int) -> String {
        guard count > 0 else { return title }
        if count == 1 {
            return String(format: Chrome.localized("%@ · 1 model"), title)
        }
        return String(format: Chrome.localized("%@ · %lld models"), title, Int64(count))
    }
}

private struct ProviderModelsSection: View {
    @Environment(AppModel.self) private var model
    let provider: ProviderKind
    var query = ""
    var matchingCatalogue: [ModelOption]?
    var alignsCardTop = false

    /// The lines showing their earlier versions, and whether the free and preview models show.
    @State private var openLineages: Set<String> = []
    @State private var showsTrials = false
    @State private var showsFusion = false
    @State private var lineages = LineageCache()

    /// A catalogue longer than this folds each line to its newest version and sets the
    /// free and preview models aside; a shorter one reads at a glance as it is.
    private static let foldingThreshold = 12

    private enum Row: Identifiable {
        /// A model; `earlier` counts the versions folded under it, `lineage` names its line.
        case model(ModelOption, earlier: Int = 0, lineage: String? = nil)
        case trials(count: Int)
        case fusion(count: Int)
        /// The route the models below it are reached through (see `ModelOption.group`).
        case group(String)

        var id: String {
            switch self {
            case .group(let name): "group/" + name
            case .model(let option, _, _): "model/" + option.id
            case .trials: "trials"
            case .fusion: "fusion"
            }
        }
    }

    var body: some View {
        let settings = model.settings
        let registry = model.providers
        let fullCatalogue = matchingCatalogue ?? registry.sortedModels(for: provider)
        let isFiltering = !query.isEmpty
        // The simplified catalogue drops clearly outdated versions; search always lists the full one.
        let catalogue = isFiltering || !settings.hidesOutdatedModels ? fullCatalogue : model.pickerModels(for: provider)
        let modelList = settings.modelList
        let isFull = modelList.count >= AppSettings.modelListLimit
        let pinned = Set(modelList)
        let rows = rows(catalogue, pinned: pinned, isFiltering: isFiltering)
        // Lazy, so only the rows on screen are built. Same fill and shape as ChromeCard.
        LazyVStack(spacing: 0) {
            HStack(spacing: 12) {
                ProviderIcon(provider: provider, size: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: provider.displayName)
                        .font(.ui(.title3, weight: .semibold))
                        .foregroundStyle(Chrome.primaryText)
                        .accessibilityAddTraits(.isHeader)
                    if !provider.routeSummary.isEmpty {
                        Text(verbatim: provider.routeSummary)
                            .font(.ui(.subheadline))
                            .foregroundStyle(Chrome.secondaryText)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            ChromeRowDivider()
            if fullCatalogue.isEmpty {
                ChromeRow(title: registry.loadingCatalogs.contains(provider) ? "Loading models…" : "No models loaded") {
                    Button("Load models") {
                        Task { await registry.loadCatalog(provider, force: true) }
                    }
                    .chromeGlassButtonStyle()
                    .disabled(registry.loadingCatalogs.contains(provider))
                }
            } else {
                // Only visible rows are built: catalogues run to hundreds of models, and
                // mounting every hidden one (each with its own tooltip tracking area)
                // made the page re-measure them all on every hover, keystroke and resize.
                ForEach(rows) { row in
                    if row.id != rows.first?.id, !isGroupHeading(row) {
                        ChromeRowDivider()
                    }
                    switch row {
                    case .group(let name):
                        Text(verbatim: name)
                            .font(.ui(.subheadline, weight: .semibold))
                            .foregroundStyle(Chrome.secondaryText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                            .padding(.top, row.id == rows.first?.id ? 12 : 16)
                            .padding(.bottom, 2)
                            .accessibilityAddTraits(.isHeader)
                    case .model(let option, let earlier, let lineage):
                        modelRow(option, earlier: earlier, lineage: lineage, pinned: pinned, isFull: isFull, isFiltering: isFiltering)
                    case .trials(let count):
                        ChromeRow(title: "Free and preview models", detail: String(format: Chrome.localized("%lld models"), count)) {
                            disclosure(isOpen: showsTrials, label: nil, show: "Show free and preview models", hide: "Hide free and preview models") {
                                showsTrials.toggle()
                            }
                        }
                    case .fusion(let count):
                        ChromeRow(title: "Fusion pairings", detail: String(format: Chrome.localized("%lld pairings"), count)) {
                            disclosure(isOpen: showsFusion, label: nil, show: "Show Fusion pairings", hide: "Hide Fusion pairings") {
                                showsFusion.toggle()
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
        // Search re-filters instantly, typing and clearing alike.
        .animation(nil, value: query)
        .modifier(ModelCardTopAlignment(enabled: alignsCardTop))
        .task { await registry.loadCatalog(provider) }
    }

    /// Search shows only matches and collapsed only the chosen models, all in catalogue
    /// order. Expanded shows everything; a long catalogue (see `foldingThreshold`) shows
    /// each line's newest version with the earlier ones folded under it, and the free
    /// and preview models as one row. A chosen model always shows.
    private func isGroupHeading(_ row: Row) -> Bool {
        if case .group = row { return true }
        return false
    }

    /// The rows, with a heading over each route's models when the provider lists one model
    /// per route; the routes keep the order the provider gave them.
    private func rows(_ catalogue: [ModelOption], pinned: Set<ModelPin>, isFiltering: Bool) -> [Row] {
        // Headings only where the provider lists models on more than one route.
        guard Set(catalogue.compactMap(\.group)).count > 1 else {
            return ungroupedRows(catalogue, pinned: pinned, isFiltering: isFiltering)
        }
        var order: [String] = []
        for option in model.providers.models(for: provider) {
            if let group = option.group, !order.contains(group) { order.append(group) }
        }
        let rank = { (option: ModelOption) in option.group.flatMap { order.firstIndex(of: $0) } ?? order.count }
        let sorted = catalogue.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map(\.element)
        var out: [Row] = []
        var current: String?
        for row in ungroupedRows(sorted, pinned: pinned, isFiltering: isFiltering) {
            if case .model(let option, _, _) = row, let group = option.group, group != current {
                out.append(.group(group))
                current = group
            }
            out.append(row)
        }
        return out
    }

    private func ungroupedRows(_ catalogue: [ModelOption], pinned: Set<ModelPin>, isFiltering: Bool) -> [Row] {
        let isPinned = { (option: ModelOption) in pinned.contains(ModelPin(provider: provider, modelID: option.id)) }
        if isFiltering {
            return catalogue.map { .model($0) }
        }
        guard catalogue.count > Self.foldingThreshold else { return catalogue.map { .model($0) } }
        // Fusion pairings fold into one row of their own; a pinned one stays a normal row.
        let fusion = catalogue.filter { Self.isFusion($0) && !isPinned($0) }
        let layout = lineages.layout(of: catalogue.filter { !Self.isFusion($0) || isPinned($0) })
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
        if !fusion.isEmpty {
            rows.append(.fusion(count: fusion.count))
            if showsFusion {
                // Grouped by lead model, leads sorted, catalogue order within each lead.
                var order: [String] = []
                var grouped: [String: [ModelOption]] = [:]
                for option in fusion {
                    let lead = Self.fusionLead(of: option.name)
                    if grouped[lead] == nil { order.append(lead) }
                    grouped[lead, default: []].append(option)
                }
                for lead in order.sorted() {
                    rows += (grouped[lead] ?? []).map { .model($0) }
                }
            }
        }
        return rows
    }

    private static func isFusion(_ option: ModelOption) -> Bool {
        option.name.hasPrefix("Fusion (")
    }

    /// The lead model of a "Fusion (Lead + Head)" pairing: the text before " + ".
    private static func fusionLead(of name: String) -> String {
        guard let open = name.range(of: "Fusion ("),
              let plus = name.range(of: " + ", range: open.upperBound..<name.endIndex) else { return name }
        return String(name[open.upperBound..<plus.lowerBound])
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
