import AppKit
import SwiftUI

/// The models the composer offers: the list chosen in Settings, or every ready provider's models until one is set up.
@MainActor
enum ModelCatalog {
    struct Entry: Identifiable, Hashable {
        let provider: ProviderKind
        let option: ModelOption

        var id: String { "\(provider.rawValue)/\(option.id)" }
    }

    static func entries(_ model: AppModel, including thread: ChatThread?) -> [Entry] {
        let registry = model.providers
        var result: [Entry] = if model.settings.modelList.isEmpty {
            ProviderKind.alphabetical.filter(Set(registry.availableProviders).contains).flatMap { provider in
                var ids: Set<String> = []
                if let thread, thread.provider == provider, let current = thread.model { ids.insert(current) }
                return model.pickerModels(for: provider, keeping: ids).map { Entry(provider: provider, option: $0) }
            }
        } else {
            model.settings.modelList.compactMap { pin in
                guard model.settings.isEnabled(pin.provider) else { return nil }
                return registry.model(pin.modelID, for: pin.provider).map { Entry(provider: pin.provider, option: $0) }
            }
        }
        if let thread, model.settings.isEnabled(thread.provider),
           let current = registry.model(thread.model, for: thread.provider),
           !result.contains(where: { $0.provider == thread.provider && $0.option.id == current.id }) {
            result.insert(Entry(provider: thread.provider, option: current), at: 0)
        }
        return result
    }

    static func fullCatalogueEntries(_ model: AppModel, forProvidersIn entries: [Entry]) -> [Entry] {
        var providers: [ProviderKind] = []
        for entry in entries where !providers.contains(entry.provider) {
            providers.append(entry.provider)
        }
        return providers.flatMap { provider in
            model.providers.sortedModels(for: provider).map { Entry(provider: provider, option: $0) }
        }
    }
}

// MARK: - Composer chip

/// The composer's model chip. It opens the effort slider, and the card's model line opens the model list.
struct ModelEffortButton: View {
    @Environment(AppModel.self) private var model
    let thread: ChatThread
    let hasHistory: Bool
    /// Floating panels are narrow: the chip collapses to the provider's icon so the
    /// text field keeps its room. The full name stays in the tooltip and VoiceOver.
    var compact: Bool = false

    @State private var isPresented = false

    /// Where the popover's arrow hangs, measured from the chip's leading edge: about the
    /// center of a typical "model · effort · preset" chip. The popover is anchored once
    /// when it opens, so later chip resizes never move it.
    private static let popoverAnchorX: CGFloat = 100

    private var fallbackName: String {
        thread.model.map { ModelPin(provider: thread.provider, modelID: $0).displayName } ?? thread.provider.displayName
    }

    var body: some View {
        let registry = model.providers
        let current = registry.model(thread.model, for: thread.provider)
        let isHydra = model.hydraModeIsOn(thread)
        let isChimera = model.chimeraIsOn(thread)
        let pair = isHydra ? model.hydraPair(for: thread) : nil
        Button {
            isPresented.toggle()
        } label: {
            HStack(spacing: 5) {
                if compact, let pair {
                    HydraFusedPairIcon(lead: pair.provider, heads: model.hydraHeadsProvider(of: pair), size: 15)
                        .id(pair.id)
                } else {
                    ProviderIcon(provider: thread.provider, size: 14)
                }
                if thread.fastMode, current?.supportsFast == true {
                    Image(systemName: "bolt.fill")
                        .font(Chrome.inlineIconFont)
                        .foregroundStyle(.yellow)
                }
                if !compact {
                    Text(verbatim: current?.chipName ?? fallbackName)
                        .foregroundStyle(Chrome.primaryText)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let current, !current.efforts.isEmpty {
                        Text(verbatim: "·")
                            .foregroundStyle(Chrome.secondaryText)
                            .fixedSize()
                        Text(verbatim: Chrome.localized(ModelOption.effortTitle((thread.provider == .minimaxCode ? thread.effort.flatMap { current.efforts.contains($0) ? $0 : nil } : thread.effort) ?? current.defaultEffort ?? "")))
                            .foregroundStyle(Chrome.primaryText.opacity(0.72))
                            .lineLimit(1)
                            .fixedSize()
                    }
                    if let pair {
                        Text(verbatim: "·")
                            .foregroundStyle(Chrome.secondaryText)
                            .fixedSize()
                        HStack(spacing: 4) {
                            HydraFusedPairIcon(lead: pair.provider, heads: model.hydraHeadsProvider(of: pair), size: 13, animates: false)
                                .id(pair.id)
                            Text(verbatim: pair.customName?.trimmed.nilIfEmpty ?? Chrome.localized("Preset"))
                                .foregroundStyle(Chrome.primaryText.opacity(0.85))
                                .lineLimit(1)
                                .fixedSize()
                        }
                    } else if isHydra {
                        Text(verbatim: "·")
                            .foregroundStyle(Chrome.secondaryText)
                            .fixedSize()
                        HStack(spacing: 3) {
                            HydraMarkImage()
                                .frame(width: 12, height: 12)
                            Text(verbatim: Chrome.localized("Same-model"))
                                .lineLimit(1)
                        }
                        .foregroundStyle(Chrome.accent)
                        .fixedSize()
                    } else if isChimera {
                        Text(verbatim: "·")
                            .foregroundStyle(Chrome.secondaryText)
                            .fixedSize()
                        HStack(spacing: 3) {
                            ChimeraMarkImage()
                                .frame(width: 14, height: 12)
                            Text(verbatim: Chrome.localized("Adaptive"))
                                .lineLimit(1)
                        }
                        .foregroundStyle(Chrome.accent)
                        .fixedSize()
                    }
                    Image(systemName: "chevron.down")
                        .font(Chrome.chevronFont)
                        .foregroundStyle(Chrome.secondaryText)
                }
            }
        }
        .buttonStyle(.chip(active: isPresented))
        .focusable(false)
        .help(Text(verbatim: helpText(current: current, isHydra: isHydra, isChimera: isChimera, pair: pair)))
        .accessibilityLabel(Text(verbatim: helpText(current: current, isHydra: isHydra, isChimera: isChimera, pair: pair)))
        .anchoredPopover(
            isPresented: $isPresented,
            arrowEdge: .bottom,
            sizing: .tracksContent,
            anchor: compact ? nil : { bounds in
                CGRect(x: min(Self.popoverAnchorX, max(bounds.width - 14, bounds.width / 2)), y: 0, width: 1, height: bounds.height)
            }
        ) {
            ModelEffortPanel(threadID: thread.id, hasHistory: hasHistory)
        }
        #if DEBUG
        .background {
            // The website captures hang the slider and the switcher from the real chip: the
            // composer's, never a panel's icon-only one, which would leave the popover with
            // nothing to hang from once the panel is gone.
            if CaptureRun.isEnabled, !compact {
                AttachmentAnchorCapture { WebsiteCaptures.modelChipAnchor = WeakView($0) }
            }
        }
        // And where the chip is, in the window, by the thread it belongs to: a popover
        // hung from that rect on the window itself outlives any remaking of the chip's view.
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
            if CaptureRun.isEnabled, !compact { WebsiteCaptures.modelChipFrames[thread.id] = frame }
        }
        #endif
        .task(id: thread.provider) { await registry.loadCatalog(thread.provider) }
        .onChange(of: current, initial: true) { _, current in
            guard thread.provider == .minimaxCode, let current,
                  let effort = model.thread(thread.id)?.effort,
                  !current.efforts.contains(effort) else { return }
            model.updateThread(thread.id) { $0.effort = nil }
        }
    }

    /// The full model, effort and sub-agent mode, for the tooltip and VoiceOver.
    private func helpText(current: ModelOption?, isHydra: Bool, isChimera: Bool, pair: HydraPair?) -> String {
        var parts = [current?.shortName ?? fallbackName]
        if let current, !current.efforts.isEmpty {
            parts.append(Chrome.localized(ModelOption.effortTitle((thread.provider == .minimaxCode ? thread.effort.flatMap { current.efforts.contains($0) ? $0 : nil } : thread.effort) ?? current.defaultEffort ?? "")))
        }
        parts.append(thread.provider.routeSummary)
        if let pair {
            parts.append(HydraPairSummary.title(pair, registry: model.providers))
        } else if isHydra {
            parts.append(Chrome.localized("Same-model sub-agents"))
        } else if isChimera {
            parts.append(Chrome.localized("Adaptive sub-agents"))
        }
        return parts.joined(separator: " · ")
    }
}

/// The popover behind the chip: effort, model choices and the chat's temporary pair.
private struct ModelEffortPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.closePopover) private var closePopover
    let threadID: UUID
    let hasHistory: Bool

    private enum Page {
        case slider, models, temporaryPair
    }

    @State private var page: Page = .slider

    private func close() {
        if let closePopover {
            closePopover()
        } else {
            dismiss()
        }
    }

    var body: some View {
        if let thread = model.thread(threadID) {
            Group {
                switch page {
                case .models:
                    modelList(for: thread)
                        .transition(.opacity)
                case .temporaryPair:
                    if let pair = thread.temporaryHydraPair {
                        temporaryPairEditor(pair, for: thread)
                            .transition(.opacity)
                    } else {
                        modelList(for: thread)
                            .transition(.opacity)
                            .onAppear { page = .models }
                    }
                case .slider:
                    slider(for: thread)
                        .transition(.opacity)
                }
            }
            .frame(width: page == .models ? nil : (page == .temporaryPair ? 360 : 330))
            .animation(.easeOut(duration: 0.12), value: page)
            .onChange(of: thread.temporaryHydraPair == nil) { _, isMissing in
                if isMissing, page == .temporaryPair { page = .models }
            }
        }
    }

    private func modelList(for thread: ChatThread) -> some View {
        ModelList(thread: thread, hasHistory: hasHistory, allowsPairColumns: true) { entry in
            choose(entry, for: thread)
            page = .slider
        } onEnterPair: { pair in
            if !hasHistory { model.settings.noteNewChatChoice(.pair(pair)) }
            model.enterHydraPair(pair, for: thread.id)
            page = .slider
            close()
        } onEnterTemporaryPair: { pair in
            if !hasHistory { model.settings.noteNewChatChoice(.pair(pair)) }
            model.enterHydraPair(pair, for: thread.id, temporary: true)
            page = .slider
            close()
        } onEditTemporaryPair: {
            if !hasHistory, let pair = model.thread(thread.id)?.temporaryHydraPair {
                model.settings.noteNewChatChoice(.pair(pair))
            }
            page = .temporaryPair
        } onBack: {
            page = .slider
        }
    }

    private func temporaryPairEditor(_ pair: HydraPair, for thread: ChatThread) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Button { page = .models } label: {
                    Image(systemName: "chevron.left")
                        .font(.ui(.subheadline, weight: .semibold))
                        .frame(width: 20, height: 20)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Chrome.secondaryText)
                .help(Text(verbatim: Chrome.localized("Back")))
                .accessibilityLabel(Text(verbatim: Chrome.localized("Back")))
                Text("Temporary combo")
                    .font(.ui(.body))
                    .foregroundStyle(Chrome.secondaryText)
            }
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .padding(.bottom, 4)

            HydraPairEditor(pair: pair, showsName: false, update: { change in
                model.updateTemporaryHydraPair(for: thread.id, change)
                if !hasHistory, let updatedPair = model.thread(thread.id)?.temporaryHydraPair {
                    model.settings.noteNewChatChoice(.pair(updatedPair))
                }
            })

            Text("Used by this chat only, not saved to Settings › Sub-agents & Combos.")
                .font(.ui(size: 11))
                .foregroundStyle(Chrome.secondaryText)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
        }
        .padding(6)
    }

    private func slider(for thread: ChatThread) -> some View {
        let option = model.providers.model(thread.model, for: thread.provider)
        let fallbackName = thread.model.map { ModelPin(provider: thread.provider, modelID: $0).displayName } ?? thread.provider.displayName
        // In a pair the slider is the lead's: it wears the pair's fusion and says whose
        // effort it sets.
        let pair = model.hydraIsOn(thread) ? model.hydraPair(for: thread) : nil
        let pairLook = pair.map { EffortPairLook($0, registry: model.providers, resolvedHeadsEffort: model.hydraLaunch(for: thread)?.workerEffort) }
        return EffortSliderCard(
            modelName: option.map { $0.label(among: model.pinnedOptions(for: thread.provider)) } ?? fallbackName,
            provider: thread.provider,
            pair: pairLook,
            efforts: option?.efforts ?? [],
            defaultEffort: option?.defaultEffort,
            supportsFast: option?.supportsFast ?? false,
            effort: Binding(
                get: { thread.effort },
                set: { effort in
                    model.updateThread(thread.id) { $0.effort = effort }
                    remember(thread.id)
                }
            ),
            fastMode: Binding(
                get: { thread.fastMode },
                set: { isOn in
                    model.updateThread(thread.id) { $0.fastMode = isOn }
                    remember(thread.id)
                }
            ),
            dshMode: thread.provider == .dsh ? Binding(
                get: { thread.dshMode ?? .standard },
                set: { mode in
                    model.updateThread(thread.id) { $0.dshMode = mode == .standard ? nil : mode }
                }
            ) : nil,
            threadID: thread.isHelper ? nil : thread.id,
            hasHistory: hasHistory,
            onTitleTap: { page = .models }
        )
    }

    /// A choice made in a chat becomes that model's setting for every future chat.
    private func remember(_ id: UUID) {
        guard let thread = model.thread(id), let modelID = thread.model else { return }
        model.settings.setPreference(ModelPreference(effort: thread.effort, fastMode: thread.fastMode), for: thread.provider, model: modelID)
        model.settings.remember(model: modelID, effort: thread.effort, for: thread.provider)
    }

    private func choose(_ entry: ModelCatalog.Entry, for thread: ChatThread) {
        if !hasHistory {
            model.settings.noteNewChatChoice(.model(ModelPin(provider: entry.provider, modelID: entry.option.id)))
        }
        let provider = entry.provider
        let option = entry.option
        let switchesProvider = provider != thread.provider
        let preference = model.settings.preference(for: provider, model: option.id)
        let effort = preference.effort.flatMap { option.efforts.contains($0) ? $0 : nil }
        if (hasHistory && switchesProvider) || thread.pendingProviderSwitch != nil {
            model.stageProviderSwitch(thread.id) { thread in
                thread.provider = provider
                thread.model = option.id
                thread.effort = effort
                thread.fastMode = option.supportsFast && preference.fastMode
                thread.hydraPairID = nil
                thread.temporaryHydraPair = nil
            }
            return
        }
        model.updateThread(thread.id) { thread in
            if switchesProvider {
                thread.provider = provider
                thread.providerSessionID = nil
                thread.providerResumeAt = nil
            }
            thread.model = option.id
            thread.effort = effort
            thread.fastMode = option.supportsFast && preference.fastMode
        }
        // A model row is the choice of a model alone: the chat leaves any pair it led with.
        model.leaveHydraPair(for: thread.id)
        if switchesProvider { model.existingRuntime(for: thread.id)?.stopSession() }
        model.settings.remember(model: option.id, effort: effort, for: provider)
        model.settings.defaultProvider = provider
    }
}

