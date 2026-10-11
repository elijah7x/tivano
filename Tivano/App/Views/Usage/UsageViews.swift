import SwiftUI

/// A provider's plan usage limits as the registry last read them: a header naming the plan,
/// a row per rolling window, and a spinner or a note while they load or when none came back.
/// The composer's usage popover and Settings, Providers both show limits through this view,
/// so the two can never disagree. Refreshing is the caller's call: this only renders.
struct PlanLimitsView: View {
    @Environment(AppModel.self) private var model
    let provider: ProviderKind

    var body: some View {
        let registry = model.providers
        let limits = registry.planLimits[provider]
        let isLoading = registry.loadingLimits.contains(provider)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(verbatim: limits?.planName.map { String(format: Chrome.localized("Plan usage limits · %@"), $0) } ?? Chrome.localized("Plan usage limits"))
                    .font(.ui(.body))
                    .foregroundStyle(Chrome.secondaryText)
                Spacer(minLength: 8)
                if isLoading {
                    ProgressView().controlSize(.mini)
                }
            }
            if let limits {
                ForEach(limits.windows) { window in
                    LimitRow(window: window)
                        .padding(.top, 14)
                }
                // The rule sits between the windows and the banked resets, so only where
                // both are there: a plan with no resets to bank used to end on a line to nothing.
                if let credits = limits.resetCredits {
                    if !limits.windows.isEmpty {
                        Divider()
                            .padding(.top, 14)
                    }
                    BankedResetsView(provider: provider, credits: credits)
                        .padding(.top, 14)
                }
                // A read that filled no windows carries the provider's own words instead of
                // silence: an expired login must never look like an unchanged number. The note
                // sits at the foot of the block, small and quiet, with the one tap that fixes
                // it beside it.
                if let problem = limits.problem {
                    if provider.isAPIKeyBased {
                        HStack(alignment: .center, spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.ui(.footnote, weight: .semibold))
                                .foregroundStyle(Chrome.warning)
                            Text(verbatim: Chrome.localized(problem))
                                .font(.ui(.subheadline))
                                .foregroundStyle(Chrome.secondaryText)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 8)
                        }
                        .padding(.top, 14)
                    } else {
                        HStack(spacing: 8) {
                            Text("Click here to login again")
                                .font(.ui(.callout))
                                .foregroundStyle(Chrome.secondaryText)
                            Spacer(minLength: 8)
                            Button("Login") { Workspace.openTerminal(running: provider.loginCommand) }
                                .buttonStyle(.glass)
                                .controlSize(.small)
                        }
                        .padding(.top, 14)
                    }
                }
            } else if !isLoading {
                Text(verbatim: String(format: Chrome.localized("%@ did not report plan limits."), provider.displayName))
                    .font(.ui(.callout))
                    .foregroundStyle(Chrome.secondaryText)
                    .padding(.top, 8)
            }
        }
        .animation(Chrome.panelSlide, value: limits)
    }
}

/// A pay-as-you-go balance: what is left of the credit the API key is billed against, as one
/// settings row. The title and its note on the left, the amount and the dashboard's top-up
/// page on the right; a balance that is gone reads in the danger colour and says so in the
/// note. Shared by the usage popover and Settings, Providers.
struct CreditsView: View {
    @Environment(AppModel.self) private var model
    let provider: ProviderKind

