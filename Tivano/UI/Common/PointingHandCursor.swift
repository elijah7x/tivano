import AppKit
import SwiftUI

extension View {
    /// The pointing hand while hovered. Pops on disappear so the cursor never sticks.
    func pointingHandCursor() -> some View {
        modifier(PointingHandCursorModifier())
    }
}

private struct PointingHandCursorModifier: ViewModifier {
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .onContinuousHover { phase in
                switch phase {
                case .active:
                    if !hovering { NSCursor.pointingHand.push(); hovering = true }
                case .ended:
                    if hovering { NSCursor.pop(); hovering = false }
                }
            }
            .onDisappear {
                if hovering { NSCursor.pop(); hovering = false }
            }
    }
}
