import AppKit
import SwiftUI

/// How an `anchoredPopover` sizes its panel while open.
enum AnchoredPopoverSizing {
    /// Measured once before opening and held at that size while shown.
    case fixed
    /// Starts at the measured size and updates `contentSize` when the content's own size changes.
    case tracksContent
}

/// Injects the host window's SwiftUI environment (app model, live-resize state, theme) into
/// an AppKit-hosted popover's separate view tree. Kept in a reference box so the window root
/// hands down one stable identity across renders.
final class PopoverHostEnvironment {
    let apply: @MainActor (AnyView) -> AnyView

    init(_ apply: @escaping @MainActor (AnyView) -> AnyView) {
        self.apply = apply
    }
}

extension EnvironmentValues {
    @Entry var popoverHostEnvironment: PopoverHostEnvironment? = nil
}

extension View {
    /// Presents `content` in an AppKit `NSPopover` anchored once to a real backing view
    /// for this view's bounds. SwiftUI's `.popover` re-anchors an open popover from
    /// cached geometry, which in a long-running window was seen to drift every popover
    /// ~30pt sideways moments after opening; anchoring once in AppKit does not.
    ///
    /// `anchor` maps the backing view's flipped bounds (top-left origin, same size as
    /// the modified view) to the rect the arrow points at; `nil` uses the whole bounds.
    func anchoredPopover<Content: View>(
        isPresented: Binding<Bool>,
        arrowEdge: Edge = .bottom,
        sizing: AnchoredPopoverSizing = .fixed,
        anchor: ((CGRect) -> CGRect)? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        modifier(AnchoredPopoverModifier(
            isPresented: isPresented,
            arrowEdge: arrowEdge,
            sizing: sizing,
            anchor: anchor,
            popoverContent: content
        ))
    }
}

private struct AnchoredPopoverModifier<PopoverContent: View>: ViewModifier {
    @Binding var isPresented: Bool
    let arrowEdge: Edge
    let sizing: AnchoredPopoverSizing
    let anchor: ((CGRect) -> CGRect)?
    @ViewBuilder let popoverContent: () -> PopoverContent

    @State private var coordinator = AnchoredPopoverCoordinator()
    /// The backing view exists only while the popover is asked for or still closing: a row
    /// list mounts one of these per row, and an idle row should not carry an AppKit view.
    @State private var isAnchorMounted = false
    @Environment(\.popoverHostEnvironment) private var popoverHostEnvironment
    @Environment(\.chatColumnVisibility) private var chatColumnVisibility

    func body(content: Content) -> some View {
        content
            .background {
                if isAnchorMounted {
                    AnchorRepresentable(coordinator: coordinator, makeRoot: makeRootContent)
                        .allowsHitTesting(false)
                        .focusable(false)
                        .accessibilityHidden(true)
                }
            }
            .onChange(of: isPresented, initial: true) { _, shown in
                bindCallbacks()
                if shown {
                    // A click on the button while its popover was open closed the popover
                    // first (it is transient) and now asks for it again: leave it closed.
                    if coordinator.isReopenFromClosingClick() {
                        isPresented = false
                        return
                    }
                    isAnchorMounted = true
                    present()
                } else {
                    coordinator.close()
                }
            }
            .onDisappear {
                coordinator.close()
            }
    }

    private func bindCallbacks() {
        coordinator.onDismiss = { isPresented = false }
        coordinator.onDidClose = { if !isPresented { isAnchorMounted = false } }
    }

    private func makeRootContent() -> AnyView {
        let base = AnyView(
            popoverContent()
                .presentedChrome()
                .environment(\.closePopoverBox, coordinator.closeBox)
                .environment(\.chatColumnVisibility, chatColumnVisibility)
        )
        if let popoverHostEnvironment {
            return popoverHostEnvironment.apply(base)
        }
        return base
    }

