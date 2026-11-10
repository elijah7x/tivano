import SwiftUI

struct ChimeraPresetsSection: View {
    @Environment(AppModel.self) private var model
    @State private var drag = RowDrag<ChimeraPreset.ID>()
    @State private var rowHeights: [ChimeraPreset.ID: CGFloat] = [:]

    private static let slide = Animation.spring(response: 0.28, dampingFraction: 0.82)

    var body: some View {
        @Bindable var settings = model.settings
        let firstProvider = ProviderKind.alphabetical.first {
            settings.isEnabled($0) && model.providers.status($0).isInstalled
        }
        ChromeSection(title: "Model presets") {
            ChromeCard {
                if !settings.chimeraPresets.isEmpty {
                    // A plain stack preserves row identity and zIndex while rows change slots.
                    // Keep the add row outside the reorderable stack.
                    VStack(spacing: 0) {
                        ForEach($settings.chimeraPresets) { $preset in
                            let isDragged = drag.id == preset.id
                            VStack(spacing: 0) {
                                ChromeRowDivider().opacity(preset.id == settings.chimeraPresets.first?.id || isDragged ? 0 : 1)
                                ChimeraPresetRow(
                                    preset: $preset,
                                    isDragged: isDragged,
                                    onDragChanged: { translation in dragChanged(preset.id, translation: translation) },
                                    onDragEnded: { dragEnded() },
                                    onRemove: {
                                        // Reading the element binding inside removeAll overlaps the array's
                                        // exclusive access and traps, so capture the ID first.
                                        let id = preset.id
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
                    title: settings.chimeraPresets.isEmpty ? "No presets yet" : "Add preset",
                    detail: settings.chimeraPresets.isEmpty ? "Add a model and describe what it is good at." : nil
                ) {
                    Button {
                        guard let provider = firstProvider else { return }
                        withAnimation(Chrome.panelSlide) {
                            settings.chimeraPresets.append(ChimeraPreset(
                                specialty: "", pick: ChimeraPick(provider: provider, model: model.providers.defaultModel(for: provider)?.id, effort: nil)
                            ))
                        }
                    } label: {
                        Label("Add preset", systemImage: "plus")
                    }
                    .buttonStyle(.glass)
                    .disabled(firstProvider == nil)
                }
            }
            Text("Describe what each model is good at. In a real conversation Chimera reads these to match helpers with models and pre-fills the casting card, so you rarely pick by hand. Nothing runs until you confirm.")
                .font(.ui(.subheadline))
                .foregroundStyle(Chrome.secondaryText)
                .padding(.horizontal, 4)
        }
    }

    private func dragChanged(_ id: ChimeraPreset.ID, translation: CGFloat) {
        guard model.settings.chimeraPresets.contains(where: { $0.id == id }) else {
            if drag.id == id { drag = RowDrag() }
            return
        }
        if drag.id != id {
            drag = RowDrag(id: id)
        }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { drag.translation = translation }

        let order = model.settings.chimeraPresets.map(\.id)
        let moved = withAnimation(Self.slide) {
            drag.settle(order: order, heights: rowHeights, fallbackHeight: 54) { neighbour, placeAfter in
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

private struct ChimeraPresetRow: View {
    @Binding var preset: ChimeraPreset
    let isDragged: Bool
    let onDragChanged: (CGFloat) -> Void
    let onDragEnded: () -> Void
    let onRemove: () -> Void

    @AppStorage("performanceMode", store: CaptureRun.defaults ?? .standard) private var performanceMode = false

    var body: some View {
        HStack(spacing: 10) {
            ChimeraPresetGrip()
                .pointerStyle(isDragged ? .grabActive : .grabIdle)
                .gesture(
                    DragGesture(minimumDistance: 1, coordinateSpace: .global)
                        .onChanged { value in onDragChanged(value.translation.height) }
                        .onEnded { _ in onDragEnded() }
                )
                .help(Text(verbatim: Chrome.localized("Drag to reorder")))
                .accessibilityLabel(Text("Drag to reorder"))
            ChimeraPickPicker(pick: Binding(
                get: { preset.pick },
                set: { if let pick = $0 { preset.pick = pick } }
            ), width: 190)
            TextField("Describe what this model is good at", text: $preset.specialty)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(Text("Describe what this model is good at"))
            Button(action: onRemove) {
                Image(systemName: "minus.circle")
                    .font(.ui(.callout, weight: .medium))
                    .foregroundStyle(Chrome.secondaryText)
                    .frame(width: 24, height: 24)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help(Text(verbatim: Chrome.localized("Remove this preset")))
            .accessibilityLabel(Text("Remove this preset"))
        }
        .padding(.leading, 10)
        .padding(.trailing, Chrome.rowControlTrailingPadding)
        .padding(.vertical, 9)
        .background {
            if isDragged {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Chrome.overlay(0.12))
                    .shadow(color: .black.opacity(performanceMode ? 0 : 0.28), radius: performanceMode ? 0 : 10, y: performanceMode ? 0 : 4)
            }
        }
        .scaleEffect(isDragged ? 1.02 : 1)
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isDragged)
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
