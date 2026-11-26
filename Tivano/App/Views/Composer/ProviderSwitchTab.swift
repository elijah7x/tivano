import SwiftUI

/// A provider switch the chat has staged but not sent, as a one-line tab behind the top of
/// the chat box, like the usage-limit tab: the next send hands off, Undo keeps the old session.
struct ProviderSwitchTab: View {
    @Environment(AppModel.self) private var model
    let threadID: UUID

    var body: some View {
        if let thread: ChatThread = model.thread(threadID),
           let origin: ProviderSwitchOrigin = thread.pendingProviderSwitch {
            let modelName: String = model.modelLabel(provider: origin.provider, model: origin.model)
            let back: String = String(format: Chrome.localized("Back to %@"), modelName)
            let bottomPadding: CGFloat = 6 + ThreadChangesTab.overlap
            row(back: back)
                .padding(.leading, 12)
                .padding(.trailing, 8)
                .padding(.top, 6)
                .padding(.bottom, bottomPadding)
                .modifier(ProviderSwitchTabSurface())
                .pointerStyle(.default)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func row(back: String) -> some View {
        let notice: String = Chrome.localized("Context may be incomplete after switching providers")
        let isRunning: Bool = model.existingRuntime(for: threadID)?.isRunning ?? false
        let labelFont: Font = Font.ui(.callout, weight: .medium).monospacedDigit()
        return HStack(spacing: 7) {
            Text(verbatim: notice)
                .foregroundStyle(Chrome.primaryText.opacity(0.9))
            undoButton(back: back, isDisabled: isRunning)
        }
        .font(labelFont)
        .lineLimit(1)
        .fixedSize()
        .accessibilityElement(children: .contain)
    }

    private func undoButton(back: String, isDisabled: Bool) -> some View {
        let title: String = Chrome.localized("Undo")
        return Button(title) { model.undoProviderSwitch(threadID) }
            .buttonStyle(.bordered)
            // Once sent, the new session is starting; undoing then would race it.
            .disabled(isDisabled)
            .help(Text(verbatim: back))
            .accessibilityLabel(Text(verbatim: back))
            .controlSize(.small)
            .focusable(false)
            .pointerStyle(.default)
            .padding(.leading, 4)
    }
}

private struct ProviderSwitchTabSurface: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.solidSurfaces) private var solid

    func body(content: Content) -> some View {
        let shape = UnevenRoundedRectangle(topLeadingRadius: 12, topTrailingRadius: 12, style: .continuous)
        content
            .background(shape.fill(Chrome.overlay(0.05)).background(shape.fill(solid?.elevated ?? Color(nsColor: .controlBackgroundColor))))
            .clipShape(shape)
            .overlay { shape.strokeBorder(solid?.hairline ?? Chrome.floatingGlassRim(isDark: colorScheme == .dark), lineWidth: 1) }
    }
}