    var body: some View {
        let registry = model.providers
        let credits = registry.credits[provider]
        let isLoading = registry.loadingCredits.contains(provider)
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Remaining credits")
                    .font(.ui(.body))
                    .foregroundStyle(Chrome.primaryText)
                if let note = note(for: credits, isLoading: isLoading) {
                    Text(verbatim: Chrome.localized(note))
                        .font(.ui(.subheadline))
                        .foregroundStyle(Chrome.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            HStack(spacing: 10) {
                if isLoading {
                    ProgressView().controlSize(.mini)
                }
                if let credits {
                    Text(verbatim: credits.amountText)
                        .font(.ui(.body, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(credits.isDepleted ? Chrome.danger : Chrome.primaryText)
                        .lineLimit(1)
                }
                if let topUpURL = CreditsReader.topUpURL(provider) {
                    Link("Top up", destination: topUpURL)
                        .buttonStyle(.glass)
                        .controlSize(.small)
                }
            }
        }
        .animation(.easeOut(duration: 0.15), value: credits)
    }

    /// The line under the title: the top-up and grant split while there is credit, the
    /// consequence once there is none, and what happened when nothing came back.
    private func note(for credits: ProviderCredits?, isLoading: Bool) -> String? {
        guard let credits else {
            return isLoading ? nil : String(format: Chrome.localized("%@ did not report a balance."), provider.displayName)
        }
        if credits.isDepleted {
            return String(format: Chrome.localized("%@ declines turns until the balance is topped up."), provider.displayName)
        }
        return credits.breakdownText
    }
}

private struct LimitRow: View {
    let window: PlanLimits.Window

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Text(verbatim: Chrome.localized(window.title))
                    .font(.ui(.body))
                    .foregroundStyle(Chrome.primaryText)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let resetsAt = window.resetsAt {
                    Text(verbatim: String(format: Chrome.localized("Resets %@"), Self.resetText(resetsAt)))
                        .font(.ui(.callout))
                        .foregroundStyle(Chrome.secondaryText)
                        .lineLimit(1)
                }
                Text(verbatim: "\(Int(window.percent.rounded()))%")
                    .font(.ui(.callout))
                    .foregroundStyle(Chrome.secondaryText)
                    .monospacedDigit()
            }
            if let detail = window.detail {
                Text(verbatim: Chrome.localized(detail))
                    .font(.ui(.subheadline))
                    .foregroundStyle(Chrome.secondaryText)
                    .lineLimit(1)
            }
            UsageBar(fraction: window.percent / 100, tint: Self.tint(for: window.percent), label: Chrome.localized(window.title))
        }
    }

    private static func tint(for percent: Double) -> Color {
        if percent >= 90 { return Chrome.danger }
        if percent >= 75 { return Chrome.warning }
        return Chrome.accent
    }

    /// "in 3 hr 34 min" within a day, a weekday and time within a week, and a date beyond that.
    static func resetText(_ date: Date, now: Date = .now) -> String {
        let seconds = max(0, date.timeIntervalSince(now))
        if seconds < 86_400 {
            let hours = Int(seconds) / 3_600
            let minutes = Int(seconds) % 3_600 / 60
            return hours > 0 ? String(format: Chrome.localized("in %lld hr %lld min"), hours, minutes) : String(format: Chrome.localized("in %lld min"), max(1, minutes))
        }
        if seconds < 6 * 86_400 {
            return date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
        }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }
}

/// One banked reset, moved out of the view so both views can name it.
fileprivate struct BankedResetRowModel: Identifiable {
    var id: String
    var credit: PlanLimits.ResetCredit?
}

/// A provider's banked resets (Codex's reset credits, Z.ai's reset cards): a one-line header
/// with how many the account holds, then a row per reset with a button to spend it. Spending
/// goes through the registry so the bars refresh in the same pass; a line under the header
/// carries the outcome for a few seconds before it reads the count again.
private struct BankedResetsView: View {
    @Environment(AppModel.self) private var model
    let provider: ProviderKind
    let credits: PlanLimits.ResetCredits

    fileprivate enum Phase: Equatable {
        case idle
        case confirming(String)
        case applying(String)
        case done(PlanLimits.ResetOutcome)
        case failed(String)
    }

    @State private var phase: Phase = .idle
    @State private var settle: Task<Void, Never>?

