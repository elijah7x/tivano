import SwiftUI

struct QuickChatView: View {
    @Environment(AppModel.self) private var model
    @Bindable var state: QuickChatState
    let controller: QuickChatPanelController

    var body: some View {
        let preview = model.newThreadPreview(overridingModel: state.modelOverride)
        let previewPair = preview.hydraPairID.flatMap { id in model.hydraPickerPairs.first { $0.id == id } }
            ?? model.settings.hydraPair(preview.hydraPairID)
        let modelName = model.providers.model(preview.model, for: preview.provider)?.chipName
            ?? preview.model.map { ModelPin(provider: preview.provider, modelID: $0).displayName }
            ?? preview.provider.displayName
        let chipTitle = previewPair.map { HydraPairSummary.title($0, registry: model.providers) } ?? modelName

        QuickChatInput(
            state: state,
            controller: controller,
            preview: preview,
            previewPair: previewPair,
            chipTitle: chipTitle
        )
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 12)
        .environment(\.isOnGlassPanel, true)
        .frame(width: 640)
        .floatingGlass(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .floatingGlassContainer()
        .padding(24)
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
            controller.resize(to: height)
        }
    }
}

private struct QuickChatInput: View {
    @Environment(AppModel.self) private var model
    @Bindable var state: QuickChatState
    let controller: QuickChatPanelController
    let preview: ChatThread
    let previewPair: HydraPair?
    let chipTitle: String
    @FocusState private var isFocused: Bool
    @State private var showsModelPicker = false

    var body: some View {
        let isEmpty = state.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        VStack(alignment: .leading, spacing: 12) {
            TextField("Ask anything, or hand the agent a task…", text: $state.text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.ui(size: 17))
                .lineLimit(1...8)
                .focused($isFocused)
                .onAppear { isFocused = true }
                .onChange(of: state.focusToken) { _, _ in isFocused = true }
                .onKeyPress(.return, phases: .down) { press in
                    // A vertical field submits on Shift-Return too, so the newline goes in by hand,
                    // at the caret through the field editor.
                    if press.modifiers.contains(.shift) {
                        if let editor = NSApp.keyWindow?.firstResponder as? NSTextView {
                            editor.insertNewlineIgnoringFieldEditor(nil)
                        } else {
                            state.text += "\n"
                        }
                        return .handled
                    }
                    controller.send(model: model, openAfter: press.modifiers.contains(.command))
                    return .handled
                }
                .onKeyPress(.escape) {
                    controller.hide()
                    return .handled
                }

            HStack(spacing: 8) {
                Button { showsModelPicker.toggle() } label: {
                    HStack(spacing: 6) {
                        if let previewPair {
                            HydraFusedPairIcon(
                                lead: previewPair.provider,
                                heads: model.hydraHeadsProvider(of: previewPair),
                                size: 14,
                                animates: false
                            )
                        } else {
                            ProviderIcon(provider: preview.provider, size: 14)
                        }
                        Text(verbatim: chipTitle)
                            .font(.ui(.subheadline))
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(Chrome.chevronFont)
                            .foregroundStyle(Chrome.secondaryText)
                    }
                    .foregroundStyle(Chrome.primaryText)
                    .padding(.horizontal, Chrome.capsuleHorizontalPadding)
                    .frame(height: Chrome.capsuleContentHeight)
                    .padding(.vertical, Chrome.capsuleVerticalPadding)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .chromeGlassCapsule()
                .popover(isPresented: $showsModelPicker) {
                    NewThreadDefaultPicker(
                        selection: state.modelOverride,
                        selectedModelID: preview.model,
                        initialProvider: preview.provider
                    ) { selection in
                        state.modelOverride = selection
                        switch selection {
                        case nil, .pair:
                            showsModelPicker = false
                        case .model:
                            break
                        }
                    }
                    .presentedChrome()
                }
                Spacer()
                ChromeCircleButton(symbol: "arrow.up.left.and.arrow.down.right", help: "Open in Tivano") {
                    controller.expand(model: model)
                }

                Button { controller.send(model: model, openAfter: false) } label: {
                    Image(systemName: "arrow.up")
                        .font(Chrome.iconFont.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(Chrome.accent, in: .circle)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(isEmpty)
                .opacity(isEmpty ? 0.4 : 1)
                .accessibilityLabel(Text("Send"))
            }
        }
    }
}
