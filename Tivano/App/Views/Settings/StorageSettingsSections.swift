import AppKit
import SwiftUI

/// The storage page: what Tivano keeps on this Mac, a quick find into archived chats,
/// the worktrees it made, and advanced cleanup controls.
struct StorageSettingsPage: View {
    @Environment(AppModel.self) private var model
    @Binding var filter: ArchiveFilter
    @State private var showingAllArchived = false
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
        Group {
            if showingAllArchived {
                ArchivedChatsPage(filter: $filter) {
                    showingAllArchived = false
                }
            } else {
                VStack(alignment: .leading, spacing: Chrome.pageSectionSpacing) {
                    StorageOverviewSection(
                        usage: usage,
                        diagnostics: diagnostics,
                        updates: updates,
                        isBusy: isBusy,
                        refresh: {
                            guard !isBusy else { return }
                            refreshing = true
                            generation += 1
                        },
                        cleaned: {
                            generation += 1
                        }
                    )
                    StorageFindChatSection(filter: $filter) {
                        showingAllArchived = true
                    }
                    StorageWorktreesSection(usage: usage) {
                        libraryGeneration += 1
                    }
                    StorageAdvancedSection(diagnostics: diagnostics, updates: updates)
                }
            }
        }
        // Deleting chats (and their worktrees) anywhere on the page frees space.
        .onChange(of: model.threads.count) { old, new in
            if new < old { libraryGeneration += 1 }
        }
        .onChange(of: showingAllArchived) { _, showing in
            if !showing {
                libraryGeneration += 1
            }
        }
        // Deleting a chat or cleaning build files changes disk usage, so re-measure on demand.
        .task(id: "\(generation)-\(libraryGeneration)") {
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

// MARK: - Overview

private struct StorageOverviewSection: View {
    @Environment(AppModel.self) private var model
    let usage: StorageUsage?
    let diagnostics: RuntimeStorageState
    let updates: RuntimeStorageState
    let isBusy: Bool
    let refresh: () -> Void
    let cleaned: () -> Void

    @State private var showingCleanPopover = false
    @State private var includeIdleWorktrees = true
    @State private var includeUpdates = true
    @State private var includeDiagnostics = true
    @State private var includeActiveWorktrees = false
    @State private var isCleaningWorktrees = false
    @State private var worktreeCleanupError: String?
    @State private var lastCleanIncludedDiagnostics = false
    @State private var lastCleanIncludedUpdates = false

    private struct Part: Identifiable {
        let title: String
        let bytes: Int64
        let color: Color
        var id: String { title }
    }

    private struct Metrics {
        let worktreesWithBuild: [(worktree: WorktreeUsage, isIdle: Bool)]
        let idleWorktreeCount: Int
        let idleBuildBytes: Int64
        let activeBuildBytes: Int64
        let cleanableUpdatesBytes: Int64
        let cleanableDiagnosticsBytes: Int64
        let defaultCleanableBytes: Int64
        let parts: [Part]
        let totalBytes: Int64
    }

    var body: some View {
        let metrics = makeMetrics()
        let selectedBytes = (includeIdleWorktrees ? metrics.idleBuildBytes : 0)
            + (includeUpdates ? metrics.cleanableUpdatesBytes : 0)
            + (includeDiagnostics ? metrics.cleanableDiagnosticsBytes : 0)
            + (includeActiveWorktrees ? metrics.activeBuildBytes : 0)
        let cleanTitle = cleanButtonTitle(metrics)
        ChromeSection(title: "On this Mac") {
            ChromeCard {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: usage.map { _ in formattedSize(metrics.totalBytes) } ?? Chrome.localized("Measuring…"))
                                .font(.ui(.title2, weight: .semibold))
                                .foregroundStyle(Chrome.primaryText)
                                .monospacedDigit()
                            Text(verbatim: Chrome.localized("Tivano data"))
                                .font(.ui(.subheadline))
                                .foregroundStyle(Chrome.secondaryText)
                        }
                        Spacer(minLength: 12)
                        if anyBusy {
                            ProgressView().controlSize(.small)
                        }
                        Button("Refresh", action: refresh)
                            .chromeGlassButtonStyle()
                            .controlSize(.small)
                            .disabled(anyBusy)
                    }
                    bar(metrics.parts)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 24, alignment: .leading)], alignment: .leading, spacing: 14) {
                        ForEach(metrics.parts) { part in
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
                }
                .padding(16)
                ChromeRowDivider()
                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: "checkmark.shield")
                        .font(.ui(.title3, weight: .medium))
                        .foregroundStyle(Chrome.accent)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: Chrome.localized("Clean up regenerable files"))
                            .font(.ui(.body))
                            .foregroundStyle(Chrome.primaryText)
                        Text(verbatim: Chrome.localized("Old diagnostic reports, obsolete update files, and dependencies and build output in idle worktrees. Chats, code and uncommitted changes are never touched."))
                            .font(.ui(.subheadline))
                            .foregroundStyle(Chrome.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 12)
                    Button(cleanTitle) {
                        includeIdleWorktrees = true
                        includeUpdates = true
                        includeDiagnostics = true
                        includeActiveWorktrees = false
                        showingCleanPopover = true
                    }
                    .chromeGlassButtonStyle(prominent: true)
                    .controlSize(.small)
                    .disabled(anyBusy || isCleaning || metrics.defaultCleanableBytes + metrics.activeBuildBytes == 0)
                    .popover(isPresented: $showingCleanPopover, arrowEdge: .bottom) {
                        cleanPopover(metrics, selectedBytes: selectedBytes)
                            .presentedChrome()
                    }
                }
                .padding(.leading, 16)
                .padding(.trailing, Chrome.rowControlTrailingPadding)
                .padding(.vertical, 11)
                if let error = combinedCleanupError {
                    Text(verbatim: String(format: Chrome.localized("Cleanup did not finish. Some files may already have been removed. %@"), error))
                        .font(.ui(.subheadline))
                        .foregroundStyle(Chrome.danger)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 16)
                        .padding(.trailing, Chrome.rowControlTrailingPadding)
                        .padding(.bottom, 11)
                }
            }
        }
    }

    private var anyBusy: Bool {
        isBusy || isCleaningWorktrees
    }

    private var isCleaning: Bool {
        isCleaningWorktrees || diagnostics.isClearing || updates.isClearing
    }

    private func makeMetrics() -> Metrics {
        var worktreesWithBuild: [(worktree: WorktreeUsage, isIdle: Bool)] = []
        var idleWorktreeCount = 0
        var idleBuildBytes: Int64 = 0
        var activeBuildBytes: Int64 = 0
        for worktree in usage?.worktrees ?? [] {
            let isIdle = model.isIdle(worktree)
            if isIdle {
                idleBuildBytes += worktree.buildFilesSize
            } else if worktree.buildFilesSize > 0 {
                activeBuildBytes += worktree.buildFilesSize
            }
            if worktree.buildFilesSize > 0 {
                worktreesWithBuild.append((worktree, isIdle))
                if isIdle { idleWorktreeCount += 1 }
            }
        }

        let cleanableUpdatesBytes = updates.usage?.cleanableBytes ?? 0
        let cleanableDiagnosticsBytes = diagnostics.usage?.cleanableBytes ?? 0
        var parts = [
            Part(title: "Chats and attachments", bytes: usage.map { $0.chats + $0.attachments } ?? 0, color: Chrome.blue),
            Part(title: "Worktrees", bytes: max(0, (usage?.worktreesTotal ?? 0) - idleBuildBytes), color: Chrome.success),
            Part(title: "Safe to clean up", bytes: idleBuildBytes + cleanableDiagnosticsBytes + cleanableUpdatesBytes, color: Chrome.accent),
        ]
        if let patches = usage?.patches, patches > 0 {
            parts.append(Part(title: "Recovery patches", bytes: patches, color: Chrome.gray))
        }
        // Files cleanup keeps (latest hang report, pending installs, rollback) still count.
        let keptDiagnostics = (diagnostics.usage?.totalBytes ?? 0) - cleanableDiagnosticsBytes
        if keptDiagnostics > 0 {
            parts.append(Part(title: "Diagnostic files", bytes: keptDiagnostics, color: Chrome.gray))
        }
        let keptUpdates = (updates.usage?.totalBytes ?? 0) - cleanableUpdatesBytes
        if keptUpdates > 0 {
            parts.append(Part(title: "Update files", bytes: keptUpdates, color: Chrome.gray))
        }
        return Metrics(
            worktreesWithBuild: worktreesWithBuild,
            idleWorktreeCount: idleWorktreeCount,
            idleBuildBytes: idleBuildBytes,
            activeBuildBytes: activeBuildBytes,
            cleanableUpdatesBytes: cleanableUpdatesBytes,
            cleanableDiagnosticsBytes: cleanableDiagnosticsBytes,
            defaultCleanableBytes: idleBuildBytes + cleanableUpdatesBytes + cleanableDiagnosticsBytes,
            parts: parts,
            totalBytes: parts.reduce(0) { $0 + $1.bytes }
        )
    }

    private func cleanButtonTitle(_ metrics: Metrics) -> String {
        if isCleaning {
            return Chrome.localized("Cleaning up…")
        }
        if metrics.defaultCleanableBytes > 0 {
            return String(format: Chrome.localized("Free up %@…"), formattedSize(metrics.defaultCleanableBytes))
        }
        if metrics.activeBuildBytes > 0 {
            return String(format: Chrome.localized("Free up %@…"), formattedSize(metrics.activeBuildBytes))
        }
        return Chrome.localized("Nothing to clean up")
    }

    private var combinedCleanupError: String? {
        let errors = [
            worktreeCleanupError,
            lastCleanIncludedDiagnostics ? diagnostics.cleanupError : nil,
            lastCleanIncludedUpdates ? updates.cleanupError : nil,
        ].compactMap { $0 }.filter { !$0.isEmpty }
        return errors.isEmpty ? nil : errors.joined(separator: " ")
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

    private func cleanPopover(_ metrics: Metrics, selectedBytes: Int64) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: String(format: Chrome.localized("Free up %@"), formattedSize(selectedBytes)))
                    .font(.ui(.headline))
                    .foregroundStyle(Chrome.primaryText)
                    .monospacedDigit()
                Text(verbatim: Chrome.localized("These files come back on their own when needed."))
                    .font(.ui(.subheadline))
                    .foregroundStyle(Chrome.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 12) {
                if metrics.idleBuildBytes > 0 {
                    cleanOptionRow(
                        title: Chrome.localized("Dependencies and build output in idle worktrees"),
                        detail: String(
                            format: Chrome.localized("%lld worktrees · node_modules, DerivedData, .venv and similar. The next install or build brings them back."),
                            metrics.idleWorktreeCount
                        ),
                        bytes: metrics.idleBuildBytes,
                        isOn: $includeIdleWorktrees
                    )
                }
                if metrics.cleanableUpdatesBytes > 0 {
                    cleanOptionRow(
                        title: Chrome.localized("Obsolete update files"),
                        detail: Chrome.localized("Keeps pending installations and rollback files."),
                        bytes: metrics.cleanableUpdatesBytes,
                        isOn: $includeUpdates
                    )
                }
                if metrics.cleanableDiagnosticsBytes > 0 {
                    cleanOptionRow(
                        title: Chrome.localized("Old diagnostic reports"),
                        detail: Chrome.localized("Keeps the latest hang report and current logs."),
                        bytes: metrics.cleanableDiagnosticsBytes,
                        isOn: $includeDiagnostics
                    )
                }
                if metrics.activeBuildBytes > 0 {
                    cleanOptionRow(
                        title: Chrome.localized("Build output in worktrees chats are using"),
                        detail: Chrome.localized("Off by default: an active chat may need it soon."),
                        bytes: metrics.activeBuildBytes,
                        isOn: $includeActiveWorktrees
                    )
                }
            }
            Text(verbatim: Chrome.localized("Never deleted: chats, attachments, code and uncommitted changes in worktrees, branches and commits, recovery patches."))
                .font(.ui(.footnote))
                .foregroundStyle(Chrome.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") { showingCleanPopover = false }
                    .chromeGlassButtonStyle()
                Button("Clean up") { startCleanup(metrics) }
                    .chromeGlassButtonStyle(prominent: true)
                    .disabled(selectedBytes == 0)
            }
        }
        .padding(18)
        .frame(width: 380)
    }

    private func cleanOptionRow(title: String, detail: String, bytes: Int64, isOn: Binding<Bool>) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title)
                    .font(.ui(.body))
                    .foregroundStyle(Chrome.primaryText)
                Text(verbatim: detail)
                    .font(.ui(.subheadline))
                    .foregroundStyle(Chrome.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Text(verbatim: formattedSize(bytes))
                .font(.ui(.subheadline))
                .foregroundStyle(Chrome.secondaryText)
                .monospacedDigit()
            SettingsSwitch(isOn: isOn)
                .accessibilityLabel(Text(verbatim: title))
        }
    }

    private func startCleanup(_ metrics: Metrics) {
        // Classified again at the click: a worktree may have become active since the last render.
        let worktreesToClean: [WorktreeUsage] = metrics.worktreesWithBuild.compactMap { classified -> WorktreeUsage? in
            guard model.isIdle(classified.worktree) ? includeIdleWorktrees : includeActiveWorktrees else { return nil }
            return classified.worktree
        }
        let clearUpdates = includeUpdates && metrics.cleanableUpdatesBytes > 0
        let clearDiagnostics = includeDiagnostics && metrics.cleanableDiagnosticsBytes > 0

        showingCleanPopover = false
        worktreeCleanupError = nil
        lastCleanIncludedDiagnostics = clearDiagnostics
        lastCleanIncludedUpdates = clearUpdates
        isCleaningWorktrees = !worktreesToClean.isEmpty

        if clearDiagnostics {
            diagnostics.clear()
        }
        if clearUpdates {
            updates.clear()
        }

        Task {
            var failures: [String] = []
            for worktree in worktreesToClean {
                do {
                    try await Storage.removeBuildFiles(of: worktree)
                } catch {
                    failures.append("\(worktree.name): \(error.localizedDescription)")
                }
            }
            if !failures.isEmpty {
                worktreeCleanupError = failures.joined(separator: " ")
            }
            isCleaningWorktrees = false
            cleaned()
        }
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

// MARK: - Worktrees

private struct StorageWorktreesSection: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let usage: StorageUsage?
    let changed: () -> Void
    @State private var busy: Set<String> = []
    @State private var pendingRemoval: WorktreeUsage?
    @State private var rowsCache = WorktreeRowsCache()
    @State private var showingEachWorktree = false
    @State private var copiedPrompt = false
    @State private var copyResetTask: Task<Void, Never>?

    private var worktrees: [WorktreeUsage] { usage?.worktrees ?? [] }

    private struct WorktreeRow: Identifiable {
        let worktree: WorktreeUsage
        let detail: String
        let canRemove: Bool
        let reason: String?
        var id: String { worktree.path }
    }

    @MainActor
    private final class WorktreeRowsCache {
        private struct ThreadRef: Equatable {
            let id: UUID
            let worktreePath: String?
            let targetCheckout: String?
            let title: String
            let isArchived: Bool
        }

        private struct Signature: Equatable {
            let worktrees: [WorktreeUsage]
            let threads: [ThreadRef]
            let projectPaths: [String]
        }

        private var lastSignature: Signature?
        private var cached: [WorktreeRow] = []

        func rows(worktrees: [WorktreeUsage], threads: [ChatThread], projects: [Project]) -> [WorktreeRow] {
            let threadRefs: [ThreadRef] = threads.compactMap { thread in
                guard thread.worktreePath != nil || thread.hydra?.targetCheckout != nil else { return nil }
                return ThreadRef(
                    id: thread.id,
                    worktreePath: thread.worktreePath,
                    targetCheckout: thread.hydra?.targetCheckout,
                    title: thread.title,
                    isArchived: thread.isArchived
                )
            }
            let signature = Signature(
                worktrees: worktrees,
                threads: threadRefs,
                projectPaths: projects.map(\.path)
            )
            if lastSignature == signature {
                return cached
            }
            let result: [WorktreeRow]
            if worktrees.isEmpty {
                result = []
            } else {
                var resolvedCache: [String: String] = [:]
                func resolve(_ path: String) -> String {
                    if let cached = resolvedCache[path] { return cached }
                    let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
                    resolvedCache[path] = resolved
                    return resolved
                }
                let threadPaths: [(thread: ChatThread, paths: [String])] = threads.compactMap { thread in
                    var paths: [String] = []
                    if let wt = thread.worktreePath, !wt.isEmpty { paths.append(resolve(wt)) }
                    if let target = thread.hydra?.targetCheckout, !target.isEmpty { paths.append(resolve(target)) }
                    return paths.isEmpty ? nil : (thread, paths)
                }
                let projectPaths = projects.map { resolve($0.path) }
                result = worktrees.map { worktree in
                    let path = resolve(worktree.path)
                    let prefix = path + "/"
                    let users = threadPaths.compactMap { entry in
                        entry.paths.contains { $0 == path || $0.hasPrefix(prefix) } ? entry.thread : nil
                    }
                    let usedByProject = projectPaths.contains { $0 == path || $0.hasPrefix(prefix) }
                    let canRemove = users.isEmpty && !usedByProject
                        && (worktree.isRegistered ? worktree.changedFiles == 0 : true)
                    return WorktreeRow(
                        worktree: worktree,
                        detail: StorageWorktreesSection.detail(for: worktree, users: users),
                        canRemove: canRemove,
                        reason: StorageWorktreesSection.reason(for: worktree, users: users, canRemove: canRemove)
                    )
                }
            }
            lastSignature = signature
            cached = result
            return result
        }
    }

    var body: some View {
        let idleCount = usage.map { $0.worktrees.filter { model.isIdle($0) }.count }
        let uncommittedCount = usage.map { $0.worktrees.filter { ($0.changedFiles ?? 0) > 0 }.count }
        let hasWorktrees = !(usage?.worktrees.isEmpty ?? true)
        ChromeSection(title: "Worktrees") {
            ChromeCard {
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 2) {
                        metricText("%lld worktrees", value: usage?.worktrees.count)
                        Text(verbatim: usage.map { formattedSize($0.worktreesTotal) } ?? "—")
                            .font(.ui(.subheadline))
                            .foregroundStyle(Chrome.secondaryText)
                            .monospacedDigit()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    metricText("%lld not used by an active chat", value: idleCount)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    metricText("%lld with uncommitted changes", value: uncommittedCount)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                ChromeRowDivider()
                ChromeRow(
                    title: "Not sure which to delete? Let an agent review them",
                    detail: String(
                        format: Chrome.localized("Opens a new chat with a prompt and a list of these %lld worktrees already written. Read it, then send it yourself. It only inspects and deletes nothing."),
                        worktrees.count
                    ),
                    localizesDetail: false
                ) {
                    HStack(spacing: 8) {
                        Button {
                            guard let usage, !usage.worktrees.isEmpty else { return }
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(model.worktreeReviewPrompt(for: usage), forType: .string)
                            copiedPrompt = true
                            copyResetTask?.cancel()
                            copyResetTask = Task {
                                try? await Task.sleep(for: .seconds(1.5))
                                guard !Task.isCancelled else { return }
                                copiedPrompt = false
                            }
                        } label: {
                            Text(verbatim: Chrome.localized(copiedPrompt ? "Copied" : "Copy prompt"))
                        }
                        .chromeGlassButtonStyle()
                        .disabled(!hasWorktrees)
                        Button("Start review chat") {
                            guard let usage, !usage.worktrees.isEmpty else { return }
                            model.startWorktreeReview(for: usage)
                        }
                        .chromeGlassButtonStyle(prominent: true)
                        .disabled(!hasWorktrees)
                    }
                    .controlSize(.small)
                }
                ChromeRowDivider()
                Button {
                    withAnimation(reduceMotion ? nil : Chrome.panelSlide) {
                        showingEachWorktree.toggle()
                    }
                } label: {
                    ChromeRow(title: "Show each worktree") {
                        Image(systemName: "chevron.right")
                            .font(.ui(.caption, weight: .semibold))
                            .foregroundStyle(Chrome.secondaryText)
                            .rotationEffect(.degrees(showingEachWorktree ? 90 : 0))
                            .animation(reduceMotion ? nil : Chrome.panelSlide, value: showingEachWorktree)
                            .frame(width: 20, height: 20)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityValue(Text(verbatim: Chrome.localized(showingEachWorktree ? "Expanded" : "Collapsed")))
                ChromeReveal(isExpanded: showingEachWorktree) {
                    let rows = rowsCache.rows(worktrees: worktrees, threads: model.threads, projects: model.projects)
                    VStack(alignment: .leading, spacing: 0) {
                        ChromeRowDivider()
                        ChromeRow(title: "Worktrees", detail: Storage.worktreesDirectory.path, localizesDetail: false) {
                            Button("Reveal") { Workspace.revealInFinder(Storage.worktreesDirectory.path) }
                                .chromeGlassButtonStyle()
                                .controlSize(.small)
                        }
                        ForEach(rows) { row in
                            let worktree = row.worktree
                            ChromeRowDivider()
                            ChromeRow(title: worktree.name, detail: row.detail, localizesDetail: false) {
                                if busy.contains(worktree.path) {
                                    ProgressView().controlSize(.small)
                                } else if worktree.buildFilesSize > 0 || row.canRemove {
                                    FreeSpaceButton(worktree: worktree, canRemove: row.canRemove,
                                                    reason: row.reason) { action in
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
        .onDisappear { copyResetTask?.cancel() }
    }

    private func metricText(_ key: String, value: Int?) -> Text {
        let parts = Chrome.localized(key).components(separatedBy: "%lld")
        let number = Text(verbatim: value.map(String.init) ?? "—")
            .font(.ui(.title2, weight: .semibold))
            .foregroundColor(Chrome.primaryText)
            .monospacedDigit()
        let before = Text(verbatim: parts.first ?? "")
            .font(.ui(.subheadline))
            .foregroundColor(Chrome.secondaryText)
        let after = Text(verbatim: parts.count > 1 ? parts[1] : "")
            .font(.ui(.subheadline))
            .foregroundColor(Chrome.secondaryText)
        return before + number + after
    }

    private static func detail(for worktree: WorktreeUsage, users: [ChatThread]) -> String {
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
        if let branch = worktree.branch, !branch.isEmpty {
            parts.append(branch)
        }
        return parts.joined(separator: " · ")
    }

    /// Why the whole worktree cannot go from here, shown under the greyed-out choice.
    private static func reason(for worktree: WorktreeUsage, users: [ChatThread], canRemove: Bool) -> String? {
        guard !canRemove else { return nil }
        if !users.isEmpty {
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
            .chromeGlassButtonStyle()
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

// MARK: - Advanced

private struct StorageAdvancedSection: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let diagnostics: RuntimeStorageState
    let updates: RuntimeStorageState
    @State private var isExpanded = false

    var body: some View {
        ChromeSection(title: "Advanced") {
            ChromeCard {
                Button {
                    withAnimation(reduceMotion ? nil : Chrome.panelSlide) {
                        isExpanded.toggle()
                    }
                } label: {
                    ChromeRow(title: "Diagnostics, update files and folders") {
                        Image(systemName: "chevron.right")
                            .font(.ui(.caption, weight: .semibold))
                            .foregroundStyle(Chrome.secondaryText)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .animation(reduceMotion ? nil : Chrome.panelSlide, value: isExpanded)
                            .frame(width: 20, height: 20)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityValue(Text(verbatim: Chrome.localized(isExpanded ? "Expanded" : "Collapsed")))
                ChromeReveal(isExpanded: isExpanded) {
                    VStack(alignment: .leading, spacing: 0) {
                        ChromeRowDivider()
                        RuntimeStorageRow(state: diagnostics)
                        ChromeRowDivider()
                        RuntimeStorageRow(state: updates)
                    }
                }
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
                    .chromeGlassButtonStyle()
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
