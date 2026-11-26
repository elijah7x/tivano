import SwiftUI

/// Popover for adding models to the picker or to a specific model group.
struct ModelAddPopover: View {
    @Environment(AppModel.self) private var model
    let sectionID: UUID?
    let sectionName: String?

    @State private var query = ""
    @State private var highlightedPin: ModelPin?
    @State private var scrollTarget: ModelPin?
    @State private var addedPins: Set<ModelPin> = []
    @FocusState private var searchIsFocused: Bool

    private static let popoverWidth: CGFloat = 340
    private static let maxListHeight: CGFloat = 420

    init(sectionID: UUID? = nil, sectionName: String? = nil) {
        self.sectionID = sectionID
        self.sectionName = sectionName
    }

    private enum DisplayRow: Identifiable {
        case providerHeader(ProviderKind, isFirst: Bool)
        case model(ProviderKind, ModelOption, label: String)

        var id: String {
            switch self {
            case .providerHeader(let provider, _): "header/\(provider.rawValue)"
            case .model(let provider, let option, _): "\(provider.rawValue)/\(option.id)"
            }
        }
    }

    var body: some View {
        let settings: AppSettings = model.settings
        let registry: ProviderRegistry = model.providers
        let modelList: [ModelPin] = settings.modelList
        let pinned = Set<ModelPin>(modelList)
        let isFull: Bool = modelList.count >= AppSettings.modelListLimit
        let searchQuery: String = query.trimmed.lowercased(with: .current)
        let availableProviders: [ProviderKind] = sortedAvailableProviders()
        let sections: [(provider: ProviderKind, models: [ModelOption])] = displaySections(availableProviders: availableProviders, searchQuery: searchQuery)
        let rows: [DisplayRow] = buildRows(from: sections)
        let allPins: [ModelPin] = sections.flatMap { (section: (provider: ProviderKind, models: [ModelOption])) -> [ModelPin] in
            section.models.map { (option: ModelOption) -> ModelPin in
                ModelPin(provider: section.provider, modelID: option.id)
            }
        }
        let addablePins: [ModelPin] = isFull ? [] : allPins.filter { (pin: ModelPin) -> Bool in !pinned.contains(pin) }
        let rowHeight: CGFloat = TypeScale.shared.ui(32)
        let firstHeaderHeight: CGFloat = TypeScale.shared.ui(24)
        let headerHeight: CGFloat = TypeScale.shared.ui(30)
        let emptyHeight: CGFloat = TypeScale.shared.ui(56)
        let listHeight: CGFloat = estimatedListHeight(
            rows: rows,
            rowHeight: rowHeight,
            firstHeaderHeight: firstHeaderHeight,
            headerHeight: headerHeight,
            emptyHeight: emptyHeight
        )
        let headerTitle: String = if let sectionName, !sectionName.isEmpty {
            String(format: Chrome.localized("Add to %@"), sectionName)
        } else {
            Chrome.localized("Add a model")
        }

        VStack(alignment: .leading, spacing: 0) {
            headerRow(title: headerTitle, count: modelList.count)

            searchField
                .padding(.horizontal, 10)
                .padding(.bottom, 6)

            if rows.isEmpty {
                emptyRowsView(
                    searchQuery: searchQuery,
                    availableProviders: availableProviders,
                    registry: registry,
                    emptyHeight: emptyHeight
                )
            } else {
                rowsScrollView(
                    rows: rows,
                    settings: settings,
                    pinned: pinned,
                    isFull: isFull,
                    rowHeight: rowHeight,
                    firstHeaderHeight: firstHeaderHeight,
                    headerHeight: headerHeight,
                    listHeight: listHeight
                )
            }
        }
        .padding(.bottom, 4)
        .frame(width: Self.popoverWidth)
        .presentedChrome()
        .onAppear {
            highlightedPin = addablePins.first
            searchIsFocused = true
        }
        .onChange(of: query) { (_: String, _: String) in
            let first: ModelPin? = currentAddablePins().first
            highlightedPin = first
            scrollTarget = first
        }
        .onChange(of: addablePins) { (_: [ModelPin], updated: [ModelPin]) in
            if let current = highlightedPin, updated.contains(current) { return }
            highlightedPin = updated.first
        }
        .task {
            await loadCatalogs(for: availableProviders)
        }
    }

