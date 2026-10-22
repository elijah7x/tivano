import SwiftUI

/// The first chat's Hydra intro, opened by the mark itself until it has been read.
/// Says what Hydra is, how a chat leads heads, what pairs are, and how to switch
/// Hydra off for a chat.
struct HydraIntroPopover: View {
    @Environment(AppModel.self) private var model
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
                    Text("Meet Hydra")
                        .font(.ui(.title2, weight: .semibold))
                    Text("Hydra is on. Big jobs go out to a team of heads, so this chat leads instead of doing everything itself.")
                        .font(.ui(.body))
                        .foregroundStyle(Chrome.secondaryText)
                }
            }
            VStack(alignment: .leading, spacing: 12) {
                hydraIntroStep(
                    glyph: AnyView(HydraMarkImage().foregroundStyle(Chrome.primaryText).frame(width: 18, height: 18)),
                    title: "You ask, the chat leads",
                    line: "Ask as you always do. Small things it does itself; anything bigger it splits into briefs."
                )
                hydraIntroStep(
                    glyph: AnyView(HStack(spacing: -8) {
                        HydraGlyph(persona: HydraRoster.persona(at: 0), size: 24)
                        HydraGlyph(persona: HydraRoster.persona(at: 1), size: 24)
                    }),
                    title: "Heads go out in parallel",
                    line: "Each head gets one brief and a panel of its own beside the chat. Hank, Walter, Ada and the rest work at the same time."
                )
                hydraIntroStep(
                    glyph: AnyView(Image(systemName: "checkmark.circle").font(.ui(size: 20)).foregroundStyle(Chrome.success)),
                    title: "Reports come back, the lead finishes",
                    line: "The lead checks their work, fixes what needs fixing and answers you. Their changes land as one merge."
                )
            }
            Divider().opacity(0.5)
            VStack(alignment: .leading, spacing: 2) {
                Text("Pairs")
                    .font(.ui(.body, weight: .semibold))
                Text("A pair says which model leads and which model, or which provider, runs the heads: Opus leading Sonnet, or Claude leading Gemini heads. Without one, the heads run on this chat's model at a working effort. Pairs live in the model picker and in Settings › Hydra.")
                    .font(.ui(.callout))
                    .foregroundStyle(Chrome.secondaryText)
            }
            HStack(alignment: .center, spacing: 6) {
                Image(systemName: "cursorarrow.click.2")
                Text("Right-click the mark to switch Hydra off or on per chat.")
                    .lineLimit(1)
            }
            .font(.ui(.callout))
            .foregroundStyle(Chrome.secondaryText)
            HStack(spacing: 8) {
                Spacer()
                Button("Set up in Settings") {
                    dismiss()
                    WindowManager.shared.showSettings(page: .hydra)
                }
                .buttonStyle(.glass)
                Button("Got it") { dismiss() }
                    .buttonStyle(.glassProminent)
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
        case .hydra: "Hydra"
        case .heads: "Heads"
        case .history: "Codex head history"
        }
    }

    private var subtitle: String {
        switch topic {
        case .hydra: "One chat leads a team of heads on big jobs."
        case .heads: "The helpers a chat sends out, one brief each."
        case .history: "Archive completed heads and keep the option to continue."
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
                        line: "Ask as you always do. Small things it does itself; anything bigger it splits into briefs."
                    )
                    hydraIntroStep(
                        glyph: AnyView(HStack(spacing: -8) {
                            HydraGlyph(persona: HydraRoster.persona(at: 0), size: 24)
                            HydraGlyph(persona: HydraRoster.persona(at: 1), size: 24)
                        }),
                        title: "Heads go out in parallel",
                        line: "Each head gets one brief and a panel of its own beside the chat, all working at the same time. Heads use the selected models to do their tasks, then return their reports to the lead chat."
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
                        line: "A head gets a self-contained brief and its own panel beside the chat, on the model its pair names or the chat's own."
                    )
                    hydraIntroStep(
                        glyph: AnyView(Image(systemName: "square.on.square").font(.ui(size: 18)).foregroundStyle(Chrome.primaryText)),
                        title: "Its own copy of the checkout",
                        line: "With the switch on, each head works in a copy of the project so heads never trip over each other; its changes land in the chat's checkout when it reports."
                    )
                    hydraIntroStep(
                        glyph: AnyView(Image(systemName: "arrow.uturn.backward.circle").font(.ui(size: 20)).foregroundStyle(Chrome.success)),
                        title: "Reports back to the lead",
                        line: "A finished head hands its report to the lead, which checks the work and answers you. Completed heads collapse automatically; their reports stay in completion cards in the chat."
                    )
                case .history:
                    hydraIntroStep(
                        glyph: AnyView(Image(systemName: "checkmark.circle").font(.ui(size: 20)).foregroundStyle(Chrome.success)),
                        title: "Only newly dispatched heads",
                        line: "Only newly dispatched Codex heads managed by Tivano can be archived after successful completion. Lead chats, older sessions, heads with user follow-ups or descendant sessions, and heads not confirmed idle stay visible."
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
                Text("Right-click the Hydra mark in a chat to switch it off or on for that chat.")
                    .font(.ui(.callout))
                    .foregroundStyle(Chrome.secondaryText)
            }
        }
        .padding(18)
    }
}
