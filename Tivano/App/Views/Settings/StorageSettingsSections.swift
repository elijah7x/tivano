import SwiftUI

/// The storage page: what Tivano keeps on this Mac, the worktrees it made, and the
/// archived chats, so freeing space and tidying chats happen in one place.
struct StorageSettingsPage: View {
    @Environment(AppModel.self) private var model
    @Binding var filter: ArchiveFilter
    @State private var usage: StorageUsage?
    @State private var generation = 0

    var body: some View {
        VStack(alignment: .leading, spacing: Chrome.pageSectionSpacing) {
            StorageOverviewSection(usage: usage) { generation += 1 }
            if let usage, !usage.worktrees.isEmpty {
                StorageWorktreesSection(worktrees: usage.worktrees) { generation += 1 }
            }
            ArchivedChatsSection(filter: $filter, usage: usage)
        }
        // Deleting a chat can take its worktree with it, so the measure follows the library.
        .task(id: "\(model.threads.count)-\(generation)") {
            let measured = await Storage.measureUsage()
            guard !Task.isCancelled else { return }
            usage = measured
        }
    }
}

private func formattedSize(_ bytes: Int64) -> String {
    bytes.formatted(.byteCount(style: .file))
}

/// A section's one-line explanation, under its header.
private struct StorageSectionNote: View {
    let text: String