struct ModelList: View {
    @Environment(AppModel.self) private var model
    let thread: ChatThread
    let hasHistory: Bool
    var allowsPairColumns = false
    let onChoose: (ModelCatalog.Entry) -> Void
    /// Left out where the list is only shown, as in the website captures.
    var onEnterPair: (HydraPair) -> Void = { _ in }
    var onEnterTemporaryPair: (HydraPair) -> Void = { _ in }
    var onEditTemporaryPair: () -> Void = {}
    let onBack: () -> Void

    @State private var query = ""
    @State private var showsOtherModels = false
    @State private var selectedCategory: Category?
    @State private var highlightedRowID: String?
    @State private var rightScrollRequest: ScrollRequest?
    @State private var leftScrollRequest: ScrollRequest?
    @State private var scrollNonce = 0
    @State private var hoveredHeading: String?
    @FocusState private var searchIsFocused: Bool

    private static let groupColumnWidth: CGFloat = 128
    private static let groupedPopoverWidth: CGFloat = 460
    private static let maxListHeight: CGFloat = 440
    /// A pair row carries two lines, like a model row with its provider under it.
    private static let pairRowHeight: CGFloat = 42
    /// What a group title takes: an 11 pt line with its own padding above and below.
    private static let sectionHeaderHeight: CGFloat = 22
    /// The same for Recent, Pairs and Models, which read one size larger than the groups under them.
    private static let topHeaderHeight: CGFloat = 25

    fileprivate enum Category: Hashable, Identifiable {
        case all
        case group(UUID)
        case ungrouped
        case combos

        var id: String {
            switch self {
            case .all: "all"
            case .group(let id): "group/\(id.uuidString)"
            case .ungrouped: "ungrouped"
            case .combos: "combos"
            }
        }
    }

    fileprivate enum CategoryIcon {
        case all
        case provider(ProviderKind)
        case emptyGroup
        case pair(lead: ProviderKind, heads: ProviderKind)
        case hydra
    }

    fileprivate struct CategoryItem: Identifiable {
        let category: Category
        let title: String
        let count: Int
        let icon: CategoryIcon

        var id: String { category.id }
    }

    private struct GroupBlock: Identifiable {
        let section: ModelSection
        var entries: [ModelCatalog.Entry]
        var id: UUID { section.id }
    }

    private enum ScrollAnchor: Equatable {
        case automatic
        case top
    }

    private struct ScrollRequest: Equatable {
        let id: String
        let anchor: ScrollAnchor
        let nonce: Int
    }

    private enum DisplayRow: Identifiable {
        case header(String)
        case searchHeader(id: String, title: String)
        case pair(HydraPair, temporary: Bool, recent: Bool)
        case newTemporaryPair
        case entry(ModelCatalog.Entry, recent: Bool)
        case section(ModelSection, hiddenCount: Int)
        case otherFold(Int)
        case empty(searching: Bool)
        case emptyGroup
        case noPairsMatch

        var id: String {
            switch self {
            case .header(let title): "header/\(title)"
            case .searchHeader(let id, _): "search-header/\(id)"
            case .pair(let pair, let temporary, let recent): "\(recent ? "recent-pair" : (temporary ? "temporary-pair" : "pair"))/\(pair.id)"
            case .newTemporaryPair: "new-temporary-pair"
            case .entry(let entry, let recent): "\(recent ? "recent" : "model")/\(entry.id)"
            case .section(let section, _): "section/\(section.id)"
            case .otherFold: "other-fold"
            case .empty: "empty"
            case .emptyGroup: "empty-group"
            case .noPairsMatch: "no-pairs-match"
            }
        }

        func height(modelRowHeight: CGFloat) -> CGFloat {
            switch self {
            case .header: ModelList.topHeaderHeight
            case .searchHeader, .section: ModelList.sectionHeaderHeight
            case .pair, .newTemporaryPair: ModelList.pairRowHeight
            case .otherFold: 34
            case .entry, .empty, .emptyGroup, .noPairsMatch: modelRowHeight
            }
        }
    }

    var body: some View {
        let entries = ModelCatalog.entries(model, including: thread)
        // The pairs are Hydra's: on offer while it is on, out of sight otherwise.
        let pairs = model.hydraIsOn(thread) ? model.hydraPickerPairs : []
        let activeTemporaryPair = model.temporaryHydraPair(for: thread)
        let searchQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let isSearching = !searchQuery.isEmpty
        let searchEntries = isSearching ? ModelCatalog.fullCatalogueEntries(model, forProvidersIn: entries) : entries
        // A chat leads with one pair or runs one model, never both: the checkmark sits on
        // the pair while the chat is in one, even though the pair's lead model is a row too.
        let leadsWithTemporaryPair = activeTemporaryPair != nil
        let leadsWithPair = leadsWithTemporaryPair || pairs.contains { model.leadsWithHydraPair($0, thread: thread) }
        let currentModelID = model.providers.model(thread.model, for: thread.provider)?.id ?? thread.model
        let showsProviders = Set(entries.map(\.provider)).count > 1
        // Fixed row heights let the popover size itself in one pass instead of measuring and resizing.
        let rowHeight: CGFloat = showsProviders || (hasHistory && entries.contains { $0.provider != thread.provider }) ? 42 : 32
        let hasUserGroups = !model.settings.modelSections.isEmpty
        let showsPairs = !pairs.isEmpty || (hasUserGroups && activeTemporaryPair != nil) || (!hasHistory && model.hydraIsOn(thread))

        let partitioned = hasUserGroups ? partitionedGroups(entries: entries) : (groups: [], ungrouped: [])
        let categories = hasUserGroups ? buildCategories(
            groups: partitioned.groups,
            ungrouped: partitioned.ungrouped,
            pairs: pairs,
            activeTemporaryPair: activeTemporaryPair,
            showsPairs: showsPairs
        ) : []
        let initialCategory = hasUserGroups ? defaultCategory(
            groups: partitioned.groups,
            showsPairs: showsPairs,
            leadsWithPair: leadsWithPair,
            currentModelID: currentModelID
        ) : .all
        let activeCategory = hasUserGroups ? resolvedCategory(available: categories, fallback: initialCategory) : .all

        let groupedRightRows: [DisplayRow] = if !hasUserGroups {
            []
        } else if isSearching {
            groupedSearchRows(
                entries: entries,
                searchEntries: searchEntries,
                groups: partitioned.groups,
                ungrouped: partitioned.ungrouped,
                pairs: pairs,
                activeTemporaryPair: activeTemporaryPair,
                showsPairs: showsPairs,
                query: searchQuery
            )
        } else {
            groupedCategoryRows(
                for: activeCategory,
                groups: partitioned.groups,
                ungrouped: partitioned.ungrouped,
                pairs: pairs,
                activeTemporaryPair: activeTemporaryPair,
                showsOtherModels: showsOtherModels
            )
        }

        let twoColumns = !hasUserGroups && allowsPairColumns && showsPairs
        let leftRows = hasUserGroups ? [] : pairRows(pairs: pairs, query: searchQuery)
        let rows = hasUserGroups ? [] : modelColumnRows(entries: entries, searchEntries: searchEntries, query: searchQuery)
        let singleRows = hasUserGroups ? [] : displayRows(entries: entries, searchEntries: searchEntries, pairs: pairs, query: searchQuery)

        let activeKeyboardRows: [DisplayRow] = if hasUserGroups {
            groupedRightRows
        } else if twoColumns {
            isSearching ? rows + leftRows : leftRows + rows
        } else {
            singleRows
        }
        let interactiveIDs = activeKeyboardRows.filter(isInteractive).map(\.id)

        let groupRowHeight = max(Chrome.rowHeight, TypeScale.shared.ui(28))
        let leftColumnHeight = CGFloat(categories.count) * groupRowHeight + CGFloat(max(0, categories.count - 1)) * 2 + 4
        let groupedBodyHeight: CGFloat = if hasUserGroups {
            min(
                max(
                    leftColumnHeight,
                    contentHeight(
                        groupedCategoryRows(
                            for: .all,
                            groups: partitioned.groups,
                            ungrouped: partitioned.ungrouped,
                            pairs: pairs,
                            activeTemporaryPair: activeTemporaryPair,
                            showsOtherModels: false
                        ),
                        rowHeight: rowHeight
                    ),
                    showsPairs ? contentHeight(
                        groupedCategoryRows(
                            for: .combos,
                            groups: partitioned.groups,
                            ungrouped: partitioned.ungrouped,
                            pairs: pairs,
                            activeTemporaryPair: activeTemporaryPair,
                            showsOtherModels: false
                        ),
                        rowHeight: rowHeight
                    ) : 0,
                    contentHeight(groupedRightRows, rowHeight: rowHeight)
                ),
                Self.maxListHeight
            )
        } else {
            0
        }
        let legacyContentHeight = twoColumns
            ? max(contentHeight(leftRows, rowHeight: rowHeight), contentHeight(rows, rowHeight: rowHeight))
            : contentHeight(singleRows, rowHeight: rowHeight)

        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .font(.ui(.subheadline, weight: .semibold))
                        .frame(width: 20, height: 20)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .focusable(false)
                .foregroundStyle(Chrome.secondaryText)
                .help(Text(verbatim: Chrome.localized("Back")))
                .accessibilityLabel(Text(verbatim: Chrome.localized("Back")))
                TextField("Search models", text: $query)
                    .textFieldStyle(.plain)
                    .focusEffectDisabled()
                    .font(.ui(.body))
                    .foregroundStyle(Chrome.primaryText)
                    .focused($searchIsFocused)
                    .onSubmit {
                        _ = submitHighlighted(in: activeKeyboardRows)
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
                    .focusable(false)
                    .accessibilityLabel(Text(verbatim: Chrome.localized("Clear search")))
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .padding(.bottom, hasUserGroups ? 6 : 4)

            if hasUserGroups {
                Divider()
                    .padding(.horizontal, 4)
                    .padding(.bottom, 4)

                HStack(alignment: .top, spacing: 0) {
                    groupColumn(
                        categories: categories,
                        selected: activeCategory,
                        isEnabled: !isSearching,
                        rowHeight: groupRowHeight
                    )
                    .frame(width: Self.groupColumnWidth)
                    .opacity(isSearching ? 0.45 : 1)
                    .allowsHitTesting(!isSearching)

                    Divider()
                        .frame(width: 1)
                        .padding(.vertical, 4)

                    column(
                        groupedRightRows,
                        allEntries: entries,
                        label: activeCategory == .combos && !isSearching ? "Combos" : "Models",
                        rowHeight: rowHeight,
                        showsProviders: showsProviders,
                        leadsWithPair: leadsWithPair,
                        leadsWithTemporaryPair: leadsWithTemporaryPair,
                        currentModelID: currentModelID
                    )
                    .frame(maxWidth: .infinity)
                }
                .frame(height: groupedBodyHeight)
            } else if twoColumns {
                HStack(alignment: .top, spacing: 0) {
                    column(
                        leftRows,
                        allEntries: entries,
                        label: "Combos",
                        rowHeight: rowHeight,
                        showsProviders: showsProviders,
                        leadsWithPair: leadsWithPair,
                        leadsWithTemporaryPair: leadsWithTemporaryPair,
                        currentModelID: currentModelID
                    )
                    .frame(width: 250)
                    Divider()
                        .frame(width: 1)
                        .padding(.vertical, 6)
                    column(
                        rows,
                        allEntries: entries,
                        label: "Models",
                        rowHeight: rowHeight,
                        showsProviders: showsProviders,
                        leadsWithPair: leadsWithPair,
                        leadsWithTemporaryPair: leadsWithTemporaryPair,
                        currentModelID: currentModelID
                    )
                    .frame(maxWidth: .infinity)
                }
                .frame(height: min(legacyContentHeight, Self.maxListHeight))
            } else {
                column(
                    singleRows,
                    allEntries: entries,
                    label: "Models",
                    rowHeight: rowHeight,
                    showsProviders: showsProviders,
                    leadsWithPair: leadsWithPair,
                    leadsWithTemporaryPair: leadsWithTemporaryPair,
                    currentModelID: currentModelID,
                    horizontalPadding: 0
                )
                .frame(height: min(legacyContentHeight, Self.maxListHeight))
            }
        }
        .padding(6)
        .frame(width: hasUserGroups ? Self.groupedPopoverWidth : (twoColumns ? 580 : 330))
        .background {
            ModelListKeyMonitor(
                onMoveRow: { offset in
                    moveHighlight(by: offset, in: activeKeyboardRows)
                },
                onMoveGroup: { offset in
                    guard hasUserGroups, query.isEmpty else { return false }
                    moveCategory(by: offset, categories: categories, current: activeCategory)
                    return true
                },
                onSubmit: {
                    submitHighlighted(in: activeKeyboardRows)
                }
            )
        }
        .onAppear {
            if hasUserGroups {
                selectedCategory = initialCategory
            }
            let preferred = preferredHighlightID(
                in: activeKeyboardRows,
                isSearching: isSearching,
                leadsWithPair: leadsWithPair,
                leadsWithTemporaryPair: leadsWithTemporaryPair,
                currentModelID: currentModelID
            )
            highlightedRowID = preferred
            if let preferred {
                requestRightScroll(to: preferred, anchor: .automatic)
            }
            if hasUserGroups {
                requestLeftScroll(to: initialCategory.id, anchor: .automatic)
            }
            searchIsFocused = true
        }
        .onChange(of: query) { _, _ in
            let preferred = preferredHighlightID(
                in: activeKeyboardRows,
                isSearching: isSearching,
                leadsWithPair: leadsWithPair,
                leadsWithTemporaryPair: leadsWithTemporaryPair,
                currentModelID: currentModelID
            )
            highlightedRowID = preferred
            if let topID = activeKeyboardRows.first?.id {
                requestRightScroll(to: topID, anchor: .top)
            }
        }
        .onChange(of: activeCategory) { _, updatedCategory in
            guard hasUserGroups else { return }
            let preferred = preferredHighlightID(
                in: activeKeyboardRows,
                isSearching: isSearching,
                leadsWithPair: leadsWithPair,
                leadsWithTemporaryPair: leadsWithTemporaryPair,
                currentModelID: currentModelID
            )
            highlightedRowID = preferred
            requestLeftScroll(to: updatedCategory.id, anchor: .automatic)
            let firstInteractiveID = activeKeyboardRows.first(where: isInteractive)?.id
            if preferred == firstInteractiveID, let topID = activeKeyboardRows.first?.id {
                requestRightScroll(to: topID, anchor: .top)
            } else if let preferred {
                requestRightScroll(to: preferred, anchor: .automatic)
            }
        }
        .onChange(of: interactiveIDs) { _, updated in
            if let current = highlightedRowID, updated.contains(current) { return }
            highlightedRowID = preferredHighlightID(
                in: activeKeyboardRows,
                isSearching: isSearching,
                leadsWithPair: leadsWithPair,
                leadsWithTemporaryPair: leadsWithTemporaryPair,
                currentModelID: currentModelID
            )
        }
        .task {
            // A pair on another provider, or with its heads on one, names its models from
            // that provider's catalogue, which this chat may never have loaded.
            for provider in Set(pairs.flatMap { [$0.provider, $0.headsProvider] }) where provider != thread.provider {
                await model.providers.loadCatalog(provider)
            }
        }
    }

