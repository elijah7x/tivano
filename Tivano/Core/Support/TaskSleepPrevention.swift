import Foundation

/// One app-wide idle-sleep assertion, shared by all running tasks.
@MainActor
final class TaskSleepPrevention {
    private var activity: NSObjectProtocol?

    var isPreventingSleep: Bool { activity != nil }

    func update(isEnabled: Bool, hasRunningTasks: Bool) {
        if isEnabled && hasRunningTasks {
            guard activity == nil else { return }
            // Foundation's NSProcessInfo.h: this flag prevents idle system sleep,
            // not display sleep. Releasing the token also ends the activity.
            activity = ProcessInfo.processInfo.beginActivity(
                options: .idleSystemSleepDisabled,
                reason: "Tivano tasks are running"
            )
        } else if let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
    }
}
