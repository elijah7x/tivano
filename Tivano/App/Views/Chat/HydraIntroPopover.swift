import SwiftUI

/// The first chat's Hydra intro, opened by the mark itself until it has been read.
/// Says what Hydra is, how a chat leads heads, what pairs are, and how to switch
/// Hydra off for a chat.
struct HydraIntroPopover: View {
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 12) {
                HStack(spacing: -6) {
                    ForEach(0..<5, id: \.self) { i in
                        HydraGlyph(persona: HydraRoster.persona(at: i), size: 30)
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Meet sub-agents")
                        .font(.ui(.title2, weight: .semibold))
                    Text(verbatim: Chrome.localized("Sub-agents are on. This chat leads the work, delegating independent pieces to parallel sub-agents instead of doing everything itself."))
                        .font(.ui(.body))
                        .foregroundStyle(Chrome.secondaryText)
                }
            }
            VStack(alignment: .leading, spacing: 12) {
                hydraIntroStep(
                    glyph: AnyView(HydraMarkImage().foregroundStyle(Chrome.primaryText).frame(width: 18, height: 18)),
                    title: "You ask, the chat leads",
                    line: "Ask as you always do. The lead keeps tightly coupled work and decides which independent pieces to brief to sub-agents."
                )
                hydraIntroStep(
                    glyph: AnyView(HStack(spacing: -8) {
                        HydraGlyph(persona: HydraRoster.persona(at: 0), size: 24)
                        HydraGlyph(persona: HydraRoster.persona(at: 1), size: 24)
                    }),
                    title: "Sub-agents go out in parallel",
                    line: "Each sub-agent gets one brief and a panel of its own beside the chat. Hank, Walter, Ada and the rest work at the same time."
                )
                hydraIntroStep(
                    glyph: AnyView(Image(systemName: "checkmark.circle").font(.ui(size: 20)).foregroundStyle(Chrome.success)),
                    title: "Reports come back, the lead finishes",
                    line: "The lead checks their work, fixes what needs fixing and answers you. Their changes land as one merge."
                )
            }
            Divider().opacity(0.5)
            VStack(alignment: .leading, spacing: 2) {
                Text("Combos")
                    .font(.ui(.body, weight: .semibold))
                Text("A combo says which model leads and which model, or which provider, runs the sub-agents: Opus leading Sonnet, or Claude leading Gemini sub-agents. Without one, the sub-agents run on this chat's model at a working effort. Combos live in the model picker and in Settings › Sub-agent control.")
                    .font(.ui(.callout))
                    .foregroundStyle(Chrome.secondaryText)
            }
            HStack(alignment: .center, spacing: 6) {
                Image(systemName: "slider.horizontal.3")
                Text("Open the model picker in a chat to switch sub-agents off or on per chat.")
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.ui(.callout))
            .foregroundStyle(Chrome.secondaryText)
            HStack(spacing: 8) {
                Spacer()
                Button("Set up in Settings") {
                    dismiss()
                    WindowManager.shared.showSettings(page: .hydra)
                }
                .chromeGlassButtonStyle()
                Button("Got it") { dismiss() }
                    .chromeGlassButtonStyle(prominent: true)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

@MainActor private func hydraIntroStep(glyph: AnyView, title: String, line: String) -> some View {
    HStack(alignment: .top, spacing: 12) {
        glyph.frame(width: 30, height: 30)
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: Chrome.localized(title))
                .font(.ui(.body, weight: .semibold))
            Text(verbatim: Chrome.localized(line))
                .font(.ui(.callout))
                .foregroundStyle(Chrome.secondaryText)
        }
    }
}

struct HydraInfoPopover: View {
    enum Topic { case hydra, heads, history }
    let topic: Topic

    private var title: String {
        switch topic {
        case .hydra: "Sub-agents"
        case .heads: "Sub-agents"
        case .history: "Codex sub-agent history"
        }
    }

