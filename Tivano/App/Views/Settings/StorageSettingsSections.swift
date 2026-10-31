import SwiftUI

/// The storage page: what Tivano keeps on this Mac, the worktrees it made, and the
/// archived chats, so freeing space and tidying chats happen in one place.
struct StorageSettingsPage: View {
    @Environment(AppModel.self) private var model
    @Binding var filter: ArchiveFilter
    @State private var usage: StorageUsage?
    @State private var generation = 0
    @State private var libraryGeneration = 0
    @State private var measuringLibrary = true
    @State private var refreshing = true
    @State private var diagnostics = RuntimeStorageState(kind: .diagnostics)
    @State private var updates = RuntimeStorageState(kind: .updates)

    private var isBusy: Bool {
        refreshing || measuringLibrary || diagnostics.isMeasuring || updates.isMeasuring
            || diagnostics.isClearing || updates.isClearing
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Chrome.pageSectionSpacing) {
            StorageOverviewSection(usage: usage, diagnostics: diagnostics, updates: updates, isBusy: isBusy) {
                guard !isBusy else { return }
                refreshing = true
                generation += 1
            }
            RuntimeStorageSection(diagnostics: diagnostics, updates: updates)
            if let usage, !usage.worktrees.isEmpty {
                StorageWorktreesSection(worktrees: usage.worktrees) { libraryGeneration += 1 }
            }
            ArchivedChatsSection(filter: $filter, usage: usage)
        }
        // Deleting a chat can take its worktree with it, so the measure follows the library.
        .task(id: "\(model.threads.count)-\(generation)-\(libraryGeneration)") {
            guard !Task.isCancelled else { return }
            measuringLibrary = true
            let measured = await Storage.measureUsage()
            guard !Task.isCancelled else { return }
            usage = measured
            measuringLibrary = false
        }
        .task(id: generation) {
            guard !Task.isCancelled else { return }
            refreshing = true
            async let measuredDiagnostics: Void = diagnostics.measure()
            async let measuredUpdates: Void = updates.measure()
            _ = await (measuredDiagnostics, measuredUpdates)
            guard !Task.isCancelled else { return }
            refreshing = false
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
    let diagnostics: RuntimeStorageState
    let updates: RuntimeStorageState
    let isBusy: Bool
    let refresh: () -> Void

    private struct Part: Identifiable {
        let title: String
        let bytes: Int64
        let color: Color
        var id: String { title }
    }

    var body: some View {
        ChromeSection(title: "On this Mac") {
            StorageSectionNote(text: "Measured categories below, not all app data on this Mac.")
            ChromeCard {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text(verbatim: usage.map { String(format: Chrome.localized("Measured storage: %@"), formattedSize(total($0))) }
                            ?? Chrome.localized("Measuring…"))
                            .font(.ui(.body, weight: .semibold))
                            .foregroundStyle(Chrome.primaryText)
                        Spacer(minLength: 12)
                        if isBusy {
                            ProgressView().controlSize(.small)
                        }
                        Button("Refresh", action: refresh)
                            .buttonStyle(.glass)
                            .controlSize(.small)
                            .disabled(isBusy)
                    }
                    let parts = parts
                    bar(parts)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 24, alignment: .leading)], alignment: .leading, spacing: 14) {
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
                    if diagnostics.usage == nil {
                        StorageSectionNote(text: "Diagnostics are not included in the measured total yet.")
                    }
                    if updates.usage == nil {
                        StorageSectionNote(text: "Update files are not included in the measured total yet.")
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
            parts.append(Part(title: "Recovery patches", bytes: patches, color: Chrome.gray))
        }
        if let measured = diagnostics.usage {
            parts.append(Part(title: "Diagnostic files", bytes: measured.totalBytes, color: Chrome.accent))
        }
        if let measured = updates.usage {
            parts.append(Part(title: "Update files", bytes: measured.totalBytes, color: Chrome.warning))
        }
        return parts
    }

