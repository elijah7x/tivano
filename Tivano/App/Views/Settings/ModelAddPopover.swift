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
        let settings = model.settings
        let registry = model.providers
        let modelList = settings.modelList
        let pinned = Set(modelList)
        let isFull = modelList.count >= AppSettings.modelListLimit
        let searchQuery = query.trimmed.lowercased(with: .current)
        let availableProviders = sortedAvailableProviders()
        let sections = displaySections(availableProviders: availableProviders, searchQuery: searchQuery)
        let rows = buildRows(from: sections)
        let allPins = sections.flatMap { section in
            section.models.map { ModelPin(provider: section.provider, modelID: $0.id) }
        }
        let addablePins = isFull ? [] : allPins.filter { !pinned.contains($0) }
        let rowHeight = TypeScale.shared.ui(32)
        let firstHeaderHeight = TypeScale.shared.ui(24)
        let headerHeight = TypeScale.shared.ui(30)
        let emptyHeight = TypeScale.shared.ui(56)
        let listHeight = estimatedListHeight(
            rows: rows,
            rowHeight: rowHeight,
            firstHeaderHeight: firstHeaderHeight,
            headerHeight: headerHeight,
            emptyHeight: emptyHeight
        )
        let headerTitle = if let sectionName, !sectionName.isEmpty {
            String(format: Chrome.localized("Add to %@"), sectionName)
        } else {
            Chrome.localized("Add a model")
        }

        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(verbatim: headerTitle)
                    .font(.ui(.body, weight: .semibold))
                    .foregroundStyle(Chrome.primaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                Text(verbatim: "\(modelList.count) / \(AppSettings.modelListLimit)")
                    .font(.ui(size: 11).monospacedDigit())
                    .foregroundStyle(Chrome.secondaryText)
                    .fixedSize()
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 8)

            searchField
                .padding(.horizontal, 10)
                .padding(.bottom, 6)

            if rows.isEmpty {
                let isLoading = searchQuery.isEmpty && availableProviders.contains { registry.loadingCatalogs.contains($0) }
                Text(verbatim: Chrome.localized(isLoading ? "Loading models…" : "No matching models"))
                    .font(.ui(.body))
                    .foregroundStyle(Chrome.secondaryText)
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity, minHeight: emptyHeight, alignment: .leading)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(rows) { row in
                                switch row {
                                case .providerHeader(let provider, let isFirst):
                                    providerHeader(provider, isFirst: isFirst, height: isFirst ? firstHeaderHeight : headerHeight)
                                case .model(let provider, let option, let label):
                                    let pin = ModelPin(provider: provider, modelID: option.id)
                                    let isAdded = pinned.contains(pin)
                                    let showsEffortMenu = isAdded && addedPins.contains(pin) && !option.efforts.isEmpty
                                    let currentEffort = showsEffortMenu
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
                                        onSelectEffort: { effort in setEffort(effort, for: pin) }
                                    )
                                }
                            }
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .frame(height: listHeight)
                    .onChange(of: scrollTarget) { _, target in
                        guard let target else { return }
                        proxy.scrollTo(target.id)
                    }
                }
            }
        }
        .padding(.bottom, 4)
        .frame(width: Self.popoverWidth)
        .presentedChrome()
        .onAppear {
            highlightedPin = addablePins.first
            searchIsFocused = true
        }
        .onChange(of: query) { _, _ in
            let first = currentAddablePins().first
            highlightedPin = first
            scrollTarget = first
        }
        .onChange(of: addablePins) { _, updated in
            if let current = highlightedPin, updated.contains(current) { return }
            highlightedPin = updated.first
        }
        .task {
            for provider in availableProviders {
                await model.providers.loadCatalog(provider)
            }
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
        if isAdded { return Chrome.localized("Already in your models") }
        if isFull { return String(format: Chrome.localized("The picker holds up to %lld models"), AppSettings.modelListLimit) }
        return Chrome.localized("Add to the picker")
    }

    private var accessibilityText: String {
        if isAdded {
            return "\(displayName), \(Chrome.localized("Already in your models"))"
        }
        return String(format: Chrome.localized("Add %@ to the picker"), displayName)
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
        return Menu {
            Picker(selection: selection) {
                ForEach(option.efforts, id: \.self) { level in
                    Text(verbatim: Chrome.localized(ModelOption.effortTitle(level)))
                        .tag(level)
                }
            } label: {
                EmptyView()
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: 4) {
                Text(verbatim: Chrome.localized(ModelOption.effortTitle(currentEffort)))
                    .font(.ui(size: 11, weight: .medium))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(Chrome.chevronFont)
            }
            .foregroundStyle(Chrome.secondaryText)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background {
                Capsule(style: .continuous)
                    .fill(Chrome.overlay(0.08))
            }
            .contentShape(Capsule(style: .continuous))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(Text(verbatim: Chrome.localized("Reasoning effort")))
        .accessibilityLabel(Text(verbatim: Chrome.localized("Reasoning effort")))
    }
}
