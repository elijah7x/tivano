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
        let shelvedProjectIDs = Set(projects.lazy.filter(\.isShelved).map(\.id))
        // The parents with a helper still at work, in one pass over the library:
        // asking `hasWorkingHelpers` per thread walks each thread's children again.
        // Helpers sit in a panel, not the sidebar, so a decision one waits on counts for its parent.
        var workingParents = Set<UUID>()
        var approvalParents = Set<UUID>()
        var questionParents = Set<UUID>()
        for thread in threadsUnobserved {
            guard !thread.isArchived,
                  let parent = thread.parentThreadID,
                  let runtime = existingRuntime(for: thread.id) else { continue }
            if runtime.isRunning || runtime.isHydraMerging { workingParents.insert(parent) }
            if !runtime.approvals.isEmpty { approvalParents.insert(parent) }
            if !runtime.questions.isEmpty { questionParents.insert(parent) }
        }
        return HeroWeather.resolveSnapshot(
            threads.lazy
                .filter { thread in
                    !thread.isArchived
                        && !thread.isHydraHead
                        && !thread.isInPanel
                        && (thread.projectID.map { !shelvedProjectIDs.contains($0) } ?? true)
                }
                .map { thread -> ThreadActivityStatus in
                    let runtime = self.existingRuntime(for: thread.id)
                    return ThreadActivityStatus.resolve(
                        lastStatus: thread.unreadStatus ?? thread.lastStatus,
                        hasUnread: thread.hasUnread,
                        needsApproval: !(runtime?.approvals.isEmpty ?? true) || approvalParents.contains(thread.id),
                        needsAnswer: runtime?.needsUserAnswer == true || questionParents.contains(thread.id),
                        isWorking: runtime?.isRunning == true || runtime?.isHydraMerging == true
                            || workingParents.contains(thread.id)
                            || !(runtime?.backgroundTasks.isEmpty ?? true)
                            || runtime?.isWaitingForLimit == true
                    )
                }
        )
    }
}
