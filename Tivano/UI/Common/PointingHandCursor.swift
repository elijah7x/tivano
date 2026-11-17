import SwiftUI

extension View {
    /// The pointing hand while hovered. Uses `pointerStyle` rather than NSCursor.push/pop,
    /// whose pop can restore a stale cursor (such as the I-beam) after the pointer has left.
    func pointingHandCursor() -> some View {
        pointerStyle(.link)
    }
}