    private var subtitle: String {
        switch topic {
        case .hydra: "One chat leads a team of sub-agents, keeping judgement and delegating independent work."
        case .heads: "The helpers a chat sends out, one brief each."
        case .history: "Archive completed sub-agents and keep the option to continue."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                HStack(spacing: -6) {
                    ForEach(0..<5, id: \.self) { i in
                        HydraGlyph(persona: HydraRoster.persona(at: i), size: 24)
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: Chrome.localized(title))
                        .font(.ui(.title3, weight: .semibold))
                    Text(verbatim: Chrome.localized(subtitle))
                        .font(.ui(.callout))
                        .foregroundStyle(Chrome.secondaryText)
                }
            }
            VStack(alignment: .leading, spacing: 12) {
                switch topic {
                case .hydra:
                    hydraIntroStep(
                        glyph: AnyView(HydraMarkImage().foregroundStyle(Chrome.primaryText).frame(width: 18, height: 18)),
                        title: "You ask, the chat leads",
                        line: "Ask as you always do. The lead keeps tightly coupled work and decides which independent pieces to brief to sub-agents."
                    )
                    hydraIntroStep(
                        glyph: AnyView(HStack(spacing: -8) {
                            HydraGlyph(persona: HydraRoster.persona(at: 0), size: 24)
                            HydraGlyph(persona: HydraRoster.persona(at: 1), size: 24)
                        }),
                        title: "Sub-agents go out in parallel",
                        line: "Each sub-agent gets one brief and a panel of its own beside the chat, all working at the same time. Sub-agents use the selected models to do their tasks, then return their reports to the lead chat."
                    )
                    hydraIntroStep(
                        glyph: AnyView(Image(systemName: "checkmark.circle").font(.ui(size: 20)).foregroundStyle(Chrome.success)),
                        title: "Reports come back, the lead finishes",
                        line: "The lead checks their work, fixes what needs fixing and answers you. Their changes land as one merge."
                    )
                case .heads:
                    hydraIntroStep(
                        glyph: AnyView(HydraGlyph(persona: HydraRoster.persona(at: 0), size: 24)),
                        title: "One brief, one panel",
                        line: "A sub-agent gets a self-contained brief and its own panel beside the chat, on the model its combo names or the chat's own."
                    )
                    hydraIntroStep(
                        glyph: AnyView(Image(systemName: "square.on.square").font(.ui(size: 18)).foregroundStyle(Chrome.primaryText)),
                        title: "Its own copy of the checkout",
                        line: "With the switch on, each sub-agent works in a copy of the project so sub-agents never trip over each other; its changes land in the chat's checkout when it reports."
                    )
                    hydraIntroStep(
                        glyph: AnyView(Image(systemName: "arrow.uturn.backward.circle").font(.ui(size: 20)).foregroundStyle(Chrome.success)),
                        title: "Reports back to the lead",
                        line: "A finished sub-agent hands its report to the lead, which checks the work and answers you. Completed sub-agents collapse automatically; their reports stay in completion cards in the chat."
                    )
                case .history:
                    hydraIntroStep(
                        glyph: AnyView(Image(systemName: "checkmark.circle").font(.ui(size: 20)).foregroundStyle(Chrome.success)),
                        title: "Only newly dispatched sub-agents",
                        line: "Only newly dispatched Codex sub-agents managed by Tivano can be archived after successful completion. Lead chats, older sessions, sub-agents with user follow-ups or descendant sessions, and sub-agents not confirmed idle stay visible."
                    )
                    hydraIntroStep(
                        glyph: AnyView(Image(systemName: "arrow.uturn.backward.circle").font(.ui(size: 20)).foregroundStyle(Chrome.success)),
                        title: "Continue when needed",
                        line: "Archived sessions keep their IDs and can be resumed. Archiving does not affect Tivano's sidebar or history on provider websites."
                    )
                    hydraIntroStep(
                        glyph: AnyView(Image(systemName: "archivebox").font(.ui(size: 18)).foregroundStyle(Chrome.primaryText)),
                        title: "Codex only, no permanent deletion",
                        line: "Other providers do not currently offer this archive option. Permanent deletion is unavailable to avoid also deleting child sessions."
                    )
                }
            }
            if topic == .hydra {
                Divider().opacity(0.5)
                Text("Open the model picker in a chat to switch sub-agents off or on for that chat.")
                    .font(.ui(.callout))
                    .foregroundStyle(Chrome.secondaryText)
            }
        }
        .padding(18)
    }
}
