import AppKit
import SwiftUI

/// The floating, non-activating panel the MCP key and setup guides share: sized to its
/// content, parked in the top-right corner of the main screen and closed on Escape.
@MainActor
class FloatingGuidePanel {
    private(set) var panel: NSPanel?
    private var escapeMonitor: Any?
    private var performanceModeObserver: NSObjectProtocol? = nil
    private let width: CGFloat

    init(width: CGFloat) {
        self.width = width
    }

    func present(_ content: some View) {
        observePerformanceModeChanges()
        let height = NSHostingView(rootView: content.frame(width: width)).fittingSize.height.rounded(.up)
        let panel = self.panel ?? makePanel()
        panel.hasShadow = !(CaptureRun.defaults ?? .standard).bool(forKey: "performanceMode")
        panel.contentViewController = NSHostingController(rootView: content)
        panel.setContentSize(NSSize(width: width, height: max(height, 100)))
        if let visible = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: visible.maxX - width - 24, y: visible.maxY - panel.frame.height - 24))
        }
        startEscapeMonitor()
        panel.orderFrontRegardless()
    }

    func close() {
        stopEscapeMonitor()
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 200),
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // No traffic lights: the panel closes from its own xmark and on Escape, and the
        // close button sat over the content in a corner that has no title bar to hold it.
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }
        self.panel = panel
        return panel
    }

    private func observePerformanceModeChanges() {
        guard performanceModeObserver == nil else { return }
        performanceModeObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshShadow() }
        }
    }

    private func refreshShadow() {
        panel?.hasShadow = !(CaptureRun.defaults ?? .standard).bool(forKey: "performanceMode")
    }

    private func startEscapeMonitor() {
        guard escapeMonitor == nil else { return }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.panel?.isVisible == true, event.keyCode == 53 else { return event }
            // Escape aimed at another window belongs to it: a nonactivating panel stays
            // out of the key window's way, so the composer's Escape still stops a turn.
            guard event.window === self.panel || self.panel?.isKeyWindow == true else { return event }
            self.close()
            return nil
        }
    }

    private func stopEscapeMonitor() {
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        escapeMonitor = nil
    }
}
