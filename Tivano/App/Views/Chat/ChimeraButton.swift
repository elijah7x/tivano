import SwiftUI

struct ChimeraButton: View {
    @Environment(AppModel.self) private var model
    let thread: ChatThread
    let runtime: ThreadRuntime
    @State private var isHovering = false

    var body: some View {
        if model.chimeraAvailable(thread) {
            let isOn = model.chimeraIsOn(thread)
            let canSwitch = model.canSwitchChimeraMode(thread.id)
            let running = model.panelHeads(of: thread.id).count { $0.hydra?.status == .running }
            Button {
                model.setChimera(!isOn, for: thread.id)
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
                .animation(Chrome.panelSlide, value: isOn)
            }
            .buttonStyle(.plain)
            .chromeGlassCircle()
            .disabled(!canSwitch)
            .onHover { hovering in
                withAnimation(Chrome.hover) { isHovering = hovering }
            }
            .help(Text(verbatim: !canSwitch
                ? Chrome.localized("Switch when no heads are at work.")
                : isOn
                    ? Chrome.localized("Turn off Chimera and go back to Hydra.")
                    : Chrome.localized("Turn on Chimera: you pick a model for each helper. Hydra turns off.")))
            .accessibilityLabel(Text("Chimera"))
            .accessibilityValue(Text(verbatim: isOn ? Chrome.localized("On") : Chrome.localized("Off")))
        }
    }
}
