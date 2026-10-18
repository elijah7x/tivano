import AppKit
import SwiftUI

/// The text the reader had selected when the menu opened, copied the way Command-C would,
/// from whichever text view held it: the prose's own or SwiftUI's. The right-click is the
/// moment to look, since the popover takes the key window after it. The view is held
/// weakly, so a menu left open pins no row.
@MainActor
final class SelectionCopy {
    private weak var holder: NSView?

    /// Remembers the window's first responder when it can copy and sits inside `area`: a
    /// selection in another row, or in the chat box, is not this menu's to copy.
    fileprivate func capture(in area: NSView) {
        holder = nil
        guard let view = area.window?.firstResponder as? NSView,
              view.responds(to: #selector(NSText.copy(_:))),
              view.convert(view.bounds, to: nil).intersects(area.convert(area.bounds, to: nil)) else { return }
        if let text = view as? NSTextView, text.selectedRange().length == 0 { return }
        holder = view
    }

    /// Whether the selection reached the clipboard. False leaves nothing for the caller to
    /// undo: a view with no selection copies nothing, and an empty copy does not count.
    func copy() -> Bool {
        guard let holder else { return false }
        let pasteboard = NSPasteboard.general
        let before = pasteboard.changeCount
        guard NSApp.sendAction(#selector(NSText.copy(_:)), to: holder, from: nil),
              pasteboard.changeCount != before else { return false }
        return pasteboard.string(forType: .string)?.isEmpty == false
    }
}

private struct RightClickPopoverModifier: ViewModifier {
    let actions: (SelectionCopy) -> [RowAction]
    @State private var anchor: CGPoint?
    @State private var selection = SelectionCopy()

    func body(content: Content) -> some View {
        content
            .overlay {
                RightClickCatcher { [selection] point, view in
                    selection.capture(in: view)
                    anchor = point
                }
            }
            .popover(
                isPresented: Binding(get: { anchor != nil }, set: { if !$0 { anchor = nil } }),
                attachmentAnchor: .rect(.rect(CGRect(origin: anchor ?? .zero, size: CGSize(width: 1, height: 1)))),
                arrowEdge: .top
            ) {
                PopoverMenu { RowActionItems(actions: actions(selection)) }
            }
    }
}

extension View {
    /// A right-click or control-click anywhere on the view opens a `PopoverMenu` of `actions` at the pointer.
    /// `actions` gets the selection the reader had when the menu opened, for a Copy that honours it.
    func rightClickPopover(actions: @escaping (SelectionCopy) -> [RowAction]) -> some View {
        modifier(RightClickPopoverModifier(actions: actions))
    }
}

private struct RightClickCatcher: NSViewRepresentable {
    var onRightClick: (CGPoint, NSView) -> Void

    func makeNSView(context: Context) -> RightClickCatcherView {
        RightClickCatcherView(onRightClick: onRightClick)
    }

    func updateNSView(_ nsView: RightClickCatcherView, context: Context) {
        nsView.onRightClick = onRightClick
    }
}

/// A transparent overlay that only claims secondary clicks. It returns nil from
/// hit-testing for every other event, so text selection, links, buttons and
/// drags in the SwiftUI content underneath behave exactly as if it were absent.
private final class RightClickCatcherView: NSView {
    var onRightClick: (CGPoint, NSView) -> Void

    init(onRightClick: @escaping (CGPoint, NSView) -> Void) {
        self.onRightClick = onRightClick
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    override var mouseDownCanMoveWindow: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let event = NSApp.currentEvent else { return nil }
        let isSecondary = event.type == .rightMouseDown
            || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
        guard isSecondary, bounds.contains(convert(point, from: superview)) else { return nil }
        return self
    }

    override func rightMouseDown(with event: NSEvent) {
        onRightClick(convert(event.locationInWindow, from: nil), self)
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            onRightClick(convert(event.locationInWindow, from: nil), self)
        } else {
            super.mouseDown(with: event)
        }
    }

    override func rightMouseUp(with event: NSEvent) {}
}
