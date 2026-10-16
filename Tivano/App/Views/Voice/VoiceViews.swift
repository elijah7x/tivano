import AppKit
import SwiftUI

// Voice agent mode's chrome: the sidebar trigger, the full-window stage and the orb above
// the call's composer. A call follows no chat selection, so neither surface lives inside
// the conversation column: the user moves between threads while the orchestrator listens.
//
// Ported from Zeron (https://github.com/zeronsh/zeron, MIT), `crates/ui/src/shell/voice_stage.rs`:
// adapted to Tivano's type scale and floating glass. See THIRD_PARTY_NOTICES.md.

enum VoiceStageMetrics {
    /// The stage paints the hero orb magnified to fill the canvas.
    static let orbScale: CGFloat = 2.25
    /// Stage orb footprint, including breathing room around the artwork.
    static let orbBox: CGFloat = 128 * orbScale + 112
    /// Captions show the tail of a long utterance rather than wrapping off-stage.
    static let captionCharacters = 160
    /// Call-bar geometry: round controls inside a floating pill.
    static let barControl: CGFloat = 44
    static let barPadding: CGFloat = 8
    /// Ease-out-expo in over 460 ms, a plain ease out over 220 ms.
    static let enter = Animation.timingCurve(0.16, 1, 0.3, 1, duration: 0.46)
    static let exit = Animation.timingCurve(0.25, 0.1, 0.25, 1, duration: 0.22)
}

// MARK: - Sidebar trigger

/// The sidebar's microphone: starts a call, or while one is live shows its orb and
/// raises or hides the stage. A failed start explains itself once, anchored to it.
struct VoiceSidebarTrigger: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let voice = model.voice!
        if voice.isOffered {
            let live = voice.isLive
            let failure = voice.failureText
            SidebarRow(
                title: live ? (voice.stageOpen ? "Hide voice" : "Voice is live") : "Start voice",
                action: { voice.start() }
            ) {
                SidebarIconBadge {
                    if live {
                        ThinkingOrb(state: voice.orbState, size: .inline, microphone: voice.microphone, speaker: voice.speaker, reducedMotion: reduceMotion, paused: !model.sidebar.isVisible || (WindowManager.shared.usesFullWindowSettings && SettingsNavigation.shared.isPresented))
                    } else {
                        SidebarSymbol("waveform")
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if failure != nil {
                        Circle().fill(Chrome.warning).frame(width: 5, height: 5).offset(x: -1, y: 1)
                    }
                }
            } accessory: { _ in EmptyView() }
            .help(Chrome.localized(live ? (voice.stageOpen ? "Hide voice · Esc" : "Voice is live · open") : (failure ?? "Start voice · Codex orchestrator")))
            .popover(isPresented: Binding(get: { failure != nil }, set: { if !$0 { voice.dismissReason() } }), arrowEdge: .top) {
                VoiceFailureCard(text: failure ?? "") { voice.dismissReason() }
            }
        }
    }
}

private struct VoiceFailureCard: View {
    let text: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.ui(size: 12, weight: .semibold))
                .foregroundStyle(Chrome.warning)
                .padding(.top, 1)
            Text(verbatim: Chrome.localized(text))
                .font(.ui(size: 12))
                .foregroundStyle(Chrome.secondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.ui(size: 10, weight: .semibold))
                    .foregroundStyle(Chrome.primaryText.opacity(0.45))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Dismiss"))
        }
        .padding(12)
        .frame(width: 232)
    }
}

// MARK: - Composer orb

/// The live orb above the call chat's composer. Every other chat keeps its plain
/// composer; pressing the orb returns to the stage.
struct VoiceComposerOrb: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.chatColumnIsShown) private var isColumnShown
    let threadID: UUID

    var body: some View {
        let voice = model.voice!
        if voice.isLive, voice.threadID == threadID {
            Button { voice.setStageOpen(true) } label: {
                ThinkingOrb(state: voice.orbState, size: .avatar, microphone: voice.microphone, speaker: voice.speaker, reducedMotion: reduceMotion, paused: !isColumnShown)
                    .padding(4)
                    .floatingGlass(Circle(), isInteractive: true)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Open voice"))
            .help("Open voice")
            .padding(.bottom, 4)
            .transition(.opacity)
        }
    }
}

// MARK: - Composer button

