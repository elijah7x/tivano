import Foundation

extension AppModel {
    var globalWeather: HeroWeather {
        globalWeatherSnapshot.weather
    }

    var globalWeatherSnapshot: HeroWeatherSnapshot {
        #if DEBUG
        if let forced = WeatherPreview.shared.weather {
            let counts: (failed: Int, awaiting: Int, done: Int) = switch forced {
            case .idle: (0, 0, 0)
            case .failed(let count): (count, 0, 0)
            case .awaiting(let count): (0, count, 0)
            case .done(let count): (0, 0, count)
            }
            return HeroWeatherSnapshot(
                weather: forced,
                hasRunningWork: false,
                failed: counts.failed,
                awaiting: counts.awaiting,
                done: counts.done
            )
        }
        #endif
        let shelvedProjectIDs: Set<UUID> = Set(projects.lazy.filter(\.isShelved).map(\.id))
        // The parents with a helper still at work, in one pass over the library:
        // asking `hasWorkingHelpers` per thread walks each thread's children again.
        // Helpers sit in a panel, not the sidebar, so a decision one waits on counts for its parent.
        var workingParents = Set<UUID>()
        var approvalParents = Set<UUID>()
        var questionParents = Set<UUID>()
        for thread in threadsUnobserved {
            guard !thread.isArchived,
                  let parent: UUID = thread.parentThreadID,
                  let runtime = existingRuntime(for: thread.id) else { continue }
            if runtime.isRunning || runtime.isHydraMerging { workingParents.insert(parent) }
            if !runtime.approvals.isEmpty { approvalParents.insert(parent) }
            if !runtime.questions.isEmpty { questionParents.insert(parent) }
        }
        let visibleThreads = threads.lazy.filter { thread -> Bool in
            if thread.isArchived || thread.isHydraHead || thread.isInPanel {
                return false
            }
            if let projectID: UUID = thread.projectID {
                return !shelvedProjectIDs.contains(projectID)
            }
            return true
        }
        let statuses = visibleThreads.map { thread -> ThreadActivityStatus in
            let runtime = self.existingRuntime(for: thread.id)
            let lastStatus: TurnStatus? = thread.unreadStatus ?? thread.lastStatus
            let hasApprovals: Bool
            let runtimeNeedsAnswer: Bool
            let isRunning: Bool
            let isMerging: Bool
            let hasBackgroundTasks: Bool
            let isWaitingForLimit: Bool
            if let runtime {
                hasApprovals = !runtime.approvals.isEmpty
                runtimeNeedsAnswer = runtime.needsUserAnswer
                isRunning = runtime.isRunning
                isMerging = runtime.isHydraMerging
                hasBackgroundTasks = !runtime.backgroundTasks.isEmpty
                isWaitingForLimit = runtime.isWaitingForLimit
            } else {
                hasApprovals = false
                runtimeNeedsAnswer = false
                isRunning = false
                isMerging = false
                hasBackgroundTasks = false
                isWaitingForLimit = false
            }
            let needsApproval: Bool = hasApprovals || approvalParents.contains(thread.id)
            let needsAnswer: Bool = runtimeNeedsAnswer || questionParents.contains(thread.id)
            let hasWorkingParent: Bool = workingParents.contains(thread.id)
            let isRuntimeWorking: Bool = isRunning || isMerging || hasBackgroundTasks || isWaitingForLimit
            let isWorking: Bool = isRuntimeWorking || hasWorkingParent
            return ThreadActivityStatus.resolve(
                lastStatus: lastStatus,
                hasUnread: thread.hasUnread,
                needsApproval: needsApproval,
                needsAnswer: needsAnswer,
                isWorking: isWorking
            )
        }
        return HeroWeather.resolveSnapshot(statuses)
    }
}
