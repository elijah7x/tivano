import SwiftUI

struct ChimeraPresetsSection: View {
    @Environment(AppModel.self) private var model
    @State private var drag = RowDrag<ChimeraPreset.ID>()
    @State private var rowHeights: [ChimeraPreset.ID: CGFloat] = [:]
    @State private var editingID: ChimeraPreset.ID?

    private static let slide = Animation.spring(response: 0.28, dampingFraction: 0.82)

    var body: some View {
        @Bindable var settings = model.settings
        let builtins = settings.chimeraPresets.filter { $0.builtin != nil }
        let customs = settings.chimeraPresets.filter { $0.builtin == nil }

        VStack(alignment: .leading, spacing: Chrome.sectionSpacing) {
            if !builtins.isEmpty {
                ChromeSection(title: "Built-in identities") {
                    ChromeCard {
                        VStack(spacing: 0) {
                            ForEach(builtins) { preset in
                                if preset.id != builtins.first?.id {
                                    ChromeRowDivider()
                                }
                                ChimeraIdentityRow(
                                    preset: presetBinding(for: preset),
                                    isDragged: false,
                                    onDragChanged: nil,
                                    onDragEnded: nil,
                                    onEdit: { editingID = preset.id },
                                    onRemove: nil
                                )
                            }
                        }
                    }
                }
            }

            ChromeSection(title: "My identities") {
                ChromeCard {
                    if !customs.isEmpty {
                        // A plain stack preserves row identity and zIndex while rows change slots.
                        // Keep the add row outside the reorderable stack.
                        VStack(spacing: 0) {
                            ForEach(customs) { preset in
                                let binding = presetBinding(for: preset)
                                let isDragged = drag.id == preset.id
                                VStack(spacing: 0) {
                                    ChromeRowDivider().opacity(preset.id == customs.first?.id || isDragged ? 0 : 1)
                                    ChimeraIdentityRow(
                                        preset: binding,
                                        isDragged: isDragged,
                                        onDragChanged: { translation in dragChanged(preset.id, translation: translation) },
                                        onDragEnded: { dragEnded() },
                                        onEdit: { editingID = preset.id },
                                        onRemove: {
                                            // Reading the element binding inside removeAll overlaps the array's
                                            // exclusive access and traps, so capture the ID first.
                                            let id = preset.id
                                            if editingID == id { editingID = nil }
                                            withAnimation(Chrome.panelSlide) {
                                                settings.chimeraPresets.removeAll { $0.id == id }
                                            }
                                        }
                                    )
                                }
                                .modifier(ChimeraPresetRowHeightReporter(id: preset.id, heights: $rowHeights))
                                .offset(y: isDragged ? drag.visualOffset : 0)
                                .zIndex(isDragged ? 1 : 0)
                            }
                        }
                        .zIndex(drag.id == nil ? 0 : 1)
                        ChromeRowDivider()
                    }
                    ChromeRow(
                        title: "Add identity",
                        detail: customs.isEmpty ? "Write your own identity with a short prompt." : nil
                    ) {
                        Button {
                            let added = ChimeraPreset(specialty: "", pick: nil)
                            withAnimation(Chrome.panelSlide) {
                                settings.chimeraPresets.append(added)
                            }
                            editingID = added.id
                        } label: {
                            Label("Add identity", systemImage: "plus")
                        }
                        .chromePillButton()
                    }
                }
            }
        }
        .sheet(isPresented: Binding(
            get: { editingID.flatMap { id in settings.chimeraPresets.contains { $0.id == id } } ?? false },
            set: { if !$0 { editingID = nil } }
        )) {
            if let id = editingID, let preset = settings.chimeraPresets.first(where: { $0.id == id }) {
                ChimeraIdentityEditorSheet(
                    preset: presetBinding(for: preset),
                    onDelete: {
                        editingID = nil
                        withAnimation(Chrome.panelSlide) {
                            settings.chimeraPresets.removeAll { $0.id == id }
                        }
                    }
                )
                .presentedChrome()
                .presentationBackground { WindowBackdrop(opacity: model.settings.backdropOpacity) }
            }
        }
        .transformPreference(ChromePresentationPreference.self) { $0 = $0 || editingID != nil }
    }