    private func contentHeight(_ rows: [DisplayRow], rowHeight: CGFloat) -> CGFloat {
        rows.reduce(CGFloat.zero) { $0 + $1.height(modelRowHeight: rowHeight) + 1 }
    }

    private func groupColumn(
        categories: [CategoryItem],
        selected: Category,
        isEnabled: Bool,
        rowHeight: CGFloat
    ) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(categories) { item in
                        GroupNavRow(
                            item: item,
                            isSelected: item.category == selected,
                            isEnabled: isEnabled,
                            rowHeight: rowHeight
                        ) {
                            selectedCategory = item.category
                            searchIsFocused = true
                        }
                        .id(item.id)
                    }
                }
                .padding(.horizontal, 2)
                .padding(.vertical, 2)
            }
            .scrollBounceBehavior(.basedOnSize)
            .accessibilityLabel(Text(verbatim: Chrome.localized("Model groups")))
            .onChange(of: leftScrollRequest) { _, request in
                guard let request else { return }
                switch request.anchor {
                case .automatic: proxy.scrollTo(request.id)
                case .top: proxy.scrollTo(request.id, anchor: .top)
                }
            }
        }
    }

    private func column(
        _ rows: [DisplayRow],
        allEntries: [ModelCatalog.Entry],
        label: String,
        rowHeight: CGFloat,
        showsProviders: Bool,
        leadsWithPair: Bool,
        leadsWithTemporaryPair: Bool,
        currentModelID: String?,
        horizontalPadding: CGFloat = 4
    ) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(rows) { row in
                        rowView(
                            row,
                            rows: rows,
                            allEntries: allEntries,
                            rowHeight: rowHeight,
                            showsProviders: showsProviders,
                            leadsWithPair: leadsWithPair,
                            leadsWithTemporaryPair: leadsWithTemporaryPair,
                            currentModelID: currentModelID
                        )
                        .id(row.id)
                    }
                }
                .padding(.horizontal, horizontalPadding)
            }
            .scrollBounceBehavior(.basedOnSize)
            .accessibilityLabel(Text(verbatim: Chrome.localized(label)))
            .onChange(of: rightScrollRequest) { _, request in
                // Each column scrolls only for rows it shows, so a highlighted combo scrolls the combo column.
                guard let request, rows.contains(where: { $0.id == request.id }) else { return }
                switch request.anchor {
                case .automatic: proxy.scrollTo(request.id)
                case .top: proxy.scrollTo(request.id, anchor: .top)
                }
            }
        }
    }

    @ViewBuilder
    private func rowView(
        _ row: DisplayRow,
        rows: [DisplayRow],
        allEntries: [ModelCatalog.Entry],
        rowHeight: CGFloat,
        showsProviders: Bool,
        leadsWithPair: Bool,
        leadsWithTemporaryPair: Bool,
        currentModelID: String?
    ) -> some View {
        let isHighlighted = highlightedRowID == row.id
        switch row {
        case .header(let title):
            PopoverSectionHeader(title, weight: .bold, style: .callout)
                .frame(height: Self.topHeaderHeight)
        case .searchHeader(_, let title):
            Text(verbatim: title)
                .font(.ui(.subheadline, weight: .semibold))
                .foregroundStyle(Chrome.secondaryText)
                .lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.top, 6)
                .padding(.bottom, 3)
                .frame(maxWidth: .infinity, minHeight: Self.sectionHeaderHeight, alignment: .leading)
                .accessibilityAddTraits(.isHeader)
        case .pair(let pair, let temporary, let recent):
            let locked = isPairLocked(pair)
            HydraPairListRow(
                pair: pair,
                title: HydraPairSummary.title(pair, registry: model.providers),
                detail: locked ? (switchBlocker ?? "") : detail(for: pair, temporary: temporary),
                rowHeight: Self.pairRowHeight,
                isSelected: isPairSelected(pair, temporary: temporary, recent: recent, leadsWithTemporaryPair: leadsWithTemporaryPair),
                isHighlighted: isHighlighted,
                isEnabled: !locked
            ) {
                activate(row)
            }
            .help(locked ? (switchBlocker ?? "") : "")
        case .newTemporaryPair:
            NewTemporaryPairListRow(rowHeight: Self.pairRowHeight, isHighlighted: isHighlighted) {
                activate(row)
            }
        case .entry(let entry, _):
            let locked = isLocked(entry)
            ModelListRow(
                entry: entry,
                // A model listed on two routes here says which route under its name.
                detail: locked ? switchBlocker : ([showsProviders ? entry.provider.displayName : nil, routeShown(entry, in: rows, allEntries: allEntries)].compactMap { $0 }.joined(separator: " · ").nilIfEmpty),
                showsIcon: showsProviders,
                rowHeight: rowHeight,
                isSelected: !leadsWithPair && entry.provider == thread.provider && entry.option.id == currentModelID,
                isHighlighted: isHighlighted,
                isEnabled: !locked
            ) {
                activate(row)
            }
            .help(locked ? (switchBlocker ?? "") : "")
        case .section(let section, let hiddenCount):
            headingRow(
                Text(verbatim: section.name),
                id: row.id,
                weight: .medium,
                style: .subheadline,
                collapsed: model.settings.isModelSectionCollapsed(section.id),
                count: hiddenCount > 0 ? hiddenCount : nil,
                height: Self.sectionHeaderHeight,
                isHighlighted: false
            ) {
                model.settings.toggleModelSectionCollapsed(section.id)
            }
        case .otherFold(let count):
            headingRow(
                Text(verbatim: Chrome.localized(hasHistory ? "Other models · Switch with handoff" : "Other models · New chats only")),
                id: row.id,
                weight: .bold,
                style: .callout,
                collapsed: !showsOtherModels,
                count: count,
                height: 34,
                isHighlighted: isHighlighted
            ) {
                activate(row)
            }
        case .emptyGroup:
            Text(verbatim: Chrome.localized("No models in this group"))
                .font(.ui(.body))
                .foregroundStyle(Chrome.secondaryText)
                .padding(10)
                .frame(height: rowHeight)
        case .noPairsMatch:
            Text(verbatim: Chrome.localized("No combos match"))
                .font(.ui(.body))
                .foregroundStyle(Chrome.secondaryText)
                .padding(10)
                .frame(height: rowHeight)
        case .empty(let searching):
            Text(verbatim: Chrome.localized(searching ? "No models match" : "Loading models…"))
                .font(.ui(.body))
                .foregroundStyle(Chrome.secondaryText)
                .padding(10)
                .frame(height: rowHeight)
        }
    }

    // MARK: - Grouped mode

    private func resolvedEntry(for pin: ModelPin, in entries: [ModelCatalog.Entry]) -> ModelCatalog.Entry? {
        if let exact = entries.first(where: { $0.provider == pin.provider && $0.option.id == pin.modelID }) {
            return exact
        }
        guard let option = model.providers.model(pin.modelID, for: pin.provider) else { return nil }
        return entries.first(where: { $0.provider == pin.provider && $0.option.id == option.id })
    }

    private func partitionedGroups(entries: [ModelCatalog.Entry]) -> (groups: [GroupBlock], ungrouped: [ModelCatalog.Entry]) {
        let items = model.settings.modelListItems
        var groups: [GroupBlock] = []
        var ungroupedPinned: [ModelCatalog.Entry] = []
        var placedIDs: Set<String> = []

        for item in items {
            switch item {
            case .section(let section):
                groups.append(GroupBlock(section: section, entries: []))
            case .pin(let pin):
                guard let entry = resolvedEntry(for: pin, in: entries),
                      placedIDs.insert(entry.id).inserted else { continue }
                if groups.isEmpty {
                    ungroupedPinned.append(entry)
                } else {
                    groups[groups.count - 1].entries.append(entry)
                }
            }
        }
        let unpinned = entries.filter { placedIDs.insert($0.id).inserted }
        return (groups, unpinned + ungroupedPinned)
    }

    private func buildCategories(
        groups: [GroupBlock],
        ungrouped: [ModelCatalog.Entry],
        pairs: [HydraPair],
        activeTemporaryPair: HydraPair?,
        showsPairs: Bool
    ) -> [CategoryItem] {
        let totalModelCount = groups.reduce(0) { $0 + $1.entries.count } + ungrouped.count
        var result: [CategoryItem] = [
            CategoryItem(
                category: .all,
                title: Chrome.localized("All"),
                count: totalModelCount,
                icon: .all
            )
        ]
        for group in groups {
            result.append(
                CategoryItem(
                    category: .group(group.id),
                    title: group.section.name,
                    count: group.entries.count,
                    icon: group.entries.first.map { .provider($0.provider) } ?? .emptyGroup
                )
            )
        }
        if !ungrouped.isEmpty {
            result.append(
                CategoryItem(
                    category: .ungrouped,
                    title: Chrome.localized("Ungrouped"),
                    count: ungrouped.count,
                    icon: ungrouped.first.map { .provider($0.provider) } ?? .emptyGroup
                )
            )
        }
        if showsPairs {
            let firstPair = activeTemporaryPair ?? pairs.first
            let comboIcon: CategoryIcon = if let firstPair {
                .pair(lead: firstPair.provider, heads: model.hydraHeadsProvider(of: firstPair))
            } else {
                .hydra
            }
            result.append(
                CategoryItem(
                    category: .combos,
                    title: Chrome.localized("Combos"),
                    count: pairs.count + (activeTemporaryPair == nil ? 0 : 1),
                    icon: comboIcon
                )
            )
        }
        return result
    }

    private func defaultCategory(
        groups: [GroupBlock],
        showsPairs: Bool,
        leadsWithPair: Bool,
        currentModelID: String?
    ) -> Category {
        if leadsWithPair, showsPairs {
            return .combos
        }
        if let currentModelID,
           let match = groups.first(where: { group in
               group.entries.contains { $0.provider == thread.provider && $0.option.id == currentModelID }
           }) {
            return .group(match.id)
        }
        return .all
    }

    private func resolvedCategory(available: [CategoryItem], fallback: Category) -> Category {
        if let selectedCategory, available.contains(where: { $0.category == selectedCategory }) {
            return selectedCategory
        }
        return fallback
    }

    private func groupedCategoryRows(
        for category: Category,
        groups: [GroupBlock],
        ungrouped: [ModelCatalog.Entry],
        pairs: [HydraPair],
        activeTemporaryPair: HydraPair?,
        showsOtherModels: Bool
    ) -> [DisplayRow] {
        switch category {
        case .all:
            let allEntries = groups.flatMap(\.entries) + ungrouped
            let selectable = allEntries.filter { !hasHistory || $0.provider == thread.provider }
            let other = allEntries.filter { hasHistory && $0.provider != thread.provider }
            var rows: [DisplayRow] = []
            let recents = recentRows(selectable: selectable, pairs: pairs)
            if !recents.isEmpty {
                rows.append(.header("Recent"))
                rows.append(contentsOf: recents)
                if !selectable.isEmpty {
                    rows.append(.header("Models"))
                }
            }
            rows.append(contentsOf: selectable.map { .entry($0, recent: false) })
            if !other.isEmpty {
                rows.append(.otherFold(other.count))
                if showsOtherModels {
                    rows.append(contentsOf: other.map { .entry($0, recent: false) })
                }
            }
            if allEntries.isEmpty {
                rows.append(.empty(searching: false))
            }
            return rows

        case .group(let sectionID):
            let groupEntries = groups.first(where: { $0.id == sectionID })?.entries ?? []
            guard !groupEntries.isEmpty else { return [.emptyGroup] }
            return scopedModelRows(from: groupEntries, showsOtherModels: showsOtherModels)

        case .ungrouped:
            guard !ungrouped.isEmpty else { return [.empty(searching: false)] }
            return scopedModelRows(from: ungrouped, showsOtherModels: showsOtherModels)

        case .combos:
            var rows: [DisplayRow] = []
            if !hasHistory, model.hydraIsOn(thread), let stored = model.settings.lastNewChatPair {
                if let saved = model.settings.hydraPair(stored.id), pairs.contains(where: { $0.id == saved.id }) {
                    rows.append(.header("Recent"))
                    rows.append(.pair(saved, temporary: false, recent: true))
                    rows.append(.header("Combos"))
                } else if model.settings.hydraPair(stored.id) == nil, stored.id != activeTemporaryPair?.id {
                    rows.append(.header("Recent"))
                    rows.append(.pair(stored, temporary: true, recent: true))
                    rows.append(.header("Combos"))
                }
            }
            if let activeTemporaryPair {
                rows.append(.pair(activeTemporaryPair, temporary: true, recent: false))
            }
            rows.append(contentsOf: pairs.map { .pair($0, temporary: false, recent: false) })
            if !hasHistory, model.hydraIsOn(thread) {
                rows.append(.newTemporaryPair)
            }
            return rows
        }
    }

    private func scopedModelRows(from entries: [ModelCatalog.Entry], showsOtherModels: Bool) -> [DisplayRow] {
        let selectable = entries.filter { !hasHistory || $0.provider == thread.provider }
        let other = entries.filter { hasHistory && $0.provider != thread.provider }
        var rows = selectable.map { DisplayRow.entry($0, recent: false) }
        if !other.isEmpty {
            rows.append(.otherFold(other.count))
            if showsOtherModels {
                rows.append(contentsOf: other.map { .entry($0, recent: false) })
            }
        }
        return rows
    }

    private func groupedSearchRows(
        entries: [ModelCatalog.Entry],
        searchEntries: [ModelCatalog.Entry],
        groups: [GroupBlock],
        ungrouped: [ModelCatalog.Entry],
        pairs: [HydraPair],
        activeTemporaryPair: HydraPair?,
        showsPairs: Bool,
        query: String
    ) -> [DisplayRow] {
        var rows: [DisplayRow] = []
        for group in groups {
            let matches = matchingModelEntries(in: group.entries, query: query)
            if !matches.isEmpty {
                rows.append(.searchHeader(id: "group/\(group.id.uuidString)", title: group.section.name))
                rows.append(contentsOf: matches.map { .entry($0, recent: false) })
            }
        }
        let ungroupedMatches = matchingModelEntries(in: ungrouped, query: query)
        if !ungroupedMatches.isEmpty {
            rows.append(.searchHeader(id: "ungrouped", title: Chrome.localized("Ungrouped")))
            rows.append(contentsOf: ungroupedMatches.map { .entry($0, recent: false) })
        }
        if showsPairs {
            let comboMatches = matchingComboRows(pairs: pairs, activeTemporaryPair: activeTemporaryPair, query: query)
            if !comboMatches.isEmpty {
                rows.append(.searchHeader(id: "combos", title: Chrome.localized("Combos")))
                rows.append(contentsOf: comboMatches)
            }
        }
        let entryIDs = Set(entries.map(\.id))
        let extraCandidates = searchEntries.filter { !entryIDs.contains($0.id) }
        let extraMatches = matchingModelEntries(in: extraCandidates, query: query)
        if !extraMatches.isEmpty {
            rows.append(.searchHeader(id: "other-models", title: Chrome.localized("Other models")))
            rows.append(contentsOf: extraMatches.map { .entry($0, recent: false) })
        }
        return rows.isEmpty ? [.empty(searching: true)] : rows
    }

    private func matchingModelEntries(in source: [ModelCatalog.Entry], query: String) -> [ModelCatalog.Entry] {
        let selectable = source.filter { !hasHistory || $0.provider == thread.provider }
        let other = source.filter { hasHistory && $0.provider != thread.provider }
        return (selectable + other).filter {
            ModelsSettingsPage.matches($0.option, id: $0.option.id, provider: $0.provider, query: query)
        }
    }

    private func matchingComboRows(
        pairs: [HydraPair],
        activeTemporaryPair: HydraPair?,
        query: String
    ) -> [DisplayRow] {
        var candidates: [(pair: HydraPair, temporary: Bool, recent: Bool)] = []
        var listedIDs: Set<UUID> = []
        if let activeTemporaryPair {
            candidates.append((activeTemporaryPair, true, false))
            listedIDs.insert(activeTemporaryPair.id)
        }
        for pair in pairs where listedIDs.insert(pair.id).inserted {
            candidates.append((pair, false, false))
        }
        if !hasHistory, model.hydraIsOn(thread),
           let stored = model.settings.lastNewChatPair,
           model.settings.hydraPair(stored.id) == nil,
           listedIDs.insert(stored.id).inserted {
            candidates.append((stored, true, true))
        }
        return candidates.compactMap { item in
            let matches = HydraPairSummary.title(item.pair, registry: model.providers).localizedCaseInsensitiveContains(query)
                || detail(for: item.pair, temporary: item.temporary).localizedCaseInsensitiveContains(query)
            return matches ? .pair(item.pair, temporary: item.temporary, recent: item.recent) : nil
        }
    }

    private func recentRows(selectable: [ModelCatalog.Entry], pairs: [HydraPair]) -> [DisplayRow] {
        guard !hasHistory else { return [] }
        var recents: [DisplayRow] = []
        if model.hydraIsOn(thread), let stored = model.settings.lastNewChatPair {
            if let saved = model.settings.hydraPair(stored.id), pairs.contains(where: { $0.id == saved.id }) {
                recents.append(.pair(saved, temporary: false, recent: true))
            } else if model.settings.hydraPair(stored.id) == nil {
                recents.append(.pair(stored, temporary: true, recent: true))
            }
        }
        if let pin = model.settings.lastNewChatModel,
           let entry = resolvedEntry(for: pin, in: selectable) {
            recents.append(.entry(entry, recent: true))
        }
        return recents
    }

    // MARK: - Keyboard navigation

    private func isPairLocked(_ pair: HydraPair) -> Bool {
        hasHistory && pair.provider != thread.provider && switchBlocker != nil
    }

    private func isPairSelected(_ pair: HydraPair, temporary: Bool, recent: Bool, leadsWithTemporaryPair: Bool) -> Bool {
        temporary
            ? (!recent || model.leadsWithHydraPair(pair, thread: thread))
            : (!leadsWithTemporaryPair && model.leadsWithHydraPair(pair, thread: thread))
    }

    private func isInteractive(_ row: DisplayRow) -> Bool {
        switch row {
        case .entry(let entry, _):
            return !isLocked(entry)
        case .pair(let pair, _, _):
            return !isPairLocked(pair)
        case .newTemporaryPair, .otherFold:
            return true
        case .header, .searchHeader, .section, .empty, .emptyGroup, .noPairsMatch:
            return false
        }
    }

    private func preferredHighlightID(
        in rows: [DisplayRow],
        isSearching: Bool,
        leadsWithPair: Bool,
        leadsWithTemporaryPair: Bool,
        currentModelID: String?
    ) -> String? {
        let interactive = rows.filter(isInteractive)
        guard !interactive.isEmpty else { return nil }
        if isSearching {
            return interactive.first?.id
        }
        if let activeNonRecent = interactive.first(where: { row in
            switch row {
            case .pair(let pair, let temporary, false):
                return isPairSelected(pair, temporary: temporary, recent: false, leadsWithTemporaryPair: leadsWithTemporaryPair)
            case .entry(let entry, false):
                return !leadsWithPair && entry.provider == thread.provider && entry.option.id == currentModelID
            default:
                return false
            }
        }) {
            return activeNonRecent.id
        }
        if let activeAny = interactive.first(where: { row in
            switch row {
            case .pair(let pair, let temporary, let recent):
                return isPairSelected(pair, temporary: temporary, recent: recent, leadsWithTemporaryPair: leadsWithTemporaryPair)
            case .entry(let entry, _):
                return !leadsWithPair && entry.provider == thread.provider && entry.option.id == currentModelID
            default:
                return false
            }
        }) {
            return activeAny.id
        }
        return interactive.first {
            if case .otherFold = $0 { return false }
            return true
        }?.id ?? interactive.first?.id
    }

    private func moveHighlight(by offset: Int, in rows: [DisplayRow]) {
        let interactive = rows.filter(isInteractive)
        guard !interactive.isEmpty else {
            highlightedRowID = nil
            return
        }
        let nextID: String
        if let current = highlightedRowID,
           let index = interactive.firstIndex(where: { $0.id == current }) {
            let clamped = min(max(0, index + offset), interactive.count - 1)
            nextID = interactive[clamped].id
        } else {
            nextID = offset < 0 ? interactive[interactive.count - 1].id : interactive[0].id
        }
        highlightedRowID = nextID
        requestRightScroll(to: nextID, anchor: .automatic)
    }

    private func moveCategory(by offset: Int, categories: [CategoryItem], current: Category) {
        guard !categories.isEmpty else { return }
        let index = categories.firstIndex(where: { $0.category == current }) ?? 0
        let clamped = min(max(0, index + offset), categories.count - 1)
        let next = categories[clamped].category
        guard next != current else { return }
        selectedCategory = next
        searchIsFocused = true
    }

    @discardableResult
    private func submitHighlighted(in rows: [DisplayRow]) -> Bool {
        let interactive = rows.filter(isInteractive)
        guard let target = highlightedRowID.flatMap({ id in interactive.first { $0.id == id } }) ?? interactive.first else {
            return false
        }
        activate(target)
        return true
    }

    private func activate(_ row: DisplayRow) {
        switch row {
        case .entry(let entry, _):
            guard !isLocked(entry) else { return }
            onChoose(entry)
        case .pair(let pair, let temporary, let recent):
            guard !isPairLocked(pair) else { return }
            if temporary {
                if recent { onEnterTemporaryPair(pair) }
                else { onEditTemporaryPair() }
            } else {
                onEnterPair(pair)
            }
        case .newTemporaryPair:
            model.startTemporaryHydraPair(for: thread.id)
            onEditTemporaryPair()
        case .otherFold:
            showsOtherModels.toggle()
            searchIsFocused = true
        case .header, .searchHeader, .section, .empty, .emptyGroup, .noPairsMatch:
            break
        }
    }

    private func requestRightScroll(to id: String, anchor: ScrollAnchor) {
        scrollNonce &+= 1
        rightScrollRequest = ScrollRequest(id: id, anchor: anchor, nonce: scrollNonce)
    }

    private func requestLeftScroll(to id: String, anchor: ScrollAnchor) {
        scrollNonce &+= 1
        leftScrollRequest = ScrollRequest(id: id, anchor: anchor, nonce: scrollNonce)
    }

    // MARK: - Unchanged single-list layout

    private func pairRows(pairs: [HydraPair], query: String) -> [DisplayRow] {
        let rows = displayRows(entries: [], searchEntries: [], pairs: pairs, query: "").filter {
            switch $0 {
            case .pair, .newTemporaryPair: return true
            default: return false
            }
        }
        if !query.isEmpty {
            // A recent pair also listed under Pairs shows once; one only in Recent stays.
            let listed = Set(rows.compactMap { row -> UUID? in
                if case .pair(let pair, _, false) = row { return pair.id }
                return nil
            })
            let matches = rows.filter {
                guard case .pair(let pair, let temporary, let recent) = $0,
                      !(recent && listed.contains(pair.id)) else { return false }
                return HydraPairSummary.title(pair, registry: model.providers).localizedCaseInsensitiveContains(query)
                    || detail(for: pair, temporary: temporary).localizedCaseInsensitiveContains(query)
            }
            return matches.isEmpty ? [.noPairsMatch] : matches
        }
        var result: [DisplayRow] = []
        for row in rows {
            if case .pair(_, _, true) = row {
                result.append(.header("Recent"))
                result.append(row)
            }
        }
        result.append(.header("Combos"))
        result.append(contentsOf: rows.filter {
            if case .pair(_, _, true) = $0 { return false }
            return true
        })
        return result
    }

    private func modelColumnRows(entries: [ModelCatalog.Entry], searchEntries: [ModelCatalog.Entry], query: String) -> [DisplayRow] {
        displayRows(entries: entries, searchEntries: searchEntries, pairs: [], query: query).filter {
            switch $0 {
            case .pair, .newTemporaryPair: return false
            case .header(let title):
                if title == "Combos" { return false }
                let hasRecentModel = !hasHistory && entries.contains {
                    !isLocked($0) && $0.provider == model.settings.lastNewChatModel?.provider
                        && $0.option.id == model.settings.lastNewChatModel?.modelID
                }
                return hasRecentModel
            default: return true
            }
        }
    }

    private var switchBlocker: String? {
        model.existingRuntime(for: thread.id)?.providerSwitchBlocker
    }

    private func isLocked(_ entry: ModelCatalog.Entry) -> Bool {
        hasHistory && entry.provider != thread.provider && switchBlocker != nil
    }

    private func displayRows(entries: [ModelCatalog.Entry], searchEntries: [ModelCatalog.Entry], pairs: [HydraPair], query: String) -> [DisplayRow] {
        let displayedEntries = query.isEmpty ? entries : searchEntries
        let selectable = displayedEntries.filter { !hasHistory || $0.provider == thread.provider }
        let locked = displayedEntries.filter { hasHistory && $0.provider != thread.provider }
        if !query.isEmpty {
            let matches = (selectable + locked).filter {
                ModelsSettingsPage.matches($0.option, id: $0.option.id, provider: $0.provider, query: query)
            }
            return matches.isEmpty ? [.empty(searching: true)] : matches.map { .entry($0, recent: false) }
        }

        var rows: [DisplayRow] = []
        // Recent: the last pair and the last model new chats started on, each when there is one.
        let recents = recentRows(selectable: selectable, pairs: pairs)
        let recent = recents.first
        if !recents.isEmpty {
            rows.append(.header("Recent"))
            rows.append(contentsOf: recents)
        }
        let showsTemporaryRows = !hasHistory && model.hydraIsOn(thread)
        let showsPairs = !pairs.isEmpty || showsTemporaryRows
        if showsPairs {
            rows.append(.header("Combos"))
            if showsTemporaryRows, let pair = model.temporaryHydraPair(for: thread) {
                rows.append(.pair(pair, temporary: true, recent: false))
            }
            rows.append(contentsOf: pairs.map { .pair($0, temporary: false, recent: false) })
            if showsTemporaryRows { rows.append(.newTemporaryPair) }
        }
        if showsPairs || recent != nil { rows.append(.header("Models")) }
        rows.append(contentsOf: modelRows(entries: selectable))
        if !locked.isEmpty {
            rows.append(.otherFold(locked.count))
            if showsOtherModels { rows.append(contentsOf: locked.map { .entry($0, recent: false) }) }
        }
        if entries.isEmpty { rows.append(.empty(searching: false)) }
        return rows
    }

    private func modelRows(entries: [ModelCatalog.Entry]) -> [DisplayRow] {
        let items = model.settings.modelListItems
        guard !model.settings.modelList.isEmpty,
              items.contains(where: { if case .section = $0 { return true }; return false }) else {
            return entries.map { .entry($0, recent: false) }
        }
        let pinnedIDs = Set(items.compactMap { item -> String? in
            if case .pin(let pin) = item { return pin.id }
            return nil
        })
        var rows = entries.filter { !pinnedIDs.contains($0.id) }.map { DisplayRow.entry($0, recent: false) }
        var section: ModelSection?
        var sectionEntries: [ModelCatalog.Entry] = []
        for item in items {
            switch item {
            case .pin(let pin):
                if let entry = entries.first(where: { $0.provider == pin.provider && $0.option.id == pin.modelID }) {
                    sectionEntries.append(entry)
                }
            case .section(let next):
                appendSection(section, entries: sectionEntries, to: &rows)
                section = next
                sectionEntries = []
            }
        }
        appendSection(section, entries: sectionEntries, to: &rows)
        return rows
    }

    private func appendSection(_ section: ModelSection?, entries: [ModelCatalog.Entry], to rows: inout [DisplayRow]) {
        guard !entries.isEmpty else { return }
        if let section {
            let collapsed = model.settings.isModelSectionCollapsed(section.id)
            rows.append(.section(section, hiddenCount: collapsed ? entries.count : 0))
            if collapsed { return }
        }
        rows.append(contentsOf: entries.map { .entry($0, recent: false) })
    }

    /// The route a row names under its model, when the picker also holds the same model of
    /// that provider on another route.
    private func routeShown(_ entry: ModelCatalog.Entry, in rows: [DisplayRow], allEntries: [ModelCatalog.Entry]) -> String? {
        var others = allEntries.filter { $0.provider == entry.provider }.map(\.option)
        for row in rows {
            if case .entry(let other, _) = row, other.provider == entry.provider,
               !others.contains(where: { $0.id == other.option.id }) {
                others.append(other.option)
            }
        }
        return entry.option.label(among: others) == entry.option.shortName ? nil : entry.option.group
    }

    private func headingRow(
        _ title: Text,
        id: String,
        weight: Font.Weight,
        style: Font.TextStyle,
        collapsed: Bool,
        count: Int?,
        height: CGFloat,
        isHighlighted: Bool,
        action: @escaping () -> Void
    ) -> some View {
        let isHovering = hoveredHeading == id
        return Button(action: action) {
            HStack(spacing: 6) {
                title
                    .lineLimit(1)
                DisclosureChevron(collapsed: collapsed, hovering: isHovering)
                Spacer()
                if let count { Text(verbatim: "\(count)") }
            }
            .font(.ui(style, weight: weight))
            .foregroundStyle(Chrome.secondaryText)
            .padding(.horizontal, 8)
            .padding(.top, 6)
            .padding(.bottom, 3)
            .frame(height: height)
            .background {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(isHighlighted ? Chrome.overlay(0.1) : (isHovering ? Chrome.overlay(0.06) : Color.clear))
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hoveredHeading = $0 ? id : (hoveredHeading == id ? nil : hoveredHeading) }
        .accessibilityValue(Text(verbatim: Chrome.localized(collapsed ? "Collapsed" : "Expanded")))
        .accessibilityAddTraits(isHighlighted ? .isSelected : [])
    }

    /// The line under a pair's title: the providers, and the efforts when any is set. The
    /// title names the models, so this never repeats them, unless the user named the pair:
    /// then the title is that name and the models come first here.
    private func detail(for pair: HydraPair, temporary: Bool = false) -> String {
        hydraPairDetail(pair, temporary: temporary, model: model)
    }
}

