import AppKit
import SwiftUI

/// Builds Tivano's windows the way the app builds its settings window: a plain titled AppKit window
/// with a clear background and a SwiftUI glass pane, so no scene background draws a second corner.
/// Every window is a `DCDisplayCycleGuardedWindow`: SwiftUI under a transparent title bar makes
/// AppKit evaluate the view graph inside its own display cycle, and the guard is what keeps the
/// passes that evaluation asks for from ending the app on macOS 26 and later.
@MainActor
final class WindowManager {
    static let shared = WindowManager()

    let model = AppModel()

    private var mainWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private weak var responderBeforeSettings: NSView?
    private var threadBeforeSettings: UUID?

    var usesFullWindowSettings: Bool {
        let defaults = CaptureRun.defaults ?? .standard
        return defaults.string(forKey: "settingsPresentation") != "window"
    }

    private enum Size {
        static let main = NSSize(width: 1320, height: 860)
        static let mainMinimum = NSSize(width: 860, height: 560)
        static let settings = NSSize(width: 780, height: 580)
    }

    private static let mainFrameName = "TivanoMainWindow"

    func showMain() {
        let window = mainWindow ?? makeMainWindow()
        mainWindow = window
        present(window)
    }

    func showSettings(page: SettingsPage? = nil) {
        let navigation = SettingsNavigation.shared
        if usesFullWindowSettings {
            settingsWindow?.orderOut(nil)
            let window = mainWindow ?? makeMainWindow()
            mainWindow = window
            if !navigation.isPresented {
                // The chat stays mounted behind Settings and must not keep keyboard focus.
                let responder = window.firstResponder
                // A shared field editor outlives its control; restore the control instead.
                if let editor = responder as? NSTextView, editor.isFieldEditor {
                    responderBeforeSettings = editor.delegate as? NSView
                } else {
                    responderBeforeSettings = responder as? NSView
                }
                threadBeforeSettings = model.selectedThreadID
                window.makeFirstResponder(nil)
            }
            model.isCommandPalettePresented = false
            navigation.present(page: page)
            present(window)
            return
        }
        hideSettings()
        if let page { navigation.requestedPage = page }
        let window = settingsWindow ?? makeSettingsWindow()
        settingsWindow = window
        centerOverMainWindow(window)
        present(window)
    }

    func hideSettings() {
        let navigation = SettingsNavigation.shared
        guard navigation.isPresented else { return }
        navigation.dismiss()
        guard let window = mainWindow else { return }
        window.makeFirstResponder(nil)
        let responder = responderBeforeSettings
        let threadID = threadBeforeSettings
        responderBeforeSettings = nil
        threadBeforeSettings = nil
        // Let the mounted chat become interactive again before restoring AppKit focus.
        DispatchQueue.main.async { [weak self, weak window, weak responder] in
            guard let self, let window, !SettingsNavigation.shared.isPresented,
                  window.firstResponder == nil || window.firstResponder === window else { return }
            guard model.selectedThreadID == threadID,
                  let responder, responder.window === window,
                  !responder.isHiddenOrHasHiddenAncestor, responder.acceptsFirstResponder,
                  window.makeFirstResponder(responder) else {
                window.makeFirstResponder(nil)
                return
            }
        }
    }

    func toggleSettings() {
        if usesFullWindowSettings, SettingsNavigation.shared.isPresented, mainWindow?.isKeyWindow == true {
            hideSettings()
        } else {
            showSettings()
        }
    }

    /// Opens a window centered over the main window, kept on the screen the main window is on.
    private func centerOverMainWindow(_ window: NSWindow) {
        guard let main = mainWindow, main.isVisible, !main.isMiniaturized else {
            window.center()
            return
        }
        let parent = main.frame
        var frame = window.frame
        frame.origin.x = (parent.midX - frame.width / 2).rounded()
        frame.origin.y = (parent.midY - frame.height / 2).rounded()
        if let visible = (main.screen ?? NSScreen.main)?.visibleFrame {
            frame.origin.x = min(max(frame.origin.x, visible.minX), visible.maxX - frame.width)
            frame.origin.y = min(max(frame.origin.y, visible.minY), visible.maxY - frame.height)
        }
        window.setFrame(frame, display: false)
    }

