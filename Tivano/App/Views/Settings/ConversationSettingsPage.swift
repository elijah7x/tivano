import SwiftUI

/// New-thread defaults, conversation interface controls, thread list rules and realtime voice.
struct ConversationSettingsPage: View {
    @Environment(AppModel.self) private var model

    private static let workspaceOptions = WorkspaceMode.allCases.map { ($0, $0.title) }
    private static let autoShelveOptions: [(Int, String)] = [
        (0, "Never"),
        (3, "3 days"),
        (7, "7 days"),
        (14, "14 days"),
    ]

    var body: some View {
        @Bindable var settings = model.settings
        let textGenOff = settings.textGeneration == .off

        ChromeSection(title: "New thread defaults") {
            Text("This is how a new thread opens. Click any control to change its default.")
                .font(.ui(.subheadline))
                .foregroundStyle(Chrome.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            ChromeCard {
                NewThreadStagePreview(
                    location: $settings.newThreadLocation,
                    runtimeMode: $settings.defaultRuntimeMode
                )
                ChromeRowDivider()
                ChromeRow(title: "Workspace", detail: settings.defaultWorkspaceMode.summary) {
                    ChromeVisualPicker(options: Self.workspaceOptions, selection: $settings.defaultWorkspaceMode) { mode in
                        Image(systemName: mode.symbol)
                    }
                }
            }
        }

        ChromeSection(title: "Conversation interface") {
            ChromeCard {
                ChromeRow(title: "Show thinking", detail: "The working line opens to the agent's thinking") {
                    SettingsSwitch(isOn: $settings.showReasoning)
                }
                ChromeRowDivider()
                ChromeRow(title: "Working line", detail: "A card with the turn's progress bar, or a plain line") {
                    ChromeVisualPicker(options: [(true, "Card"), (false, "Line")], selection: $settings.showsWorkingCard) { isCard in
                        Image(systemName: isCard ? "rectangle.fill" : "minus")
                    }
                }
                ChromeRowDivider()
                ChromeRow(title: "Chime when a turn finishes", detail: "A soft chime, whether or not the thread is in view") {
                    SettingsSwitch(isOn: $settings.chimeWhenFinished)
                }
                .onChange(of: settings.chimeWhenFinished) { _, isOn in
                    if isOn { FinishChime.play() }
                }
                ChromeRowDivider()
                ChromeRow(
                    title: "Composer predictions",
                    detail: textGenOff
                        ? "Turn on a background model in Settings › Models to use composer predictions."
                        : "After a reply, suggests your likely next message in the empty composer; press Tab or → to use it."
                ) {
                    SettingsSwitch(isOn: $settings.promptPredictionsEnabled)
                        .accessibilityLabel(Text("Composer predictions"))
                }
                .disabled(textGenOff)
                .opacity(textGenOff ? 0.5 : 1)
                ChromeRowDivider()
                ChromeRow(title: "Collapse top controls", detail: "Keep the upper-right controls and file changes behind a … button") {
                    SettingsSwitch(isOn: $settings.collapseTopControls)
                }
                ChromeRowDivider()
                ChromeRow(
                    title: "Prevent sleep while tasks are running",
                    detail: "While tasks run, your Mac won't doze off. Keep Mac awake lets the screen turn off on its own; Keep Mac and screen awake leaves it lit too, which helps when an agent needs to see a front end. Manual sleep and closing the lid still work."
                ) {
                    GlassPickerButton(options: TaskSleepMode.allCases.map { ($0, $0.title) }, selection: $settings.taskSleepMode)
                }
            }
        }

        ChromeSection(title: "Thread list") {
            ChromeCard {
                ChromeRow(
                    title: "Thread titles",
                    detail: textGenOff
                        ? "Turn on a background model in Settings › Models to name threads automatically."
                        : "Name once titles a chat from its first message. Keep updated renames it every few turns when the work moves on. Titles you set yourself never change."
                ) {
                    GlassPickerButton(options: ThreadTitleMode.allCases.map { ($0, $0.title) }, selection: $settings.threadTitleMode)
                }
                .disabled(textGenOff)
                .opacity(textGenOff ? 0.5 : 1)
                ChromeRowDivider()
                ChromeRow(title: "Confirm before deleting threads") {
                    SettingsSwitch(isOn: $settings.confirmBeforeDeleting)
                }
                ChromeRowDivider()
                ChromeRow(title: "Auto-shelve projects", detail: "Shelve a project after its latest thread has been idle this long. Projects with running, unread or selected threads stay put.") {
                    GlassPickerButton(options: Self.autoShelveOptions, selection: $settings.autoShelveDays, maxWidth: 190)
                }
                .onChange(of: settings.autoShelveDays) { model.autoShelveIdleProjects() }
            }
        }

        ChromeSection(title: "Realtime voice") {
            ChromeCard {
                ChromeRow(title: "Codex realtime voice", detail: "Talk with Codex out loud. Start a call from the waveform button next to send in any Codex chat's composer. Codex listens, answers and does the work in the chat. Needs Codex 0.159 or later, signed in with ChatGPT. Turning this off ends the current call.") {
                    SettingsSwitch(isOn: $settings.voiceEnabled)
                        .accessibilityLabel(Text("Codex realtime voice"))
                }
                if settings.voiceEnabled {
                    ChromeRowDivider()
                    VoiceStyleRow()
                }
            }
        }
        .onChange(of: settings.isVoiceEnabled) { _, enabled in
            if !enabled { model.voice.end() }
        }
    }
}

/// Miniature main-window stage where the location, default model and default permission chips
/// sit in the places they occupy when starting a new conversation.
private struct NewThreadStagePreview: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var location: NewThreadLocation
    @Binding var runtimeMode: RuntimeMode

