import AppKit
import CoreGraphics

extension AppModel {
    var secondsUntilInputIdle: TimeInterval {
        max(0, 600 - CGEventSource.secondsSinceLastEventType(
            .combinedSessionState, eventType: CGEventType(rawValue: ~0)!
        ))
    }

    var isIdleForUpdate: Bool {
        isLibraryLoaded && alert == nil && installBlockers().isEmpty
            && !SettingsNavigation.shared.isPresented
            && !NSApp.windows.contains { $0.attachedSheet != nil || $0.isModalPanel }
            && !hasUnsentInput
            && secondsUntilInputIdle == 0
    }
}
