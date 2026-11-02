import SwiftUI

/// A provider switch the chat has staged but not sent, as a one-line tab behind the top of
/// the chat box, like the usage-limit tab: the next send hands off, Undo keeps the old session.
struct ProviderSwitchTab: View {
    @Environment(AppModel.self) private var model
    let threadID: UUID

    var body: some View {
        if let thread = model.thread(threadID), let origin = thread.pendingProviderSwitch {
            let back = String(format: Chrome.localized("Back to %@"), model.modelLabel(provider: origin.provider, model: origin.model))
            row(back: back)
            .padding(.leading, 12)
            .padding(.trailing, 8)
            .padding(.top, 6)
            .padding(.bottom, 6 + ThreadChangesTab.overlap)
            .modifier(ProviderSwitchTabSurface())
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func row(back: String) -> some View {
        HStack(spacing: 7) {
            Text(verbatim: Chrome.localized("Switching providers may lose some context"))
                .foregroundStyle(Chrome.primaryText.opacity(0.9))
            Button(Chrome.localized("Undo")) { model.undoProviderSwitch(threadID) }
                .buttonStyle(.bordered)
                // Once sent, the new session is starting; undoing then would race it.
                .disabled(model.existingRuntime(for: threadID)?.isRunning ?? false)
                .help(Text(verbatim: back))
                .accessibilityLabel(Text(verbatim: back))
                .controlSize(.small)
                .focusable(false)
                .padding(.leading, 4)
        }
        .font(.ui(.callout, weight: .medium).monospacedDigit())
        .lineLimit(1)
        .fixedSize()
        .accessibilityElement(children: .contain)
    }
}

private struct ProviderSwitchTabSurface: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let shape = UnevenRoundedRectangle(topLeadingRadius: 12, topTrailingRadius: 12, style: .continuous)
        content
            .background(shape.fill(Chrome.overlay(0.05)).background(shape.fill(Color(nsColor: .controlBackgroundColor))))
            .clipShape(shape)
            .overlay { shape.strokeBorder(Chrome.floatingGlassRim(isDark: colorScheme == .dark), lineWidth: 1) }
    }
}