    @State private var shimmerPhase: CGFloat = 0
    @State private var isShimmering = false
    @State private var hasShimmered = false

    private var activeShimmer: CGFloat? {
        !reduceMotion && isShimmering ? shimmerPhase : nil
    }

    var body: some View {
        HStack(spacing: 0) {
            MiniatureSidebarStrip()
            Rectangle()
                .fill(Chrome.overlay(0.08))
                .frame(width: 0.5)
                .accessibilityHidden(true)

            VStack(spacing: 14) {
                HStack {
                    Spacer(minLength: 0)
                    Image(systemName: "ellipsis")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 8)
                        .frame(height: 18)
                        .background(Capsule(style: .continuous).fill(Chrome.overlay(0.05)))
                        .overlay(Capsule(style: .continuous).strokeBorder(Chrome.overlay(0.10), lineWidth: 0.5))
                        .accessibilityHidden(true)
                }

                VStack(spacing: 10) {
                    Text("What should we build?")
                        .font(.ui(.title, weight: .regular))
                        .foregroundStyle(Chrome.primaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)

                    VStack(spacing: 4) {
                        DefaultLocationChip(selection: $location, shimmerPhase: activeShimmer)
                        StageCallout("Where new threads go")
                    }
                }
                .frame(maxWidth: .infinity)

                VStack(spacing: 5) {
                    VStack(alignment: .leading, spacing: 10) {
                        GeometryReader { proxy in
                            Capsule(style: .continuous)
                                .fill(Chrome.overlay(0.10))
                                .frame(width: proxy.size.width * 0.55, height: 7)
                        }
                        .frame(height: 7)
                        .padding(.horizontal, 4)
                        .padding(.top, 2)
                        .accessibilityHidden(true)

                        HStack(spacing: 6) {
                            DefaultModelStageChip(shimmerPhase: activeShimmer)
                            Spacer(minLength: 8)
                            HStack(spacing: 4) {
                                Image(systemName: "paperclip")
                                    .font(Chrome.iconFont)
                                    .foregroundStyle(.tertiary)
                                    .frame(width: Chrome.capsuleContentHeight, height: Chrome.capsuleContentHeight)
                                    .allowsHitTesting(false)
                                    .accessibilityHidden(true)
                                DefaultPermissionMenu(selection: $runtimeMode, shimmerPhase: activeShimmer)
                                    .fixedSize(horizontal: true, vertical: false)
                                Image(systemName: "arrow.up")
                                    .font(Chrome.iconFont)
                                    .foregroundStyle(.white)
                                    .frame(width: Chrome.capsuleContentHeight, height: Chrome.capsuleContentHeight)
                                    .background(.quaternary, in: .circle)
                                    .padding(.leading, 2)
                                    .allowsHitTesting(false)
                                    .accessibilityHidden(true)
                            }
                            .layoutPriority(1)
                        }
                    }
                    .padding(.leading, 10)
                    .padding(.trailing, 8)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Chrome.overlay(0.05))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Chrome.overlay(0.10), lineWidth: 0.5)
                    )

