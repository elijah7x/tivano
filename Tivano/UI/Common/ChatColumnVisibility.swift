import SwiftUI

/// Whether a chat column is the one on screen. Each hosted column owns one for its whole
/// life and `ThreadColumns` flips `isShown` as the column hides and shows. It reaches the
/// column's views as one stable environment object, so a flip re-evaluates only the views
/// that read `isShown`: flipping an environment value instead invalidated the whole column,
/// about 150 ms on every switch to a column built ahead of the click.
/// Not actor-isolated so it can be the environment's default; only the main thread writes it.
@Observable
final class ChatColumnVisibility {
    var isShown: Bool

    init(isShown: Bool) {
        self.isShown = isShown
    }

    /// Outside a hosted column (a panel, the quick chat): always shown. Never written.
    nonisolated(unsafe) static let alwaysShown = ChatColumnVisibility(isShown: true)
}

extension EnvironmentValues {
    @Entry var chatColumnVisibility: ChatColumnVisibility = .alwaysShown
}