/// A Codex chat's live-voice button, a waveform rather than a dictation mic: starts a
/// call on this chat, keeping its history and session, and while that call is live
/// raises its stage. A call elsewhere disables it.
struct VoiceComposerButton: View {
    @Environment(AppModel.self) private var model
    let thread: ChatThread

    var body: some View {
        let voice = model.voice!
        if thread.provider == .codex, !thread.isHydraHead, voice.isOffered {
            let liveHere = voice.isLive && voice.threadID == thread.id
            let liveElsewhere = voice.isLive && !liveHere
            let help = liveHere ? "Open voice" : liveElsewhere ? "Voice is live in another chat" : "Start voice in this chat"
            Button {
                if liveHere { voice.setStageOpen(true) } else { voice.start(in: thread.id) }
            } label: {
                Image(systemName: "waveform")
                    .font(Chrome.iconFont)
            }
            .buttonStyle(.chip(active: liveHere))
            .focusable(false)
            .disabled(liveElsewhere)
            .help(Text(verbatim: Chrome.localized(help)))
            .accessibilityLabel(Text(verbatim: Chrome.localized(help)))
        }
    }
}

// MARK: - Stage

/// The full-window stage over the chat area: the call's orb, its live caption and the
/// call controls. Escape returns to the chats without ending the call; M mutes.
struct VoiceStage: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// How far the stage has arrived: 0 hidden, 1 fully covering the chat.
    let reveal: CGFloat
    @FocusState private var focused: Bool

    var body: some View {
        let voice = model.voice!
        ZStack {
            VStack(spacing: 0) {
                ThinkingOrb(
                    state: voice.orbState,
                    size: .hero,
                    scale: VoiceStageMetrics.orbScale,
                    microphone: voice.microphone,
                    speaker: voice.speaker,
                    reducedMotion: reduceMotion,
                    paused: !voice.stageOpen || (WindowManager.shared.usesFullWindowSettings && SettingsNavigation.shared.isPresented)
                )
                // The orb blooms out of the sidebar as the stage arrives.
                .scaleEffect(0.82 + 0.18 * reveal)
                .frame(width: VoiceStageMetrics.orbBox, height: VoiceStageMetrics.orbBox)
                Text(verbatim: Chrome.localized(voice.statusText))
                    .font(.ui(size: 12))
                    .foregroundStyle(Chrome.secondaryText)
                    .padding(.bottom, 8)
                    .accessibilityAddTraits(.updatesFrequently)
                VoiceCaptionView(item: voice.caption.item, text: voice.caption.text)
                    .padding(.top, 10)
            }
            .offset(y: 18 * (1 - reveal))
            .padding(.bottom, 64)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            VoiceCallBar()
                .frame(maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, 32 - 16 * (1 - reveal))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .detailSheet()
        // The stage covers the chat's titlebar: its top band still drags the window.
        .overlay(alignment: .top) { WindowDragArea().frame(height: 52) }
        .opacity(reveal)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = true }
        .onKeyPress(.escape) {
            guard voice.stageOpen, !(WindowManager.shared.usesFullWindowSettings && SettingsNavigation.shared.isPresented) else { return .ignored }
            voice.setStageOpen(false)
            return .handled
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "mM"), phases: .down) { press in
            guard voice.stageOpen, !(WindowManager.shared.usesFullWindowSettings && SettingsNavigation.shared.isPresented),
                  press.modifiers.isEmpty || press.modifiers == .shift else { return .ignored }
            voice.toggleMute()
            return .handled
        }
    }
}

/// The newest speaker turn, its tail when long. A new turn fades the previous one out.
private struct VoiceCaptionView: View {
    let item: String?
    let text: String

    var body: some View {
        let shown = text.count > VoiceStageMetrics.captionCharacters
            ? "…" + text.suffix(VoiceStageMetrics.captionCharacters).trimmingCharacters(in: .whitespacesAndNewlines)
            : text
        ZStack {
            Text(verbatim: shown)
                .id(item ?? "")
                .transition(.opacity.animation(.easeOut(duration: 0.3)))
                .contentTransition(.opacity)
                .animation(.easeOut(duration: 0.2), value: shown)
        }
        .font(.ui(size: 14))
        .lineSpacing(5)
        .multilineTextAlignment(.center)
        .lineLimit(2)
        .foregroundStyle(Chrome.secondaryText)
        .frame(maxWidth: 560)
        .frame(height: 48, alignment: .top)
        .padding(.horizontal, 24)
        .clipped()
    }
}