private struct GroupNavRow: View {
    let item: ModelList.CategoryItem
    let isSelected: Bool
    let isEnabled: Bool
    let rowHeight: CGFloat
    let action: () -> Void

    @State private var isHovering = false

    private var fill: Color {
        if isSelected { return Chrome.overlay(0.12) }
        if isHovering && isEnabled { return Chrome.overlay(0.06) }
        return .clear
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Chrome.rowCornerRadius, style: .continuous)
        Button(action: action) {
            HStack(spacing: 6) {
                leadingIcon
                    .frame(width: 15, height: 15, alignment: .center)
                Text(verbatim: item.title)
                    .font(.ui(.callout, weight: isSelected ? .medium : .regular))
                    .foregroundStyle(Chrome.primaryText.opacity(isSelected ? 1 : 0.88))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                Text(verbatim: "\(item.count)")
                    .font(.ui(size: 11).monospacedDigit())
                    .foregroundStyle(Chrome.secondaryText)
                    .fixedSize()
            }
            .padding(.horizontal, 7)
            .frame(height: rowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                shape
                    .fill(fill)
                    .animation(Chrome.hover, value: isSelected)
                    .animation(Chrome.hover, value: isHovering)
            }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .focusable(false)
        .disabled(!isEnabled)
        .onHover { hovering in
            guard isHovering != hovering else { return }
            isHovering = hovering
        }
        .help(Text(verbatim: item.title))
        .accessibilityLabel(Text(verbatim: "\(item.title), \(item.count)"))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder
    private var leadingIcon: some View {
        switch item.icon {
        case .all:
            Image(systemName: "square.grid.2x2")
                .font(.ui(size: 12, weight: .medium))
                .foregroundStyle(Chrome.primaryText.opacity(isSelected ? 0.95 : 0.78))
        case .provider(let provider):
            ProviderIcon(provider: provider, size: 13)
                .foregroundStyle(Chrome.primaryText.opacity(isSelected ? 0.95 : 0.8))
        case .emptyGroup:
            Image(systemName: "square.stack")
                .font(.ui(size: 12, weight: .medium))
                .foregroundStyle(Chrome.secondaryText)
        case .pair(let lead, let heads):
            HydraFusedPairIcon(lead: lead, heads: heads, size: 13, animates: false)
        case .hydra:
            HydraMarkImage()
                .foregroundStyle(Chrome.primaryText.opacity(isSelected ? 0.95 : 0.8))
                .frame(width: 13, height: 13)
        }
    }
}

private struct ModelListKeyMonitor: NSViewRepresentable {
    var onMoveRow: (Int) -> Void
    var onMoveGroup: (Int) -> Bool
    var onSubmit: () -> Bool

