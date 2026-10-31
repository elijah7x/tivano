import AppKit
import Observation
import SwiftUI

final class QuickChatNSPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@Observable
final class QuickChatState {
    var text = ""
    var modelOverride: NewThreadModelSelection?
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
        let hosting = NSHostingView(rootView: QuickChatView(state: state, controller: self).environment(model))
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
                if model.thread(thread.id)?.controlWorkspace?.phase == .ready {
                    if untouched { runtime.send() }
                } else if model.thread(thread.id) != nil {
                    // The draft stays in the chat, where the failure shows.
                    model.openThread(thread.id)
                    WindowManager.shared.showMain()
                    NSApp.activate()
                }
            }
        } else {
            runtime.send()
        }
        if openAfter {
            model.openThread(thread.id)
            WindowManager.shared.showMain()
            NSApp.activate()
        }
    }

    func expand(model: AppModel) {
        guard let thread = model.newThread(affiliation: .current, overridingModel: state.modelOverride) else { return }
        model.runtime(for: thread.id).draft.text = state.text
        clearAndHide()
        model.openThread(thread.id)
        WindowManager.shared.showMain()
        NSApp.activate()
    }

    private func clearAndHide() {
        state.text = ""
        state.modelOverride = nil
        hide()
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
                self.hide()
            }
        }
        return panel
    }
}