                    HStack(spacing: 8) {
                        StageCallout("Default model", arrowPlacement: .leading)
                            .padding(.leading, 12)
                        Spacer(minLength: 8)
                        StageCallout("Default permission", arrowPlacement: .trailing)
                            .padding(.trailing, 52)
                    }
                }
                .padding(.top, 8)
            }
            .padding(10)
            .frame(maxWidth: .infinity)
        }
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Chrome.overlay(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Chrome.overlay(0.10), lineWidth: 0.5)
        )
        .padding(.horizontal, Chrome.contentHorizontalPadding)
        .padding(.vertical, 14)
        .background { NoWindowDragArea() }
        .task {
            guard !reduceMotion, !hasShimmered else { return }
            isShimmering = true
            shimmerPhase = 0
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled, !reduceMotion else {
                isShimmering = false
                return
            }
            withAnimation(.easeInOut(duration: 1.2)) {
                shimmerPhase = 1
            }
            try? await Task.sleep(for: .milliseconds(1250))
            guard !Task.isCancelled else { return }
            isShimmering = false
            hasShimmered = true
        }
        .onChange(of: reduceMotion) { _, reduced in
            if reduced { isShimmering = false }
        }
        .onDisappear {
            if isShimmering {
                isShimmering = false
                hasShimmered = true
            }
        }
    }
}

private struct MiniatureSidebarStrip: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { _ in
                    Circle()
                        .fill(Chrome.overlay(0.14))
                        .frame(width: 5.5, height: 5.5)
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                Capsule(style: .continuous)
                    .fill(Chrome.overlay(0.08))
                    .frame(width: 22, height: 3.5)
                sidebarBar(width: 48, opacity: 0.13)
                sidebarBar(width: 38, opacity: 0.08)
                sidebarBar(width: 44, opacity: 0.08)
            }

            VStack(alignment: .leading, spacing: 5) {
                Capsule(style: .continuous)
                    .fill(Chrome.overlay(0.08))
                    .frame(width: 26, height: 3.5)
                sidebarBar(width: 42, opacity: 0.08)
                sidebarBar(width: 32, opacity: 0.08)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 10)
        .frame(width: 68, alignment: .leading)
        .background(
            UnevenRoundedRectangle(
                topLeadingRadius: 12,
                bottomLeadingRadius: 12,
                bottomTrailingRadius: 0,
                topTrailingRadius: 0,
                style: .continuous
            )
            .fill(Chrome.overlay(0.025))
        )
        .accessibilityHidden(true)
    }

    private func sidebarBar(width: CGFloat, opacity: Double) -> some View {
        RoundedRectangle(cornerRadius: 3.5, style: .continuous)
            .fill(Chrome.overlay(opacity))
            .frame(width: width, height: 7)
    }
}

private struct StageCallout: View {
    enum ArrowPlacement {
        case leading
        case trailing
    }

    let title: String
    var arrowPlacement: ArrowPlacement = .leading

    init(_ title: String, arrowPlacement: ArrowPlacement = .leading) {
        self.title = title
        self.arrowPlacement = arrowPlacement
    }

    var body: some View {
        HStack(spacing: 3) {
            if arrowPlacement == .leading {
                arrow
            }
            Text(verbatim: Chrome.localized(title))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            if arrowPlacement == .trailing {
                arrow
            }
        }
        .font(.ui(.caption))
        .foregroundStyle(.tertiary)
        .accessibilityHidden(true)
    }

    private var arrow: some View {
        Image(systemName: "arrow.up")
            .font(.system(size: 8, weight: .semibold))
    }
}

private struct StageChipLabel: View {
    var provider: ProviderKind? = nil
    var symbol: String? = nil
    let title: String
    let isActive: Bool

    var body: some View {
        HStack(spacing: 5) {
            if let provider {
                ProviderIcon(provider: provider, size: 14)
            } else if let symbol {
                Image(systemName: symbol)
                    .font(.ui(size: TypeScale.stockPointSize(.callout) + 1.5, weight: .semibold))
                    .frame(width: TypeScale.shared.ui(14), height: TypeScale.shared.ui(14))
                    .foregroundStyle(isActive ? Chrome.accent : Chrome.secondaryText)
            }
            Text(verbatim: title)
                .font(.ui(.callout, weight: .medium))
                .foregroundStyle(Chrome.primaryText)
                .lineLimit(1)
                .truncationMode(.tail)
            Image(systemName: "chevron.down")
                .font(Chrome.chevronFont)
                .foregroundStyle(Chrome.secondaryText)
        }
        .padding(.horizontal, 10)
        .frame(height: Chrome.capsuleContentHeight)
    }
}

