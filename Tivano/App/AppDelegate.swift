import AppKit
import SwiftUI
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    var model: AppModel?
    private var quitPending = false
    private var mcpShutdownCompleted = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Nothing the app fetches is worth keeping on disk (API calls, the MCP proxy's
        // streams, link titles), and the shared cache wrote a SQLite commit for every
        // response: a third of the app's disk writes while a team ran. Memory only.
        URLCache.shared = URLCache(memoryCapacity: 8 * 1024 * 1024, diskCapacity: 0)
        MarkdownDelegationCard.render = { AnyView(HydraDelegationBlock(json: $0, sent: $1)) }
        UNUserNotificationCenter.current().delegate = self
        let windows = WindowManager.shared
        model = windows.model
        #if DEBUG
        if CaptureRun.isEnabled {
            Task { await WebsiteCaptures.run(model: windows.model) }
            return
        }
        #endif
        windows.showMain()
        windows.model.openThreadOnLaunch()
        Task { await windows.model.bootstrap() }
        UpdateChecker.shared.startBackgroundChecks()
        // The relaunch after an install: the update story finishes on About, where it began.
        if AppUpdater.shared.consumeRelaunchMarker() {
            UpdateInstallProgress.shared.armCelebration()
            windows.showSettings(page: .about)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { WindowManager.shared.showMain() }
        return true
    }

    /// A quit while the team's work is going out waits for it: the merge is a minute or
    /// two of git and one model call, and losing it half-way leaves the work unmerged
    /// until the user's next message. Capped, so a stuck merge never holds the quit.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if quitPending { return .terminateLater }
        if let model, model.isLibraryLoaded, !model.isAnyHydraMergeRunning {
            guard model.saveBeforeQuit() else { return .terminateCancel }
            if !MCPHub.hasLiveProcesses { return .terminateNow }
        } else if model == nil, !MCPHub.hasLiveProcesses {
            return .terminateNow
        }
        quitPending = true
        Task { @MainActor in
            if let model {
                if !model.isLibraryLoaded { await model.bootstrap() }
                let loadDeadline = Date.now.addingTimeInterval(30)
                while !model.isLibraryLoaded, Date.now < loadDeadline {
                    try? await Task.sleep(for: .milliseconds(25))
                }
                if model.isLibraryLoaded {
                    let deadline = Date.now.addingTimeInterval(4 * 60)
                    while model.isAnyHydraMergeRunning, Date.now < deadline {
                        try? await Task.sleep(for: .milliseconds(250))
                    }
                    guard model.saveBeforeQuit() else {
                        quitPending = false
                        sender.reply(toApplicationShouldTerminate: false)
                        return
                    }
                }
            }
            await MCPHub.shared.shutdown()
            mcpShutdownCompleted = true
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let model, model.isLibraryLoaded { model.saveBeforeQuit() }
        TokenLedger.shared.flushLiveSpend()
        // The MCP servers the hub started go with the app.
        if !mcpShutdownCompleted { MCPHub.terminateAll() }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        let threadIDString = notification.request.content.userInfo["threadID"] as? String
        if let threadIDString, let notifiedID = UUID(uuidString: threadIDString) {
            let isOpenChat = await MainActor.run {
                NSApp.isActive && self.model?.selectedThreadID == notifiedID
            }
            if isOpenChat { return [] }
        }
        return [.banner, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let userInfo = response.notification.request.content.userInfo
        let identifier = userInfo["threadID"] as? String
        let isUpdate = userInfo["update"] != nil
        await MainActor.run {
            if !isUpdate {
                WindowManager.shared.hideSettings()
                WindowManager.shared.showMain()
            }
            if let identifier, let threadID = UUID(uuidString: identifier) {
                self.model?.openThread(threadID)
            }
            NSApp.activate()
            if isUpdate { WindowManager.shared.showSettings(page: .about) }
        }
    }
}