/// Video-call style bar: session time, the call controls grouped around a red hang-up,
/// and the way back to the chats.
private struct VoiceCallBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let voice = model.voice!
        let awaiting = voice.work == .awaitingInput
        let muted = voice.muted
        let liveTone: Color = awaiting ? Chrome.warning : (muted ? Chrome.primaryText.opacity(0.35) : Chrome.success)
        HStack(spacing: 6) {
            // Session clock, like a meeting's running time.
            HStack(spacing: 8) {
                Circle().fill(liveTone).frame(width: 7, height: 7)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(verbatim: voice.activeSince.map { VoiceCatalog.formatElapsed(max(0, Int(context.date.timeIntervalSince($0)))) } ?? "–:––")
                        .font(.ui(size: 13, design: .monospaced))
                        .foregroundStyle(Chrome.secondaryText)
                        .frame(minWidth: 40, alignment: .leading)
                }
                Text(verbatim: voice.hostName == "This Mac" ? Chrome.localized("This Mac") : voice.hostName)
                    .font(.ui(size: 12))
                    .foregroundStyle(Chrome.primaryText.opacity(0.45))
                    .lineLimit(1)
            }
            .padding(.leading, 10)
            .padding(.trailing, 6)

            divider

            // Microphone: inverted plate while muted.
            VoiceRoundControl(active: muted, help: muted ? "Unmute · M" : "Mute · M", action: voice.toggleMute) {
                Image(systemName: muted ? "mic.slash" : "mic")
            }
            .disabled(voice.phase != .active)

            if voice.threadID != nil {
                VoiceRoundControl(active: false, help: awaiting ? "Codex is asking you something" : "Transcript", action: voice.openTranscript) {
                    Image(systemName: "bubble.left")
                        .foregroundStyle(awaiting ? Chrome.warning : Chrome.primaryText)
                }
                .overlay(alignment: .topTrailing) {
                    if awaiting {
                        Circle()
                            .fill(Chrome.warning)
                            .frame(width: 8, height: 8)
                            .padding(9)
                    }
                }
            }

            // The hang-up: the one saturated control, wide enough to never be mistaken
            // for its neighbours.
            VoiceEndButton(action: voice.end)

            divider

            VoiceRoundControl(active: false, help: "Back to chats · Esc", action: { voice.setStageOpen(false) }) {
                Image(systemName: "chevron.down")
                    .foregroundStyle(Chrome.secondaryText)
            }
        }
        .padding(VoiceStageMetrics.barPadding)
        .floatingGlass(Capsule(style: .continuous))
    }

    private var divider: some View {
        Rectangle()
            .fill(Chrome.primaryText.opacity(0.12))
            .frame(width: 1, height: 24)
            .padding(.horizontal, 4)
    }
}

/// A round call-bar control; `active` inverts it onto the solid plate.
private struct VoiceRoundControl<Label: View>: View {
    let active: Bool
    let help: String
    let action: () -> Void
    @ViewBuilder var label: Label
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            label
                .font(.ui(size: 17, weight: .regular))
                .foregroundStyle(active ? Color(nsColor: .windowBackgroundColor) : Chrome.primaryText)
                .frame(width: VoiceStageMetrics.barControl, height: VoiceStageMetrics.barControl)
                .background(Circle().fill(active ? Chrome.primaryText : Chrome.primaryText.opacity(hovered ? 0.12 : 0.06)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(Chrome.hover, value: hovered)
        .accessibilityLabel(Text(verbatim: Chrome.localized(help)))
        .help(Chrome.localized(help))
    }
}

private struct VoiceEndButton: View {
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "phone.down.fill")
                    .font(.ui(size: 15, weight: .regular))
                Text("End")
                    .font(.ui(size: 13, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 20)
            .frame(height: VoiceStageMetrics.barControl)
            .background(Capsule(style: .continuous).fill(Chrome.danger))
            .overlay { Capsule(style: .continuous).fill(Color.black.opacity(hovered ? 0.14 : 0)) }
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(Chrome.hover, value: hovered)
        .help("End voice")
    }
}