private struct StageEditableChipStyle: ButtonStyle {
    let isActive: Bool
    let shimmerPhase: CGFloat?
    var shimmerDelay: CGFloat = 0

    func makeBody(configuration: Configuration) -> some View {
        ChipBody(
            configuration: configuration,
            isActive: isActive,
            shimmerPhase: shimmerPhase,
            shimmerDelay: shimmerDelay
        )
    }

    private struct ChipBody: View {
        let configuration: Configuration
        let isActive: Bool
        let shimmerPhase: CGFloat?
        let shimmerDelay: CGFloat
        @Environment(\.colorScheme) private var colorScheme
        @State private var isHovering = false

        var body: some View {
            configuration.label
                .background {
                    Capsule(style: .continuous)
                        .fill(fillColor)
                }
                .overlay {
                    Capsule(style: .continuous)
                        .strokeBorder(borderColor, lineWidth: isActive || isHovering ? 1 : 0.75)
                }
                .overlay {
                    if let shimmerPhase {
                        shimmerOverlay(phase: shimmerPhase)
                    }
                }
                .contentShape(Capsule(style: .continuous))
                .onHover { isHovering = $0 }
                .animation(Chrome.hover, value: isHovering)
        }

        private var fillColor: Color {
            if isActive { return Chrome.accent.opacity(configuration.isPressed ? 0.24 : 0.15) }
            if configuration.isPressed { return Chrome.overlay(0.13) }
            return Chrome.overlay(isHovering ? 0.09 : 0.055)
        }

        private var borderColor: Color {
            if isActive { return Chrome.accent.opacity(0.45) }
            if isHovering { return Chrome.overlay(0.28) }
            return Chrome.overlay(0.12)
        }

        private func shimmerOverlay(phase: CGFloat) -> some View {
            let isDark = colorScheme == .dark
            let wash = isDark ? Color.white.opacity(0.12) : Chrome.accent.opacity(0.12)
            let rim = isDark ? Color.white.opacity(0.30) : Chrome.accent.opacity(0.30)
            return GeometryReader { proxy in
                let width = max(proxy.size.width, 1)
                let band = max(width * 0.75, 56)
                let startX = -band * 1.2 - shimmerDelay * width
                let endX = width + band * 1.2 - shimmerDelay * width
                Capsule(style: .continuous)
                    .fill(wash)
                    .overlay {
                        Capsule(style: .continuous)
                            .strokeBorder(rim, lineWidth: 1)
                    }
                    .mask(alignment: .leading) {
                        LinearGradient(
                            colors: [.clear, .white.opacity(0.55), .white, .white.opacity(0.55), .clear],
                            startPoint: UnitPoint(x: 0, y: 0.25),
                            endPoint: UnitPoint(x: 1, y: 0.75)
                        )
                        .frame(width: band, height: proxy.size.height + 8)
                        .offset(x: startX + (endX - startX) * phase)
                    }
            }
            .clipShape(Capsule(style: .continuous))
            .allowsHitTesting(false)
        }
    }
}

private struct DefaultLocationChip: View {
    @Binding var selection: NewThreadLocation
    var shimmerPhase: CGFloat?
    @State private var isPresented = false

    private static let options: [(value: NewThreadLocation, title: String, symbol: String)] = [
        (.recent, "Follow the latest chat", "clock.arrow.circlepath"),
        (.standalone, "No project", "bubble.left"),
    ]

    private var current: (value: NewThreadLocation, title: String, symbol: String) {
        Self.options.first { $0.value == selection } ?? Self.options[0]
    }

    var body: some View {
        let valueTitle = Chrome.localized(current.title)
        let chipTitle = String(format: Chrome.localized("Place in: %@"), valueTitle)

        Button {
            isPresented.toggle()
        } label: {
            StageChipLabel(symbol: current.symbol, title: chipTitle, isActive: isPresented)
        }
        .buttonStyle(StageEditableChipStyle(isActive: isPresented, shimmerPhase: shimmerPhase, shimmerDelay: 0))
        .help(Text(verbatim: Chrome.localized("By default, follow the latest chat's location, including Tasks. Applies only to ordinary new chats; creating a chat from a project still places it in that project.")))
        .accessibilityLabel(Text("Where new threads go"))
        .accessibilityValue(Text(verbatim: valueTitle))
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            PopoverMenu {
                PopoverSectionHeader("Default location")
                ForEach(Self.options, id: \.value) { option in
                    PopoverItem(option.title, symbol: option.symbol, isChecked: selection == option.value) {
                        selection = option.value
                        isPresented = false
                    }
                }
            }
        }
    }
}

