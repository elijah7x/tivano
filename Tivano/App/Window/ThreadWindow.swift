import AppKit

final class ThreadWindow: DCDisplayCycleGuardedWindow {
    var selectThread: ((Int) -> Void)?
    var escapeSettings: (() -> Bool)?
    /// ⌘1 to ⌘9, taken before the event is dispatched. AppKit hands a chord that a menu item
    /// carries to the item without asking the window, and firing the item flashes its menu
    /// title, which holds the main thread for a tenth of a second on every switch.
    var selectThreadNumber: ((Int) -> Void)? {
        didSet {
            guard digitMonitor == nil else { return }
            digitMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, event.window === self, attachedSheet == nil,
                      event.modifierFlags.intersection(KeyChord.allowedModifiers) == .command,
                      let number = Self.digitKeyCodes[event.keyCode], let selectThreadNumber else { return event }
                selectThreadNumber(number)
                return nil
            }
        }
    }
    private var digitMonitor: Any?

    /// The number row, by key code, for ⌘1 to ⌘9.
    private static let digitKeyCodes: [UInt16: Int] = [18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9]

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, event.keyCode == 53, attachedSheet == nil,
           event.modifierFlags.intersection(KeyChord.allowedModifiers).isEmpty,
           !(firstResponder is NSText), escapeSettings?() == true {
            return
        }
        super.sendEvent(event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.keyCode == 48, attachedSheet == nil {
            let chord = KeyChord(keyCode: Int(event.keyCode), modifiers: event.modifierFlags)
            if chord == ShortcutStore.shared.chord(for: .nextThread) {
                selectThread?(1)
                return true
            }
            if chord == ShortcutStore.shared.chord(for: .previousThread) {
                selectThread?(-1)
                return true
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}
