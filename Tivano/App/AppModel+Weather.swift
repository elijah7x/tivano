import Foundation

extension AppModel {
    var globalWeather: HeroWeather {
        globalWeatherSnapshot.weather
    }

    var globalWeatherSnapshot: HeroWeatherSnapshot {
        #if DEBUG
        if let forced = WeatherPreview.shared.weather {
            return HeroWeatherSnapshot(weather: forced, hasRunningWork: false)
        }
        #endif
        // The parents with a helper still at work, in one pass over the library:
        // asking `hasWorkingHelpers` per thread walks each thread's children again.
        var workingParents = Set<UUID>()
        for thread in threads {
            guard let parent = thread.parentThreadID,
                  let runtime = existingRuntime(for: thread.id),
                  runtime.isRunning || runtime.isHydraMerging else { continue }
            workingParents.insert(parent)
        }
        return HeroWeather.resolveSnapshot(
            threads.lazy
                .filter { !$0.isArchived && !$0.isHydraHead }
                .map { thread -> ThreadActivityStatus in
                    let runtime = self.existingRuntime(for: thread.id)
                    return ThreadActivityStatus.resolve(
                        lastStatus: thread.unreadStatus ?? thread.lastStatus,
                        hasUnread: thread.hasUnread,
                        needsApproval: !(runtime?.approvals.isEmpty ?? true),
                        needsAnswer: !(runtime?.questions.isEmpty ?? true),
                        isWorking: runtime?.isRunning == true || runtime?.isHydraMerging == true
                            || (runtime != nil && workingParents.contains(thread.id))
                            || !(runtime?.backgroundTasks.isEmpty ?? true)
                            || runtime?.isWaitingForLimit == true
                    )
                }
        )
    }
}