    var body: some View {
        Text(verbatim: Chrome.localized(text))
            .font(.ui(.subheadline))
            .foregroundStyle(Chrome.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Overview

private struct StorageOverviewSection: View {
    @Environment(AppModel.self) private var model
    let usage: StorageUsage?
    let refresh: () -> Void

    private struct Part: Identifiable {
        let title: String
        let bytes: Int64
        let color: Color
        var id: String { title }
    }

    var body: some View {
        ChromeSection(title: "On this Mac") {
            StorageSectionNote(text: "Chats, attachments and the worktrees Tivano made for your projects.")
            ChromeCard {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text(verbatim: usage.map { String(format: Chrome.localized("Tivano uses %@"), formattedSize(total($0))) }
                            ?? Chrome.localized("Measuring…"))
                            .font(.ui(.body, weight: .semibold))
                            .foregroundStyle(Chrome.primaryText)
                        Spacer(minLength: 12)
                        if usage == nil {
                            ProgressView().controlSize(.small)
                        } else {
                            Button("Refresh", action: refresh)
                                .buttonStyle(.glass)
                                .controlSize(.small)
                        }
                    }
                    let parts = parts
                    bar(parts)
                    HStack(alignment: .top, spacing: 24) {
                        ForEach(parts) { part in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Circle().fill(part.color).frame(width: 8, height: 8)
                                    Text(verbatim: Chrome.localized(part.title))
                                        .font(.ui(.subheadline))
                                        .foregroundStyle(Chrome.primaryText)
                                }
                                Text(verbatim: usage == nil ? "—" : formattedSize(part.bytes))
                                    .font(.ui(.subheadline))
                                    .foregroundStyle(Chrome.secondaryText)
                                    .monospacedDigit()
                                    .padding(.leading, 14)
                            }
                        }
                    }
                    if let usage, usage.buildFilesTotal > 0 {
                        Text(verbatim: String(format: Chrome.localized("%@ of the worktrees is dependencies and build output, which can be deleted and rebuilt."),
                                              formattedSize(usage.buildFilesTotal)))
                            .font(.ui(.subheadline))
                            .foregroundStyle(Chrome.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(16)
            }
        }
    }

    private var parts: [Part] {
        let archivedIDs = Set(model.threads.filter(\.isArchived).map(\.id))
        let archived = usage?.chatSizes.reduce(Int64(0)) { $0 + (archivedIDs.contains($1.key) ? $1.value : 0) } ?? 0
        var parts = [
            Part(title: "Chats", bytes: (usage.map { $0.chats + $0.attachments } ?? 0) - archived, color: Chrome.blue),
            Part(title: "Archived chats", bytes: archived, color: Chrome.orange),
            Part(title: "Worktrees", bytes: usage?.worktreesTotal ?? 0, color: Chrome.success),
        ]
        if let patches = usage?.patches, patches > 0 {
            parts.append(Part(title: "Other", bytes: patches, color: Chrome.gray))
        }
        return parts
    }

    private func total(_ usage: StorageUsage) -> Int64 {
        usage.chats + usage.attachments + usage.worktreesTotal + usage.patches
    }

    private func bar(_ parts: [Part]) -> some View {
        let shown = parts.filter { $0.bytes > 0 }
        let sum = max(shown.reduce(Int64(0)) { $0 + $1.bytes }, 1)
        return GeometryReader { proxy in
            let width = proxy.size.width - CGFloat(max(shown.count - 1, 0)) * 2
            HStack(spacing: 2) {
                ForEach(shown) { part in
                    Rectangle()
                        .fill(part.color)
                        .frame(width: max(2, width * CGFloat(part.bytes) / CGFloat(sum)))
                }
                Spacer(minLength: 0)
            }
            .background(Chrome.overlay(0.1))
            .clipShape(Capsule(style: .continuous))
        }
        .frame(height: 10)
        .accessibilityHidden(true)
    }
}

// MARK: - Worktrees

private struct StorageWorktreesSection: View {
    @Environment(AppModel.self) private var model
    let worktrees: [WorktreeUsage]
    let changed: () -> Void
    @State private var busy: Set<String> = []
    @State private var pendingRemoval: WorktreeUsage?

    var body: some View {
        ChromeSection(title: "Worktrees") {
            StorageSectionNote(text: "Each worktree is a separate copy of a project, made so a chat can work without touching your checkout. Most of its space is usually dependencies and build output.")
            ChromeCard {
                ForEach(worktrees) { worktree in
                    if worktree.id != worktrees.first?.id { ChromeRowDivider() }
                    ChromeRow(title: worktree.name, detail: detail(for: worktree), localizesDetail: false) {
                        if busy.contains(worktree.path) {
                            ProgressView().controlSize(.small)
                        } else if worktree.buildFilesSize > 0 || model.canRemove(worktree) {
                            FreeSpaceButton(worktree: worktree, canRemove: model.canRemove(worktree),
                                            reason: reason(for: worktree)) { action in
                                switch action {
                                case .buildFiles: run(worktree) { await model.removeBuildFiles(of: worktree) }
                                case .worktree: pendingRemoval = worktree
                                }
                            }
                        }
                    }
                }
            }
        }
        .confirmationDialog(
            pendingRemoval.map { String(format: Chrome.localized("Delete the worktree \"%@\"?"), $0.name) } ?? "",
            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
            presenting: pendingRemoval
        ) { worktree in
            Button(String(format: Chrome.localized("Delete worktree (%@)"), formattedSize(worktree.size)), role: .destructive) {
                pendingRemoval = nil
                run(worktree) { _ = await model.removeUnusedWorktree(worktree) }
            }
        } message: { worktree in
            Text(worktree.isRegistered
                ? "The whole folder is deleted. Its branch and commits stay in the repository."
                : "Git no longer knows this folder, so it is moved to the Trash.")
        }
    }

    private func detail(for worktree: WorktreeUsage) -> String {
        let users = model.threadsUsing(worktree)
        var parts: [String]
        if let thread = users.first(where: { !$0.isHelper }) ?? users.first {
            parts = [String(format: Chrome.localized(thread.isArchived ? "Used by archived chat “%@”" : "Used by chat “%@”"), thread.title)]
        } else {
            parts = [Chrome.localized(worktree.isRegistered ? "Not used by any chat" : "Leftover folder, not a worktree")]
        }
        if worktree.buildFilesSize > 0 {
            parts.append(String(format: Chrome.localized("%@, of which %@ build files"), formattedSize(worktree.size), formattedSize(worktree.buildFilesSize)))
        } else {
            parts.append(formattedSize(worktree.size))
        }
        if let changed = worktree.changedFiles, changed > 0 {
            parts.append(String(format: Chrome.localized("%lld uncommitted changes"), changed))
        }
        return parts.joined(separator: " · ")
    }

    /// Why the whole worktree cannot go from here, shown under the greyed-out choice.
    private func reason(for worktree: WorktreeUsage) -> String? {
        guard !model.canRemove(worktree) else { return nil }
        if !model.threadsUsing(worktree).isEmpty {
            return "A chat still uses it. Delete that chat to delete its worktree."
        }
        if (worktree.changedFiles ?? 0) > 0 {
            return "It has uncommitted changes. Commit or discard them first."
        }
        return "It is in use by a project."
    }

    private func run(_ worktree: WorktreeUsage, _ action: @escaping () async -> Void) {
        busy.insert(worktree.path)
        Task {
            await action()
            busy.remove(worktree.path)
            changed()
        }
    }
}

/// One button per worktree; its menu spells out the two ways to free space.
private struct FreeSpaceButton: View {
    enum Action { case buildFiles, worktree }

    let worktree: WorktreeUsage
    let canRemove: Bool
    let reason: String?
    let perform: (Action) -> Void
    @State private var isPresented = false

    var body: some View {
        Button("Free up space…") { isPresented = true }
            .buttonStyle(.glass)
            .controlSize(.small)
            .popover(isPresented: $isPresented, arrowEdge: .bottom) {
                PopoverMenu {
                    if worktree.buildFilesSize > 0 {
                        PopoverItem("Delete build files", detail: formattedSize(worktree.buildFilesSize), symbol: "hammer") {
                            isPresented = false
                            perform(.buildFiles)
                        }
                        PopoverNote("Deletes node_modules and other dependency and build folders. Your code and changes stay; the next install or build brings them back.")
                        PopoverDivider()
                    }
                    PopoverItem("Delete worktree", detail: formattedSize(worktree.size), symbol: "trash",
                                isEnabled: canRemove, isDestructive: true) {
                        isPresented = false
                        perform(.worktree)
                    }
                    PopoverNote(reason ?? "Deletes this whole copy. Its branch and commits stay in the repository.")
                }
                .frame(width: 320)
            }
    }
}

// MARK: - Archived chats

private struct ArchivedChatsSection: View {
    @Environment(AppModel.self) private var model
    @Binding var filter: ArchiveFilter
    let usage: StorageUsage?
    @State private var pendingDeletion: ArchiveRow?

    private struct ArchiveRow: Identifiable {
        let thread: ChatThread
        let title: String
        var id: UUID { thread.id }
    }

    private struct ArchiveGroup: Identifiable {
        let id: ArchiveFilter.ProjectScope
        let title: String
        let rows: [ArchiveRow]
    }

    var body: some View {
        let archived = model.archivedThreads
        let projects = ArchiveFilter.projects(in: archived, from: model.projects)
        let known = Set(projects.map(\.id))
        let options: [(value: ArchiveFilter.ProjectScope, title: String)] = [(.all, "All projects")]
            + projects.map { (.project($0.id), $0.name) } + [(.none, "No project")]
        let shown = filter.apply(to: archived, known: known)
        let rows = shown.map { thread in
            let title: String
            if let info = thread.hydra, !info.task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                title = "\(info.persona.name) · \(info.task)"
            } else {
                title = thread.title
            }
            return ArchiveRow(thread: thread, title: title)
        }
        let grouped = Dictionary(grouping: rows) { ArchiveFilter.scope(of: $0.thread, known: known) }
        let groups = options.filter { $0.value != .all }.compactMap { option -> ArchiveGroup? in
            guard let rows = grouped[option.value], !rows.isEmpty else { return nil }
            return ArchiveGroup(id: option.value, title: option.title, rows: rows)
        }
        ChromeSection(
            title: "Archived chats",
            trailing: archived.isEmpty ? nil : AnyView(ArchiveDeleteAllButton(threadIDs: Set(shown.map(\.id)), isFiltered: filter.isActive))
        ) {
            StorageSectionNote(text: archived.isEmpty
                ? "Chats you archive leave the sidebar and wait here. Nothing is archived yet."
                : "Restore a chat to the sidebar, or delete it for good. A chat's worktree can go with it.")
            if !archived.isEmpty {
                HStack(spacing: 8) {
                    ChromeSearchField(query: $filter.query, prompt: "Search archived chats")
                    GlassPickerButton(options: ArchiveFilter.ChatType.allCases.map { ($0, $0.title) }, selection: $filter.chatType)
                        .accessibilityLabel(Text("Chat type"))
                    GlassPickerButton(options: options, selection: $filter.project, symbol: { _ in "folder" })
                        .accessibilityLabel(Text("Project"))
                }
                if groups.isEmpty {
                    Text("No matching chats")
                        .font(.ui(.body))
                        .foregroundStyle(Chrome.secondaryText)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, Chrome.sectionSpacing)
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
                                ChromeRow(title: row.title, detail: detail(for: row.thread), localizesDetail: false) {
                                    HStack(spacing: 8) {
                                        Button("Restore") { model.unarchive(row.id) }
                                            .buttonStyle(.glass)
                                        Button("Delete", role: .destructive) {
                                            // A chat holding a worktree always asks, since the
                                            // answer decides whether its space is freed.
                                            if model.settings.confirmBeforeDeleting || model.ownWorktree(of: row.thread) != nil {
                                                pendingDeletion = row
                                            } else {
                                                model.delete(row.id)
                                            }
                                        }
                                        .buttonStyle(.glass)
                                    }
                                    .controlSize(.small)
                                }
                            }
                        }
                    }
                    .padding(.top, 6)
                }
            }
        }
        .confirmationDialog(
            pendingDeletion.map { String(format: Chrome.localized("Delete \"%@\"?"), $0.title) } ?? Chrome.localized("Delete the archived thread?"),
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            presenting: pendingDeletion
        ) { row in
            if model.ownWorktree(of: row.thread) != nil {
                Button("Delete thread and worktree", role: .destructive) {
                    model.delete(row.id, removeWorktree: true)
                    pendingDeletion = nil
                }
                Button("Delete thread, keep worktree") {
                    model.delete(row.id)
                    pendingDeletion = nil
                }
            } else {
                Button("Delete thread", role: .destructive) {
                    model.delete(row.id)
                    pendingDeletion = nil
                }
            }
        } message: { row in
            if model.ownWorktree(of: row.thread) != nil {
                Text("Its history will be removed. Removing its worktree frees its space; its branch and commits stay, and a worktree with uncommitted changes is kept.")
            } else {
                Text("Its history will be removed. Files in your project stay as they are.")
            }
        }
    }

    /// When it was last active, and the space its worktree holds.
    private func detail(for thread: ChatThread) -> String {
        var parts = [thread.updatedAt.formatted(date: .abbreviated, time: .shortened)]
        if let path = model.ownWorktree(of: thread),
           let worktree = usage?.worktrees.first(where: { $0.path == path }) {
            parts.append(String(format: Chrome.localized("Worktree %@"), formattedSize(worktree.size)))
        }
        return parts.joined(separator: " · ")
    }
}

