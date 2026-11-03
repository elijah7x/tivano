import SwiftUI

/// The settings page's scroll travel and titlebar inset, read when a sticky row's selection changes.
@MainActor @Observable
final class SettingsScrollOffset {
    var travel: CGFloat = 0
    var topInset: CGFloat = 0
    /// An offset the page should scroll to, taken and cleared by the page's scroll view
    /// along with the selection change to make in the same update.
    var scrollRequest: ScrollRequest?

    struct ScrollRequest: Equatable {
        let id = UUID()
        let y: CGFloat
        let then: () -> Void

        static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    }

    /// Runs a sidebar selection with the row's top back under the titlebar. The page scrolls
    /// together with the selection change: a column that gets shorter while the page is past
    /// its end leaves a lazy page scrolled beyond its content, blank until scrolled back by hand.
    func select(rowMinY: CGFloat, _ change: @escaping () -> Void) {
        let top = max(0, rowMinY - topInset)
        guard travel > top else { return change() }
        scrollRequest = ScrollRequest(y: top, then: change)
    }
}

private struct SettingsStickyContextKey: EnvironmentKey {
    static let defaultValue: SettingsScrollOffset? = nil
}

extension EnvironmentValues {
    var settingsStickyContext: SettingsScrollOffset? {
        get { self[SettingsStickyContextKey.self] }
        set { self[SettingsStickyContextKey.self] = newValue }
    }
}

enum SettingsStickyCoordinates {
    static let space = "settingsScrollContent"
}

struct StickySidebarRow<Sidebar: View, Detail: View>: View {
    let alignment: VerticalAlignment
    let spacing: CGFloat
    var sidebarWidth: CGFloat = 200
    /// Builds the sidebar with a wrapper for its selection changes, which returns the page
    /// to the row's top first.
    @ViewBuilder let sidebar: (_ select: @escaping (@escaping () -> Void) -> Void) -> Sidebar
    @ViewBuilder let detail: () -> Detail

    @Environment(\.settingsStickyContext) private var context
    @State private var rowFrame: CGRect = .zero
    @State private var sidebarHeight: CGFloat = 0

    var body: some View {
        HStack(alignment: alignment, spacing: spacing) {
            sidebar { change in
                if let context { context.select(rowMinY: rowFrame.minY, change) } else { change() }
            }
                .frame(width: sidebarWidth)
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { height in
                    sidebarHeight = height
                }
                .modifier(StickySidebarOffset(topInset: context?.topInset,
                                             maxShift: max(0, rowFrame.height - sidebarHeight)))
            detail()
        }
        .onGeometryChange(for: CGRect.self, of: {
            $0.frame(in: .named(SettingsStickyCoordinates.space))
        }) { frame in
            rowFrame = frame
        }
    }
}

/// Reads the column's place in the scroll view while rendering, so the shift always matches the
/// frame being drawn. Scroll travel and the row's position arrive in separate updates, and on a
/// lazy page that re-estimates rows above while scrolling fast they disagree for a frame.
private struct StickySidebarOffset: ViewModifier {
    let topInset: CGFloat?
    let maxShift: CGFloat

    func body(content: Content) -> some View {
        if let topInset {
            content.visualEffect { content, proxy in
                content.offset(y: min(max(0, topInset - proxy.frame(in: .scrollView).minY), maxShift))
            }
        } else {
            content
        }
    }
}