    private var rows: [BankedResetRowModel] {
        let listed = credits.credits.map { BankedResetRowModel(id: $0.id, credit: $0) }
        let unlisted = (0..<max(0, credits.availableCount - listed.count)).map { BankedResetRowModel(id: "unlisted-\($0)", credit: nil) }
        return listed + unlisted
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text("Banked resets")
                    .font(.ui(.body))
                    .foregroundStyle(Chrome.primaryText)
                Text(verbatim: "· \(countText)")
                    .font(.ui(.callout))
                    .foregroundStyle(Chrome.secondaryText)
                    .contentTransition(.numericText())
            }
            // One line to a screen reader too, "Banked resets, 2 available".
            .accessibilityElement(children: .combine)
            statusLine
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                BankedResetRow(
                    row: row,
                    index: index,
                    several: rows.count > 1,
                    phase: phase,
                    onConfirm: { phase = .confirming(row.id) },
                    onCancel: { phase = .idle },
                    onUse: { spend(row) }
                )
                .padding(.top, 12)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(Chrome.panelSlide, value: phase)
        .animation(Chrome.panelSlide, value: credits)
        .onDisappear { settle?.cancel() }
    }

    /// The outcome once a reset was spent, the error when it failed; nothing while idle.
    @ViewBuilder private var statusLine: some View {
        switch phase {
        case .done(let outcome):
            HStack(spacing: 5) {
                Image(systemName: outcome == .reset ? "checkmark.circle.fill" : "info.circle")
                    .font(.ui(.subheadline, weight: .semibold))
                    .foregroundStyle(outcome == .reset ? Chrome.success : Chrome.secondaryText)
                    .symbolEffect(.bounce, value: phase)
                Text(verbatim: Chrome.localized(outcome.message))
                    .font(.ui(.subheadline))
                    .foregroundStyle(outcome == .reset ? Chrome.success : Chrome.secondaryText)
            }
            .padding(.top, 4)
            .transition(.blurReplace)
        case .failed(let message):
            Text(verbatim: Chrome.localized(message))
                .font(.ui(.subheadline))
                .foregroundStyle(Chrome.danger)
                .padding(.top, 4)
                .transition(.blurReplace)
        default:
            EmptyView()
        }
    }

    private var countText: String {
        switch credits.availableCount {
        case 0: Chrome.localized("None available yet")
        case 1: Chrome.localized("1 available")
        default: String(format: Chrome.localized("%lld available"), credits.availableCount)
        }
    }

    private func spend(_ row: BankedResetRowModel) {
        phase = .applying(row.id)
        settle?.cancel()
        settle = Task {
            do {
                let outcome = try await model.providers.consumeResetCredit(provider, row.credit?.id)
                phase = .done(outcome)
            } catch {
                phase = .failed(error.localizedDescription)
            }
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            phase = .idle
        }
    }
}

/// One banked reset: its title and expiry on the left; on the right the button that spends it,
/// which turns into a Cancel / Reset now pair before anything is sent, and into a spinner while
/// the app-server works.
private struct BankedResetRow: View {
    let row: BankedResetRowModel
    let index: Int
    let several: Bool
    let phase: BankedResetsView.Phase
    let onConfirm: () -> Void
    let onCancel: () -> Void
    let onUse: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: row.credit?.title.map { Chrome.localized($0) } ?? (several ? String(format: Chrome.localized("Reset %lld"), index + 1) : Chrome.localized("Reset")))
                    .font(.ui(.body))
                    .foregroundStyle(Chrome.primaryText)
                    .lineLimit(1)
                Text(verbatim: row.credit?.detail.map { Chrome.localized($0) } ?? expiryText)
                    .font(.ui(.subheadline))
                    .foregroundStyle(Chrome.secondaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            control
        }
    }

    private var expiryText: String {
        guard let expiresAt = row.credit?.expiresAt else { return Chrome.localized("No expiry reported") }
        if expiresAt <= .now { return Chrome.localized("Expired") }
        return String(format: Chrome.localized("Expires %@"), LimitRow.resetText(expiresAt))
    }

    @ViewBuilder private var control: some View {
        switch phase {
        case .confirming(let id) where id == row.id:
            HStack(spacing: 6) {
                Button("Cancel", action: onCancel).buttonStyle(.glass).controlSize(.small)
                Button("Reset now", action: onUse).buttonStyle(.glassProminent).controlSize(.small).tint(Chrome.accent)
            }
            .transition(.blurReplace)
        case .applying(let id) where id == row.id:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Resetting…")
                    .font(.ui(.callout))
                    .foregroundStyle(Chrome.secondaryText)
            }
            .transition(.blurReplace)
        default:
            Button("Use reset", action: onConfirm).buttonStyle(.glass).controlSize(.small)
                .disabled(isApplying)
                .transition(.blurReplace)
        }
    }

    private var isApplying: Bool {
        if case .applying = phase { true } else { false }
    }
}

/// A thin capsule filled to a fraction, the bar under every limit and the context window.
struct UsageBar: View {
    let fraction: Double
    let tint: Color
    /// What the bar measures, for VoiceOver. The percentage on its own said nothing about
    /// which window or balance it belonged to.
    var label = "Used"

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(Chrome.overlay(0.1))
                Capsule(style: .continuous)
                    .fill(tint)
                    .frame(width: max(fraction > 0 ? 5 : 0, proxy.size.width * min(max(fraction, 0), 1)))
            }
        }
        .frame(height: 5)
        .accessibilityElement()
        .accessibilityLabel(Text(verbatim: Chrome.localized(label)))
        .accessibilityValue(Text(verbatim: String(format: Chrome.localized("%lld%% used"), Int((max(fraction, 0) * 100).rounded()))))
    }
}