private struct DefaultPermissionMenu: View {
    @Binding var selection: RuntimeMode
    var shimmerPhase: CGFloat?
    @State private var isPresented = false

    var body: some View {
        let title = Chrome.localized(selection.title)

        Button {
            isPresented.toggle()
        } label: {
            StageChipLabel(symbol: selection.symbol, title: title, isActive: isPresented)
        }
        .buttonStyle(StageEditableChipStyle(isActive: isPresented, shimmerPhase: shimmerPhase, shimmerDelay: 0.20))
        .help(Text(verbatim: "\(title) · \(Chrome.localized(selection.summary))"))
        .accessibilityLabel(Text("Default permission"))
        .accessibilityValue(Text(verbatim: title))
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            PopoverMenu {
                PopoverSectionHeader("Permissions")
                ForEach(RuntimeMode.allCases) { mode in
                    PopoverItem(mode.title, symbol: mode.symbol, isChecked: selection == mode) {
                        selection = mode
                        isPresented = false
                    }
                }
            }
        }
    }
}

private struct DefaultModelStageChip: View {
    @Environment(AppModel.self) private var model
    var shimmerPhase: CGFloat?
    @State private var isPresented = false

    var body: some View {
        let registry = model.providers
        let providers = registry.availableProviders
        let selection = model.settings.newThreadModelSelection
        let option = selection.flatMap { registry.model($0.modelID, for: $0.provider) }
        let isAvailable = selection.map { providers.contains($0.provider) && option != nil } ?? true
        let name = selection.map { ModelPin(provider: $0.provider, modelID: $0.modelID).displayName }
        let effortTitle = option.flatMap { option -> String? in
            guard !option.efforts.isEmpty else { return nil }
            let effort = selection?.effort.flatMap { option.efforts.contains($0) ? $0 : nil }
            return Chrome.localized(ModelOption.effortTitle(effort ?? option.defaultEffort ?? ""))
        }
        let title = selection.map { [$0.provider.displayName, option?.shortName ?? name ?? $0.modelID, effortTitle].compactMap { $0 }.joined(separator: " · ") }
            ?? Chrome.localized("Last selection")
        let fullTitle = selection.map { [$0.provider.displayName, option?.name ?? name ?? $0.modelID, effortTitle].compactMap { $0 }.joined(separator: " · ") }
            ?? Chrome.localized("Last selection")
        let displayedTitle = isAvailable ? title : String(format: Chrome.localized("%@ (unavailable)"), title)
        let helpTitle = isAvailable ? fullTitle : String(format: Chrome.localized("%@ (unavailable)"), fullTitle)
        let availabilityNote = isAvailable
            ? nil
            : Chrome.localized("The selected model is unavailable. New chats will use Last selection.")
        let helpText = [
            helpTitle,
            Chrome.localized("Project combos take priority. Otherwise, Last selection uses the current or most recent model; a selected model stays fixed."),
            availabilityNote,
        ].compactMap { $0 }.joined(separator: "\n")

        Button {
            isPresented.toggle()
        } label: {
            StageChipLabel(
                provider: selection?.provider,
                symbol: selection == nil ? "clock.arrow.circlepath" : nil,
                title: displayedTitle,
                isActive: isPresented
            )
        }
        .buttonStyle(StageEditableChipStyle(isActive: isPresented, shimmerPhase: shimmerPhase, shimmerDelay: 0.10))
        .help(Text(verbatim: helpText))
        .accessibilityLabel(Text("Default model"))
        .accessibilityValue(Text(verbatim: helpTitle))
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            DefaultModelPopover(
                selection: selection,
                selectedModelID: option?.id ?? selection?.modelID,
                initialProvider: selection?.provider
                    ?? (providers.contains(model.settings.defaultProvider) ? model.settings.defaultProvider : providers.first)
            ) { chosen in
                model.settings.newThreadModelSelection = chosen
                if chosen == nil { isPresented = false }
            }
            .frame(width: 360)
            .presentedChrome()
        }
    }
}

private struct VoiceStyleRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        var options = model.voice.voices
        if let saved = settings.codexVoice, !options.contains(saved) { options.append(saved) }
        return ChromeRow(title: "Codex voice style", detail: "Applies to your next voice session") {
            GlassPickerButton(
                options: [(String?.none, "Codex default")] + options.map { (String?.some($0), VoiceCatalog.label($0)) },
                selection: $settings.codexVoice
            )
            .accessibilityLabel(Text("Codex voice style"))
        }
    }
}
