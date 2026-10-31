import AppKit
import Carbon
import Observation

@MainActor
@Observable
final class GlobalHotKey {
    static let shared = GlobalHotKey()
    nonisolated static let hotKeyID = EventHotKeyID(signature: 0x54565143, id: 1)
    private(set) var lastRegistrationFailed = false
    @ObservationIgnored private var hotKey: EventHotKeyRef?
    @ObservationIgnored private var eventHandler: EventHandlerRef?
    @ObservationIgnored private var handler: (@MainActor () -> Void)?

    func register(_ chord: KeyChord?, handler: @escaping @MainActor () -> Void) {
        unregister()
        guard let chord else { return }
        self.handler = handler
        if eventHandler == nil {
            var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
                var pressed = EventHotKeyID()
                let read = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                             nil, MemoryLayout<EventHotKeyID>.size, nil, &pressed)
                guard read == noErr, pressed.signature == GlobalHotKey.hotKeyID.signature,
                      pressed.id == GlobalHotKey.hotKeyID.id else { return OSStatus(eventNotHandledErr) }
                Task { @MainActor in GlobalHotKey.shared.handler?() }
                return noErr
            }, 1, &type, nil, &eventHandler)
            guard status == noErr else {
                lastRegistrationFailed = true
                return
            }
        }
        var modifiers: UInt32 = 0
        let flags = chord.modifierFlags
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        lastRegistrationFailed = RegisterEventHotKey(UInt32(chord.keyCode), modifiers, Self.hotKeyID,
                                                     GetApplicationEventTarget(), 0, &hotKey) != noErr
    }

    func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
        if let eventHandler { RemoveEventHandler(eventHandler) }
        eventHandler = nil
        handler = nil
        lastRegistrationFailed = false
    }
}
