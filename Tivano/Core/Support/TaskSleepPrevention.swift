import Foundation

enum TaskSleepMode: String, CaseIterable, Identifiable {
    case off
    case system
    case display

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: "Off"
        case .system: "Keep Mac awake"
        case .display: "Keep Mac and screen awake"
        }
    }
}

/// One app-wide idle-sleep assertion, shared by all running tasks.
@MainActor
final class TaskSleepPrevention {
    private var activity: NSObjectProtocol?
    private var activeMode = TaskSleepMode.off

    var isPreventingSleep: Bool { activity != nil }

    func update(mode: TaskSleepMode, hasRunningTasks: Bool) {
        let wanted = hasRunningTasks ? mode : .off
        guard wanted != activeMode else { return }
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
        activeMode = wanted
        // Foundation's NSProcessInfo.h: `.idleSystemSleepDisabled` prevents idle system sleep, not
        // display sleep; `.idleDisplaySleepDisabled` keeps the display lit. Releasing the token
        // also ends the activity.
        let options: ProcessInfo.ActivityOptions
        switch wanted {
        case .off: return
        case .system: options = .idleSystemSleepDisabled
        case .display: options = [.idleDisplaySleepDisabled, .idleSystemSleepDisabled]
        }
        activity = ProcessInfo.processInfo.beginActivity(options: options, reason: "Tivano tasks are running")
    }
}
