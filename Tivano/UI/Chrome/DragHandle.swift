import AppKit
import SwiftUI

/// The AppKit strip behind every drag handle. Not a SwiftUI gesture: only a cursor rect shows
/// the cursor before the press, and the first click must work when the window isn't key.
final class DragHandleView: NSView {
    /// Which way the handle reports the pointer's travel.
    enum Axis {
        /// Drags on x, with a vertical grip bar (the sidebar's edge).
        case horizontal
        /// Drags on y, with a horizontal grip bar (the terminal drawer's edge).
        case vertical
        /// Reports both axes, y running down like a panel's offset, and draws no grip.
        case free
    }

    /// A resize handle's centred bar, which grows on hover.
    struct Grip {
        var restLength: CGFloat
        var shownLength: CGFloat
        var thickness: CGFloat
        var alpha: Float = 0.6
        /// When set, a wider glow layer starts at this inset and lights on hover.
        var glowInset: CGFloat? = nil
        /// The sidebar re-reads the cursor's place on every layout, because its edge moves
        /// out from under a resting cursor; the terminal only snaps on entry and exit.
        var refreshesHoverOnLayout = false
        var hoverGlow: Float = 0.05
        var dragGlow: Float = 0.10
    }

    var onBegin: (() -> Void)?
    /// Travel since the press, in the axis's own terms.
    var onChange: ((CGSize) -> Void)?
    var onEnd: (() -> Void)?
    var onDoubleClick: (() -> Void)?
    /// A press released within the slop, so it never became a drag: the handle doubles as
    /// a button. Only with a slop, since without one every press starts a drag.
    var onClick: (() -> Void)?
    var axis: Axis = .horizontal
    var grip: Grip?
    var cursor: NSCursor = .arrow {
        didSet {
            guard cursor !== oldValue else { return }
            window?.invalidateCursorRects(for: self)
        }
    }
    /// Pushed while the pointer is held; nil leaves the cursor rect's cursor in place.
    var dragCursor: NSCursor?
    /// How far the pointer must travel before a press becomes a drag.
    var slop: CGFloat = 0
    var isActive = true {
        didSet {
            guard isActive != oldValue else { return }
            window?.invalidateCursorRects(for: self)
            refreshHover()
            updateGrip(animated: false)
        }
    }

    private enum Metrics {
        static let glowRadius: CGFloat = 4
        static let duration: CFTimeInterval = 0.18
    }