    private func presetBinding(for preset: ChimeraPreset) -> Binding<ChimeraPreset> {
        let id = preset.id
        return Binding(
            get: { model.settings.chimeraPresets.first(where: { $0.id == id }) ?? preset },
            set: { newPreset in
                guard let index = model.settings.chimeraPresets.firstIndex(where: { $0.id == id }) else { return }
                model.settings.chimeraPresets[index] = newPreset
            }
        )
    }

    private func dragChanged(_ id: ChimeraPreset.ID, translation: CGFloat) {
        guard model.settings.chimeraPresets.contains(where: { $0.id == id && $0.builtin == nil }) else {
            if drag.id == id { drag = RowDrag() }
            return
        }
        if drag.id != id {
            drag = RowDrag(id: id)
        }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { drag.translation = translation }

        let order = model.settings.chimeraPresets.filter { $0.builtin == nil }.map(\.id)
        let moved = withAnimation(Self.slide) {
            drag.settle(order: order, heights: rowHeights, fallbackHeight: 58) { neighbour, placeAfter in
                model.settings.moveChimeraPreset(id, to: neighbour, placeAfter: placeAfter)
            }
        }
        if moved {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
    }

    private func dragEnded() {
        guard drag.id != nil else { return }
        withAnimation(.spring(response: 0.32, dampingFraction: 0.8)) { drag = RowDrag() }
    }

    private struct ChimeraPresetRowHeightReporter: ViewModifier {
        let id: ChimeraPreset.ID
        @Binding var heights: [ChimeraPreset.ID: CGFloat]

        func body(content: Content) -> some View {
            content.onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { height in
                if heights[id].map({ abs($0 - height) > 0.5 }) ?? true { heights[id] = height }
            }
        }
    }
}

private struct ChimeraIdentityRow: View {
    @Environment(AppModel.self) private var model
    @Binding var preset: ChimeraPreset
    let isDragged: Bool
    let onDragChanged: ((CGFloat) -> Void)?
    let onDragEnded: (() -> Void)?
    let onEdit: () -> Void
    let onRemove: (() -> Void)?

    private var titleInfo: (text: String, isUnnamedCustom: Bool) {
        let trimmedName = preset.name.trimmed
        if !trimmedName.isEmpty {
            return (trimmedName, false)
        }
        if let builtin = preset.builtin {
            return (Chrome.localized(builtin.title), false)
        }
        let modelName = shortModelName(for: preset.pick) ?? Chrome.localized("Follow the lead")
        return (String(format: Chrome.localized("Unnamed · %@"), modelName), true)
    }

    private var promptLine: String {
        let raw: String
        if let builtin = preset.builtin, preset.specialty.trimmed.isEmpty {
            raw = Chrome.localized(builtin.defaultPrompt)
        } else {
            raw = preset.effectivePrompt
        }
        return raw.replacingOccurrences(of: "\n", with: " ").trimmed
    }

    private func shortModelName(for pick: ChimeraPick?) -> String? {
        guard let pick else { return nil }
        let registry = model.providers
        let known = pick.model.flatMap { registry.model($0, for: pick.provider) }
        let option = pick.model == nil ? registry.defaultModel(for: pick.provider) : known
        return option?.shortName ?? pick.model ?? pick.provider.displayName
    }

    var body: some View {
        let title = titleInfo
        let prompt = promptLine
        HStack(spacing: 10) {
            if let onDragChanged, let onDragEnded {
                ChimeraPresetGrip()
                    .pointerStyle(isDragged ? .grabActive : .grabIdle)
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { value in onDragChanged(value.translation.height) }
                            .onEnded { _ in onDragEnded() }
                    )
                    .help(Text(verbatim: Chrome.localized("Drag to reorder")))
                    .accessibilityLabel(Text("Drag to reorder"))
            }
            Button(action: onEdit) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: title.text)
                        .font(.ui(.body))
                        .foregroundStyle(title.isUnnamedCustom ? Chrome.secondaryText : Chrome.primaryText)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if !prompt.isEmpty {
                        Text(verbatim: prompt)
                            .font(.ui(.subheadline))
                            .foregroundStyle(Chrome.secondaryText)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .opacity(preset.enabled ? 1 : 0.5)
            ChimeraPickPicker(pick: $preset.pick, width: 170)
                .opacity(preset.enabled ? 1 : 0.5)
            SettingsSwitch(isOn: $preset.enabled)
                .accessibilityLabel(Text(verbatim: title.text))
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "minus.circle")
                        .font(.ui(.callout, weight: .medium))
                        .foregroundStyle(Chrome.secondaryText)
                        .frame(width: 24, height: 24)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help(Text(verbatim: Chrome.localized("Delete")))
                .accessibilityLabel(Text("Delete"))
            }
        }
        .padding(.leading, onDragChanged != nil ? 10 : 16)
        .padding(.trailing, Chrome.rowControlTrailingPadding)
        .padding(.vertical, 10)
        .background {
            if isDragged {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Chrome.overlay(0.12))
                    .shadow(color: .black.opacity(0.28), radius: 10, y: 4)
            }
        }
        .scaleEffect(isDragged ? 1.02 : 1)
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isDragged)
    }
}