    func makeNSView(context: Context) -> ModelListKeyMonitorHost {
        let view = ModelListKeyMonitorHost()
        view.onMoveRow = onMoveRow
        view.onMoveGroup = onMoveGroup
        view.onSubmit = onSubmit
        return view
    }

    func updateNSView(_ nsView: ModelListKeyMonitorHost, context: Context) {
        nsView.onMoveRow = onMoveRow
        nsView.onMoveGroup = onMoveGroup
        nsView.onSubmit = onSubmit
    }
}

private final class ModelListKeyMonitorHost: NSView {
    var onMoveRow: (Int) -> Void = { _ in }
    var onMoveGroup: (Int) -> Bool = { _ in false }
    var onSubmit: () -> Bool = { false }
    private var monitor: Any?

    deinit { MainActor.assumeIsolated { removeMonitor() } }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { removeMonitor() } else { installMonitor() }
    }

    private func installMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.handle(event) else { return event }
            return nil
        }
    }

    private func removeMonitor() {
        guard let monitor else { return }
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
    }

    private func handle(_ event: NSEvent) -> Bool {
        guard let window, event.window === window, !isHiddenOrHasHiddenAncestor else { return false }
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard modifiers.isEmpty else { return false }
        if let textView = window.firstResponder as? NSTextView, textView.hasMarkedText() {
            return false
        }
        switch event.keyCode {
        case 126: // Up arrow
            onMoveRow(-1)
            return true
        case 125: // Down arrow
            onMoveRow(1)
            return true
        case 123: // Left arrow
            if let textView = window.firstResponder as? NSTextView, !textView.string.isEmpty {
                return false
            }
            return onMoveGroup(-1)
        case 124: // Right arrow
            if let textView = window.firstResponder as? NSTextView, !textView.string.isEmpty {
                return false
            }
            return onMoveGroup(1)
        case 36, 76: // Return, keypad Enter
            return onSubmit()
        default:
            return false
        }
    }
}

@MainActor
private func hydraPairDetail(_ pair: HydraPair, temporary: Bool = false, model: AppModel) -> String {
    let models = pair.customName == nil ? nil : HydraPairSummary.modelsTitle(pair, registry: model.providers)
    let detail = [models, HydraPairSummary.providers(pair), HydraPairSummary.efforts(pair)].compactMap { $0 }.joined(separator: " · ")
    return temporary ? detail + " · " + Chrome.localized("Temporary") : detail
}

private struct NewTemporaryPairListRow: View {
    let rowHeight: CGFloat
    var isHighlighted = false
    let action: () -> Void

    @State private var isHovering = false

    private var rowFill: Color {
        if isHighlighted { return Chrome.overlay(0.1) }
        if isHovering { return Chrome.overlay(0.06) }
        return .clear
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "plus")
                    .font(.ui(.body))
                    .frame(width: 16)
                Text("New temporary combo")
                    .font(.ui(size: 13))
                    .lineLimit(1)
                Spacer(minLength: 12)
            }
            .foregroundStyle(Chrome.secondaryText)
            .padding(.horizontal, 10)
            .frame(height: rowHeight)
            .background {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(rowFill)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(Chrome.hover) { isHovering = hovering }
        }
        .accessibilityAddTraits(isHighlighted ? .isSelected : [])
    }
}

/// One Hydra pair in the model picker: the fused mark of lead and heads, who leads
/// whom, and the provider with the heads' model under it. Tapping it puts the chat in
/// the pair.
private struct HydraPairListRow: View {
    let pair: HydraPair
    let title: String
    let detail: String
    let rowHeight: CGFloat
    let isSelected: Bool
    var isHighlighted = false
    let isEnabled: Bool
    let action: () -> Void

    @State private var isHovering = false

    private var rowFill: Color {
        if isHighlighted && isEnabled { return Chrome.overlay(0.1) }
        if isHovering && isEnabled { return Chrome.overlay(0.06) }
        return .clear
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                HydraFusedPairIcon(lead: pair.provider, heads: pair.headsProvider, size: 15, animates: false)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: title)
                        .font(.ui(size: 13))
                        .foregroundStyle(Chrome.primaryText)
                        .lineLimit(1)
                    Text(verbatim: Chrome.localized(detail))
                        .font(.ui(.subheadline))
                        .foregroundStyle(Chrome.secondaryText)
                        .lineLimit(1)
                }
                Spacer(minLength: 12)
                Image(systemName: "checkmark")
                    .font(.ui(.callout, weight: .semibold))
                    .foregroundStyle(Chrome.primaryText)
                    .opacity(isSelected ? 1 : 0)
            }
            .padding(.horizontal, 10)
            .frame(height: rowHeight)
            .background {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(rowFill)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.45)
        .onHover { hovering in
            withAnimation(Chrome.hover) { isHovering = hovering }
        }
        .accessibilityAddTraits(isHighlighted ? .isSelected : [])
    }
}

private struct ModelListRow: View {
    let entry: ModelCatalog.Entry
    let detail: String?
    let showsIcon: Bool
    let rowHeight: CGFloat
    let isSelected: Bool
    var isHighlighted = false
    let isEnabled: Bool
    let action: () -> Void

    @State private var isHovering = false

    private var rowFill: Color {
        if isHighlighted && isEnabled { return Chrome.overlay(0.1) }
        if isHovering && isEnabled { return Chrome.overlay(0.06) }
        return .clear
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if showsIcon {
                    ProviderIcon(provider: entry.provider, size: 13)
                        .foregroundStyle(Chrome.secondaryText)
                        .frame(width: 16)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: entry.option.shortName)
                        .font(.ui(size: 13))
                        .foregroundStyle(Chrome.primaryText)
                    if let detail {
                        Text(verbatim: detail)
                            .font(.ui(.subheadline))
                            .foregroundStyle(Chrome.secondaryText)
                    }
                }
                Spacer(minLength: 12)
                if entry.option.supportsFast {
                    Image(systemName: "bolt")
                        .font(.ui(.footnote))
                        .foregroundStyle(Chrome.secondaryText)
                }
                Image(systemName: "checkmark")
                    .font(.ui(.callout, weight: .semibold))
                    .foregroundStyle(Chrome.primaryText)
                    .opacity(isSelected ? 1 : 0)
            }
            .padding(.horizontal, 10)
            .frame(height: rowHeight)
            .background {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(rowFill)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.45)
        .onHover { hovering in
            withAnimation(Chrome.hover) { isHovering = hovering }
        }
        .accessibilityAddTraits(isHighlighted ? .isSelected : [])
    }
}

// MARK: - Slider card

/// Fast mode, the model line (which opens the model list), the effort title and the effort slider.
/// What the slider shows while the chat leads a pair: the pair in words, the colours its
/// fusion runs between, and what the heads' effort is, for the line that says the slider
/// sets the lead's.
struct EffortPairLook: Hashable {
    /// "Fable + Opus (1M context)".
    var title: String
    var brand: EffortPairBrand
    /// The heads' effort by name, when the pair sets one.
    var headsEffort: String?

    @MainActor
    init(_ pair: HydraPair, registry: ProviderRegistry, resolvedHeadsEffort: String?) {
        title = HydraPairSummary.title(pair, registry: registry)
        brand = EffortPairBrand(pair)
        headsEffort = (pair.workerEffort ?? resolvedHeadsEffort).map { Chrome.localizedLowercased(ModelOption.effortTitle($0)) }
    }

    /// Whose effort the slider sets, and what the sub-agents run at.
    var caption: String {
        if let headsEffort { return String(format: Chrome.localized("The lead's effort · sub-agents run at %@ effort"), headsEffort) }
        return Chrome.localized("The lead's effort · sub-agents keep their own")
    }
}

struct EffortSliderCard: View {
    let modelName: String
    let provider: ProviderKind?
    /// The pair the chat leads with, if one: the card is the lead's then.
    var pair: EffortPairLook? = nil
    let efforts: [String]
    let defaultEffort: String?
    let supportsFast: Bool
    @Binding var effort: String?
    @Binding var fastMode: Bool
    var dshMode: Binding<DshAgentMode>? = nil
    var threadID: UUID? = nil
    var hasHistory = false
    var onTitleTap: (() -> Void)?

    @State private var isTitleHovering = false

    private var resolvedIndex: Int {
        if let effort, let index = efforts.firstIndex(of: effort) { return index }
        if let defaultEffort, let index = efforts.firstIndex(of: defaultEffort) { return index }
        return efforts.firstIndex(of: "medium") ?? 0
    }

    private var isMaxEffort: Bool {
        efforts.count > 1 && resolvedIndex == efforts.count - 1
    }

    private var title: String {
        guard !efforts.isEmpty else { return Chrome.localized("Standard") }
        return Chrome.localized(ModelOption.effortTitle(efforts[resolvedIndex]))
    }

    private var isFast: Bool { supportsFast && fastMode }

    private var brand: EffortBrand { EffortBrand(provider: provider) }

