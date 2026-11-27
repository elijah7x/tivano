import AppKit
import SwiftUI

/// Fixed-size pure-overlay utility toolbox floating over the chat timeline:
/// thread outputs, embedded diff + Git actions, and embedded terminal.
struct UtilityChestPanel: View {
    static let panelWidth: CGFloat = 540
    static let panelHeight: CGFloat = 490
    private static let cornerRadius: CGFloat = 22

    @Environment(AppModel.self) private var model
    @Environment(WindowLiveResize.self) private var liveResize
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.solidSurfaces) private var solid

    let runtime: ThreadRuntime
    let directory: String?
    let git: GitStatusModel
    let paneSize: CGSize

    @State private var artifacts: [ThreadArtifact] = []
    @State private var artifactLoadCount = 0
    @State private var selectedFilter: ThreadArtifactKind? = nil

    @State private var isCommitExpanded = false
    @State private var isGeneratingCommit = false
    @State private var isCommitting = false
    @State private var gitError: String?

    init(runtime: ThreadRuntime, directory: String?, git: GitStatusModel, paneSize: CGSize) {
        self.runtime = runtime
        self.directory = directory
        self.git = git
        self.paneSize = paneSize
    }

    private struct OutputsLoadKey: Equatable {
        let threadID: UUID
        let directory: String?
        let entryCount: Int
        let turnCount: Int
        let diffRevision: Int
        let isRunning: Bool
    }

    private var outputsLoadKey: OutputsLoadKey {
        OutputsLoadKey(
            threadID: runtime.threadID,
            directory: directory,
            entryCount: runtime.entries.count,
            turnCount: runtime.turns.count,
            diffRevision: runtime.diffRevision,
            isRunning: runtime.isRunning
        )
    }

    private var filteredArtifacts: [ThreadArtifact] {
        guard let selectedFilter else { return artifacts }
        return artifacts.filter { $0.kind == selectedFilter }
    }

    var body: some View {
        let width = min(Self.panelWidth, max(340, paneSize.width - 28))
        let height = min(Self.panelHeight, max(280, paneSize.height - 76))
        let shape = RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)

        VStack(spacing: 0) {
            headerRow
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 8)

            Group {
                switch runtime.chestTab {
                case .outputs:
                    outputsTab
                case .changes:
                    changesTab
                case .terminal:
                    terminalTab
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: width, height: height)
        // Follow live window resizing without lagging behind the pane.
        .animation(nil, value: liveResize.isActive)
        .background {
            let isDark = colorScheme == .dark
#if DEBUG
            if ProbeKnobs.isOff("glass") {
                shape.fill(Color(nsColor: .windowBackgroundColor))
            } else if let solid {
                shape
                    .fill(solid.elevated)
                    .overlay { shape.strokeBorder(solid.hairline, lineWidth: 1) }
            } else {
                shape
                    .fill(.clear)
                    .chromeGlassEffect(.regular, in: shape)
                    .overlay {
                        shape.fill(Chrome.glassTint.opacity(isDark ? 0.22 : 0.16))
                    }
            }
#else
            if let solid {
                shape
                    .fill(solid.elevated)
                    .overlay { shape.strokeBorder(solid.hairline, lineWidth: 1) }
            } else {
                shape
                    .fill(.clear)
                    .chromeGlassEffect(.regular, in: shape)
                    .overlay {
                        shape.fill(Chrome.glassTint.opacity(isDark ? 0.22 : 0.16))
                    }
            }
#endif
        }
        .clipShape(shape)
        // Separate filled scrim shape carries the shadow so streaming chat underneath never re-blurs it.
        .background {
            let isDark = colorScheme == .dark
            shape
                .fill((isDark ? Color.black : Color.white).opacity(isDark ? 0.3 : 0.34))
                .shadow(
                    color: solid != nil ? .black.opacity(0.1) : .black.opacity(isDark ? 1 : 0.65),
                    radius: solid != nil ? 18 : 28,
                    y: solid != nil ? 6 : 10
                )
        }
        .pointerStyle(.default)
        .onChange(of: runtime.threadID) {
            selectedFilter = nil
            isCommitExpanded = false
            gitError = nil
        }
    }

    // MARK: - Header

    private var headerRow: some View {
        let pinHelp = Chrome.localized(
            runtime.isChestPinned ? "Keep toolbox open" : "Close toolbox when clicking outside"
        )
        return HStack(spacing: 8) {
            HStack(spacing: 2) {
                ChestTabButton(isSelected: runtime.chestTab == .outputs) {
                    runtime.chestTab = .outputs
                } label: {
                    Text(verbatim: Chrome.localized("Outputs"))
                }

                ChestTabButton(isSelected: runtime.chestTab == .changes) {
                    if runtime.chestTab != .changes {
                        runtime.openGeneralChanges()
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(verbatim: Chrome.localized("Changes · Git"))
                        if let stats = runtime.changeStats {
                            DiffStatLabel(additions: stats.additions, deletions: stats.deletions)
                        }
                    }
                }

                ChestTabButton(isSelected: runtime.chestTab == .terminal) {
                    runtime.chestTab = .terminal
                } label: {
                    Text(verbatim: Chrome.localized("Terminal"))
                }
            }
            .padding(2)
            .background(Chrome.overlay(0.06), in: Capsule(style: .continuous))

            Spacer(minLength: 8)

            Button {
                runtime.isChestPinned.toggle()
            } label: {
                Label {
                    Text(verbatim: pinHelp)
                } icon: {
                    Image(systemName: runtime.isChestPinned ? "pin.fill" : "pin")
                }
            }
            .chromePillButton(.regular, prominent: runtime.isChestPinned, iconOnly: true)
            .help(Text(verbatim: pinHelp))
            .accessibilityLabel(Text(verbatim: pinHelp))

            ChromeCircleButton(symbol: "xmark", help: "Close toolbox") {
                withAnimation(Chrome.panelSlide) {
                    runtime.isChestOpen = false
                }
            }
        }
    }

    // MARK: - Outputs Tab

    private var outputsTab: some View {
        VStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    filterPill(title: "All", kind: nil, count: artifacts.count)
                    filterPill(title: "Documents", kind: .document, count: count(for: .document))
                    filterPill(title: "Webpages", kind: .webpage, count: count(for: .webpage))
                    filterPill(title: "Images", kind: .image, count: count(for: .image))
                    filterPill(title: "Videos", kind: .video, count: count(for: .video))
                }
                .padding(.horizontal, 12)
            }
            .fixedSize(horizontal: false, vertical: true)

            if filteredArtifacts.isEmpty {
                Group {
                    if artifactLoadCount > 0 && artifacts.isEmpty {
                        ProgressView()
                    } else {
                        ContentUnavailableView(
                            "No outputs yet",
                            systemImage: "square.grid.2x2",
                            description: Text("Documents, webpages, images and videos created in this chat appear here.")
                        )
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(filteredArtifacts, id: \.path) { artifact in
                            ChestArtifactRow(
                                artifact: artifact,
                                subtitle: artifactSubtitle(for: artifact),
                                onOpen: { NSWorkspace.shared.open(URL(fileURLWithPath: artifact.path)) },
                                onMention: artifact.mentionPath.map { mentionPath in
                                    { runtime.insertFileMention(mentionPath) }
                                },
                                onReveal: { Workspace.revealInFinder(artifact.path) }
                            )
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
                }
            }
        }
        .task(id: outputsLoadKey) {
            artifactLoadCount += 1
            defer { artifactLoadCount = max(0, artifactLoadCount - 1) }
            let items = runtime.entries.map(\.item)
            let turns = runtime.turns
            let collected = await ThreadArtifactCollector.collect(
                entries: items,
                turns: turns,
                workingDirectory: directory
            )
            guard !Task.isCancelled else { return }
            artifacts = collected
        }
    }

    private func filterPill(title: String, kind: ThreadArtifactKind?, count: Int) -> some View {
        let isSelected = selectedFilter == kind
        return Button {
            selectedFilter = kind
        } label: {
            HStack(spacing: 4) {
                Text(verbatim: Chrome.localized(title))
                if count > 0 {
                    Text(verbatim: "\(count)")
                        .foregroundStyle(isSelected ? AnyShapeStyle(.white.opacity(0.85)) : AnyShapeStyle(Chrome.secondaryText))
                        .monospacedDigit()
                }
            }
        }
        .chromePillButton(.compact, prominent: isSelected)
    }

    private func count(for kind: ThreadArtifactKind) -> Int {
        artifacts.reduce(into: 0) { total, artifact in
            if artifact.kind == kind { total += 1 }
        }
    }

    private func artifactSubtitle(for artifact: ThreadArtifact) -> String {
        var parts: [String] = []
        if !artifact.displayPath.isEmpty {
            parts.append(artifact.displayPath)
        }
        if let turnText = Self.formattedTurn(artifact.turnIndex) {
            parts.append(turnText)
        }
        if let sizeText = Self.formattedByteCount(artifact.fileSize) {
            parts.append(sizeText)
        }
        return parts.joined(separator: " · ")
    }

    private static func formattedTurn(_ index: Int?) -> String? {
        guard let index else { return nil }
        return String(format: Chrome.localized("Turn %lld"), index + 1)
    }

    private static func formattedByteCount(_ value: Int64?) -> String? {
        guard let value, value > 0 else { return nil }
        return AppFormatting.fileByteCount.string(fromByteCount: value)
    }

    private static func formattedByteCount(_ value: Int?) -> String? {
        guard let value, value > 0 else { return nil }
        return AppFormatting.fileByteCount.string(fromByteCount: Int64(value))
    }

    // MARK: - Changes & Git Tab

    private var changesTab: some View {
        VStack(spacing: 8) {
            DiffInspector(runtime: runtime, embeddedInChest: true)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let directory, git.directory == directory, git.isRepository {
                gitContainer(directory: directory)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
            }
        }
    }

    private func gitContainer(directory: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            gitActionRow(directory: directory)

            if let gitError {
                HStack(alignment: .top, spacing: 6) {
                    Text(verbatim: gitError)
                        .font(.ui(.callout))
                        .foregroundStyle(Chrome.danger)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    Spacer(minLength: 4)
                    Button {
                        self.gitError = nil
                    } label: {
                        Label {
                            Text("Dismiss")
                        } icon: {
                            Image(systemName: "xmark")
                        }
                    }
                    .chromePillButton(.compact, iconOnly: true)
                    .help(Text(verbatim: Chrome.localized("Dismiss")))
                }
            }

            if isCommitExpanded {
                inlineCommitBox(directory: directory)
            }
        }
        .padding(10)
        .background(Chrome.overlay(0.045), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func gitActionRow(directory: String) -> some View {
        let changed = git.status?.changedFiles ?? 0
        let ahead = git.status?.ahead ?? 0
        let hasBranch = git.status?.branch != nil
        let isBusy = git.activity != nil

        return HStack(spacing: 6) {
            if let activity = git.activity {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text(verbatim: Chrome.localized(activity))
                        .font(.ui(.callout))
                        .foregroundStyle(Chrome.secondaryText)
                        .lineLimit(1)
                }
            } else {
                Text(verbatim: gitStatusSummary(changedFiles: changed))
                    .font(.ui(.callout))
                    .foregroundStyle(Chrome.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 6)

            Button("Commit…") {
                withAnimation(Chrome.panelSlide) {
                    isCommitExpanded.toggle()
                }
            }
            .chromePillButton(.compact, prominent: isCommitExpanded)
            .disabled((changed == 0 && !isCommitExpanded) || isBusy)

            Button {
                push(directory: directory)
            } label: {
                if ahead > 0 {
                    HStack(spacing: 3) {
                        Text("Push")
                        Text(verbatim: "↑\(ahead)")
                            .monospacedDigit()
                    }
                } else {
                    Text("Push")
                }
            }
            .chromePillButton(.compact)
            .disabled(!hasBranch || isBusy)

            Button("Create PR") {
                openPullRequest(directory: directory)
            }
            .chromePillButton(.compact)
            .disabled(!hasBranch || isBusy)

            if let url = git.remoteURL {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Label {
                        Text("Open repository")
                    } icon: {
                        Image(systemName: "safari")
                    }
                }
                .chromePillButton(.compact, iconOnly: true)
                .help(Text(verbatim: Chrome.localized("Open repository")))
                .accessibilityLabel(Text("Open repository"))
            }
        }
    }

    private func gitStatusSummary(changedFiles: Int) -> String {
        switch changedFiles {
        case 0: Chrome.localized("Clean working tree")
        case 1: Chrome.localized("1 changed file")
        default: String(format: Chrome.localized("%d changed files"), changedFiles)
        }
    }

    private func inlineCommitBox(directory: String) -> some View {
        let bindableRuntime = Bindable(runtime)
        let canGenerate = model.textEngine(preferring: runtime.thread?.provider) != nil

        return VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: bindableRuntime.commitDraftMessage)
                    .font(.ui(.callout))
                    .scrollContentBackground(.hidden)
                    .padding(6)

                if runtime.commitDraftMessage.isEmpty {
                    Text(verbatim: isGeneratingCommit
                        ? Chrome.localized("Writing a message…")
                        : Chrome.localized("Commit message"))
                        .font(.ui(.callout))
                        .foregroundStyle(Chrome.secondaryText)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 6)
                        .allowsHitTesting(false)
                }
            }
            .frame(height: 68)
            .background(Chrome.overlay(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            HStack(spacing: 8) {
                Button {
                    Task { await generateCommitMessage(directory: directory) }
                } label: {
                    Label {
                        Text("Write for me")
                    } icon: {
                        if isGeneratingCommit {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "sparkles")
                        }
                    }
                }
                .chromePillButton(.compact)
                .disabled(isGeneratingCommit || !canGenerate)
                .help(Text(verbatim: canGenerate
                    ? Chrome.localized("Write a commit message from these changes")
                    : Chrome.localized("Turn on text generation in Settings › Model selection")))

                Toggle("Push after committing", isOn: bindableRuntime.commitPushesAfter)
                    .toggleStyle(.checkbox)
                    .font(.ui(.caption))
                    .foregroundStyle(Chrome.secondaryText)
                    .lineLimit(1)
                    .disabled(git.status?.branch == nil)

                Spacer(minLength: 4)

                Button("Cancel", role: .cancel) {
                    withAnimation(Chrome.panelSlide) {
                        isCommitExpanded = false
                    }
                }
                .chromePillButton(.compact)

                Button("Commit") {
                    Task { await commit(directory: directory) }
                }
                .chromePillButton(.compact, prominent: true)
                .disabled(runtime.commitDraftMessage.trimmed.isEmpty || isCommitting || git.activity != nil)
            }
        }
        .task(id: "\(runtime.threadID.uuidString)-\(directory)") {
            if runtime.commitDraftMessage.trimmed.isEmpty {
                await generateCommitMessage(directory: directory)
            }
        }
    }

    private func generateCommitMessage(directory: String) async {
        guard let engine = model.textEngine(preferring: runtime.thread?.provider) else { return }
        isGeneratingCommit = true
        defer { isGeneratingCommit = false }
        let changes = await Git(directory).workingChanges()
        guard !Task.isCancelled else { return }
        if let text = await TextGeneration.commitMessage(
            summary: changes.summary,
            patch: changes.patch,
            instructions: "",
            engine: engine,
            directory: URL(fileURLWithPath: directory)
        ), !Task.isCancelled {
            runtime.commitDraftMessage = text
        }
    }

    private func commit(directory: String) async {
        let text = runtime.commitDraftMessage.trimmed
        guard !text.isEmpty else { return }
        isCommitting = true
        gitError = nil
        defer { isCommitting = false }
        let repository = Git(directory)
        let pushes = runtime.commitPushesAfter && git.status?.branch != nil
        let error = await git.perform("Committing") {
            try await repository.commitAll(message: text)
            if pushes { try await repository.push() }
        }
        await git.refresh(directory)
        if let error {
            gitError = error.localizedDescription
        } else {
            runtime.commitDraftMessage = ""
            runtime.commitPushesAfter = false
            withAnimation(Chrome.panelSlide) {
                isCommitExpanded = false
            }
        }
    }

    private func push(directory: String) {
        gitError = nil
        Task {
            let repository = Git(directory)
            if let error = await git.perform("Pushing", { try await repository.push() }) {
                gitError = error.localizedDescription
            }
            await git.refresh(directory)
        }
    }

    private func openPullRequest(directory: String) {
        gitError = nil
        Task {
            let repository = Git(directory)
            var url: URL?
            let error = await git.perform("Opening pull request") {
                try await repository.push()
                let subject = (try? await repository.output(["log", "-1", "--pretty=%s"]))?
                    .trimmed ?? ""
                let body = (try? await repository.output(["log", "-1", "--pretty=%b"]))?
                    .trimmed ?? ""
                url = try await repository.createPullRequest(
                    title: subject.isEmpty ? "Update" : subject,
                    body: body.isEmpty ? "Opened from Tivano." : body
                )
            }
            if let error {
                gitError = error.localizedDescription
            } else if let url {
                NSWorkspace.shared.open(url)
            }
            await git.refresh(directory)
        }
    }

    // MARK: - Terminal Tab

    @ViewBuilder
    private var terminalTab: some View {
        if runtime.isTerminalVisible {
            VStack(spacing: 12) {
                Image(systemName: "terminal")
                    .font(.system(size: 26, weight: .regular))
                    .foregroundStyle(Chrome.secondaryText)
                Text("Terminal is docked at the bottom of this chat")
                    .font(.ui(.callout))
                    .foregroundStyle(Chrome.secondaryText)
                    .multilineTextAlignment(.center)
                HStack(spacing: 8) {
                    Button("Move to toolbox") {
                        runtime.moveTerminalToChest()
                    }
                    .chromePillButton(.regular, prominent: true)
                    Button("Hide terminal") {
                        runtime.isTerminalVisible = false
                    }
                    .chromePillButton(.regular)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            TerminalPanel(runtime: runtime, embeddedInChest: true)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
        }
    }
}

private struct ChestTabButton<Label: View>: View {
    let isSelected: Bool
    let action: () -> Void
    @ViewBuilder var label: Label

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            label
                .font(.ui(.callout, weight: isSelected ? .semibold : .medium))
                .foregroundStyle(isSelected ? Chrome.primaryText : Chrome.secondaryText)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 10)
                .frame(height: Chrome.capsuleContentHeight)
                .background {
                    if isSelected {
                        Capsule(style: .continuous)
                            .fill(Chrome.overlay(0.12))
                    } else if isHovering {
                        Capsule(style: .continuous)
                            .fill(Chrome.overlay(0.05))
                    }
                }
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .pointerStyle(.default)
        .onHover { hovering in
            guard isHovering != hovering else { return }
            withAnimation(Chrome.hover) { isHovering = hovering }
        }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct ChestArtifactRow: View {
    let artifact: ThreadArtifact
    let subtitle: String
    let onOpen: () -> Void
    let onMention: (() -> Void)?
    let onReveal: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onOpen) {
                HStack(spacing: 10) {
                    Image(systemName: symbol)
                        .font(.ui(.body))
                        .foregroundStyle(Chrome.secondaryText)
                        .frame(width: 20, alignment: .center)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: artifact.name)
                            .font(.ui(.body, weight: .medium))
                            .foregroundStyle(Chrome.primaryText)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        if !subtitle.isEmpty {
                            Text(verbatim: subtitle)
                                .font(.ui(.caption))
                                .foregroundStyle(Chrome.secondaryText)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .pointerStyle(.default)

            if isHovering {
                HStack(spacing: 4) {
                    if let onMention {
                        Button(action: onMention) {
                            Label {
                                Text("Reference in chat")
                            } icon: {
                                Image(systemName: "at")
                            }
                        }
                        .chromePillButton(.compact, iconOnly: true)
                        .help(Text(verbatim: Chrome.localized("Reference in chat")))
                        .accessibilityLabel(Text("Reference in chat"))
                    }

                    Button(action: onReveal) {
                        Label {
                            Text("Show in Finder")
                        } icon: {
                            Image(systemName: "folder")
                        }
                    }
                    .chromePillButton(.compact, iconOnly: true)
                    .help(Text(verbatim: Chrome.localized("Show in Finder")))
                    .accessibilityLabel(Text("Show in Finder"))
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            Chrome.overlay(isHovering ? 0.06 : 0.03),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .onHover { hovering in
            guard isHovering != hovering else { return }
            withAnimation(Chrome.hover) { isHovering = hovering }
        }
    }

    private var symbol: String {
        switch artifact.kind {
        case .document: "doc.richtext"
        case .webpage: "globe"
        case .image: "photo"
        case .video: "film"
        }
    }
}
