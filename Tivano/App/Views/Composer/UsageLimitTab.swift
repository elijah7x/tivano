import SwiftUI

/// The chat's usage-limit offer as a tab tucked behind the top of the chat box: the limit
/// is spent, and the user decides here whether the chat continues once it resets (see
/// `AutoContinue`).
struct UsageLimitTab: View {
    @Environment(AppModel.self) private var model
    let threadID: UUID
    let offer: AutoContinue.Offer

    var body: some View {
        // Half a minute is fine enough for a countdown in minutes, and moves the tab from
        // "resets at" to "has reset" on its own when nobody chose.
        TimelineView(.periodic(from: .now, by: 30)) { context in
            ViewThatFits(in: .horizontal) {
                row(at: context.date, showsDetail: true)
                row(at: context.date, showsDetail: false)
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .padding(.top, 6)
        .padding(.bottom, 6 + ThreadChangesTab.overlap)
        .modifier(UsageLimitTabSurface())
        .fixedSize(horizontal: false, vertical: true)
    }

    private enum Phase {
        case offered(Date)
        case waiting(Date)
        case reset
        case unknown
    }

    private func phase(at now: Date) -> Phase {
        guard let resetsAt = offer.resetsAt else { return .unknown }
        let resumeAt = resetsAt.addingTimeInterval(AutoContinue.margin)
        if offer.isWaiting { return .waiting(resumeAt) }
        return now >= resumeAt ? .reset : .offered(resetsAt)
    }

    private func row(at now: Date, showsDetail: Bool) -> some View {
        let provider = offer.provider.displayName
        let phase = phase(at: now)
        return HStack(spacing: 7) {
            switch phase {
            case .offered(let resetsAt):
                symbol("hourglass", tint: Chrome.warning)
                title(String(format: Chrome.localized("%@ usage limit reached"), provider))
                if showsDetail { detail(String(format: Chrome.localized("Resets %@"), AutoContinue.format(resetsAt))) }
                actions {
                    Button(Chrome.localized("Continue after reset")) { model.autoContinue.wait(threadID) }
                        .buttonStyle(.borderedProminent)
                        .help(Text(verbatim: Chrome.localized("Wait for the usage limit to reset, then continue")))
                    dismissButton
                }
            case .waiting(let resumeAt):
                symbol("clock", tint: Chrome.secondaryText)
                title(String(format: Chrome.localized("Continues at %@"), AutoContinue.format(resumeAt)))
                if showsDetail { detail(String(format: Chrome.localized("%@ left"), Self.remaining(until: resumeAt, from: now))) }
                actions {
                    Button(Chrome.localized("Don't wait")) { model.autoContinue.stopWaiting(threadID) }
                        .buttonStyle(.bordered)
                        .help(Text(verbatim: Chrome.localized("Stop waiting for the usage limit")))
                }
            case .reset:
                symbol("checkmark.circle", tint: Chrome.secondaryText)
                title(String(format: Chrome.localized("%@ usage limit has reset"), provider))
                actions {
                    Button(Chrome.localized("Continue")) { model.autoContinue.continueNow(threadID) }
                        .buttonStyle(.borderedProminent)
                    dismissButton
                }
            case .unknown:
                symbol("hourglass", tint: Chrome.warning)
                title(String(format: Chrome.localized("%@ usage limit reached"), provider))
                if showsDetail { detail(Chrome.localized("No reset time given")) }
                actions { dismissButton }
            }
        }
        .font(.ui(.callout, weight: .medium).monospacedDigit())
        .lineLimit(1)
        .fixedSize()
        .accessibilityElement(children: .contain)
    }

    private func symbol(_ name: String, tint: Color) -> some View {
        Image(systemName: name)
            .font(Chrome.inlineIconFont)
            .foregroundStyle(tint)
            .accessibilityHidden(true)
    }

    private func title(_ text: String) -> some View {
        Text(verbatim: text).foregroundStyle(Chrome.primaryText.opacity(0.9))
    }

    private func detail(_ text: String) -> some View {
        Text(verbatim: text).foregroundStyle(Chrome.secondaryText)
    }

    private func actions(@ViewBuilder _ content: () -> some View) -> some View {
        HStack(spacing: 6) { content() }
            .controlSize(.small)
            .focusable(false)
            .padding(.leading, 4)
    }

    private var dismissButton: some View {
        Button {
            model.autoContinue.dismiss(threadID)
        } label: {
            Image(systemName: "xmark")
                .font(Chrome.inlineIconFont)
                .foregroundStyle(Chrome.secondaryText)
                .frame(width: 22, height: 22)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(Text(verbatim: Chrome.localized("Dismiss")))
        .accessibilityLabel(Text(verbatim: Chrome.localized("Dismiss")))
    }

    /// Whole minutes, rounded up, so the countdown never reads zero while it still waits.
    private static func remaining(until date: Date, from now: Date) -> String {
        let minutes = max(1, Int((date.timeIntervalSince(now) / 60).rounded(.up)))
        return Duration.seconds(minutes * 60)
            .formatted(.units(allowed: [.hours, .minutes], width: .narrow, maximumUnitCount: 2))
    }
}

/// A solid card with its own outline, rather than the changes tab's glass: the composer's
/// glass container melts touching glass into one outline, and this tab should read as a
/// separate layer the box sits on, like a bookmark.
private struct UsageLimitTabSurface: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let shape = UnevenRoundedRectangle(topLeadingRadius: 12, topTrailingRadius: 12, style: .continuous)
        content
            // A shade darker than the box, so the box's top edge reads across it.
            .background(shape.fill(Chrome.overlay(0.05)).background(shape.fill(Color(nsColor: .controlBackgroundColor))))
            .clipShape(shape)
            .overlay { shape.strokeBorder(Chrome.floatingGlassRim(isDark: colorScheme == .dark), lineWidth: 1) }
    }
}