    /// The title takes the slider's colour: the provider's brand at maximum, gold in
    /// fast mode, and both blended when the two are on together. In a pair it runs from
    /// the lead's colour into the heads', like the track, gold at the end in fast mode.
    private var titleStyle: AnyShapeStyle {
        if let pair {
            var colors = [brand.titleColor] + pair.brand.titleColors
            if isFast { colors.append(EffortPalette.fast) }
            return AnyShapeStyle(LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing))
        }
        switch (isMaxEffort, isFast) {
        case (true, true): return AnyShapeStyle(LinearGradient(colors: [brand.titleColor, EffortPalette.fast], startPoint: .leading, endPoint: .trailing))
        case (true, false): return brand.title
        case (false, true): return AnyShapeStyle(EffortPalette.fast)
        case (false, false): return AnyShapeStyle(EffortPalette.title)
        }
    }

    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                if supportsFast {
                    HStack {
                        FastModeButton(isOn: $fastMode)
                        Spacer()
                    }
                }
                VStack(spacing: 2) {
                    // The model line opens the model list, so the chevron follows the model;
                    // the effort title below names what the slider sets.
                    Button {
                        onTitleTap?()
                    } label: {
                        HStack(spacing: 5) {
                            // In a pair the line is the pair itself, behind the Hydra mark:
                            // the slider is the lead's, and the lead is named first.
                            if pair != nil {
                                HydraMarkImage()
                                    .foregroundStyle(Chrome.primaryText.opacity(0.75))
                                    .frame(width: 12, height: 12)
                            } else if let provider {
                                ProviderIcon(provider: provider, size: 12)
                            }
                            Text(verbatim: pair?.title ?? modelName)
                                .font(.ui(.body))
                                .foregroundStyle(Chrome.primaryText.opacity(0.7))
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .minimumScaleFactor(0.85)
                            if onTitleTap != nil {
                                Image(systemName: "chevron.right")
                                    .font(.ui(.caption, weight: .semibold))
                                    .foregroundStyle(Chrome.secondaryText)
                                    .fixedSize()
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(isTitleHovering && onTitleTap != nil ? Chrome.overlay(0.08) : Color.clear)
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .disabled(onTitleTap == nil)
                    .onHover { hovering in
                        withAnimation(Chrome.hover) { isTitleHovering = hovering }
                    }
                    .help(Text(verbatim: onTitleTap == nil ? "" : Chrome.localized("Choose a model")))

                    Text(verbatim: title)
                        .font(.ui(.title2, weight: .medium))
                        .contentTransition(.numericText())
                        .foregroundStyle(titleStyle)
                        .animation(.smooth(duration: 0.3), value: isMaxEffort)
                        .animation(.smooth(duration: 0.3), value: isFast)
                        // Picking Adaptive swaps the pair's gradient for a flat colour while the
                        // popover shrinks; unanimated, that swap left the title blank until redrawn.
                        .animation(.smooth(duration: 0.3), value: pair == nil)
                }
                .padding(.horizontal, supportsFast ? 38 : 0)
            }
            .frame(maxWidth: .infinity)

            if efforts.isEmpty {
                Text(verbatim: Chrome.localized(provider == .minimaxCode
                    ? "MiniMax Code has not advertised adjustable reasoning for this model."
                    : "This model has one reasoning level."))
                    .font(.ui(.callout))
                    .foregroundStyle(Chrome.secondaryText)
                    .frame(height: EffortSlider.thumbSize)
            } else {
                EffortSlider(
                    count: efforts.count,
                    index: Binding(
                        get: { resolvedIndex },
                        set: { index in
                            withAnimation(.snappy(duration: 0.2)) { effort = efforts[index] }
                        }
                    ),
                    fastMode: isFast,
                    brand: brand,
                    pair: pair?.brand,
                    accessibilityTitle: title
                )
            }

            if let dshMode, provider == .dsh {
                ChromeRow(title: "Agent mode") {
                    GlassPickerButton(
                        options: DshAgentMode.allCases.map { ($0, $0.title) },
                        selection: dshMode
                    )
                    .accessibilityLabel(Text("Agent mode"))
                }
            }

            if let threadID {
                SubagentsCardSection(
                    threadID: threadID,
                    hasHistory: hasHistory,
                    hasLeadEfforts: !efforts.isEmpty,
                    pairLook: pair
                )
            } else if let pair, !efforts.isEmpty {
                // Whose effort this is, so a pair's slider is never taken for the heads'.
                Text(verbatim: pair.caption)
                    .font(.ui(.subheadline))
                    .foregroundStyle(Chrome.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .minimumScaleFactor(0.9)
                    .padding(.top, -6)
                    .transition(.softAppear)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 16)
    }
}

private struct SubagentsCardSection: View {
    @Environment(AppModel.self) private var model
    let threadID: UUID
    let hasHistory: Bool
    let hasLeadEfforts: Bool
    let pairLook: EffortPairLook?

    @State private var isComboMenuPresented = false
    @State private var isIntroShown = false

    /// The combo the combo row offers: the active one, else the thread's temporary pairing,
    /// the last used, then the best match for the thread's provider and model.
    private func preferredPair(active: HydraPair?, temporary: HydraPair?, selectable: [HydraPair], thread: ChatThread) -> HydraPair? {
        if let active { return active }
        if let temporary { return temporary }
        if let last = model.settings.hydraPair(model.settings.lastHydraPairID),
           let match = selectable.first(where: { $0.id == last.id }) { return match }
        if let match = selectable.first(where: { $0.provider == thread.provider && $0.orchestratorModel == thread.model }) { return match }
        if let match = selectable.first(where: { $0.provider == thread.provider && $0.orchestratorModel == nil }) { return match }
        if let match = selectable.first(where: { $0.provider == thread.provider }) { return match }
        return selectable.first
    }

    var body: some View {
        if let thread = model.thread(threadID), !thread.isHelper {
            let isHydra = model.hydraModeIsOn(thread)
            let isChimera = model.chimeraIsOn(thread)
            let isSubagentsOn = isHydra || isChimera
            let activePair = isHydra ? model.hydraPair(for: thread) : nil
            let canSwitchChimera = model.canSwitchChimeraMode(thread.id)
            let chimeraAvailable = model.chimeraAvailable(thread)
            // With the team switch off, Chimera can still be chosen here when it is available.
            let globallyOff = !model.settings.hydraEnabled && !isChimera && !chimeraAvailable
            let lockedInChimera = isChimera && !canSwitchChimera
            let savedPairs = model.hydraPickerPairs
            let switchBlocker = model.existingRuntime(for: thread.id)?.providerSwitchBlocker
            let selectablePairs = savedPairs.filter { !(hasHistory && $0.provider != thread.provider && switchBlocker != nil) }
            let temporaryPair = thread.temporaryHydraPair
            let hasAnyCombo = !savedPairs.isEmpty || temporaryPair != nil
            let canSelectComboRow = (!selectablePairs.isEmpty || temporaryPair != nil) && !lockedInChimera
            let preferredPair = preferredPair(active: activePair, temporary: temporaryPair, selectable: selectablePairs, thread: thread)

            VStack(alignment: .leading, spacing: 10) {
                PopoverDivider()
                    .padding(.horizontal, -6)

                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 6) {
                        Text("Sub-agents")
                            .font(.ui(.callout, weight: .semibold))
                            .foregroundStyle(Chrome.primaryText)
                        if model.settings.hydraEnabled && model.settings.hydraDefaultEnabled {
                            Text("on by default")
                                .font(.ui(.subheadline))
                                .foregroundStyle(Chrome.secondaryText)
                        }
                        Spacer(minLength: 8)
                        SettingsSwitch(isOn: Binding(
                            get: { isSubagentsOn },
                            set: { on in
                                if on {
                                    if model.settings.hydraEnabled {
                                        model.setHydra(true, for: thread.id)
                                        presentIntroIfNeeded()
                                    } else if chimeraAvailable {
                                        model.setChimera(true, for: thread.id)
                                    }
                                } else {
                                    guard !lockedInChimera else { return }
                                    model.setChimera(false, for: thread.id)
                                    model.setHydra(false, for: thread.id)
                                }
                            }
                        ))
                        .disabled(globallyOff || lockedInChimera)
                        .accessibilityLabel(Text("Sub-agents"))
                    }
                    .popover(isPresented: $isIntroShown, arrowEdge: .bottom) {
                        HydraIntroPopover {
                            model.settings.hasSeenHydraIntro = true
                            isIntroShown = false
                        }
                        .interactiveDismissDisabled()
                    }

                    if globallyOff {
                        Text("Turn on sub-agents in Settings › Sub-agents & Combos.")
                            .font(.ui(.subheadline))
                            .foregroundStyle(Chrome.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if isSubagentsOn {
                        VStack(spacing: 6) {
                            SubagentModeRow(
                                title: "Same-model sub-agents",
                                detail: Chrome.localized("This model splits the work and hands parts to sub-agents running the same model."),
                                isSelected: isHydra && activePair == nil,
                                isEnabled: !lockedInChimera,
                                action: { selectCurrentModelHydra(thread) }
                            ) {
                                HydraMarkImage()
                                    .foregroundStyle(Chrome.primaryText.opacity(0.85))
                                    .frame(width: 12, height: 12)
                            } trailing: {
                                EmptyView()
                            }

                            let comboDetail: String = if !hasAnyCombo {
                                Chrome.localized("Set up combos in Settings › Sub-agents & Combos.")
                            } else if selectablePairs.isEmpty && temporaryPair == nil, let switchBlocker {
                                switchBlocker
                            } else {
                                Chrome.localized("A saved lead and sub-agent combo; sub-agents run the combo's models.")
                            }

                            SubagentModeRow(
                                title: "Preset sub-agents",
                                detail: comboDetail,
                                isSelected: isHydra && activePair != nil,
                                isEnabled: canSelectComboRow,
                                action: {
                                    if activePair != nil {
                                        if savedPairs.count + (temporaryPair == nil ? 0 : 1) > 1 {
                                            isComboMenuPresented.toggle()
                                        }
                                    } else if let temporaryPair {
                                        selectCombo(temporaryPair, for: thread, temporary: true)
                                    } else if let preferredPair {
                                        selectCombo(preferredPair, for: thread)
                                    }
                                }
                            ) {
                                HydraMarkImage()
                                    .foregroundStyle(Chrome.primaryText.opacity(0.85))
                                    .frame(width: 12, height: 12)
                            } trailing: {
                                if hasAnyCombo {
                                    comboMenuButton(
                                        thread: thread,
                                        activePair: activePair,
                                        preferredPair: preferredPair,
                                        temporaryPair: temporaryPair,
                                        savedPairs: savedPairs,
                                        switchBlocker: switchBlocker,
                                        isEnabled: canSelectComboRow
                                    )
                                }
                            }

                            let chimeraDetail: String = if !chimeraAvailable {
                                Chrome.localized("Turn on adaptive sub-agents in Settings › Sub-agents & Combos.")
                            } else if !canSwitchChimera {
                                Chrome.localized("Switch when no sub-agents are at work.")
                            } else {
                                Chrome.localized("The lead splits the work into roles and matches each to a model across providers.")
                            }

                            SubagentModeRow(
                                title: "Adaptive sub-agents",
                                detail: chimeraDetail,
                                isSelected: isChimera,
                                isEnabled: chimeraAvailable && canSwitchChimera,
                                dimsWhenDisabled: !isChimera,
                                action: {
                                    guard chimeraAvailable, canSwitchChimera else { return }
                                    model.setChimera(true, for: thread.id)
                                }
                            ) {
                                ChimeraMarkImage()
                                    .foregroundStyle(Chrome.primaryText.opacity(0.85))
                                    .frame(width: 14, height: 12)
                            } trailing: {
                                EmptyView()
                            } footer: {
                                if isChimera {
                                    VStack(alignment: .leading, spacing: 6) {
                                        Divider()
                                        HStack(spacing: 8) {
                                            Text(verbatim: Chrome.localized("Auto-dispatch"))
                                                .font(.ui(.subheadline, weight: .medium))
                                                .foregroundStyle(Chrome.primaryText)
                                                .lineLimit(1)
                                            Spacer(minLength: 8)
                                            SettingsSwitch(isOn: Binding(
                                                get: { model.settings.chimeraAutoDispatch },
                                                set: { model.settings.chimeraAutoDispatch = $0 }
                                            ))
                                            .accessibilityLabel(Text(verbatim: Chrome.localized("Auto-dispatch")))
                                        }
                                        .help(Text(verbatim: Chrome.localized("Send sub-agents out as soon as the lead picks them, without waiting for you.")))
                                    }
                                    .padding(.leading, 32)
                                    .padding(.trailing, 10)
                                    .padding(.bottom, 8)
                                }
                            }
                        }

                        if let effortCaption = subagentEffortCaption(for: thread, isHydra: isHydra) {
                            Text(verbatim: effortCaption)
                                .font(.ui(.subheadline))
                                .foregroundStyle(Chrome.secondaryText)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .minimumScaleFactor(0.9)
                        }
                    }
                }
                .opacity(globallyOff ? 0.55 : 1)
            }
            .task {
                for provider in Set(savedPairs.flatMap { [$0.provider, $0.headsProvider] }) where provider != thread.provider {
                    await model.providers.loadCatalog(provider)
                }
            }
        }
    }

    private func presentIntroIfNeeded() {
        if !model.settings.hasSeenHydraIntro {
            isIntroShown = true
        }
    }

    private func selectCurrentModelHydra(_ thread: ChatThread) {
        let savedModel = thread.model
        let savedEffort = thread.effort
        if model.chimeraIsOn(thread) {
            guard model.canSwitchChimeraMode(thread.id) else { return }
            model.settings.hydraEnabled = true
        }
        model.setChimera(false, for: thread.id)
        model.setHydra(true, for: thread.id)
        model.leaveHydraPair(for: thread.id)
        if let refreshed = model.thread(thread.id), refreshed.model != savedModel || refreshed.effort != savedEffort {
            model.updateThread(thread.id) {
                $0.model = savedModel
                $0.effort = savedEffort
            }
        }
        if !hasHistory, let savedModel {
            model.settings.noteNewChatChoice(.model(ModelPin(provider: thread.provider, modelID: savedModel)))
        }
        presentIntroIfNeeded()
    }

    private func selectCombo(_ pair: HydraPair, for thread: ChatThread, temporary: Bool = false) {
        if model.chimeraIsOn(thread) {
            guard model.canSwitchChimeraMode(thread.id) else { return }
            model.settings.hydraEnabled = true
        }
        if !hasHistory {
            model.settings.noteNewChatChoice(.pair(pair))
        }
        model.enterHydraPair(pair, for: thread.id, temporary: temporary)
        isComboMenuPresented = false
        presentIntroIfNeeded()
    }

    private func subagentEffortCaption(for thread: ChatThread, isHydra: Bool) -> String? {
        guard isHydra, hasLeadEfforts else { return nil }
        if let pairLook { return pairLook.caption }
        if let workerEffort = model.hydraLaunch(for: thread)?.workerEffort {
            return String(format: Chrome.localized("The lead's effort · sub-agents run at %@ effort"), Chrome.localizedLowercased(ModelOption.effortTitle(workerEffort)))
        }
        return Chrome.localized("The lead's effort · sub-agents keep their own")
    }

    @ViewBuilder
    private func comboMenuButton(
        thread: ChatThread,
        activePair: HydraPair?,
        preferredPair: HydraPair?,
        temporaryPair: HydraPair?,
        savedPairs: [HydraPair],
        switchBlocker: String?,
        isEnabled: Bool
    ) -> some View {
        let displayedPair = activePair ?? preferredPair ?? savedPairs.first
        let buttonTitle = displayedPair.map { HydraPairSummary.title($0, registry: model.providers) } ?? Chrome.localized("Preset")
        let scrolls = savedPairs.count > 7
        Button {
            isComboMenuPresented.toggle()
        } label: {
            HStack(spacing: 4) {
                if let displayedPair {
                    HydraFusedPairIcon(lead: displayedPair.provider, heads: model.hydraHeadsProvider(of: displayedPair), size: 12, animates: false)
                        .id(displayedPair.id)
                }
                Text(verbatim: buttonTitle)
                    .font(.ui(.subheadline, weight: .medium))
                    .foregroundStyle(Chrome.primaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "chevron.down")
                    .font(Chrome.chevronFont)
                    .foregroundStyle(Chrome.secondaryText)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background {
                Capsule(style: .continuous)
                    .fill(isComboMenuPresented ? Chrome.accent.opacity(0.18) : Chrome.overlay(0.08))
            }
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .help(Text(verbatim: buttonTitle))
        .anchoredPopover(isPresented: $isComboMenuPresented, arrowEdge: .bottom) {
            PopoverMenu(idealHeight: scrolls ? 7 * 42 : nil, scrolls: scrolls) {
                PopoverSectionHeader("Combos")
                if let temporaryPair {
                    HydraPairListRow(
                        pair: temporaryPair,
                        title: HydraPairSummary.title(temporaryPair, registry: model.providers),
                        detail: hydraPairDetail(temporaryPair, temporary: true, model: model),
                        rowHeight: 42,
                        isSelected: activePair?.id == temporaryPair.id,
                        isEnabled: true
                    ) {
                        selectCombo(temporaryPair, for: thread, temporary: true)
                    }
                }
                ForEach(savedPairs) { pair in
                    let locked = hasHistory && pair.provider != thread.provider && switchBlocker != nil
                    HydraPairListRow(
                        pair: pair,
                        title: HydraPairSummary.title(pair, registry: model.providers),
                        detail: locked ? (switchBlocker ?? "") : hydraPairDetail(pair, model: model),
                        rowHeight: 42,
                        isSelected: activePair?.id == pair.id && temporaryPair?.id != pair.id,
                        isEnabled: !locked
                    ) {
                        selectCombo(pair, for: thread)
                    }
                    .help(locked ? (switchBlocker ?? "") : "")
                }
            }
            .frame(width: 280)
        }
        .frame(maxWidth: 120, alignment: .trailing)
    }
}

private struct SubagentModeRow<Leading: View, Trailing: View, Footer: View>: View {
    let title: String
    let detail: String
    let isSelected: Bool
    let isEnabled: Bool
    var dimsWhenDisabled = true
    let action: () -> Void
    @ViewBuilder let leading: () -> Leading
    @ViewBuilder let trailing: () -> Trailing
    @ViewBuilder let footer: () -> Footer

    @State private var isHovering = false

    init(
        title: String,
        detail: String,
        isSelected: Bool,
        isEnabled: Bool,
        dimsWhenDisabled: Bool = true,
        action: @escaping () -> Void,
        @ViewBuilder leading: @escaping () -> Leading,
        @ViewBuilder trailing: @escaping () -> Trailing,
        @ViewBuilder footer: @escaping () -> Footer
    ) {
        self.title = title
        self.detail = detail
        self.isSelected = isSelected
        self.isEnabled = isEnabled
        self.dimsWhenDisabled = dimsWhenDisabled
        self.action = action
        self.leading = leading
        self.trailing = trailing
        self.footer = footer
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Button(action: action) {
                        HStack(spacing: 8) {
                            ZStack {
                                Circle()
                                    .strokeBorder(isSelected ? Chrome.accent : Chrome.overlay(0.32), lineWidth: 1.5)
                                    .frame(width: 14, height: 14)
                                if isSelected {
                                    Circle()
                                        .fill(Chrome.accent)
                                        .frame(width: 7, height: 7)
                                }
                            }
                            HStack(spacing: 5) {
                                leading()
                                Text(verbatim: Chrome.localized(title))
                                    .font(.ui(.callout, weight: .medium))
                                    .foregroundStyle(Chrome.primaryText)
                                    .lineLimit(1)
                                    .layoutPriority(1)
                            }
                            Spacer(minLength: 0)
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .disabled(!isEnabled)

                    trailing()
                }

                Button(action: action) {
                    Text(verbatim: detail)
                        .font(.ui(.subheadline))
                        .foregroundStyle(Chrome.secondaryText)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 22)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .disabled(!isEnabled)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            // The whole highlighted header/detail selects, not just the title and detail
            // buttons: clicks in its padding and row gaps used to do nothing. Keeping
            // footer outside this tap area ensures footer controls never trigger selection.
            .contentShape(.rect)
            .onTapGesture {
                if isEnabled { action() }
            }

            footer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(isSelected ? Chrome.accent.opacity(0.14) : Chrome.overlay(isHovering && isEnabled ? 0.08 : 0.04))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(isSelected ? Chrome.accent.opacity(0.45) : Chrome.overlay(0.08), lineWidth: 1)
        }
        .opacity(!isEnabled && dimsWhenDisabled ? 0.45 : 1)
        .onHover { hovering in
            withAnimation(Chrome.hover) { isHovering = hovering }
        }
        .accessibilityElement(children: .contain)
    }
}

private extension SubagentModeRow where Footer == EmptyView {
    init(
        title: String,
        detail: String,
        isSelected: Bool,
        isEnabled: Bool,
        dimsWhenDisabled: Bool = true,
        action: @escaping () -> Void,
        @ViewBuilder leading: @escaping () -> Leading,
        @ViewBuilder trailing: @escaping () -> Trailing
    ) {
        self.init(
            title: title,
            detail: detail,
            isSelected: isSelected,
            isEnabled: isEnabled,
            dimsWhenDisabled: dimsWhenDisabled,
            action: action,
            leading: leading,
            trailing: trailing,
            footer: { EmptyView() }
        )
    }
}

private struct FastModeButton: View {
    @Binding var isOn: Bool
    @State private var isHovering = false

    var body: some View {
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { isOn.toggle() }
        } label: {
            Image(systemName: isOn ? "bolt.fill" : "bolt")
                .font(.ui(.body, weight: .semibold))
                .foregroundStyle(isOn ? Color.yellow : Chrome.secondaryText)
                .symbolEffect(.bounce, value: isOn)
                .frame(width: 30, height: 30)
                .background {
                    Circle().fill(isOn ? Color.yellow.opacity(0.18) : Chrome.overlay(isHovering ? 0.1 : 0.06))
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

/// A thick capsule track with a dot per level, filled up to a large glass knob that snaps to each level.
struct EffortSlider: View {
    static let trackHeight: CGFloat = 34
    static let thumbSize: CGFloat = 42

    let count: Int
    @Binding var index: Int
    /// Fast mode on, for a model that has it. Colours the fill gold with
    /// speed streaks; at maximum effort it fuses with the brand's particles.
    var fastMode = false
    /// The colours maximum effort wears: the provider's brand.
    var brand: EffortBrand = .purple
    /// The pair the chat leads with, if one: the fill runs from the lead's colour into the
    /// heads' and the two fuse at a seam, whatever the effort.
    var pair: EffortPairBrand? = nil
    let accessibilityTitle: String

    @State private var dragX: CGFloat?
    @Environment(\.solidSurfaces) private var solid

    private var look: TrackLook {
        let isMax = count > 1 && index == count - 1
        let kind: TrackLook.Kind = switch (isMax, fastMode) {
        case (true, true): .fusion
        case (true, false): .supercharged
        case (false, true): .fast
        case (false, false): .plain
        }
        return TrackLook(kind: kind, brand: brand, pair: pair)
    }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            // The lens is wider than the track: stop centres sit a lens radius in
            // from each end so the whole knob stays visible at the extremes and
            // the fill ends flush with its far edge.
            let inset = Self.thumbSize / 2
            let midY = proxy.size.height / 2
            let step = count > 1 ? (width - inset * 2) / CGFloat(count - 1) : 0
            let restingX = inset + CGFloat(index) * step
            let x = min(max(dragX ?? restingX, inset), width - inset)
            let look = look

            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(Chrome.overlay(0.1))
                    .frame(width: width, height: Self.trackHeight)
                Capsule(style: .continuous)
                    .fill(look.fill)
                    .frame(width: x + inset, height: Self.trackHeight)
                    .overlay(alignment: .leading) {
                        if look.kind != .plain || look.pair != nil {
                            TrackEffect(look: look)
                                .frame(width: x + inset, height: Self.trackHeight)
                                .clipShape(Capsule(style: .continuous))
                                .transition(.opacity)
                                .id(look.effectIdentity)
                        }
                    }
                ForEach(0..<count, id: \.self) { stop in
                    let stopX = inset + CGFloat(stop) * step
                    Circle()
                        .fill(stopX <= x ? look.stopColor : Chrome.overlay(0.32))
                        .frame(width: 5, height: 5)
                        .position(x: stopX, y: midY)
                }
                // The knob is a Liquid Glass lens: it refracts the fill's edge, the stops and
                // the particles as it slides over them, lit white just enough to read as the
                // knob on the dark track. The charged fills keep their glow under it: a blurred
                // disc beneath the lens rather than a shadow on it, because a shadow that
                // changes colour and radius on glass makes the lens flash as the look changes.
                ZStack {
                    Circle()
                        .fill(look.glow)
                        .blur(radius: look.kind == .plain ? 4 : 8)
                        .offset(y: 1)
                    if let solid {
                        Circle()
                            .fill(solid.elevated)
                            .overlay { Circle().strokeBorder(solid.hairlineStrong, lineWidth: 1) }
                    } else {
                        Circle()
                            .fill(.clear)
                            .chromeGlassEffect(.regular.tint(Color.white.opacity(look.isLightFill ? 0.55 : 0.32)).interactive(), in: Circle())
                            // On a white fill the lens needs an edge to read against it.
                            .overlay {
                                Circle().strokeBorder(Color.black.opacity(look.isLightFill ? 0.14 : 0), lineWidth: 1)
                            }
                    }
                }
                .frame(width: Self.thumbSize, height: Self.thumbSize)
                .scaleEffect(dragX == nil ? 1 : 1.06)
                .position(x: x, y: midY)
            }
            .frame(width: width, height: proxy.size.height, alignment: .leading)
            .animation(.smooth(duration: 0.3), value: look)
            .contentShape(.rect)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if dragX == nil {
                            withAnimation(.spring(response: 0.22, dampingFraction: 0.8)) { dragX = value.location.x }
                        } else {
                            dragX = value.location.x
                        }
                        let nearest = nearestStop(to: value.location.x, inset: inset, step: step)
                        if nearest != index {
                            index = nearest
                            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                        }
                    }
                    .onEnded { _ in
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) { dragX = nil }
                    }
            )
        }
        .frame(height: Self.thumbSize)
        .accessibilityElement()
        .accessibilityLabel(Text(verbatim: pair == nil ? Chrome.localized("Reasoning effort") : Chrome.localized("The lead's reasoning effort")))
        .accessibilityValue(Text(verbatim: accessibilityTitle))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: index = min(count - 1, index + 1)
            case .decrement: index = max(0, index - 1)
            @unknown default: break
            }
        }
    }

    private func nearestStop(to x: CGFloat, inset: CGFloat, step: CGFloat) -> Int {
        guard count > 1, step > 0 else { return 0 }
        return min(count - 1, max(0, Int(((x - inset) / step).rounded())))
    }
}