    private func present() {
        coordinator.scheduleShow {
            guard isPresented else { return }
            coordinator.show(
                root: makeRootContent(),
                sizing: sizing,
                arrowEdge: arrowEdge,
                anchor: anchor
            )
        }
    }
}

private final class AnchoredPopoverAnchorView: NSView {
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override var canBecomeKeyView: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        focusRingType = .none
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

private struct AnchorRepresentable: NSViewRepresentable {
    let coordinator: AnchoredPopoverCoordinator
    let makeRoot: @MainActor () -> AnyView

    func makeNSView(context: Context) -> AnchoredPopoverAnchorView {
        let view = AnchoredPopoverAnchorView(frame: .zero)
        coordinator.anchorView = view
        return view
    }

    func updateNSView(_ nsView: AnchoredPopoverAnchorView, context: Context) {
        coordinator.anchorView = nsView
        if coordinator.isShown {
            coordinator.update(makeRoot())
        }
    }
}

@MainActor
private final class AnchoredPopoverCoordinator: NSObject, NSPopoverDelegate {
    private let popover = NSPopover()
    private let host = NSHostingController(rootView: AnyView(EmptyView()))
    private var activeSizing: AnchoredPopoverSizing = .fixed
    private var fixedSize: NSSize?
    private var appearanceObservation: NSKeyValueObservation?
    /// The press on this popover's own button that closed it, kept until the button's
    /// click either asks to reopen (and is swallowed) or something else happens.
    private var closingPress: (window: NSWindow, timestamp: TimeInterval)?
    private var fixedScrolls = false
    private var needsDismiss = false
    private var pendingShow: (() -> Void)?

    weak var anchorView: NSView?
    var onDismiss: (() -> Void)?
    var onDidClose: (() -> Void)?
    /// Where the shown popover hangs, in its window, for the reopen guard.
    private var lastAnchorRect: NSRect?
    private weak var lastWindow: NSWindow?

    /// One box for the coordinator's life so updates to an open popover do not
    /// invalidate rows reading `closePopoverBox`.
    private(set) lazy var closeBox = PopoverCloseBox { [weak self] in self?.close() }

    var isShown: Bool { popover.isShown }
    var hasWindow: Bool { anchorView?.window != nil }

    override init() {
        super.init()
        host.sizingOptions = []
        popover.contentViewController = host
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
    }

    /// Whether the event asking to open is the same click whose press on the button just
    /// closed this popover. Only a press recorded as the closing event counts, so a popover
    /// closed some other way reopens on the next click however soon it comes.
    func isReopenFromClosingClick() -> Bool {
        guard let press = closingPress else { return false }
        closingPress = nil
        guard let event = NSApp.currentEvent,
              event.type == .leftMouseDown || event.type == .leftMouseUp,
              event.window === press.window,
              event.timestamp >= press.timestamp,
              event.timestamp - press.timestamp < 1,
              let lastAnchorRect else { return false }
        return lastAnchorRect.contains(event.locationInWindow)
    }

    /// Runs `action` once the backing view is in a window. It is mounted in the same update
    /// that asks for the popover, so it usually joins its window a main-queue turn later.
    func scheduleShow(_ action: @escaping @MainActor () -> Void, attempts: Int = 6) {
        pendingShow = action
        if hasWindow {
            pendingShow = nil
            action()
            return
        }
        guard attempts > 0 else {
            pendingShow = nil
            onDismiss?()
            onDidClose?()
            return
        }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.pendingShow != nil else { return }
            self.scheduleShow(action, attempts: attempts - 1)
        }
    }

