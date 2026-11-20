import AppKit
import SwiftUI

/// Sets the declarative hover cursor over `LinkTextView`—pointing hand over a link, I-beam over
/// selectable text glyphs, and the default arrow elsewhere (whitespace, gaps, or after hover
/// ends)—plus the head card over a mention. `LinkTextView` has no tracking areas (AppKit
/// rebuilds them every scrolled frame), so the cursor comes from here through `pointerStyle`,
/// never the global NSCursor stack.
struct LinkHoverModifier: ViewModifier {
    /// Weak, so a scrolled-away paragraph isn't kept alive.
    let linkView: WeakView
    @Binding var showsHand: Bool
    @Binding var hoveredHeadID: UUID?
    let personas: [HydraPersona]
    let targets: [String: HydraMentionTarget]

    @State private var overText = false

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
                switch phase {
                case .ended:
                    endHover()
                case .active(let point):
                    guard let view = linkView.value as? LinkTextView else {
                        endHover()
                        return
                    }
                    let overLink = view.hasLink(at: point)
                    if overLink != showsHand { showsHand = overLink }
                    // A head mention is clickable but keeps the arrow, like the rest of the controls.
                    let nextOverText = !overLink && view.isOverText(at: point) && view.headMention(at: point) == nil
                    if nextOverText != overText { overText = nextOverText }
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
                }
            }
            .onDisappear {
                endHover()
            }
            // Declarative, not NSCursor.push/pop: links get the pointing hand, rendered text glyphs
            // get the horizontal I-beam, and everything else (gaps, trailing whitespace, or ended
            // hover) gets `.default` explicitly so a stale I-beam cannot leak underneath.
            .pointerStyle(showsHand ? .link : (overText ? .horizontalText : .default))
    }

    private func endHover() {
        showsHand = false
        overText = false
        hoveredHeadID = nil
        HydraHeadHoverPopover.shared.hide()
    }
}
