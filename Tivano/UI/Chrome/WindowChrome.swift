import AppKit
import SwiftUI

/// Sets up the hosting window the way the settings window is built: a transparent title bar over
/// a clear window, a SwiftUI glass pane underneath, and AppKit's own traffic lights pinned to the chrome,
/// with the title bar kept reaching down to them so they take their clicks wherever they are pinned.
struct WindowChromeConfigurator: NSViewRepresentable {
    var sidebarVisible = true
    var sidebarDragging = false
    var performanceMode = false

    func makeNSView(context: Context) -> WindowChromeProbeView {
        let view = WindowChromeProbeView()
        view.performanceMode = performanceMode
        return view
    }

    func updateNSView(_ nsView: WindowChromeProbeView, context: Context) {
        if nsView.sidebarDragging != sidebarDragging { nsView.sidebarDragging = sidebarDragging }
        if nsView.sidebarVisible != sidebarVisible { nsView.sidebarVisible = sidebarVisible }
        if nsView.performanceMode != performanceMode { nsView.performanceMode = performanceMode }
    }
}

final class WindowChromeProbeView: NSView {
    var sidebarDragging = false
    var performanceMode = false {
        didSet {
            guard performanceMode != oldValue, let window else { return }
            WindowChrome.setPerformanceMode(performanceMode, on: window)
        }
    }
    var sidebarVisible = true {
        didSet {
            guard sidebarVisible != oldValue, let window, !window.styleMask.contains(.fullScreen) else { return }
            scheduleTrafficLightPlacement(animated: true)
        }
    }