    private var pressOrigin: NSPoint = .zero
    private var trackingArea: NSTrackingArea?
    private var hasConfigured = false
    private var isHovering = false
    private var isDragging = false
    private let gripLayer = CALayer()
    private let glowLayer = CALayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureLayers()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureLayers()
    }

    private func configureLayers() {
        wantsLayer = true
        gripLayer.opacity = 0
        glowLayer.cornerRadius = Metrics.glowRadius
        glowLayer.opacity = 0
        applyColors()
        layer?.addSublayer(glowLayer)
        layer?.addSublayer(gripLayer)
    }

    private func applyColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let color = NSColor.labelColor.cgColor
            gripLayer.backgroundColor = color
            glowLayer.backgroundColor = color
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    /// Sets the grip and adds or drops its tracking area when the presence of one changes.
    func configure(grip: Grip?) {
        let hadGrip = self.grip != nil
        self.grip = grip
        if hadGrip != (grip != nil) { updateTrackingAreas() }
        // A re-render must not snap a hover animation the mouse started.
        if !hasConfigured || hadGrip != (grip != nil) {
            hasConfigured = true
            updateGrip(animated: false)
        }
    }

    override func layout() {
        super.layout()
        if grip?.refreshesHoverOnLayout == true {
            let hovered = isHovering
            refreshHover()
            updateGrip(animated: hovered != isHovering)
        } else {
            updateGrip(animated: false)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Taken out mid-drag, the panel lets go of the cursor with it.
        if window == nil, isDragging {
            isDragging = false
            if dragCursor != nil { NSCursor.pop() }
        }
        if grip != nil {
            refreshHover()
            updateGrip(animated: false)
        }
    }

    private var showsGrip: Bool { isActive && (isHovering || isDragging) }

    /// Reads the cursor's actual place, so `isHovering` never outlives the cursor being over
    /// the strip; the entered/exited pair only keeps it true while the mouse itself moves.
    private func refreshHover() {
        guard isActive, let window, !isHiddenOrHasHiddenAncestor else {
            isHovering = false
            return
        }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        isHovering = bounds.contains(point)
    }

    fileprivate func updateGrip(animated: Bool) {
        guard let grip else {
            gripLayer.opacity = 0
            glowLayer.opacity = 0
            return
        }
        let length = showsGrip ? grip.shownLength : grip.restLength
        CATransaction.begin()
        if animated {
            CATransaction.setAnimationDuration(Metrics.duration)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        } else {
            CATransaction.setDisableActions(true)
        }
        gripLayer.cornerRadius = grip.thickness / 2
        if axis == .horizontal {
            gripLayer.frame = CGRect(x: (bounds.width - grip.thickness) / 2, y: (bounds.height - length) / 2, width: grip.thickness, height: length)
        } else {
            gripLayer.frame = CGRect(x: (bounds.width - length) / 2, y: (bounds.height - grip.thickness) / 2, width: length, height: grip.thickness)
        }
        gripLayer.opacity = showsGrip ? grip.alpha : 0
        if let inset = grip.glowInset {
            glowLayer.frame = CGRect(x: bounds.minX + 0.5, y: inset, width: max(0, bounds.width - 1), height: max(0, bounds.height - inset))
            glowLayer.opacity = showsGrip ? (isDragging ? grip.dragGlow : grip.hoverGlow) : 0
        } else {
            glowLayer.opacity = 0
        }
        CATransaction.commit()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The drag owns the press, so the window never moves with it.
    override var mouseDownCanMoveWindow: Bool { false }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard isActive else { return }
        addCursorRect(bounds, cursor: cursor)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        isActive ? super.hitTest(point) : nil
    }

    override func mouseDown(with event: NSEvent) {
        pressOrigin = event.locationInWindow
        if event.clickCount == 2 { onDoubleClick?() }
        guard slop == 0 else {
            isDragging = false
            return
        }
        isDragging = true
        updateGrip(animated: true)
        onBegin?()
    }

    override func mouseDragged(with event: NSEvent) {
        let travel = travel(to: event)
        if !isDragging {
            guard abs(travel.width) >= slop || abs(travel.height) >= slop else { return }
            isDragging = true
            dragCursor?.push()
            updateGrip(animated: true)
            onBegin?()
        }
        onChange?(travel)
    }

    override func mouseUp(with event: NSEvent) {
        guard isDragging else {
            if slop > 0, event.clickCount == 1 { onClick?() }
            return
        }
        let travel = travel(to: event)
        isDragging = false
        if dragCursor != nil { NSCursor.pop() }
        onChange?(travel)
        onEnd?()
        // No exit arrives while the button is held; the release decides from the cursor.
        refreshHover()
        updateGrip(animated: true)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        guard grip != nil else {
            if let trackingArea { removeTrackingArea(trackingArea) }
            trackingArea = nil
            return
        }
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = isActive
        updateGrip(animated: true)
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        updateGrip(animated: true)
    }

    /// The pointer's travel since the press. AppKit's y runs up; a free handle reports the
    /// panel's offset, which runs down.
    private func travel(to event: NSEvent) -> CGSize {
        let point = event.locationInWindow
        return switch axis {
        case .horizontal: CGSize(width: point.x - pressOrigin.x, height: 0)
        case .vertical: CGSize(width: 0, height: point.y - pressOrigin.y)
        case .free: CGSize(width: point.x - pressOrigin.x, height: pressOrigin.y - point.y)
        }
    }
}

/// The SwiftUI face of `DragHandleView`: one configuration for every call site.
struct DragHandle: NSViewRepresentable {
    var axis: DragHandleView.Axis = .horizontal
    var grip: DragHandleView.Grip?
    var cursor: NSCursor = .arrow
    var dragCursor: NSCursor?
    var slop: CGFloat = 0
    var isActive = true
    var onBegin: (() -> Void)?
    var onChange: ((CGSize) -> Void)?
    var onEnd: (() -> Void)?
    var onDoubleClick: (() -> Void)?
    var onClick: (() -> Void)?

    func makeNSView(context: Context) -> DragHandleView {
        let view = DragHandleView(frame: .zero)
        apply(to: view)
        return view
    }

    func updateNSView(_ nsView: DragHandleView, context: Context) {
        apply(to: nsView)
    }

    private func apply(to view: DragHandleView) {
        view.axis = axis
        view.configure(grip: grip)
        view.cursor = cursor
        view.dragCursor = dragCursor
        view.slop = slop
        view.isActive = isActive
        view.onBegin = onBegin
        view.onChange = onChange
        view.onEnd = onEnd
        view.onDoubleClick = onDoubleClick
        view.onClick = onClick
    }
}