    func show(
        root: AnyView,
        sizing: AnchoredPopoverSizing,
        arrowEdge: Edge,
        anchor: ((CGRect) -> CGRect)?
    ) {
        guard !popover.isShown else { return }
        guard let view = anchorView, let window = view.window else {
            onDismiss?()
            return
        }

        popover.appearance = window.effectiveAppearance
        appearanceObservation = window.observe(\.effectiveAppearance, options: [.new]) { [weak self] window, _ in
            MainActor.assumeIsolated {
                self?.popover.appearance = window.effectiveAppearance
            }
        }

        var measured = NSHostingView(rootView: root).fittingSize
        if measured.width <= 0 || measured.height <= 0 {
            measured = NSSize(width: 300, height: 200)
        }
        let size = clampedSize(for: measured, in: window)

        closingPress = nil
        fixedScrolls = sizing == .fixed && measured.height > size.height
        activeSizing = sizing
        fixedSize = sizing == .fixed ? size : nil
        host.rootView = wrapped(root, sizing: sizing, fixedSize: fixedSize)
        popover.contentSize = size

        let positioningRect = anchor?(view.bounds) ?? view.bounds
        lastAnchorRect = view.convert(view.bounds, to: nil)
        lastWindow = window
        popover.show(relativeTo: positioningRect, of: view, preferredEdge: Self.rectEdge(for: arrowEdge))
        needsDismiss = true
    }

    func update(_ root: AnyView) {
        guard popover.isShown else { return }
        host.rootView = wrapped(root, sizing: activeSizing, fixedSize: fixedSize)
    }

    func close() {
        pendingShow = nil
        if popover.isShown {
            popover.performClose(nil)
        }
    }

    func popoverWillClose(_ notification: Notification) {
        // A transient popover closes from inside the press that dismissed it, so the
        // current event is that press while this runs.
        if let event = NSApp.currentEvent, event.type == .leftMouseDown,
           let lastWindow, event.window === lastWindow,
           let lastAnchorRect, lastAnchorRect.contains(event.locationInWindow) {
            closingPress = (lastWindow, event.timestamp)
        } else {
            closingPress = nil
        }
    }

    func popoverDidClose(_ notification: Notification) {
        appearanceObservation = nil
        if !popover.isShown {
            host.rootView = AnyView(EmptyView())
        }
        if needsDismiss {
            needsDismiss = false
            onDismiss?()
        }
        onDidClose?()
    }

    private func wrapped(_ root: AnyView, sizing: AnchoredPopoverSizing, fixedSize: NSSize?) -> AnyView {
        switch sizing {
        case .fixed:
            let size = fixedSize ?? popover.contentSize
            // Content taller than the cap scrolls instead of losing its lower rows.
            if fixedScrolls {
                return AnyView(
                    ScrollView { root }
                        .scrollBounceBehavior(.basedOnSize)
                        .frame(width: size.width, height: size.height, alignment: .top)
                )
            }
            return AnyView(
                root
                    .frame(width: size.width, height: size.height, alignment: .top)
                    .clipped()
            )
        case .tracksContent:
            return AnyView(
                root
                    .fixedSize()
                    .onGeometryChange(for: CGSize.self, of: { $0.size }) { [weak self] size in
                        self?.contentSizeChanged(size)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            )
        }
    }

    private func contentSizeChanged(_ newSize: CGSize) {
        guard popover.isShown, activeSizing == .tracksContent,
              newSize.width > 0, newSize.height > 0 else { return }
        let target = clampedSize(for: newSize, in: anchorView?.window)
        let current = popover.contentSize
        guard abs(target.width - current.width) > 0.5 || abs(target.height - current.height) > 0.5 else { return }
        popover.contentSize = target
    }

    private func clampedSize(for raw: CGSize, in window: NSWindow?) -> NSSize {
        let width = raw.width.rounded(.up)
        var height = raw.height.rounded(.up)
        if let visibleHeight = (window?.screen ?? NSScreen.main)?.visibleFrame.height, visibleHeight > 0 {
            height = min(height, (visibleHeight * 0.8).rounded(.down))
        }
        return NSSize(width: width, height: height)
    }

    private static func rectEdge(for edge: Edge) -> NSRectEdge {
        switch edge {
        case .top: .minY
        case .bottom: .maxY
        case .leading: .minX
        case .trailing: .maxX
        }
    }
}