    /// The title bar whose height this view keeps (see `WindowChrome.fitTitlebar`), or nil until
    /// the view is in a window.
    private weak var titlebarContainer: NSView?
    /// The window the didEndLiveResize and fullscreen observers belong to, so moving windows never stack them.
    private weak var observedWindow: NSWindow?
    /// A fit is queued for after AppKit's current layout pass.
    private var titlebarFitPending = false
    private var trafficLightPlacementPending = false
    private var pendingPlacementAnimated = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let titlebarContainer {
            NotificationCenter.default.removeObserver(self, name: NSView.frameDidChangeNotification, object: titlebarContainer)
            self.titlebarContainer = nil
        }
        if let observedWindow {
            NotificationCenter.default.removeObserver(self, name: NSWindow.didEndLiveResizeNotification, object: observedWindow)
            NotificationCenter.default.removeObserver(self, name: NSWindow.willEnterFullScreenNotification, object: observedWindow)
            NotificationCenter.default.removeObserver(self, name: NSWindow.didEnterFullScreenNotification, object: observedWindow)
            NotificationCenter.default.removeObserver(self, name: NSWindow.didExitFullScreenNotification, object: observedWindow)
            self.observedWindow = nil
        }
        guard let window else { return }
        WindowChrome.configure(window)
        WindowChrome.setPerformanceMode(performanceMode, on: window)
        if window.styleMask.contains(.fullScreen) {
            WindowChrome.resetTrafficLights(on: window)
        } else {
            scheduleTrafficLightPlacement(animated: false)
        }
        // The probe's previous window keeps its own observer; moving windows register fresh.
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowDidEndLiveResize), name: NSWindow.didEndLiveResizeNotification, object: window
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowWillEnterFullScreen), name: NSWindow.willEnterFullScreenNotification, object: window
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowDidEnterFullScreen), name: NSWindow.didEnterFullScreenNotification, object: window
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowDidExitFullScreen), name: NSWindow.didExitFullScreenNotification, object: window
        )
        observedWindow = window
        // AppKit tiles the title bar back to its own height when the window resizes, and with
        // that the buttons level with the chrome are out of its reach again. It says so through
        // the container's frame, and the fit goes back on.
        guard let container = WindowChrome.titlebarContainer(of: window) else { return }
        container.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(titlebarFrameDidChange), name: NSView.frameDidChangeNotification, object: container
        )
        titlebarContainer = container
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// These calls arrive while SwiftUI renders the window, and forcing the title bar's layout
    /// there is a re-entrant layout AppKit skips; placing the buttons on the next turn lets
    /// that pass run. Requests in one turn merge, animated only if every one of them was.
    private func scheduleTrafficLightPlacement(animated: Bool) {
        pendingPlacementAnimated = trafficLightPlacementPending ? pendingPlacementAnimated && animated : animated
        guard !trafficLightPlacementPending else { return }
        trafficLightPlacementPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            trafficLightPlacementPending = false
            guard let window else { return }
            WindowChrome.placeTrafficLights(
                on: window,
                sidebarVisible: sidebarVisible,
                animated: pendingPlacementAnimated && !window.inLiveResize && !sidebarDragging
            )
        }
    }

    /// Runs inside AppKit's own tiling of the title bar; the fit waits for it to finish, so the
    /// container is never resized halfway through a pass that is laying out its subviews.
    /// Cheap per frame during a live resize: a container that already has the wanted
    /// height queues nothing, and the fit itself never lays out or draws synchronously.
    @objc private func titlebarFrameDidChange(_ notification: Notification) {
        guard let container = notification.object as? NSView,
              let window,
              !window.styleMask.contains(.fullScreen),
              container.frame.height < WindowChrome.titlebarHeight,
              !titlebarFitPending else { return }
        titlebarFitPending = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            titlebarFitPending = false
            if let currentWindow = self.window, !currentWindow.styleMask.contains(.fullScreen) {
                WindowChrome.fitTitlebar(of: currentWindow)
            }
        }
    }

    /// One final unanimated placement once the window settles, so the buttons end up
    /// correct after following the drag without animations.
    @objc private func windowDidEndLiveResize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, !window.styleMask.contains(.fullScreen) else { return }
        WindowChrome.placeTrafficLights(on: window, sidebarVisible: sidebarVisible, animated: false)
        WindowChrome.fitTitlebar(of: window)
    }

    @objc private func windowWillEnterFullScreen(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        WindowChrome.resetTrafficLights(on: window)
    }

    @objc private func windowDidEnterFullScreen(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        WindowChrome.resetTrafficLights(on: window)
    }

    @objc private func windowDidExitFullScreen(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        WindowChrome.placeTrafficLights(on: window, sidebarVisible: sidebarVisible, animated: false)
        WindowChrome.fitTitlebar(of: window)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor
enum WindowChrome {
    private static let leadingIdentifier = "tivano.trafficLight.leading"
    private static let topIdentifier = "tivano.trafficLight.top"
    private static let widthIdentifier = "tivano.trafficLight.width"
    private static let heightIdentifier = "tivano.trafficLight.height"
    /// Windows `configure` has already set up. Weak, so a closed window drops out on its own.
    private static let configuredWindows = NSHashTable<NSWindow>.weakObjects()

    static func configure(_ window: NSWindow) {
        // Idempotent: viewDidMoveToWindow fires on every reorder, so the setup pays once.
        if configuredWindows.contains(window) { return }
        configuredWindows.add(window)
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        // A focused window draws a separator under the title bar that cuts through the rounded corner.
        window.titlebarSeparatorStyle = .none
        window.isOpaque = false
        // A zero-alpha base can flash flat gray when Stage Manager restores Liquid Glass
        // on macOS 27.0.1. A visually negligible nonzero alpha avoids it in the focus probe.
        window.backgroundColor = NSColor.white.withAlphaComponent(0.000001)
        window.hasShadow = true
        window.isMovableByWindowBackground = false
        window.invalidateShadow()
        // AppKit owns the key view loop, rebuilt only when Tab navigation asks for it.
        // Left off, SwiftUI rebuilds the loop itself, synchronously, every time a
        // focusable view or an AppKit view in the window changes shape: it walks every
        // focus item in reading order, and on macOS 26 that walk never ended inside the
        // composer's follow-up queue tab, so the main thread stood still until a force
        // quit (the Sept 15 2026 freezes, `FocusBridge.updateDefaultKeyViewLoop` at the
        // top of every sample). With this on, SwiftUI only marks the loop dirty and keeps
        // its focus items by the finite, group-based route; nothing is rebuilt during
        // layout. Full Keyboard Access is what makes Tab move between controls at all,
        // and the loop is still rebuilt for it, just on demand.
        window.autorecalculatesKeyViewLoop = true
    }

    /// Keep AppKit's exterior corners and shadow; SwiftUI owns the backdrop fill.
    /// Refresh the system shadow when performance mode changes the fill.
    static func setPerformanceMode(_ performanceMode: Bool, on window: NSWindow) {
        window.invalidateShadow()
    }

    /// Where the buttons sit with the sidebar hidden: level with the chat's chrome capsules,
    /// which then step aside for them, and inset like the chrome is from the sheet's edge.
    static var collapsedTrafficLightTop: CGFloat {
        Chrome.sheetInset + Chrome.chromeTopPadding + (Chrome.capsuleHeight - Chrome.trafficLightDiameter) / 2
    }

    /// How far down the title bar reaches: to the bottom of the chrome row, so the buttons are
    /// inside it in either placement. AppKit only hands a click or a hover to a button within the
    /// title bar's own bounds, and its own bar stops short of buttons level with the chrome; the
    /// clicks fell through to the pane underneath. Being transparent, the bar shows nothing of
    /// its size; what changes is that the row's gaps drag the window, as a title bar's do, while
    /// the controls on it never do. Every chrome control carries a `NoWindowDragArea` behind its
    /// content (and native controls refuse the drag on their own), so a press starting on the zoom
    /// slider or any button, menu or field works only that control and leaves the window in place.
    static var titlebarHeight: CGFloat {
        Chrome.sheetInset + Chrome.chromeTopPadding + Chrome.capsuleHeight
    }

    /// The view AppKit sizes the title bar with: the buttons' bar and its accessories together.
    static func titlebarContainer(of window: NSWindow) -> NSView? {
        window.standardWindowButton(.closeButton)?.superview?.superview
    }

    /// Reaches the title bar down to `titlebarHeight`, keeping its top edge where it is. The
    /// buttons' bar fills the container, so it grows with it and the pinned buttons come inside.
    /// Never lays out synchronously: the fit lands on the frame and AppKit's own pass lays
    /// it out, so a notification fired mid-tiling costs one frame assignment.
    static func fitTitlebar(of window: NSWindow) {
        guard !window.styleMask.contains(.fullScreen) else { return }
        guard let container = titlebarContainer(of: window), let themeFrame = container.superview else { return }
        var fitted = container.frame
        guard fitted.height < titlebarHeight else { return }
        if themeFrame.isFlipped {
            fitted.size.height = titlebarHeight
        } else {
            fitted.origin.y = fitted.maxY - titlebarHeight
            fitted.size.height = titlebarHeight
        }
        container.frame = fitted
    }

    /// Restores standard window button positioning so AppKit can layout the buttons
    /// natively in full-screen mode without conflicting Auto Layout constraints.
    static func resetTrafficLights(on window: NSWindow) {
        let types: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        for type in types {
            guard let button = window.standardWindowButton(type) else { continue }
            if let titlebar = button.superview {
                let toRemove = titlebar.constraints.filter { constraint in
                    (constraint.firstItem as? NSView === button || constraint.secondItem as? NSView === button) &&
                    (constraint.identifier == leadingIdentifier || constraint.identifier == topIdentifier)
                }
                NSLayoutConstraint.deactivate(toRemove)
            }
            let buttonConstraints = button.constraints.filter { constraint in
                constraint.identifier == widthIdentifier || constraint.identifier == heightIdentifier
            }
            NSLayoutConstraint.deactivate(buttonConstraints)
            button.translatesAutoresizingMaskIntoConstraints = true
        }
        window.standardWindowButton(.closeButton)?.superview?.needsLayout = true
        window.standardWindowButton(.closeButton)?.superview?.layoutSubtreeIfNeeded()
    }

    /// Pins the native buttons with constraints, since the title bar's own layout pass resets
    /// frames. Beside the sidebar they sit in its top corner; with it hidden they move over
    /// to the chat's chrome row and down to its centre line, with the slide the chrome makes.
    static func placeTrafficLights(on window: NSWindow, sidebarVisible: Bool, animated: Bool) {
        guard !window.styleMask.contains(.fullScreen) else { return }
        let leading = sidebarVisible ? Chrome.trafficLightLeading : Chrome.sheetInset + Chrome.chromeHorizontalPadding
        let top = sidebarVisible ? Chrome.trafficLightTop : collapsedTrafficLightTop
        guard let titlebar = window.standardWindowButton(.closeButton)?.superview else { return }
        fitTitlebar(of: window)
        var changed = false
        let types: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        for (index, type) in types.enumerated() {
            guard let button = window.standardWindowButton(type) else { continue }
            button.isHidden = false
            let x = leading + CGFloat(index) * Chrome.trafficLightPitch
            if button.translatesAutoresizingMaskIntoConstraints {
                button.translatesAutoresizingMaskIntoConstraints = false
                let oldTitlebarConstraints = titlebar.constraints.filter { constraint in
                    (constraint.firstItem as? NSView === button || constraint.secondItem as? NSView === button) &&
                    (constraint.identifier == leadingIdentifier || constraint.identifier == topIdentifier)
                }
                NSLayoutConstraint.deactivate(oldTitlebarConstraints)
                let oldButtonConstraints = button.constraints.filter { constraint in
                    constraint.identifier == widthIdentifier || constraint.identifier == heightIdentifier
                }
                NSLayoutConstraint.deactivate(oldButtonConstraints)

                let leadingConstraint = button.leadingAnchor.constraint(equalTo: titlebar.leadingAnchor, constant: x)
                leadingConstraint.identifier = leadingIdentifier
                let topConstraint = button.topAnchor.constraint(equalTo: titlebar.topAnchor, constant: top)
                topConstraint.identifier = topIdentifier
                let widthConstraint = button.widthAnchor.constraint(equalToConstant: Chrome.trafficLightDiameter)
                widthConstraint.identifier = widthIdentifier
                let heightConstraint = button.heightAnchor.constraint(equalToConstant: Chrome.trafficLightDiameter)
                heightConstraint.identifier = heightIdentifier
                NSLayoutConstraint.activate([
                    leadingConstraint,
                    topConstraint,
                    widthConstraint,
                    heightConstraint,
                ])
                changed = true
            } else {
                for constraint in titlebar.constraints where constraint.firstItem as? NSView === button {
                    let target: CGFloat? = switch constraint.identifier {
                    case leadingIdentifier: x
                    case topIdentifier: top
                    default: nil
                    }
                    guard let target, constraint.constant != target else { continue }
                    constraint.constant = target
                    changed = true
                }
            }
        }
        guard changed else { return }
        // Never animated mid-resize: a fresh group every frame is what lagged the buttons.
        guard animated, !window.inLiveResize else {
            titlebar.layoutSubtreeIfNeeded()
            return
        }
        // The same run as Chrome.panelSlide, so the buttons and the chrome row that makes
        // room for them arrive together. A plain ease-out spends the run gliding; a curve
        // that is nearly done after its first few frames reads as the buttons popping over.
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduceMotion ? 0.18 : 0.32
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            context.allowsImplicitAnimation = true
            titlebar.layoutSubtreeIfNeeded()
        }
    }
}

