import AppKit
import SwiftUI

/// A menu-opening string snapshot, separate from the weak responder used by Copy.
/// Reading the selection directly never borrows or changes the general pasteboard.
@MainActor
final class SelectionCopy {
    private weak var holder: NSView?
    private(set) var text: String?

    fileprivate func capture(in area: RightClickCatcherView, owner: UUID) {
        holder = nil
        text = nil
        guard let window = area.window,
              let view = window.firstResponder as? NSView,
              view.window === window,
              view.responds(to: #selector(NSText.copy(_:))) else { return }
        // A field editor/composer is not message text, even if temporarily over a row.
        guard (view as? NSTextView)?.isEditable != true else { return }

        if let native = view as? LinkTextView {
            // Native prose carries the enclosing menu's identity, not just its frame.
            guard native.selectionOwner == owner,
                  let storage = native.textStorage else { return }
            let range = native.selectedRange()
            guard range.location != NSNotFound, range.location >= 0, range.length > 0,
                  range.location <= storage.length,
                  range.length <= storage.length - range.location else { return }
            if native.selectedRanges.count == 1 {
                text = (storage.string as NSString).substring(with: range)
            }
            // Keep native multi-range Copy; only a single range is quoted directly.
        } else {
            // SwiftUI's selectable Text exposes NSAccessibility, not NSTextInputClient.
            // Require a static text element wholly owned by one message; a shared hosting
            // view or an editable field must never lend another message its selection.
            let frame = window.convertToScreen(view.convert(view.bounds, to: nil))
            guard view.accessibilityRole() == .staticText,
                  area.uniquelyContainsSelectionRect(frame) else { return }
            let range = view.accessibilitySelectedTextRange()
            guard range.location != NSNotFound, range.location >= 0, range.length > 0,
                  range.length <= Int.max - range.location,
                  view.accessibilitySelectedTextRanges() == [NSValue(range: range)],
                  let selected = view.accessibilitySelectedText(),
                  selected.utf16.count == range.length,
                  view.accessibilitySelectedTextRange() == range else { return }
            text = selected
        }
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
    @State private var owner = UUID()
    @State private var menuActions: [RowAction] = []

    func body(content: Content) -> some View {
        content
            .environment(\.markdownSelectionOwner, owner)
            .overlay {
                RightClickCatcher { [actions, owner, anchor = $anchor, menuActions = $menuActions] point, view in
                    let selection = SelectionCopy()
                    selection.capture(in: view, owner: owner)
                    // Freeze the full-message fallback and code actions too. A body update
                    // while the menu is open must not replace any of these values.
                    menuActions.wrappedValue = actions(selection)
                    anchor.wrappedValue = point
                }
            }
            .popover(
                isPresented: Binding(get: { anchor != nil }, set: {
                    if !$0 {
                        anchor = nil
                        menuActions = []
                    }
                }),
                attachmentAnchor: .rect(.rect(CGRect(origin: anchor ?? .zero, size: CGSize(width: 1, height: 1)))),
                arrowEdge: .top
            ) {
                PopoverMenu { RowActionItems(actions: menuActions) }
            }
    }
}

extension View {
    /// A right-click or control-click anywhere on the view opens a `PopoverMenu` of `actions` at the pointer.
    /// `actions` runs once at opening with the owned selection snapshot, never on a menu redraw.
    func rightClickPopover(actions: @escaping (SelectionCopy) -> [RowAction]) -> some View {
        modifier(RightClickPopoverModifier(actions: actions))
    }
}

private struct RightClickCatcher: NSViewRepresentable {
    var onRightClick: (CGPoint, RightClickCatcherView) -> Void

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
fileprivate final class RightClickCatcherView: NSView {
    private static let instances = NSHashTable<RightClickCatcherView>.weakObjects()
    var onRightClick: (CGPoint, RightClickCatcherView) -> Void

    init(onRightClick: @escaping (CGPoint, RightClickCatcherView) -> Void) {
        self.onRightClick = onRightClick
        super.init(frame: .zero)
        Self.instances.add(self)
    }

    /// Require the entire text element inside exactly one message, including its
    /// offscreen portion. Visible rects can extend beyond bounds on unclipped NSViews.
    func uniquelyContainsSelectionRect(_ rect: NSRect) -> Bool {
        guard let window, rect.minX.isFinite, rect.minY.isFinite,
              rect.maxX.isFinite, rect.maxY.isFinite, rect.width > 0, rect.height > 0 else { return false }
        let owners = Self.instances.allObjects.filter { area in
            guard area.window === window, !area.isHiddenOrHasHiddenAncestor else { return false }
            let frame = window.convertToScreen(area.convert(area.bounds, to: nil))
            return frame.contains(rect)
        }
        return owners.count == 1 && owners.first === self
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