struct ArchiveDeleteAllButton: View {
    @Environment(AppModel.self) private var model
    let threadIDs: Set<UUID>
    let isFiltered: Bool
    @State private var isConfirming = false
    @State private var pendingIDs: Set<UUID> = []
    @State private var pendingIsFiltered = false

    var body: some View {
        ChromeTextButton(
            symbol: "trash",
            title: String(format: Chrome.localized(isFiltered ? "Delete matching chats (%lld)" : "Delete all archived chats (%lld)"), threadIDs.count),
            help: isFiltered ? "Delete matching archived chats" : "Delete every archived thread",
            isEnabled: !threadIDs.isEmpty,
            isDestructive: true
        ) {
            if model.settings.confirmBeforeDeleting {
                pendingIDs = threadIDs
                pendingIsFiltered = isFiltered
                isConfirming = true
            } else {
                model.deleteArchivedThreads(ids: threadIDs)
            }
        }
        .popover(isPresented: $isConfirming, arrowEdge: .bottom) {
            PopoverMenu {
                PopoverSectionHeader(pendingIsFiltered ? "Delete matching archived chats?" : "Delete all archived threads?")
                PopoverNote(String(format: Chrome.localized(pendingIsFiltered
                    ? "The histories of the %lld matching chats will be removed. Files in your projects stay as they are."
                    : "The histories of all %lld threads will be removed. Files in your projects stay as they are."), pendingIDs.count))
                PopoverDivider()
                PopoverItem(String(format: Chrome.localized("Delete %lld threads"), pendingIDs.count), symbol: "trash", isDestructive: true) {
                    model.deleteArchivedThreads(ids: pendingIDs)
                    isConfirming = false
                }
            }
        }
    }
}
