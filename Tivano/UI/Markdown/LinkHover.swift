import AppKit
import SwiftUI

/// The pointing hand over a link and the head card over a mention. `LinkTextView` has no
/// tracking areas (AppKit rebuilds them every scrolled frame), so the cursor comes from here,
/// through `pointerStyle`, never the global NSCursor stack.
struct LinkHoverModifier: ViewModifier {
    /// Weak, so a scrolled-away paragraph isn't kept alive.
    let linkView: WeakView
    @Binding var showsHand: Bool
    @Binding var hoveredHeadID: UUID?
    let personas: [HydraPersona]
    let targets: [String: HydraMentionTarget]

    @MainActor private static var personaCache = RecentCache<[HydraPersona], [String: HydraPersona]>(limit: 32)

    @MainActor
    private static func persona(named name: String, in personas: [HydraPersona]) -> HydraPersona? {
        guard !personas.isEmpty else { return nil }
        if let hit = personaCache.value(for: personas) { return hit[name] }
        var map: [String: HydraPersona] = [:]
        map.reserveCapacity(personas.count)
        for persona in personas where map[persona.name] == nil {
            map[persona.name] = persona
        }
        personaCache.insert(map, for: personas)
        return map[name]
    }

    func body(content: Content) -> some View {
        content
            .onContinuousHover(coordinateSpace: .local) { phase in
                guard let view = linkView.value as? LinkTextView else { return }
                switch phase {
                case .active(let point):
                    let overLink = view.hasLink(at: point)
                    if overLink != showsHand { showsHand = overLink }
                    if !targets.isEmpty,
                       let (name, url, rect) = view.headMentionRect(at: point),
                       let target = targets[name], target.url == url,
                       let persona = Self.persona(named: name, in: personas) {
                        if hoveredHeadID != target.threadID {
                            hoveredHeadID = target.threadID
                            HydraHeadHoverPopover.shared.show(persona: persona, target: target, relativeTo: rect, of: view)
                        }
                    } else if hoveredHeadID != nil {
                        hoveredHeadID = nil
                        HydraHeadHoverPopover.shared.hide()
                    }
                case .ended:
                    endHover()
                }
            }
            .onDisappear {
                endHover()
            }
            // Declarative, not NSCursor.push/pop: a pop restores whatever was under the hand
            // (often the I-beam from adjacent selectable text) even after the pointer has left
            // for the sidebar or toolbar, which have no cursor rects to correct it.
            .pointerStyle(showsHand ? .link : nil)
    }

    private func endHover() {
        showsHand = false
        hoveredHeadID = nil
        HydraHeadHoverPopover.shared.hide()
    }
}