// MARK: - Sidebar layout

/// The sidebar's width and visibility. Dragging its edge resizes it, and dragging past the
/// collapse point hides it, the same interaction as the settings sidebar.
@MainActor
@Observable
final class SidebarLayout {
    static let minimumWidth: CGFloat = 210
    static let maximumWidth: CGFloat = 440
    static let collapseThreshold: CGFloat = 110
    static let defaultWidth: CGFloat = 268

    private enum Key {
        static let width = "sidebarWidth"
        static let startsOpen = "sidebarStartsOpen"
    }

    private(set) var width: CGFloat
    private(set) var isVisible: Bool
    /// Whether the sidebar is open when the app starts (Settings → Appearance → Other).
    /// Open by default; toggling the sidebar only changes the current session.
    var startsOpen: Bool {
        didSet { persist() }
    }
    /// Whether the sidebar, as laid out this frame, is wide enough to hold the window buttons
    /// in its top corner. Until it is (while it slides open, or is dragged out from the edge)
    /// they stay over the chat's chrome, and the chrome keeps their room; the moment it is,
    /// they move over and the chrome closes up, together.
    private(set) var holdsTrafficLights: Bool
    /// True while the sidebar's edge is held; the chat follows the width with no spring until it is let go.
    private(set) var isDragging = false
    /// True for the run of the open or close slide started by `toggle()` or a drag let go past
    /// the collapse point: the chat treats the slide as a pane reshape (no springs inside the
    /// timeline, one layout width) the way it treats a drag of the edge.
    private(set) var isSliding = false
    /// How much the chat pane's width changes over the current slide: negative while the
    /// sidebar opens, positive while it closes. Zero outside a slide.
    private(set) var slideDelta: CGFloat = 0
    @ObservationIgnored private var slideTask: Task<Void, Never>?