    private func headerRow(title: String, count: Int) -> some View {
        let countText: String = "\(count) / \(AppSettings.modelListLimit)"
        return HStack(spacing: 8) {
            Text(verbatim: title)
                .font(.ui(.body, weight: .semibold))
                .foregroundStyle(Chrome.primaryText)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            Text(verbatim: countText)
                .font(.ui(size: 11).monospacedDigit())
                .foregroundStyle(Chrome.secondaryText)
                .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private func emptyRowsView(
        searchQuery: String,
        availableProviders: [ProviderKind],
        registry: ProviderRegistry,
        emptyHeight: CGFloat
    ) -> some View {
        let isLoading: Bool = searchQuery.isEmpty && availableProviders.contains { (provider: ProviderKind) -> Bool in
            registry.loadingCatalogs.contains(provider)
        }
        let message: String = Chrome.localized(isLoading ? "Loading models…" : "No matching models")
        return Text(verbatim: message)
            .font(.ui(.body))
            .foregroundStyle(Chrome.secondaryText)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: emptyHeight, alignment: .leading)
    }

    private func rowsScrollView(
        rows: [DisplayRow],
        settings: AppSettings,
        pinned: Set<ModelPin>,
        isFull: Bool,
        rowHeight: CGFloat,
        firstHeaderHeight: CGFloat,
        headerHeight: CGFloat,
        listHeight: CGFloat
    ) -> some View {
        ScrollViewReader { (proxy: ScrollViewProxy) in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(rows) { (row: DisplayRow) in
                        displayRowView(
                            row: row,
                            settings: settings,
                            pinned: pinned,
                            isFull: isFull,
                            rowHeight: rowHeight,
                            firstHeaderHeight: firstHeaderHeight,
                            headerHeight: headerHeight
                        )
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: listHeight)
            .onChange(of: scrollTarget) { (_: ModelPin?, target: ModelPin?) in
                guard let target else { return }
                proxy.scrollTo(target.id)
            }
        }
    }

    @ViewBuilder
    private func displayRowView(
        row: DisplayRow,
        settings: AppSettings,
        pinned: Set<ModelPin>,
        isFull: Bool,
        rowHeight: CGFloat,
        firstHeaderHeight: CGFloat,
        headerHeight: CGFloat
    ) -> some View {
        switch row {
        case .providerHeader(let provider, let isFirst):
            providerHeader(provider, isFirst: isFirst, height: isFirst ? firstHeaderHeight : headerHeight)
        case .model(let provider, let option, let label):
            let pin = ModelPin(provider: provider, modelID: option.id)
            let isAdded: Bool = pinned.contains(pin)
            let showsEffortMenu: Bool = isAdded && addedPins.contains(pin) && !option.efforts.isEmpty
            let currentEffort: String? = showsEffortMenu
                ? Self.resolvedEffort(for: option, preference: settings.preference(for: provider, model: option.id))
                : nil
            AddModelRow(
                option: option,
                displayName: label,
                rowHeight: rowHeight,
                isAdded: isAdded,
                isFull: isFull,
                isHighlighted: !isAdded && !isFull && highlightedPin == pin,
                showsEffortMenu: showsEffortMenu,
                currentEffort: currentEffort,
                onAdd: { addModel(pin) },
                onSelectEffort: { (effort: String) in setEffort(effort, for: pin) }
            )
        }
    }

    private func loadCatalogs(for providers: [ProviderKind]) async {
        let registry: ProviderRegistry = model.providers
        for provider in providers {
            await registry.loadCatalog(provider)
        }
    }

    private var searchField: some View {
        // Uses SidebarSearchField's Chrome tokens directly so the field spans the popover,
        // takes @FocusState + arrow/Return keys, and lets Escape close the popover natively.
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.ui(.callout, weight: .medium))
                .foregroundStyle(Chrome.secondaryText.opacity(0.85))
                .accessibilityHidden(true)
            TextField(Chrome.localized("Search models"), text: $query)
                .textFieldStyle(.plain)
                .focusEffectDisabled()
                .font(.ui(.body))
                .foregroundStyle(Chrome.primaryText)
                .focused($searchIsFocused)
                .onSubmit { submitHighlighted() }
                .onKeyPress(.upArrow) {
                    moveHighlight(by: -1)
                    return .handled
                }
                .onKeyPress(.downArrow) {
                    moveHighlight(by: 1)
                    return .handled
                }
            if !query.isEmpty {
                Button {
                    query = ""
                    searchIsFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.ui(.callout))
                        .foregroundStyle(Chrome.secondaryText.opacity(0.75))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Clear search"))
            }
        }
        .padding(.horizontal, 9)
        .frame(minHeight: TypeScale.shared.ui(30))
        .background {
            Capsule(style: .continuous).fill(Chrome.overlay(0.07))
        }
        .contentShape(Capsule(style: .continuous))
    }

    private func providerHeader(_ provider: ProviderKind, isFirst: Bool, height: CGFloat) -> some View {
        HStack(spacing: 6) {
            ProviderIcon(provider: provider, size: 14)
            Text(verbatim: provider.displayName)
                .font(.ui(.subheadline, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundStyle(Chrome.secondaryText)
        .padding(.horizontal, 8)
        .padding(.top, isFirst ? 2 : 8)
        .padding(.bottom, 2)
        .frame(maxWidth: .infinity, minHeight: height, alignment: .leading)
        .accessibilityAddTraits(.isHeader)
    }

    private func sortedAvailableProviders() -> [ProviderKind] {
        let available = Set(model.providers.availableProviders)
        return ProviderKind.alphabetical.filter { available.contains($0) }
    }

    private func displaySections(availableProviders: [ProviderKind], searchQuery: String) -> [(provider: ProviderKind, models: [ModelOption])] {
        let registry = model.providers
        return availableProviders.compactMap { provider in
            let models: [ModelOption]
            if searchQuery.isEmpty {
                models = model.pickerModels(for: provider)
            } else {
                let catalogue = registry.sortedModels(for: provider)
                if provider.displayName.localizedCaseInsensitiveContains(searchQuery) {
                    models = catalogue
                } else {
                    models = catalogue.filter {
                        ModelsSettingsPage.matches($0, id: $0.id, provider: provider, query: searchQuery)
                    }
                }
            }
            return models.isEmpty ? nil : (provider, models)
        }
    }

    private func buildRows(from sections: [(provider: ProviderKind, models: [ModelOption])]) -> [DisplayRow] {
        var rows: [DisplayRow] = []
        for (index, section) in sections.enumerated() {
            rows.append(.providerHeader(section.provider, isFirst: index == 0))
            for option in section.models {
                rows.append(.model(section.provider, option, label: option.label(among: section.models)))
            }
        }
        return rows
    }

    private func estimatedListHeight(
        rows: [DisplayRow],
        rowHeight: CGFloat,
        firstHeaderHeight: CGFloat,
        headerHeight: CGFloat,
        emptyHeight: CGFloat
    ) -> CGFloat {
        guard !rows.isEmpty else { return emptyHeight }
        let itemsHeight = rows.reduce(CGFloat.zero) { sum, row in
            switch row {
            case .providerHeader(_, let isFirst): sum + (isFirst ? firstHeaderHeight : headerHeight)
            case .model: sum + rowHeight
            }
        }
        let spacing = CGFloat(max(0, rows.count - 1))
        return min(itemsHeight + spacing + 8, Self.maxListHeight)
    }

    private func currentAllPins() -> [ModelPin] {
        let searchQuery = query.trimmed.lowercased(with: .current)
        let sections = displaySections(availableProviders: sortedAvailableProviders(), searchQuery: searchQuery)
        return sections.flatMap { section in
            section.models.map { ModelPin(provider: section.provider, modelID: $0.id) }
        }
    }

    private func currentAddablePins() -> [ModelPin] {
        let settings = model.settings
        guard settings.modelList.count < AppSettings.modelListLimit else { return [] }
        let pinned = Set(settings.modelList)
        return currentAllPins().filter { !pinned.contains($0) }
    }

    private func moveHighlight(by offset: Int) {
        let addable = currentAddablePins()
        guard !addable.isEmpty else {
            highlightedPin = nil
            return
        }
        let next: ModelPin
        if let current = highlightedPin, let index = addable.firstIndex(of: current) {
            let clamped = min(max(0, index + offset), addable.count - 1)
            next = addable[clamped]
        } else {
            next = offset < 0 ? addable[addable.count - 1] : addable[0]
        }
        highlightedPin = next
        scrollTarget = next
    }

    private func submitHighlighted() {
        let addable = currentAddablePins()
        guard let target = highlightedPin.flatMap({ addable.contains($0) ? $0 : nil }) ?? addable.first else { return }
        addModel(target)
    }

    private func addModel(_ pin: ModelPin) {
        let settings = model.settings
        guard !settings.modelList.contains(pin),
              settings.modelList.count < AppSettings.modelListLimit else { return }
        let allPins = currentAllPins()
        let wasHighlighted = highlightedPin == pin
        withAnimation(Chrome.panelSlide) {
            settings.addToModelList(pin, toSection: sectionID)
        }
        addedPins.insert(pin)
        if settings.modelList.count >= AppSettings.modelListLimit {
            highlightedPin = nil
        } else if wasHighlighted {
            let updatedPinned = Set(settings.modelList)
            if let index = allPins.firstIndex(of: pin) {
                let after = allPins[(index + 1)...].first { !updatedPinned.contains($0) }
                let before = allPins[..<index].last { !updatedPinned.contains($0) }
                highlightedPin = after ?? before
            } else {
                highlightedPin = allPins.first { !updatedPinned.contains($0) }
            }
            scrollTarget = highlightedPin
        }
    }

    private func setEffort(_ effort: String, for pin: ModelPin) {
        let settings = model.settings
        var updated = settings.preference(for: pin.provider, model: pin.modelID)
        updated.effort = effort
        settings.setPreference(updated, for: pin.provider, model: pin.modelID)
    }

    /// Mirrors `EffortSliderCard`'s effort resolution: stored preference first, then the
    /// model's advertised default, then "medium" or the lowest listed level.
    static func resolvedEffort(for option: ModelOption, preference: ModelPreference) -> String {
        let efforts = option.efforts
        guard !efforts.isEmpty else { return "" }
        if let effort = preference.effort, efforts.contains(effort) { return effort }
        if let defaultEffort = option.defaultEffort, efforts.contains(defaultEffort) { return defaultEffort }
        return efforts.contains("medium") ? "medium" : efforts[0]
    }
}

private struct AddModelRow: View {
    let option: ModelOption
    let displayName: String
    let rowHeight: CGFloat
    let isAdded: Bool
    let isFull: Bool
    let isHighlighted: Bool
    let showsEffortMenu: Bool
    let currentEffort: String?
    let onAdd: () -> Void
    let onSelectEffort: (String) -> Void

    @State private var isHovering = false

    private var canAdd: Bool { !isAdded && !isFull }
    private var isDimmed: Bool { !isAdded && isFull }

    private var helpText: String {
        if isAdded { return Chrome.localized("Already in the model picker") }
        if isFull { return String(format: Chrome.localized("The model picker holds up to %lld models"), AppSettings.modelListLimit) }
        return Chrome.localized("Add to the model picker")
    }

    private var accessibilityText: String {
        if isAdded {
            return "\(displayName), \(Chrome.localized("Already in the model picker"))"
        }
        return String(format: Chrome.localized("Add %@ to the model picker"), displayName)
    }

    private var rowFill: Color {
        if isHighlighted { return Chrome.overlay(0.1) }
        if isHovering && canAdd { return Chrome.overlay(0.06) }
        return .clear
    }

    var body: some View {
        if isAdded {
            rowContent
                .help(Text(verbatim: helpText))
                .accessibilityElement(children: .contain)
                .accessibilityLabel(Text(verbatim: accessibilityText))
        } else {
            Button(action: onAdd) {
                rowContent
            }
            .buttonStyle(.plain)
            .disabled(isDimmed)
            .opacity(isDimmed ? 0.35 : 1)
            .onHover { hovering in
                withAnimation(Chrome.hover) { isHovering = hovering }
            }
            .help(Text(verbatim: helpText))
            .accessibilityLabel(Text(verbatim: accessibilityText))
            .accessibilityAddTraits(isHighlighted ? .isSelected : [])
        }
    }

    private var rowContent: some View {
        HStack(spacing: 8) {
            Text(verbatim: displayName)
                .font(.ui(size: 13))
                .foregroundStyle(Chrome.primaryText)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            if option.supportsFast {
                Image(systemName: "bolt")
                    .font(.ui(size: 11))
                    .foregroundStyle(Chrome.secondaryText)
                    .help(Text(verbatim: Chrome.localized("Supports fast mode")))
            }
            if showsEffortMenu, let currentEffort {
                effortMenu(currentEffort: currentEffort)
            }
            Image(systemName: isAdded ? "checkmark.circle.fill" : "plus.circle")
                .font(.ui(size: 15))
                .foregroundStyle(isAdded ? Chrome.accent : Chrome.secondaryText)
                .contentTransition(.symbolEffect(.replace))
        }
        .padding(.horizontal, 10)
        .frame(height: rowHeight)
        .background {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(rowFill)
        }
        .contentShape(.rect)
    }

    private func effortMenu(currentEffort: String) -> some View {
        let selection = Binding<String>(
            get: { currentEffort },
            set: { onSelectEffort($0) }
        )
        return GlassPickerButton(
            options: option.efforts.map { (value: $0, title: ModelOption.effortTitle($0)) },
            selection: selection
        )
        .help(Text(verbatim: Chrome.localized("Reasoning effort")))
        .accessibilityLabel(Text(verbatim: Chrome.localized("Reasoning effort")))
    }
}