enum EffortPalette {
    /// The accent lifted a little, so the effort name reads clearly on glass.
    static var title: Color { Chrome.accent.mix(with: .white, by: 0.22) }
    static let supercharged = Color(red: 0.74, green: 0.55, blue: 1.0)
    static let superchargedFill = Color(red: 0.55, green: 0.34, blue: 0.97)
    /// Fast mode's gold: the bolt's yellow, deepened for a fill.
    static let fast = Color(red: 1.0, green: 0.84, blue: 0.36)
    static let fastFill = Color(red: 0.93, green: 0.66, blue: 0.13)
}

/// The colours a provider's maximum effort wears: its brand. Claude's terracotta,
/// DeepSeek's blue, Meta's blue gradient, Google's Gemini gradient for Antigravity.
/// Brands whose marks are black and white (Codex, Cursor, Grok, OpenCode, Devin, Copilot, Command Code) get
/// a white fill with dark sparks, and everything in the track flips dark to read on it.
enum EffortBrand: Hashable {
    case claude
    case deepseek
    case meta
    case antigravity
    case silver
    /// The stock purple, for a slider with no provider behind it.
    case purple

    init(provider: ProviderKind?) {
        self = switch provider {
        case .claude: .claude
        case .deepseek, .dsh: .deepseek
        case .meta: .meta
        case .antigravity: .antigravity
        case .codex, .cursor, .grok, .opencode, .devin, .copilot, .commandcode, .pi, .omp, .zai, .zcode, .kimi, .minimaxCode: .silver
        case nil: .purple
        }
    }

    /// The colour the effort name takes at maximum, also the near end of the fast blend.
    var titleColor: Color {
        switch self {
        case .claude: Color(red: 0.93, green: 0.58, blue: 0.44)
        case .deepseek: Color(red: 0.49, green: 0.58, blue: 1.0)
        case .meta: Color(red: 0.31, green: 0.64, blue: 1.0)
        case .antigravity: Color(red: 0.61, green: 0.45, blue: 0.80)
        case .silver: Chrome.primaryText
        case .purple: EffortPalette.supercharged
        }
    }

    var title: AnyShapeStyle {
        switch self {
        case .antigravity: AnyShapeStyle(LinearGradient(colors: Self.gemini, startPoint: .leading, endPoint: .trailing))
        default: AnyShapeStyle(titleColor)
        }
    }

    /// The fill behind the particles.
    var fill: AnyShapeStyle {
        switch self {
        case .claude: AnyShapeStyle(Color(red: 0.80, green: 0.42, blue: 0.28))
        case .deepseek: AnyShapeStyle(Color(red: 0.24, green: 0.36, blue: 0.98))
        case .meta: AnyShapeStyle(LinearGradient(
            colors: [Color(red: 0.0, green: 0.39, blue: 0.88), Color(red: 0.0, green: 0.51, blue: 0.98)],
            startPoint: .leading, endPoint: .trailing
        ))
        case .antigravity: AnyShapeStyle(LinearGradient(colors: Self.gemini, startPoint: .leading, endPoint: .trailing))
        case .silver: AnyShapeStyle(LinearGradient(
            colors: [Color.white, Color(red: 0.88, green: 0.88, blue: 0.91)],
            startPoint: .leading, endPoint: .trailing
        ))
        case .purple: AnyShapeStyle(EffortPalette.superchargedFill)
        }
    }

    /// The fill's darkest colour, for the fusion blend's near end and the knob's glow.
    var fillColor: Color {
        switch self {
        case .claude: Color(red: 0.80, green: 0.42, blue: 0.28)
        case .deepseek: Color(red: 0.24, green: 0.36, blue: 0.98)
        case .meta: Color(red: 0.0, green: 0.45, blue: 0.93)
        case .antigravity: Color(red: 0.56, green: 0.45, blue: 0.80)
        case .silver: Color(red: 0.92, green: 0.92, blue: 0.94)
        case .purple: EffortPalette.superchargedFill
        }
    }

    /// The particles and sheen: white on colour, dark on white.
    var spark: Color { self == .silver ? .black : .white }

    /// Whether the fill is light enough that the knob and stops must read dark against it.
    var isLight: Bool { self == .silver }

    var glow: Color { self == .silver ? .black.opacity(0.35) : fillColor.opacity(0.6) }

    /// Google's Gemini sweep: blue into violet into coral.
    static let gemini = [
        Color(red: 0.26, green: 0.52, blue: 0.96),
        Color(red: 0.61, green: 0.45, blue: 0.80),
        Color(red: 0.85, green: 0.40, blue: 0.44),
    ]
}

/// The colours a pair's fusion runs between: the lead's brand at the near end, and at the
/// far end the heads' provider's brand when they run on another provider than the lead
/// (Claude's terracotta into the Gemini sweep, say), else the roster's colours, for one
/// lead over many heads.
struct EffortPairBrand: Hashable {
    /// The heads' colours, near end first.
    var colors: [Color]
    /// Whether the far end is light, so the knob needs its edge there.
    var isLight: Bool

    init(_ pair: HydraPair) {
        if pair.sendsHeadsElsewhere {
            let brand = EffortBrand(provider: pair.headsProvider)
            switch brand {
            case .antigravity: colors = EffortBrand.gemini
            case .silver: colors = [Color(white: 0.8), Color(white: 0.95)]
            default: colors = [brand.fillColor, brand.titleColor]
            }
            isLight = brand.isLight
        } else {
            colors = HydraRoster.personas.prefix(4).map(\.color)
            isLight = false
        }
    }

    /// The heads' colours for the effort's name: lifted a little, like the lead's.
    var titleColors: [Color] { colors.map { $0.mix(with: .white, by: 0.18) } }
}

/// How the filled part of the effort track looks.
struct TrackLook: Hashable {
    enum Kind: Hashable {
        case plain
        /// Maximum effort: the brand's fill with particles drifting toward the knob.
        case supercharged
        /// Fast mode: gold with speed streaks and lightning.
        case fast
        /// Both: the brand running into gold, particles, streaks, lightning and a sweeping sheen.
        case fusion
    }

    var kind: Kind
    var brand: EffortBrand
    /// The pair the chat leads with: its colours take the fill over, whatever the kind, and
    /// the kind's own effects play on top.
    var pair: EffortPairBrand? = nil

    var fill: AnyShapeStyle {
        if let pair {
            return AnyShapeStyle(LinearGradient(colors: [brand.fillColor] + pair.colors, startPoint: .leading, endPoint: .trailing))
        }
        switch kind {
        case .plain: return AnyShapeStyle(Chrome.accent)
        case .supercharged: return brand.fill
        case .fast: return AnyShapeStyle(EffortPalette.fastFill)
        case .fusion: return AnyShapeStyle(LinearGradient(
            colors: [brand.fillColor, brand.fillColor, EffortPalette.fastFill],
            startPoint: .leading, endPoint: .trailing
        ))
        }
    }

    var glow: Color {
        if let pair, let last = pair.colors.last { return pair.isLight ? .black.opacity(0.35) : last.opacity(0.7) }
        switch kind {
        case .plain: return .black.opacity(0.28)
        case .supercharged: return brand.glow
        case .fast: return EffortPalette.fastFill.opacity(0.7)
        case .fusion: return EffortPalette.fast.opacity(0.75)
        }
    }