    /// The width from which the buttons fit beside the sidebar's edge with their usual clearance.
    static var trafficLightsFitWidth: CGFloat {
        Chrome.trafficLightLeading + Chrome.trafficLightsWidth + Chrome.trafficLightClearance
    }

    /// The spring of Chrome.panelSlide is visually settled by then.
    private static var slideRun: Int { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 220 : 420 }

    @ObservationIgnored private var anchorWidth: CGFloat = 0
    @ObservationIgnored private var restingWidth: CGFloat
    /// The width as last laid out, so a resize frame that changes nothing writes nothing.
    @ObservationIgnored private var lastLaidOutWidth: CGFloat = -1

    init() {
        let defaults = CaptureRun.defaults ?? .standard
        let stored = (defaults.object(forKey: Key.width) as? Double).map { CGFloat($0) } ?? Self.defaultWidth
        restingWidth = min(Self.maximumWidth, max(Self.minimumWidth, stored))
        width = restingWidth
        let visible = defaults.object(forKey: Key.startsOpen) as? Bool ?? true
        startsOpen = visible
        isVisible = visible
        holdsTrafficLights = visible
    }

    var renderedWidth: CGFloat { isVisible ? width : 0 }

    /// The sidebar's width as laid out, reported every frame it changes, so the buttons follow
    /// the sidebar as it actually is on screen rather than the state it is heading for.
    /// Unchanged reports write nothing, so a height-only resize frame costs no state.
    func noteLaidOutWidth(_ laidOut: CGFloat) {
        guard laidOut != lastLaidOutWidth else { return }
        lastLaidOutWidth = laidOut
        let fits = laidOut >= Self.trafficLightsFitWidth
        if fits != holdsTrafficLights { holdsTrafficLights = fits }
    }

