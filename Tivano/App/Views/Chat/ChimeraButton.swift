import SwiftUI

struct ChimeraButton: View {
    @Environment(AppModel.self) private var model
    let thread: ChatThread
    let runtime: ThreadRuntime
    @State private var isHovering = false
    @State private var isSending = false

    var body: some View {
        if model.chimeraAvailable(thread) {
            let isOn = model.chimeraIsOn(thread)
            let canSwitch = model.canSwitchChimeraMode(thread.id)
            let heads = model.panelHeads(of: thread.id)
            let running = heads.count { $0.hydra?.status == .running }
            let isDelegating = isOn && running == 0 && runtime.isRunning && HydraButton.isLeadDelegating(runtime.entries)
            // While heads are at work the mode cannot switch, so the mark opens their panel;
            // otherwise it stays the switch, so Chimera can always be turned off from here.
            let opensPanel = isOn && !canSwitch && !heads.isEmpty
            Button {
                if opensPanel {
                    HydraButton.togglePanel(model: model, runtime: runtime)
                } else {
                    model.setChimera(!isOn, for: thread.id)
                }
            } label: {
                ZStack {
                    if isOn {
                        // Hydra's own charge: the two modes never light at once.
                        HydraCharge(isWorking: running > 0)
                            .transition(.scale(scale: 0.6).combined(with: .opacity))
                    }
                    ChimeraMarkImage()
                        .foregroundStyle(Chrome.primaryText.opacity(isOn || isHovering ? 1 : 0.6))
                        .frame(width: 20, height: 20)
                }
                .frame(width: Chrome.capsuleHeight, height: Chrome.capsuleHeight)
                .contentShape(Circle())
                // Keep the badge in the glass's own content so it draws above the glass.
                .overlay(alignment: .topTrailing) {
                    if isOn && (running > 0 || isSending || isDelegating) {
                        HydraSendWorkingBadge(running: running, isSending: isSending || isDelegating, isChimera: true)
                            .offset(x: 3, y: -3)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .animation(.spring(response: 0.3, dampingFraction: 0.7), value: running)
                .animation(Chrome.panelSlide, value: isSending)
                .animation(Chrome.panelSlide, value: isDelegating)
                .animation(Chrome.panelSlide, value: isOn)
                .onChange(of: running) { old, new in
                    guard new > old else { return }
                    isSending = true
                }
                .task(id: isSending) {
                    guard isSending else { return }
                    try? await Task.sleep(for: .seconds(0.9))
                    guard !Task.isCancelled else { return }
                    isSending = false
                }
            }
            .buttonStyle(.plain)
            .chromeGlassCircle()
            .disabled(!canSwitch && !opensPanel)
            .onHover { hovering in
                withAnimation(Chrome.hover) { isHovering = hovering }
            }
            .help(Text(verbatim: opensPanel
                ? (running == 0
                    ? Chrome.localized("Chimera is on, show the panel")
                    : running == 1
                        ? Chrome.localized("Chimera is on, 1 head working, show or hide the panel")
                        : String(format: Chrome.localized("Chimera is on, %d heads working, show or hide the panel"), running))
                : !canSwitch
                ? Chrome.localized("Switch when no heads are at work.")
                : isOn
                    ? Chrome.localized("Turn off Chimera and go back to Hydra.")
                    : Chrome.localized("Turn on Chimera: you pick a model for each helper. Hydra turns off.")))
            .accessibilityLabel(Text("Chimera"))
            .accessibilityValue(Text(verbatim: isOn ? Chrome.localized("On") : Chrome.localized("Off")))
        }
    }
}