    /// Whether the fill under the knob is light (a white brand at maximum, not in fusion,
    /// whose far end is gold; or a pair whose heads' colours are white).
    var isLightFill: Bool { pair.map(\.isLight) ?? (kind == .supercharged && brand.isLight) }

    /// The passed stops: white on colour, dark on a white fill.
    var stopColor: Color { isLightFill ? .black.opacity(0.35) : .white.opacity(0.6) }

    /// The particles' and sheen's colour.
    var spark: Color { pair == nil && (kind == .supercharged || kind == .fusion) ? brand.spark : .white }

    /// What one run of the track's animation stands for. A look without a pair starts its
    /// effect over on every change, crossfading. A pair's fusion is the whole track's
    /// animation, so it keeps its time through the kind's changes: the seam does not jump
    /// because the knob reached maximum, and the kind's effects join it in place.
    var effectIdentity: AnyHashable {
        pair.map { AnyHashable(TrackLook(kind: .plain, brand: brand, pair: $0)) } ?? AnyHashable(self)
    }
}

/// The track's animation, one small Canvas drawn only while the slider needs it.
///
/// Maximum effort: particles drifting through the fill toward the knob, each with its own height,
/// size, speed and shimmer, fading at the ends. Fast mode: speed streaks zipping toward the knob
/// and a lightning bolt flashing now and then. Both together layer the two, over a fill that runs
/// from purple into gold, with a glossy sheen sweeping across. 30fps, 60 when streaks move.
///
/// Each particle's and streak's traits are fixed by its index, so they are worked out once
/// per fill width (`Traits`) and every frame is arithmetic and fills; six `sin` per element
/// per frame was most of what a frame cost.
struct TrackEffect: View {
    let look: TrackLook
    @Environment(\.chatColumnVisibility) private var columnVisibility
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var startedAt = Date.now
    @State private var traits = TraitCache()

    var body: some View {
        let kind = look.kind
        let spark = look.spark
        let pair = look.pair
        let paused = reduceMotion || ScrollActivity.shared.isScrolling || !FrontMonitor.shared.isVisible || !columnVisibility.isShown
        TimelineView(.animation(minimumInterval: 1.0 / (kind == .supercharged && pair == nil ? 30 : 60), paused: paused)) { timeline in
            let time = timeline.date.timeIntervalSince(startedAt)
            Canvas { context, size in
                guard size.width > 8 else { return }
                if let pair {
                    Self.drawFusion(context, size: size, time: time, lead: look.brand.fillColor, heads: pair.colors)
                }
                let traits = traits.traits(width: Double(size.width))
                if kind == .supercharged || kind == .fusion {
                    Self.drawParticles(context, size: size, time: time, color: spark, particles: traits.particles)
                }
                if kind == .fast || kind == .fusion {
                    Self.drawStreaks(context, size: size, time: time, streaks: traits.streaks)
                    Self.drawBolts(context, size: size, time: time)
                }
                if kind == .fusion {
                    Self.drawSheen(context, size: size, time: time, color: spark)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    struct Particle: Equatable {
        var height: Double
        var speed: Double
        var radius: Double
        /// Where along the span the particle starts, 0..<1.
        var start: Double
        var brightness: Double
        var shimmerRate: Double
    }

    struct Streak: Equatable {
        var length: Double
        var speed: Double
        var thickness: Double
        var start: Double
        var height: Double
        var brightness: Double
    }

    struct Traits: Equatable {
        var particles: [Particle]
        var streaks: [Streak]

        /// The traits for a fill of this width: as many particles as one per five points and
        /// streaks as one per fourteen, each element's traits the same at every width.
        static func build(width: Double) -> Traits {
            let particles = (0..<max(10, Int(width / 5))).map { index -> Particle in
                let seed = Double(index)
                return Particle(
                    height: random(seed, 1), speed: 12 + 28 * random(seed, 2), radius: 0.7 + 1.1 * random(seed, 3),
                    start: random(seed, 4), brightness: 0.22 + 0.5 * random(seed, 5), shimmerRate: 2 + 3 * random(seed, 6)
                )
            }
            let streaks = (0..<max(5, Int(width / 14))).map { index -> Streak in
                let seed = Double(index) + 100
                return Streak(
                    length: 10 + 20 * random(seed, 1), speed: 110 + 190 * random(seed, 2), thickness: 1.1 + 1.1 * random(seed, 3),
                    start: random(seed, 4), height: 0.2 + 0.6 * random(seed, 5), brightness: 0.35 + 0.55 * random(seed, 6)
                )
            }
            return Traits(particles: particles, streaks: streaks)
        }
    }

    /// The traits of the width last drawn. A reference the canvas closure updates in
    /// place: the width changes only while the knob is dragged, and a frame at the same
    /// width reuses what the last one built.
    final class TraitCache {
        private var width = -1.0
        private var built = Traits(particles: [], streaks: [])

        func traits(width: Double) -> Traits {
            if width != self.width {
                self.width = width
                built = Traits.build(width: width)
            }
            return built
        }
    }

    private static func drawParticles(_ context: GraphicsContext, size: CGSize, time: TimeInterval, color: Color, particles: [Particle]) {
        let span = Double(size.width) + 8
        for (index, particle) in particles.enumerated() {
            let x = (particle.start * span + time * particle.speed).truncatingRemainder(dividingBy: span) - 4
            let y = Double(size.height) * (0.16 + 0.68 * particle.height)
            let shimmer = 0.6 + 0.4 * sin(time * particle.shimmerRate + Double(index))
            let opacity = particle.brightness * shimmer * edgeFade(x, width: Double(size.width))
            guard opacity > 0.01 else { continue }
            let radius = particle.radius
            context.fill(
                Path(ellipseIn: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)),
                with: .color(color.opacity(opacity))
            )
        }
    }

    /// Thin streaks racing toward the knob, bright at the head and fading down the tail.
    private static func drawStreaks(_ context: GraphicsContext, size: CGSize, time: TimeInterval, streaks: [Streak]) {
        let width = Double(size.width)
        for streak in streaks {
            let length = streak.length
            let thickness = streak.thickness
            let span = width + length + 12
            let x = (streak.start * span + time * streak.speed).truncatingRemainder(dividingBy: span) - length - 6
            let y = Double(size.height) * streak.height
            let brightness = streak.brightness * edgeFade(x + length, width: width)
            guard brightness > 0.02 else { continue }
            let rect = CGRect(x: x, y: y - thickness / 2, width: length, height: thickness)
            context.fill(
                Path(roundedRect: rect, cornerRadius: thickness / 2),
                with: .linearGradient(
                    Gradient(colors: [.white.opacity(0), .white.opacity(brightness)]),
                    startPoint: CGPoint(x: rect.minX, y: rect.midY),
                    endPoint: CGPoint(x: rect.maxX, y: rect.midY)
                )
            )
        }
    }

    /// Two lightning bolts on their own beats: each flashes for a quarter second every second
    /// or two, somewhere new along the fill, as a glowing zigzag.
    private static func drawBolts(_ context: GraphicsContext, size: CGSize, time: TimeInterval) {
        let width = Double(size.width)
        let height = Double(size.height)
        for slot in 0..<2 {
            let seed = Double(slot) + 200
            let period = 1.4 + 0.9 * random(seed, 1)
            let offset = random(seed, 2) * period
            let cycle = ((time + offset) / period).rounded(.down)
            let phase = (time + offset) - cycle * period
            let flash = 0.26
            guard phase < flash else { continue }
            let intensity = sin(phase / flash * .pi)
            let cycleSeed = seed + cycle * 7.31
            let x = 12 + (width - 24) * random(cycleSeed, 3)
            guard x > 6, x < width - 6 else { continue }
            let lean = 3.0 + 3.0 * random(cycleSeed, 4)
            var bolt = Path()
            bolt.move(to: CGPoint(x: x + lean, y: 3))
            bolt.addLine(to: CGPoint(x: x - lean * 0.4, y: height * 0.42))
            bolt.addLine(to: CGPoint(x: x + lean * 0.5, y: height * 0.5))
            bolt.addLine(to: CGPoint(x: x - lean, y: height - 3))
            var glow = context
            glow.addFilter(.blur(radius: 3))
            glow.stroke(bolt, with: .color(EffortPalette.fast.opacity(0.9 * intensity)), style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
            context.stroke(bolt, with: .color(.white.opacity(intensity)), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        }
    }

    /// A slanted band of light sweeping the whole fill every few seconds.
    private static func drawSheen(_ context: GraphicsContext, size: CGSize, time: TimeInterval, color: Color) {
        let width = Double(size.width)
        let height = Double(size.height)
        let band = 46.0
        let period = 2.8
        let progress = (time / period).truncatingRemainder(dividingBy: 1)
        let x = -band + (width + band * 2) * progress
        var path = Path()
        path.move(to: CGPoint(x: x + 10, y: 0))
        path.addLine(to: CGPoint(x: x + band + 10, y: 0))
        path.addLine(to: CGPoint(x: x + band, y: height))
        path.addLine(to: CGPoint(x: x, y: height))
        path.closeSubpath()
        context.fill(
            path,
            with: .linearGradient(
                Gradient(colors: [color.opacity(0), color.opacity(0.22), color.opacity(0)]),
                startPoint: CGPoint(x: x, y: 0),
                endPoint: CGPoint(x: x + band + 10, y: 0)
            )
        )
    }

    /// A pair's fusion: the lead's colour streaming in from the near end and the heads'
    /// from the far end, meeting at a white-hot seam that drifts and breathes. Bands of
    /// each colour flow on into the other's side and fade there, sparks fly off the seam
    /// to either side, cooling from white to the colour they land in, and the sheen sweeps
    /// over it all. The gradient itself is drawn here, over the fill, so the seam can move.
    private static func drawFusion(_ context: GraphicsContext, size: CGSize, time: TimeInterval, lead: Color, heads: [Color]) {
        let width = Double(size.width)
        let height = Double(size.height)
        let seam = width * (0.5 + 0.13 * sin(time * 0.7) + 0.05 * sin(time * 1.9 + 1))
        let pulse = 0.5 + 0.5 * sin(time * 2.4)
        let headsNear = heads.first ?? lead

        // The two colours meeting: each holds its own side and they fuse over a short run
        // around the seam, whose heart is white.
        var stops: [Gradient.Stop] = [.init(color: lead, location: 0)]
        stops.append(.init(color: lead, location: max(0, seam / width - 0.22)))
        stops.append(.init(color: .white.opacity(0.92), location: seam / width))
        let farStart = min(1, seam / width + 0.16)
        if heads.count == 1 {
            stops.append(.init(color: headsNear, location: farStart))
            stops.append(.init(color: headsNear, location: 1))
        } else {
            for (index, color) in heads.enumerated() {
                stops.append(.init(color: color, location: min(1, farStart + (1 - farStart) * Double(index) / Double(heads.count - 1))))
            }
        }
        context.fill(
            Path(CGRect(origin: .zero, size: size)),
            with: .linearGradient(Gradient(stops: stops), startPoint: CGPoint(x: 0, y: height / 2), endPoint: CGPoint(x: width, y: height / 2))
        )

        // Plasma: bands of the far side's colour flowing into each side, soft and additive,
        // brightest at the seam and gone by the fill's end, so each colour keeps reaching
        // into the other.
        for band in 0..<3 {
            let seed = Double(band) + 300
            let amplitude = height * (0.12 + 0.16 * random(seed, 1))
            let wavelength = 30 + 34 * random(seed, 2)
            let speed = 22 + 34 * random(seed, 3)
            let thickness = 1.8 + 2.2 * random(seed, 4)
            let phase = time * speed / wavelength * 2 * .pi
            for stream in 0..<2 {
                let toNear = stream == 0
                var path = Path()
                let steps = Int(width / 3) + 1
                for step in 0...steps {
                    let x = min(width, Double(step) * 3)
                    let y = height / 2 + amplitude * sin(x / wavelength * 2 * .pi + (toNear ? phase : -phase) + seed * (toNear ? 1 : 1.7))
                    if step == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
                }
                var plasma = context
                plasma.blendMode = .plusLighter
                plasma.addFilter(.blur(radius: 2.5))
                let reach = width * 0.55
                let side = toNear ? CGRect(x: 0, y: 0, width: seam, height: height) : CGRect(x: seam, y: 0, width: width - seam, height: height)
                plasma.clip(to: Path(side))
                let color = toNear ? headsNear : lead
                let brightness = 0.32 + 0.16 * random(seed, 5)
                plasma.stroke(
                    path,
                    with: .linearGradient(
                        Gradient(colors: toNear ? [color.opacity(0), color.opacity(brightness)] : [color.opacity(brightness), color.opacity(0)]),
                        startPoint: CGPoint(x: toNear ? seam - reach : seam, y: 0),
                        endPoint: CGPoint(x: toNear ? seam : seam + reach, y: 0)
                    ),
                    style: StrokeStyle(lineWidth: thickness, lineCap: .round, lineJoin: .round)
                )
            }
        }

        // Sparks off the seam, flung to either side on beats of their own, white as they
        // leave and the colour of the side they land in as they cool.
        for index in 0..<22 {
            let seed = Double(index) + 400
            let life = 0.7 + 0.8 * random(seed, 1)
            let age = (time + random(seed, 2) * life).truncatingRemainder(dividingBy: life)
            let progress = age / life
            let toNear = random(seed, 3) < 0.5
            let speed = 28 + 74 * random(seed, 4)
            let x = seam + (toNear ? -1 : 1) * speed * age
            let y = height * (0.18 + 0.64 * random(seed, 5)) + 5 * sin(age * 8 + seed)
            let radius = 0.7 + 1.5 * (1 - progress)
            let opacity = (1 - progress) * (0.5 + 0.5 * random(seed, 6)) * edgeFade(x, width: width)
            guard opacity > 0.01 else { continue }
            let color = Color.white.mix(with: toNear ? lead : headsNear, by: progress * 0.8)
            context.fill(
                Path(ellipseIn: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)),
                with: .color(color.opacity(opacity))
            )
        }

        // The seam: a white-hot core that breathes, its glow spilling to both sides.
        var glow = context
        glow.blendMode = .plusLighter
        glow.addFilter(.blur(radius: 7))
        let coreWidth = 9 + 8 * pulse
        glow.fill(
            Path(ellipseIn: CGRect(x: seam - coreWidth, y: -height * 0.2, width: coreWidth * 2, height: height * 1.4)),
            with: .color(.white.opacity(0.32 + 0.3 * pulse))
        )
        var core = context
        core.addFilter(.blur(radius: 0.8))
        core.fill(
            Path(roundedRect: CGRect(x: seam - 1.1, y: 2, width: 2.2, height: height - 4), cornerRadius: 1.1),
            with: .color(.white.opacity(0.5 + 0.4 * pulse))
        )

        drawSheen(context, size: size, time: time, color: .white)
    }

    /// Fades a point out over the last 14 points at either end of the fill.
    private static func edgeFade(_ x: Double, width: Double) -> Double {
        min(1, max(0, x / 14), max(0, (width - x) / 14))
    }

    /// A stable pseudo-random value in 0..<1 for an element and one of its traits.
    nonisolated static func random(_ index: Double, _ trait: Double) -> Double {
        let value = sin(index * 12.9898 + trait * 78.233) * 43758.5453
        return value - value.rounded(.down)
    }
}
