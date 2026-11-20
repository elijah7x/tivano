import AppKit
import Observation
import SwiftUI

final class QuickChatNSPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// A press on the non-key panel works the control instead of only keying the panel.
final class QuickChatHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@Observable
final class QuickChatState {
    var text = ""
    var modelOverride: NewThreadDefault?
    var focusToken = 0
}

@MainActor
final class QuickChatPanelController {
    static let shared = QuickChatPanelController()
    let state = QuickChatState()
    private var panel: QuickChatNSPanel?
    private var resignObserver: NSObjectProtocol?

    private init() {}

    func toggle(model: AppModel) {
        if let panel, panel.isVisible, panel.isKeyWindow {
            hide()
            return
        }
        let panel = self.panel ?? makePanel()
        // Mounted only while shown: hidden, the view would keep observing the model.
        let hosting = QuickChatHostingView(rootView: QuickChatView(state: state, controller: self).environment(model))
        panel.contentView = hosting
        resize(to: hosting.fittingSize.height)
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main {
            let visible = screen.visibleFrame
            let top = visible.maxY - visible.height * 0.22 + 24
            panel.setFrameOrigin(NSPoint(x: visible.midX - panel.frame.width / 2, y: top - panel.frame.height))
        }
        panel.makeKeyAndOrderFront(nil)
        state.focusToken += 1
    }

    func hide() {
        panel?.orderOut(nil)
        // A turn later: hide often runs inside the view's own key press.
        DispatchQueue.main.async { [weak self] in
            guard let panel = self?.panel, !panel.isVisible else { return }
            panel.contentView = nil
        }
    }

    func resize(to height: CGFloat) {
        guard let panel, height.isFinite, height > 0 else { return }
        let height = height.rounded(.up)
        guard panel.frame.height != height else { return }
        var frame = panel.frame
        frame.origin.y = frame.maxY - height
        frame.size = NSSize(width: 688, height: height)
        panel.setFrame(frame, display: true)
    }

    func send(model: AppModel, openAfter: Bool) {
        let trimmed = state.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let thread = model.newThread(affiliation: .current, overridingModel: state.modelOverride) else { return }
        let runtime = model.runtime(for: thread.id)
        runtime.draft.text = trimmed
        clearAndHide()
        if model.thread(thread.id)?.controlWorkspace?.phase == .preparing {
            // A new worktree is still being made; sending now would run in the project checkout.
            Task { @MainActor in
                let deadline = Date.now.addingTimeInterval(120)
                while model.thread(thread.id)?.controlWorkspace?.phase == .preparing, Date.now < deadline {
                    try? await Task.sleep(for: .milliseconds(100))
                }
                // Only the draft as handed over: once the chat is open, an edit or a send
                // of its own belongs to the user, and the delayed send must not take it.
                let untouched = runtime.turns.isEmpty && runtime.draft.text == trimmed
                if let current = model.thread(thread.id) {
                    let workspace = current.controlWorkspace
                    if workspace == nil || workspace?.phase == .ready {
                        if untouched { runtime.send() }
                    } else {
                        // The draft stays in the chat, where the failure shows.
                        model.openThread(thread.id)
                        NSApp.activate(ignoringOtherApps: true)
                        WindowManager.shared.showMain()
                    }
                }
            }
        } else {
            runtime.send()
        }
        if openAfter {
            model.openThread(thread.id)
            NSApp.activate(ignoringOtherApps: true)
            WindowManager.shared.showMain()
        }
    }

    func expand(model: AppModel) {
        guard panel?.isVisible == true else { return }
        guard let thread = model.newThread(affiliation: .current, overridingModel: state.modelOverride) else {
            // The failure is an alert on the main window; show it there and keep the text here.
            NSApp.activate(ignoringOtherApps: true)
            WindowManager.shared.showMain()
            hide()
            return
        }
        model.runtime(for: thread.id).draft.text = state.text
        // The panel never activates the app; take the foreground before it goes so the main window comes up at once.
        NSApp.activate(ignoringOtherApps: true)
        WindowManager.shared.showMain()
        // Settings stays over the chat when nothing was selected before; the new chat is what was asked for.
        WindowManager.shared.hideSettings()
        clearAndHide()
    }

    private func clearAndHide() {
        state.text = ""
        state.modelOverride = nil
        hide()
    }

    /// Only the panel's own popovers, nested ones included, hang under it as child windows.
    private static func hasVisiblePopover(under window: NSWindow) -> Bool {
        (window.childWindows ?? []).contains { child in
            (child.isVisible && child.className.contains("Popover")) || hasVisiblePopover(under: child)
        }
    }

    private func makePanel() -> QuickChatNSPanel {
        let panel = QuickChatNSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 688, height: 160),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = Chrome.localized("Quick chat")
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        self.panel = panel
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: panel, queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                guard let self, let panel = self.panel, !panel.isKeyWindow else { return }
                var window = NSApp.keyWindow
                while let current = window {
                    if current === panel || current.className.contains("Popover") { return }
                    window = current.parent
                }
                // The model picker's popovers, including nested ones, can take key while the app is inactive and keyWindow is nil.
                if Self.hasVisiblePopover(under: panel) { return }
                self.hide()
            }
        }
        return panel
    }
}
