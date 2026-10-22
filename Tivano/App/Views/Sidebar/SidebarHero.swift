import SwiftUI

/// The last fold the hero computed; while the sidebar is collapsed or hidden
/// behind Settings nothing recomputes it, and the card keeps showing it.
@MainActor
private final class HeroWeatherCache {
    var value: HeroWeather = .idle
}

/// Folds every visible thread into one weather; the hero ignores unchanged values.
struct SidebarHero: View {
    @Environment(AppModel.self) private var model
    @Environment(\.heroWeatherContentVisible) private var contentVisible
    @State private var cache = HeroWeatherCache()

    private var weather: HeroWeather {
        guard contentVisible else { return cache.value }
        // The parents with a helper still at work, in one pass over the library:
        // asking `hasWorkingHelpers` per thread walks each thread's children again.
        var workingParents = Set<UUID>()
        for thread in model.threads {
            guard let parent = thread.parentThreadID,
                  let runtime = model.existingRuntime(for: thread.id),
                  runtime.isRunning || runtime.isHydraMerging else { continue }
            workingParents.insert(parent)
        }
        let value = HeroWeather.resolve(
            model.threads.lazy
                .filter { !$0.isArchived && !$0.isHydraHead }
                .map { thread -> ThreadActivityStatus in
                    let runtime = model.existingRuntime(for: thread.id)
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
        cache.value = value
        return value
    }

    var body: some View {
        #if DEBUG
        if CaptureRun.isEnabled && CommandLine.arguments.contains("--hero-off") {
            Color.clear.frame(height: 96)
        } else {
            card
        }
        #else
        card
        #endif
    }

    private var card: some View {
        HeroWeatherCard(weather: HeroPreview.shared.weather ?? weather, onActivate: { model.newThread() })
            .frame(height: 96)
    }
}