    private func total(_ usage: StorageUsage) -> Int64 {
        usage.chats + usage.attachments + usage.worktreesTotal + usage.patches
            + (diagnostics.usage?.totalBytes ?? 0) + (updates.usage?.totalBytes ?? 0)
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

@MainActor
@Observable
private final class RuntimeStorageState {
    enum Kind: Equatable {
        case diagnostics, updates

        var title: String {
            switch self {
            case .diagnostics: "Diagnostic files"
            case .updates: "Update files"
            }
        }

        var protection: String {
            switch self {
            case .diagnostics: "Keeps the latest hang report and current logs."
            case .updates: "Keeps pending installations and rollback files."
            }
        }
    }

    let kind: Kind
    private(set) var usage: RuntimeStorageUsage?
    private(set) var isMeasuring = true
    private(set) var isClearing = false
    private(set) var measurementError: String?
    private(set) var cleanupError: String?
    private var measurementID = UUID()

    init(kind: Kind) {
        self.kind = kind
    }

    var canClear: Bool {
        !isMeasuring && !isClearing && (usage?.cleanableBytes ?? 0) > 0
    }

    func measure() async {
        guard !Task.isCancelled, !isClearing else { return }
        let id = UUID()
        measurementID = id
        isMeasuring = true
        usage = nil
        measurementError = nil
        defer {
            if measurementID == id { isMeasuring = false }
        }
        do {
            let measured: RuntimeStorageUsage
            switch kind {
            case .diagnostics: measured = try await Storage.measureDiagnostics()
            case .updates: measured = try await AppUpdater.shared.measureStorage()
            }
            guard !Task.isCancelled, measurementID == id else { return }
            usage = measured
        } catch {
            guard !Task.isCancelled, measurementID == id else { return }
            measurementError = error.localizedDescription
        }
    }

    func clear() {
        guard canClear else { return }
        isClearing = true
        usage = nil
        cleanupError = nil
        Task {
            do {
                switch kind {
                case .diagnostics: try await Storage.clearDiagnostics()
                case .updates: try await AppUpdater.shared.clearObsoleteStorage()
                }
            } catch {
                cleanupError = error.localizedDescription
            }
            isClearing = false
            // A failed cleanup can still have removed some files; keep its error separate.
            await measure()
        }
    }
}

private struct RuntimeStorageSection: View {
    let diagnostics: RuntimeStorageState
    let updates: RuntimeStorageState

    var body: some View {
        ChromeSection(title: "Diagnostics and update files") {
            ChromeCard {
                RuntimeStorageRow(state: diagnostics)
                ChromeRowDivider()
                RuntimeStorageRow(state: updates)
            }
        }
    }
}

private struct RuntimeStorageRow: View {
    let state: RuntimeStorageState
    @State private var confirming = false

    var body: some View {
        ChromeRow(title: state.kind.title, detail: detail, localizesDetail: false) {
            HStack(spacing: 8) {
                if state.isMeasuring || state.isClearing {
                    ProgressView().controlSize(.small)
                }
                Button("Clean up…") { confirming = true }
                    .buttonStyle(.glass)
                    .disabled(!state.canClear)
                    .accessibilityLabel(Text(verbatim: Chrome.localized(state.kind == .diagnostics
                        ? "Clean up diagnostic files" : "Clean up update files")))
            }
            .controlSize(.small)
        }
        .confirmationDialog(
            Text(verbatim: Chrome.localized(state.kind == .diagnostics
                ? "Clean up diagnostic files?" : "Clean up update files?")),
            isPresented: $confirming,
            titleVisibility: .visible
        ) {
            Button("Clean up", role: .destructive) { state.clear() }
                .disabled(!state.canClear)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(verbatim: Chrome.localized(state.kind == .diagnostics
                ? "Deletes only eligible older diagnostic reports and rotated logs. Keeps the latest hang report and current logs. Chats, attachments, worktrees and recovery data are not removed."
                : "Deletes only obsolete update files that are no longer in use. Keeps files used by downloads, pending installations and rollback. Chats, attachments, worktrees and recovery data are not removed."))
        }
    }

    private var detail: String {
        var lines = [Chrome.localized(state.kind.protection)]
        if state.isClearing {
            lines.append(Chrome.localized("Cleaning up…"))
        } else if state.isMeasuring {
            lines.append(Chrome.localized("Measuring…"))
        } else if let error = state.measurementError {
            lines.append(String(format: Chrome.localized("Could not measure these files. Not included in the measured total. %@"), error))
        } else if let usage = state.usage {
            lines.append(String(format: Chrome.localized("Total: %@ · Cleanable: %@"),
                                formattedSize(usage.totalBytes), formattedSize(usage.cleanableBytes)))
            if usage.totalBytes == 0 {
                lines.append(Chrome.localized("No files found."))
            } else if usage.cleanableBytes == 0 {
                lines.append(Chrome.localized("Nothing to clean up."))
            }
        } else {
            lines.append(Chrome.localized("Measurement unavailable. Not included in the measured total."))
        }
        if let error = state.cleanupError {
            lines.append(String(format: Chrome.localized("Cleanup did not finish. Some files may already have been removed. %@"), error))
        }
        return lines.joined(separator: "\n")
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
    @State private var pending: PendingDeletion?

    /// The chats a confirmation is about, handed to the popover with its presentation:
    /// separate state read by `isPresented` content could still be empty when it renders.
    private struct PendingDeletion: Identifiable {
        let id = UUID()
        let ids: Set<UUID>
        let isFiltered: Bool
    }

    var body: some View {
        ChromeTextButton(
            symbol: "trash",
            title: String(format: Chrome.localized(isFiltered ? "Delete matching chats (%lld)" : "Delete all archived chats (%lld)"), threadIDs.count),
            help: isFiltered ? "Delete matching archived chats" : "Delete every archived thread",
            isEnabled: !threadIDs.isEmpty,
            isDestructive: true
        ) {
            if model.settings.confirmBeforeDeleting {
                pending = PendingDeletion(ids: threadIDs, isFiltered: isFiltered)
            } else {
                model.deleteArchivedThreads(ids: threadIDs)
            }
        }
        .popover(item: $pending, arrowEdge: .bottom) { pending in
            PopoverMenu(scrolls: false) {
                PopoverSectionHeader(pending.isFiltered ? "Delete matching archived chats?" : "Delete all archived chats?")
                PopoverNote(String(format: Chrome.localized(pending.isFiltered
                    ? "The histories of the %lld matching chats will be removed. Files in your projects stay as they are."
                    : "The histories of all %lld threads will be removed. Files in your projects stay as they are."), pending.ids.count))
                PopoverDivider()
                PopoverItem(String(format: Chrome.localized("Delete %lld threads"), pending.ids.count), symbol: "trash", isDestructive: true) {
                    model.deleteArchivedThreads(ids: pending.ids)
                    self.pending = nil
                }
            }
        }
    }
}