private struct ChimeraIdentityEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var preset: ChimeraPreset
    let onDelete: () -> Void

    private var namePlaceholder: String {
        preset.builtin.map { Chrome.localized($0.title) } ?? Chrome.localized("Unnamed")
    }

    private var promptPlaceholder: String {
        if let builtin = preset.builtin {
            return Chrome.localized(builtin.defaultPrompt)
        }
        return Chrome.localized("You are … Good at … Focus on …")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(verbatim: Chrome.localized("Edit identity"))
                .font(.ui(.title2, weight: .semibold))
                .foregroundStyle(Chrome.primaryText)

            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: Chrome.localized("Name"))
                    .font(.ui(.subheadline, weight: .semibold))
                    .foregroundStyle(Chrome.secondaryText)
                TextField("", text: $preset.name, prompt: Text(verbatim: namePlaceholder))
                    .textFieldStyle(.plain)
                    .focusEffectDisabled()
                    .font(.ui(.body))
                    .foregroundStyle(Chrome.primaryText)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(Chrome.overlay(0.05), in: .rect(cornerRadius: 9, style: .continuous))
                    .accessibilityLabel(Text("Name"))
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: Chrome.localized("Prompt"))
                    .font(.ui(.subheadline, weight: .semibold))
                    .foregroundStyle(Chrome.secondaryText)
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $preset.specialty)
                        .font(.ui(.body))
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .accessibilityLabel(Text("Prompt"))
                    if preset.specialty.isEmpty {
                        Text(verbatim: promptPlaceholder)
                            .font(.ui(.body))
                            .foregroundStyle(Chrome.secondaryText)
                            .padding(.horizontal, 13)
                            .padding(.vertical, 8)
                            .allowsHitTesting(false)
                    }
                }
                .frame(height: 108)
                .background(Chrome.overlay(0.05), in: .rect(cornerRadius: 10, style: .continuous))
            }

            HStack(alignment: .center, spacing: 12) {
                Text(verbatim: Chrome.localized("Model"))
                    .font(.ui(.subheadline, weight: .semibold))
                    .foregroundStyle(Chrome.secondaryText)
                Spacer(minLength: 12)
                ChimeraPickPicker(pick: $preset.pick)
            }

            HStack(spacing: 10) {
                if preset.builtin != nil {
                    Button {
                        preset.specialty = ""
                        preset.name = ""
                    } label: {
                        Text(verbatim: Chrome.localized("Restore default"))
                    }
                    .chromePillButton()
                    .disabled(preset.specialty.isEmpty && preset.name.isEmpty)
                } else {
                    Button(role: .destructive) {
                        onDelete()
                    } label: {
                        Text(verbatim: Chrome.localized("Delete"))
                    }
                    .chromePillButton()
                }
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Text(verbatim: Chrome.localized("Done"))
                }
                .chromePillButton(prominent: true)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}

private struct ChimeraPresetGrip: View {
    @State private var isHovering = false

    var body: some View {
        Image(systemName: "line.3.horizontal")
            .font(.ui(size: 11, weight: .medium))
            .foregroundStyle(Chrome.secondaryText.opacity(isHovering ? 1 : 0.7))
            .frame(width: 24, height: 24)
            .contentShape(.rect)
            .onHover { if isHovering != $0 { isHovering = $0 } }
    }
}
