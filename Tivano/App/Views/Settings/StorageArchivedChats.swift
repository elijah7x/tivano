import SwiftUI

// MARK: - Quick find section

struct StorageFindChatSection: View {
    @Environment(AppModel.self) private var model
    @Binding var filter: ArchiveFilter
    let onShowAll: () -> Void

    @State private var debouncedQuery: String
    @State private var pendingDeletion: ArchivePendingDeletion?
    @State private var listModel = ArchiveListModel()

    init(filter: Binding<ArchiveFilter>, onShowAll: @escaping () -> Void) {
        self._filter = filter
        self.onShowAll = onShowAll
        self._debouncedQuery = State(initialValue: filter.wrappedValue.query)
    }

    var body: some View {
        let archived = listModel.archived(for: model)
        let queryFilter = ArchiveFilter(query: debouncedQuery)
        let hasQuery = !queryFilter.trimmedQuery.isEmpty
        let result = listModel.quickSelection(for: model, queryFilter: queryFilter, hasQuery: hasQuery)

        ChromeSection(title: "Find a chat") {
            if archived.isEmpty {
                ArchiveSectionNote(text: "Chats you archive leave the sidebar and wait here. Nothing is archived yet.")
            } else {
                ChromeSearchField(query: $filter.query, prompt: "Search archived chats")
                if result.shown.isEmpty {
                    ArchiveEmptyMatchesView()
                } else {
                    let projectsByID = listModel.projectsByID(for: model)
                    ChromeCard {
                        ForEach(result.shown) { thread in
                            if thread.id != result.shown.first?.id { ChromeRowDivider() }
                            let title = ArchiveFormatting.title(for: thread)
                            ArchiveChatRow(
                                title: title,
                                detail: ArchiveFormatting.projectDetail(for: thread, projectsByID: projectsByID),
                                onRestore: { model.unarchive(thread.id) },
                                onDelete: {
                                    ArchiveDeletionHelper.request(
                                        thread: thread,
                                        title: title,
                                        model: model,
                                        pendingDeletion: $pendingDeletion
                                    )
                                }
                            )
                        }
                        if result.totalCount > result.shown.count || (!hasQuery && result.totalCount > 0) {
                            ChromeRowDivider()
                            let showAllTitle = String(
                                format: Chrome.localized(hasQuery ? "Show all %lld matches" : "Show all %lld archived chats"),
                                result.totalCount
                            )
                            Button(action: onShowAll) {
                                ChromeRow(title: showAllTitle, localizesTitle: false) {
                                    Image(systemName: "chevron.right")
                                        .font(.ui(.caption, weight: .semibold))
                                        .foregroundStyle(Chrome.secondaryText)
                                }
                                .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .archiveDebouncedQuery(filter.query, into: $debouncedQuery)
        .archiveDeletionConfirmation(pendingDeletion: $pendingDeletion)
    }
}

// MARK: - Full archive page

struct ArchivedChatsPage: View {
    @Environment(AppModel.self) private var model
    @Binding var filter: ArchiveFilter
    let onBack: () -> Void

    @State private var debouncedQuery: String
    @State private var pendingDeletion: ArchivePendingDeletion?
    @State private var listModel = ArchiveListModel()

    init(filter: Binding<ArchiveFilter>, onBack: @escaping () -> Void) {
        self._filter = filter
        self.onBack = onBack
        self._debouncedQuery = State(initialValue: filter.wrappedValue.query)
    }

    var body: some View {
        let data = listModel.data(for: model)
        let optionScopes = data.options.map(\.value)
        let effectiveProject = (filter.project == .all || optionScopes.contains(filter.project)) ? filter.project : .all
        let effectiveFilter = ArchiveFilter(query: debouncedQuery, chatType: filter.chatType, project: effectiveProject)
        let (groups, shownIDs) = listModel.filtered(data, by: effectiveFilter)

        VStack(alignment: .leading, spacing: Chrome.sectionSpacing) {
            ChromeTextButton(symbol: "chevron.left", title: "Storage", help: "Storage", action: onBack)
            ChromeSection(
                title: "Archived chats",
                trailing: data.isEmpty ? nil : AnyView(ArchiveBulkDeleteButton(threadIDs: shownIDs, isFiltered: effectiveFilter.isActive))
            ) {
                ArchiveSectionNote(text: data.isEmpty
                    ? "Chats you archive leave the sidebar and wait here. Nothing is archived yet."
                    : "Restore a chat to the sidebar, or delete it for good. A chat's worktree can go with it.")
                if !data.isEmpty {
                    HStack(spacing: 8) {
                        ChromeSearchField(query: $filter.query, prompt: "Search archived chats")
                        GlassPickerButton(options: ArchiveFilter.ChatType.allCases.map { ($0, $0.title) }, selection: $filter.chatType)
                            .accessibilityLabel(Text("Chat type"))
                        GlassPickerButton(options: data.options, selection: $filter.project, symbol: { _ in "folder" })
                            .accessibilityLabel(Text("Project"))
                    }
                    if groups.isEmpty {
                        ArchiveEmptyMatchesView()
                    }
                    ForEach(groups) { group in
                        VStack(alignment: .leading, spacing: 8) {
                            // A project label, quieter than the section title, so it reads as a
                            // group within Archived chats rather than a section of its own.
                            HStack(spacing: 6) {
                                Image(systemName: "folder")
                                Text(verbatim: Chrome.localized(group.title))
                                Spacer(minLength: 8)
                                Text(verbatim: String(format: Chrome.localized("%lld chats"), group.rows.count))
                            }
                            .font(.ui(.subheadline))
                            .foregroundStyle(Chrome.secondaryText)
                            .padding(.horizontal, 4)
                            ChromeCard(lazy: true) {
                                ForEach(group.rows) { row in
                                    if row.id != group.rows.first?.id { ChromeRowDivider() }
                                    ArchiveChatRow(
                                        title: row.title,
                                        detail: row.dateDetail,
                                        onRestore: { model.unarchive(row.id) },
                                        onDelete: {
                                            ArchiveDeletionHelper.request(
                                                thread: row.thread,
                                                title: row.title,
                                                model: model,
                                                pendingDeletion: $pendingDeletion
                                            )
                                        }
                                    )
                                }
                            }
                        }
                        .padding(.top, 6)
                    }
                }
            }
        }
        .archiveDebouncedQuery(filter.query, into: $debouncedQuery)
        .archiveDeletionConfirmation(pendingDeletion: $pendingDeletion)
        .onChange(of: optionScopes, initial: true) { _, scopes in
            if filter.project != .all, !scopes.contains(filter.project) {
                filter.project = .all
            }
        }
    }
}

// MARK: - List model & formatting

private struct ArchiveChatItem: Identifiable {
    let thread: ChatThread
    let title: String
    let dateDetail: String
    var id: UUID { thread.id }
}

private struct ArchiveProjectGroup: Identifiable {
    let id: ArchiveFilter.ProjectScope
    let title: String
    let rows: [ArchiveChatItem]
}

private struct ArchiveSnapshot {
    let revision: UInt64
    let isEmpty: Bool
    let options: [(value: ArchiveFilter.ProjectScope, title: String)]
    let groups: [ArchiveProjectGroup]
    let allIDs: Set<UUID>
}

@MainActor
private final class ArchiveListModel {
    private struct QuickSelectionKey: Equatable {
        let threadsRevision: UInt64
        let trimmedQuery: String
    }

    private struct FilteredKey: Equatable {
        let dataRevision: UInt64
        let filter: ArchiveFilter
    }

    private weak var source: AppModel?
    private var archivedRevision: UInt64?
    private var cachedArchived: [ChatThread] = []
    private var projectsByIDRevision: UInt64?
    private var cachedProjectsByID: [UUID: String] = [:]
    private var quickSelectionKey: QuickSelectionKey?
    private var cachedQuickSelection: (shown: [ChatThread], totalCount: Int) = ([], 0)
    private var snapshotRevisions: (threads: UInt64, projects: UInt64)?
    private var snapshotRevision: UInt64 = 0
    private var cachedSnapshot: ArchiveSnapshot?
    private var filteredKey: FilteredKey?
    private var cachedFiltered: (groups: [ArchiveProjectGroup], shownIDs: Set<UUID>) = ([], [])

    private func ensureSource(_ model: AppModel) {
        guard source !== model else { return }
        source = model
        archivedRevision = nil
        cachedArchived = []
        projectsByIDRevision = nil
        cachedProjectsByID = [:]
        quickSelectionKey = nil
        cachedQuickSelection = ([], 0)
        snapshotRevisions = nil
        cachedSnapshot = nil
        filteredKey = nil
        cachedFiltered = ([], [])
    }

    func archived(for model: AppModel) -> [ChatThread] {
        ensureSource(model)
        let rev = model.threadsRevision
        if archivedRevision == rev { return cachedArchived }
        let result = model.archivedThreads
        archivedRevision = rev
        cachedArchived = result
        return result
    }

    func projectsByID(for model: AppModel) -> [UUID: String] {
        ensureSource(model)
        let rev = model.projectsRevision
        if projectsByIDRevision == rev { return cachedProjectsByID }
        let result = Dictionary(
            model.projects.map { ($0.id, $0.name) },
            uniquingKeysWith: { first, _ in first }
        )
        projectsByIDRevision = rev
        cachedProjectsByID = result
        return result
    }

    func quickSelection(
        for model: AppModel,
        queryFilter: ArchiveFilter,
        hasQuery: Bool
    ) -> (shown: [ChatThread], totalCount: Int) {
        let archivedThreads = archived(for: model)
        let key = QuickSelectionKey(threadsRevision: model.threadsRevision, trimmedQuery: queryFilter.trimmedQuery)
        if quickSelectionKey == key { return cachedQuickSelection }
        let result: (shown: [ChatThread], totalCount: Int)
        if hasQuery {
            let matches = archivedThreads.filter { queryFilter.matchesSearch($0) }
            result = (Array(matches.prefix(8)), matches.count)
        } else {
            result = (Array(archivedThreads.prefix(5)), archivedThreads.count)
        }
        quickSelectionKey = key
        cachedQuickSelection = result
        return result
    }

    func data(for model: AppModel) -> ArchiveSnapshot {
        ensureSource(model)
        let threadsRev = model.threadsRevision
        let projectsRev = model.projectsRevision
        if let cachedSnapshot, snapshotRevisions?.threads == threadsRev, snapshotRevisions?.projects == projectsRev {
            return cachedSnapshot
        }
        let archivedThreads = archived(for: model)
        let allProjects = model.projects
        snapshotRevision &+= 1
        let result: ArchiveSnapshot
        if archivedThreads.isEmpty {
            result = ArchiveSnapshot(
                revision: snapshotRevision,
                isEmpty: true,
                options: [(.all, "All projects"), (.none, "No project")],
                groups: [],
                allIDs: []
            )
        } else {
            let projects = ArchiveFilter.projects(in: archivedThreads, from: allProjects)
            let known = Set(projects.map(\.id))
            let options: [(value: ArchiveFilter.ProjectScope, title: String)] = [(.all, "All projects")]
                + projects.map { (.project($0.id), $0.name) } + [(.none, "No project")]
            let rows = archivedThreads.map { thread in
                ArchiveChatItem(
                    thread: thread,
                    title: ArchiveFormatting.title(for: thread),
                    dateDetail: ArchiveFormatting.dateText(for: thread)
                )
            }
            let grouped = Dictionary(grouping: rows) { ArchiveFilter.scope(of: $0.thread, known: known) }
            let groups = options.filter { $0.value != .all }.compactMap { option -> ArchiveProjectGroup? in
                guard let rows = grouped[option.value], !rows.isEmpty else { return nil }
                return ArchiveProjectGroup(id: option.value, title: option.title, rows: rows)
            }
            result = ArchiveSnapshot(
                revision: snapshotRevision,
                isEmpty: false,
                options: options,
                groups: groups,
                allIDs: Set(archivedThreads.map(\.id))
            )
        }
        snapshotRevisions = (threadsRev, projectsRev)
        cachedSnapshot = result
        return result
    }

    func filtered(_ data: ArchiveSnapshot, by filter: ArchiveFilter) -> (groups: [ArchiveProjectGroup], shownIDs: Set<UUID>) {
        let normalized = ArchiveFilter(query: filter.trimmedQuery, chatType: filter.chatType, project: filter.project)
        let key = FilteredKey(dataRevision: data.revision, filter: normalized)
        if filteredKey == key { return cachedFiltered }
        let result: (groups: [ArchiveProjectGroup], shownIDs: Set<UUID>)
        if !normalized.isActive {
            result = (data.groups, data.allIDs)
        } else {
            var shownIDs = Set<UUID>()
            let groups = data.groups.compactMap { group -> ArchiveProjectGroup? in
                if normalized.project != .all, group.id != normalized.project { return nil }
                let matching = group.rows.filter { row in
                    let thread = row.thread
                    let matchesType = normalized.chatType == .all
                        || (normalized.chatType == .heads ? thread.isHydraHead : !thread.isHydraHead)
                    return matchesType && normalized.matchesSearch(thread)
                }
                guard !matching.isEmpty else { return nil }
                for row in matching { shownIDs.insert(row.id) }
                return ArchiveProjectGroup(id: group.id, title: group.title, rows: matching)
            }
            result = (groups, shownIDs)
        }
        filteredKey = key
        cachedFiltered = result
        return result
    }
}

private enum ArchiveFormatting {
    static func title(for thread: ChatThread) -> String {
        if let info = thread.hydra, !info.task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "\(info.persona.name) · \(info.task)"
        }
        return thread.displayTitle
    }

    static func dateText(for thread: ChatThread) -> String {
        thread.updatedAt.formatted(date: .abbreviated, time: .shortened)
    }

    static func projectDetail(for thread: ChatThread, projectsByID: [UUID: String]) -> String {
        let projectName = thread.projectID.flatMap { projectsByID[$0] } ?? Chrome.localized("No project")
        return "\(projectName) · \(dateText(for: thread))"
    }
}

// MARK: - Shared UI & deletion helpers

private struct ArchiveSectionNote: View {
    let text: String

    var body: some View {
        Text(verbatim: Chrome.localized(text))
            .font(.ui(.subheadline))
            .foregroundStyle(Chrome.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct ArchiveEmptyMatchesView: View {
    var body: some View {
        Text("No matching chats")
            .font(.ui(.body))
            .foregroundStyle(Chrome.secondaryText)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, Chrome.sectionSpacing)
    }
}

private struct ArchiveChatRow: View {
    let title: String
    let detail: String
    let onRestore: () -> Void
    let onDelete: () -> Void

    var body: some View {
        ChromeRow(title: title, detail: detail, localizesDetail: false, localizesTitle: false) {
            HStack(spacing: 8) {
                Button("Restore", action: onRestore)
                    .chromePillButton()
                Button("Delete", role: .destructive, action: onDelete)
                    .chromePillButton()
            }
        }
    }
}

private struct ArchivePendingDeletion: Identifiable {
    let thread: ChatThread
    let title: String
    let hasOwnWorktree: Bool
    var id: UUID { thread.id }
}

private enum ArchiveDeletionHelper {
    @MainActor
    static func request(
        thread: ChatThread,
        title: String,
        model: AppModel,
        pendingDeletion: Binding<ArchivePendingDeletion?>
    ) {
        let hasOwnWorktree = model.ownWorktree(of: thread) != nil
        // A chat holding a worktree always asks, since the
        // answer decides whether its space is freed.
        if model.settings.confirmBeforeDeleting || hasOwnWorktree {
            pendingDeletion.wrappedValue = ArchivePendingDeletion(
                thread: thread,
                title: title,
                hasOwnWorktree: hasOwnWorktree
            )
        } else {
            model.delete(thread.id)
        }
    }
}

private struct ArchiveDeletionConfirmationModifier: ViewModifier {
    @Environment(AppModel.self) private var model
    @Binding var pendingDeletion: ArchivePendingDeletion?

    func body(content: Content) -> some View {
        content.confirmationDialog(
            pendingDeletion.map { String(format: Chrome.localized("Delete \"%@\"?"), $0.title) }
                ?? Chrome.localized("Delete the archived chat?"),
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            presenting: pendingDeletion
        ) { row in
            if row.hasOwnWorktree {
                Button("Delete chat and worktree", role: .destructive) {
                    model.delete(row.thread.id, removeWorktree: true)
                    pendingDeletion = nil
                }
                Button("Delete chat, keep worktree") {
                    model.delete(row.thread.id)
                    pendingDeletion = nil
                }
            } else {
                Button("Delete chat", role: .destructive) {
                    model.delete(row.thread.id)
                    pendingDeletion = nil
                }
            }
        } message: { row in
            if row.hasOwnWorktree {
                Text("Its history will be removed. Removing its worktree frees its space; its branch and commits stay, and a worktree with uncommitted changes is kept.")
            } else {
                Text("Its history will be removed. Files in your project stay as they are.")
            }
        }
    }
}

private struct ArchiveDebouncedQueryModifier: ViewModifier {
    let query: String
    @Binding var debouncedQuery: String

    func body(content: Content) -> some View {
        content.task(id: query) {
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            let currentTrimmed = debouncedQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed == currentTrimmed {
                if debouncedQuery != query { debouncedQuery = query }
                return
            }
            if trimmed.isEmpty {
                debouncedQuery = ""
                return
            }
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            debouncedQuery = query
        }
    }
}

private extension View {
    func archiveDeletionConfirmation(pendingDeletion: Binding<ArchivePendingDeletion?>) -> some View {
        modifier(ArchiveDeletionConfirmationModifier(pendingDeletion: pendingDeletion))
    }

    func archiveDebouncedQuery(_ query: String, into debouncedQuery: Binding<String>) -> some View {
        modifier(ArchiveDebouncedQueryModifier(query: query, debouncedQuery: debouncedQuery))
    }
}

private struct ArchiveBulkDeleteButton: View {
    @Environment(AppModel.self) private var model
    let threadIDs: Set<UUID>
    let isFiltered: Bool
    @State private var pending: ArchiveBulkPendingDeletion?

    /// The chats a confirmation is about, handed to the popover with its presentation:
    /// separate state read by `isPresented` content could still be empty when it renders.
    private struct ArchiveBulkPendingDeletion: Identifiable {
        let id = UUID()
        let ids: Set<UUID>
        let isFiltered: Bool
    }

    var body: some View {
        let helpText = Chrome.localized(isFiltered ? "Delete matching archived chats" : "Delete every archived chat")
        Button(role: .destructive) {
            if model.settings.confirmBeforeDeleting {
                pending = ArchiveBulkPendingDeletion(ids: threadIDs, isFiltered: isFiltered)
            } else {
                model.deleteArchivedThreads(ids: threadIDs)
            }
        } label: {
            Label {
                Text(verbatim: String(format: Chrome.localized(isFiltered ? "Delete matching chats (%lld)" : "Delete all archived chats (%lld)"), threadIDs.count))
            } icon: {
                Image.themed("trash")
            }
        }
        .chromePillButton()
        .disabled(threadIDs.isEmpty)
        .help(Text(verbatim: helpText))
        .accessibilityLabel(Text(verbatim: helpText))
        .popover(item: $pending, arrowEdge: .bottom) { pending in
            PopoverMenu(scrolls: false) {
                PopoverSectionHeader(pending.isFiltered ? "Delete matching archived chats?" : "Delete all archived chats?")
                PopoverNote(String(format: Chrome.localized(pending.isFiltered
                    ? "The histories of the %lld matching chats will be removed. Files in your projects stay as they are."
                    : "The histories of all %lld chats will be removed. Files in your projects stay as they are."), pending.ids.count))
                PopoverDivider()
                PopoverItem(String(format: Chrome.localized("Delete %lld chats"), pending.ids.count), symbol: "trash", isDestructive: true) {
                    model.deleteArchivedThreads(ids: pending.ids)
                    self.pending = nil
                }
            }
        }
    }
}