    private func present(_ window: NSWindow) {
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func makeMainWindow() -> NSWindow {
        let window = makeWindow(title: AppInfo.name, size: Size.main, resizable: true, windowClass: ThreadWindow.self) { RootView() }
        (window as? ThreadWindow)?.selectThread = { [weak model] offset in model?.selectThread(offset: offset) }
        (window as? ThreadWindow)?.selectThreadNumber = { [weak model] number in model?.selectThread(number: number) }
        (window as? ThreadWindow)?.escapeSettings = { [weak self] in
            guard SettingsNavigation.shared.isPresented else { return false }
            self?.hideSettings()
            return true
        }
        window.contentMinSize = Size.mainMinimum
        if !window.setFrameUsingName(Self.mainFrameName) {
            window.center()
        }
        window.setFrameAutosaveName(Self.mainFrameName)
        return window
    }

    /// The main window for the onboarding captures: the same window, at a fixed size, with
    /// no frame autosave, so the run never reads or writes where the real window sits.
    func makeCaptureWindow(size: NSSize) -> NSWindow {
        let window = makeWindow(title: AppInfo.name, size: size, resizable: true) { RootView() }
        #if DEBUG
        if HeroSwitchProbe.isRequested { mainWindow = window }
        #endif
        return window
    }

    private func makeSettingsWindow() -> NSWindow {
        let window = makeWindow(title: Chrome.localized("Settings"), size: Size.settings, resizable: false, windowClass: SecondaryWindow.self) { SettingsView() }
        window.center()
        return window
    }

    private func makeWindow<Content: View>(
        title: String,
        size: NSSize,
        resizable: Bool,
        windowClass: DCDisplayCycleGuardedWindow.Type = DCDisplayCycleGuardedWindow.self,
        @ViewBuilder content: () -> Content
    ) -> NSWindow {
        var style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        if resizable { style.insert(.resizable) }
        let frame = NSRect(origin: .zero, size: size)
        let window = windowClass.init(contentRect: frame, styleMask: style, backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        window.animationBehavior = .documentWindow
        window.tabbingMode = .disallowed
        WindowChrome.configure(window)

        let liveResize = WindowLiveResize(window: window)
        let hosting = FrameHostingView(rootView: AnyView(HostedRoot(model: model, liveResize: liveResize, content: content())))
        hosting.frame = frame
        let container = NSView(frame: frame)
        container.addSubview(hosting)
        window.contentView = container
        return window
    }
}

/// Whether the window is being dragged to a new size right now. Views read it from the
/// environment to hold their settle animations and heavier layout work until the drag
/// ends: a spring restarted on every frame of a live resize is what made panels lag
/// behind the window and land somewhere else. Flipped by AppKit's live-resize
/// notifications for this one window, so a resize elsewhere leaves it alone.
@MainActor @Observable
final class WindowLiveResize {
    private(set) var isActive = false
    /// Whether the sidebar's edge or the terminal's divider is being dragged: the pane
    /// changes width or height every frame the way a live resize does, so the timeline
    /// steps its row width and holds its animations exactly as it does for one. Written
    /// by the visible chat view, whose ownership follows ThreadColumns' selection.
    private(set) var isPaneResizing = false
    @ObservationIgnored private var paneOwner: UUID?
    /// The window or a pane is being dragged to a new size right now.
    var isReshaping: Bool { isActive || isPaneResizing }

    func setPaneOwner(_ id: UUID?, resizing: Bool = false) {
        paneOwner = id
        let active = id != nil && resizing
        if isPaneResizing != active { isPaneResizing = active }
    }

    func updatePaneResizing(_ active: Bool, owner: UUID) {
        guard paneOwner == owner else { return }
        if isPaneResizing != active { isPaneResizing = active }
    }

    func releasePane(_ id: UUID) {
        guard paneOwner == id else { return }
        setPaneOwner(nil)
    }

    /// The window keeps this alive for as long as it exists, so the observations are
    /// never taken down: a window is not made twice.
    init(window: NSWindow? = nil) {
        guard let window else { return }
        let center = NotificationCenter.default
        center.addObserver(forName: NSWindow.willStartLiveResizeNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.isActive = true }
        }
        center.addObserver(forName: NSWindow.didEndLiveResizeNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.isActive = false }
        }
    }
}

/// Shared environment for every hosted window, plus the app-wide appearance choice.
private struct HostedRoot<Content: View>: View {
    let model: AppModel
    let liveResize: WindowLiveResize
    let content: Content

    var body: some View {
        content
            .modifier(HostedEnvironment(model: model, liveResize: liveResize))
            .preferredColorScheme(model.settings.theme.spec.scheme)
            .onChange(of: model.settings.theme, initial: true) { _, theme in
                NSApp.appearance = switch theme.spec.scheme {
                case nil: nil
                case .light: NSAppearance(named: .aqua)
                case .dark: NSAppearance(named: .darkAqua)
                @unknown default: nil
                }
            }
    }
}

/// The environment every hosted view tree starts from: a window's root, and a chat column
/// hosted on its own inside the main window (see `ThreadColumns`).
struct HostedEnvironment: ViewModifier {
    let model: AppModel
    let liveResize: WindowLiveResize
    var isLayoutActive = true
    @State private var inactiveResize = WindowLiveResize()

    func body(content: Content) -> some View {
        content
            .environment(model)
            .environment(isLayoutActive ? liveResize : inactiveResize)
            .font(.ui(.body))
            .buttonBorderShape(.capsule)
            .modifier(ThemeTint(theme: model.settings.theme))
    }
}

/// Tints prominent glass buttons, toggles and progress views with the
/// theme's accent. System/Light/Dark keep the system control accent.
private struct ThemeTint: ViewModifier {
    let theme: AppTheme

    func body(content: Content) -> some View {
        // One branch, never two: an `if` here made the whole window's content a different
        // view once a theme with an accent replaced one without, so every page was built
        // afresh and Settings jumped back to its top on a theme change. A nil tint keeps
        // the system accent.
        content.tint(theme.spec.accent)
    }
}

/// Lets the frame it is given define the hosting view's size instead of the content
/// hugging it: a window's content view, or a chat column filling the detail pane.
final class FrameHostingView: NSHostingView<AnyView> {
    required init(rootView: AnyView) {
        super.init(rootView: rootView)
        sizingOptions = []
        safeAreaRegions = []
        translatesAutoresizingMaskIntoConstraints = true
        autoresizingMask = [.width, .height]
    }

    @MainActor required dynamic init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Every window here holds focusable text (the composer, a search field), so the
    /// answer is always yes. SwiftUI's own answer searches the whole view tree for a
    /// navigable item, and AppKit asks on every display cycle while content scrolls
    /// under the title bar to work out the window's drag region.
    var acceptsInteraction = true

    override var acceptsFirstResponder: Bool { acceptsInteraction }

    override func hitTest(_ point: NSPoint) -> NSView? {
        acceptsInteraction ? super.hitTest(point) : nil
    }

    /// A hidden chat column keeps its buttons' shortcuts to itself: AppKit offers a chord to
    /// hidden views too, and a Return meant for the shown column's card must not land on
    /// one behind it.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        acceptsInteraction && !isHiddenOrHasHiddenAncestor && super.performKeyEquivalent(with: event)
    }
}
