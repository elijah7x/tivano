import SwiftUI

struct QuickChatView: View {
    @Environment(AppModel.self) private var model
    @Bindable var state: QuickChatState
    let controller: QuickChatPanelController
    @FocusState private var isFocused: Bool
    @State private var showsModelPicker = false

    var body: some View {
        let preview = model.newThreadPreview(overridingModel: state.modelOverride)
        let modelName = model.providers.model(preview.model, for: preview.provider)?.chipName
            ?? preview.model.map { ModelPin(provider: preview.provider, modelID: $0).displayName }
            ?? preview.provider.displayName
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
                Button { showsModelPicker = true } label: {
                    HStack(spacing: 6) {
                        ProviderIcon(provider: preview.provider, size: 14)
                        Text(verbatim: modelName)
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
                }
                .buttonStyle(.plain)
                .chromeGlassCapsule()
                .popover(isPresented: $showsModelPicker) {
                    NewThreadModelPicker(
                        selection: state.modelOverride,
                        selectedModelID: preview.model,
                        initialProvider: preview.provider
                    ) { selection in
                        state.modelOverride = selection
                        showsModelPicker = false
                    }
                    .frame(width: 360)
                    .presentedChrome()
                }
                Spacer()
                Button { controller.expand(model: model) } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(Chrome.iconFont)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .chromeGlassCircle()
                .help(Text("Open in Tivano"))
                .accessibilityLabel(Text("Open in Tivano"))

                Button { controller.send(model: model, openAfter: false) } label: {
                    Image(systemName: "arrow.up")
                        .font(Chrome.iconFont.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(Chrome.accent, in: .circle)
                }
                .buttonStyle(.plain)
                .disabled(isEmpty)
                .opacity(isEmpty ? 0.4 : 1)
                .accessibilityLabel(Text("Send"))
            }
        }
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