    private func beginSlide(delta: CGFloat) {
        slideDelta = delta
        isSliding = true
        slideTask?.cancel()
        slideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(Self.slideRun))
            guard !Task.isCancelled, let self else { return }
            isSliding = false
            slideDelta = 0
        }
    }

    func beginDrag() {
        slideTask?.cancel()
        isSliding = false
        slideDelta = 0
        isDragging = true
        if isVisible {
            anchorWidth = width
            return
        }
        anchorWidth = 0
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            width = 0
            isVisible = true
        }
    }

    func drag(by translation: CGFloat) {
        width = min(Self.maximumWidth, max(0, anchorWidth + translation))
    }

    func endDrag() {
        if width < Self.collapseThreshold {
            beginSlide(delta: width)
            withAnimation(Chrome.panelSlide) { isVisible = false }
            width = restingWidth
        } else {
            let settled = max(Self.minimumWidth, width)
            restingWidth = settled
            withAnimation(Chrome.panelSlide) { width = settled }
        }
        persist()
        isDragging = false
    }

    func toggle() {
        let opening = !isVisible
        if opening { width = restingWidth }
        beginSlide(delta: opening ? -restingWidth : width)
        withAnimation(Chrome.panelSlide) { isVisible.toggle() }
        persist()
    }

    private func persist() {
        let defaults = CaptureRun.defaults ?? .standard
        defaults.set(Double(restingWidth), forKey: Key.width)
        defaults.set(startsOpen, forKey: Key.startsOpen)
    }
}

// MARK: - Resize handle

/// The grab strip on the sidebar edge. AppKit gives it a real resize cursor and first-click tracking.
struct SidebarResizeHandle: View {
    @AppStorage("performanceMode", store: CaptureRun.defaults ?? .standard) private var performanceMode = false
    static let hitWidth: CGFloat = 9

    let isActive: Bool
    let onBegin: () -> Void
    let onChange: (CGFloat) -> Void
    let onEnd: () -> Void

    var body: some View {
        DragHandle(
            axis: .horizontal,
            grip: DragHandleView.Grip(
                restLength: 10,
                shownLength: 22,
                thickness: 2.5,
                glowInset: performanceMode ? nil : Chrome.trafficLightTop + Chrome.trafficLightDiameter,
                refreshesHoverOnLayout: true
            ),
            cursor: .columnResize,
            isActive: isActive,
            onBegin: onBegin,
            onChange: { onChange($0.width) },
            onEnd: onEnd
        )
    }
}
