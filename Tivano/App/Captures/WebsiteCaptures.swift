#if DEBUG
import AppKit
import ScreenCaptureKit
import SwiftUI

/// Shared mock data and window capture support for the development screenshots.
/// `scripts/product_captures.py` runs the app with `--website-captures <folder>`.
/// Captures use independent storage/defaults, no Keychain, and a generated backdrop.
/// ScreenCaptureKit includes only this process's windows; no personal desktop is read.
@MainActor
enum WebsiteCaptures {
    /// The composer's model chip, captured by the chip itself, so the slider and the
    /// switcher popovers hang from the real control.
    static var modelChipAnchor: WeakView?
    /// Where each thread's composer chip sits in the window (SwiftUI's global space, which
    /// is the hosting view's flipped coordinates), for a popover hung from the window itself.
    static var modelChipFrames: [UUID: CGRect] = [:]
    /// Where the toolbar's Hydra mark is, in the window, for the intro scene: the intro
    /// hangs from the mark in the app, so its capture hangs it there too.
    static var hydraMarkFrame: CGRect?
    /// Where the toolbar's Threads button is (the hidden sidebar's list hangs from it).
    static var threadsButtonFrame: CGRect?
    /// Where each lead's docked Hydra panel sits in the window (SwiftUI's global space),
    /// so the Hydra screenshot can zoom on the team's panel.
    static var hydraPanelFrames: [UUID: CGRect] = [:]

    /// Wallpaper around the window in every capture, in points.
    static let margin: CGFloat = 72

    /// One line per step into <output>/run.log, so a stalled run shows where it stopped.
    nonisolated static func log(_ line: String) {
        guard let output = CaptureRun.outputDirectory else { return }
        let stamp = String(format: "%.1f", Date.now.timeIntervalSince1970.truncatingRemainder(dividingBy: 10_000))
        let text = "\(stamp) \(line)\n"
        let url = output.appendingPathComponent("run.log")
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(text.utf8))
            try? handle.close()
        } else {
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - Mock data

    enum ID {
        static let tivanoApp = UUID(uuidString: "A0000000-0000-4000-8000-000000000001")!
        static let site = UUID(uuidString: "A0000000-0000-4000-8000-000000000002")!
        static let ios = UUID(uuidString: "A0000000-0000-4000-8000-000000000003")!
        static let composer = UUID(uuidString: "B0000000-0000-4000-8000-000000000001")!
        static let diffPopover = UUID(uuidString: "B0000000-0000-4000-8000-000000000002")!
        static let archive = UUID(uuidString: "B0000000-0000-4000-8000-000000000003")!
        static let finalAnswer = UUID(uuidString: "B0000000-0000-4000-8000-000000000004")!
        static let pricing = UUID(uuidString: "B0000000-0000-4000-8000-000000000005")!
        static let footer = UUID(uuidString: "B0000000-0000-4000-8000-000000000006")!
        static let rail = UUID(uuidString: "B0000000-0000-4000-8000-000000000007")!
        static let liveActivity = UUID(uuidString: "B0000000-0000-4000-8000-000000000008")!
        static let widgets = UUID(uuidString: "B0000000-0000-4000-8000-000000000009")!
        static let fresh = UUID(uuidString: "B0000000-0000-4000-8000-000000000010")!
        static let freshPlan = UUID(uuidString: "B0000000-0000-4000-8000-000000000011")!
    }

    /// Writes the library, the thread histories and the project folders the run opens, and
    /// resets the run's defaults. Called before anything reads settings or the library.
    static func prepare() {
        if CaptureRun.isEnabled, CommandLine.arguments.contains("--standalone-task-probe") {
            StandaloneTaskProbe.prepare()
            return
        }
        if DshNativeIntegrationProbe.isRequested {
            DshNativeIntegrationProbe.prepare()
            return
        }
        if DshCaptureReplay.isEnabled {
            DshCaptureReplay.prepare()
            return
        }
        if DshIntegrationConfiguration.isOfflineHydra {
            DshHydraIntegrationProbe.prepare()
            return
        }
        if DshIntegrationConfiguration.isEnabled {
            DshIntegrationProbe.prepare()
            return
        }
        guard let output = CaptureRun.outputDirectory, let root = CaptureRun.storageRoot, let defaults = CaptureRun.defaults else { return }
        let files = FileManager.default
        try? files.removeItem(at: root)
        try? files.createDirectory(at: root.appendingPathComponent("threads"), withIntermediateDirectories: true)
        try? files.createDirectory(at: output, withIntermediateDirectories: true)

        defaults.removePersistentDomain(forName: CaptureRun.suiteName)
        defaults.set("dark", forKey: "appTheme")
        defaults.set(false, forKey: "notifyWhenFinished")
        defaults.set(false, forKey: "chimeWhenFinished")
        defaults.set(true, forKey: "showReasoning")
        defaults.set(true, forKey: "sidebarActivityView")
        defaults.set("supervised", forKey: "defaultRuntimeMode")
        defaults.set("claude", forKey: "defaultProvider")
        defaults.set(ID.tivanoApp.uuidString, forKey: "lastProjectID")
        // The switcher shows a curated list, as a set-up Mac would.
        let pins = [
            ModelPin(provider: .claude, modelID: "opus"),
            ModelPin(provider: .claude, modelID: "sonnet"),
            ModelPin(provider: .antigravity, modelID: "gemini-3.8-flash"),
            ModelPin(provider: .deepseek, modelID: "deepseek-v4-pro"),
            ModelPin(provider: .meta, modelID: "muse-spark-1.3"),
        ]
        if let data = try? JSONEncoder().encode(pins) { defaults.set(data, forKey: "modelList") }
        defaults.synchronize()

        if CaptureRun.isEnabled {
            defaults.set(true, forKey: "hydraEnabled")
            // With Hydra on, a queued follow-up would go out as a real head (see
            // `ThreadRuntime.enqueueFollowUp`): the queue scene must queue, nothing more.
            defaults.set(false, forKey: "hydraQueueHeads")
            defaults.set(false, forKey: "hydraAlwaysHeads")
        }
        let repos = output.appendingPathComponent("repos", isDirectory: true)
        var library = Library()
        library.projects = [
            project(ID.tivanoApp, "Tivano", repos, ["Tivano/App/Views/Composer/ComposerView.swift": composerSource]),
            project(ID.site, "tivano.app", repos, ["docs/index.html": "<!doctype html>\n<html lang=\"en\">\n</html>\n"]),
            project(ID.ios, "tivano-ios", repos, ["Tivano/LiveActivity.swift": "import ActivityKit\n"]),
        ]
        library.projects[0].scripts = [
            ProjectScript(name: "Quick run", command: "scripts/quick_run.sh", symbol: "hammer"),
            ProjectScript(name: "Release", command: "scripts/release.sh", symbol: "play"),
        ]
        let now = Date.now
        let day: TimeInterval = 86_400
        library.threads = [
            thread(ID.composer, ID.tivanoApp, "Composer: draft photo spacing", .claude, "opus", "high", age: 120, status: .completed, now),
            thread(ID.fresh, ID.tivanoApp, "Attachment strip insets", .claude, "opus", "high", age: 300, status: nil, now),
            thread(ID.finalAnswer, ID.tivanoApp, "Timeline final answer", .claude, "opus", "high", age: 600, status: .completed, now, plan: true),
            thread(ID.pricing, ID.site, "Regional pricing claim expiry", .codex, "gpt-5.5", nil, age: 900, status: .running, now),
            thread(ID.freshPlan, ID.tivanoApp, "Final answer card", .claude, "opus", "high", age: 1_500, status: nil, now, plan: true),
            thread(ID.archive, ID.tivanoApp, "Archive: delete all", .codex, "gpt-5.5", nil, age: 7_200, status: .completed, now),
            thread(ID.diffPopover, ID.tivanoApp, "Diff popover row patch", .claude, "opus", "high", age: day + 3_600, status: .completed, now),
            thread(ID.footer, ID.site, "Footer dragon scrub", .cursor, nil, nil, age: day + 5_400, status: .completed, now, unread: true),
            thread(ID.rail, ID.site, "Highlight rail poster blend", .claude, "sonnet", "medium", age: day + 9_000, status: .completed, now),
            thread(ID.liveActivity, ID.ios, "Live Activity for Pomodoro", .claude, "opus", "high", age: 3 * day, status: .completed, now),
            thread(ID.widgets, ID.ios, "Widget snapshots", .antigravity, "gemini-3.8-flash", "high", age: 6 * day, status: .completed, now),
        ]
        if CaptureRun.isEnabled {
            ProductCaptures.addHydraMocks(to: &library, storageRoot: root, repos: repos, now: now)
        }
        write(library, to: root.appendingPathComponent("library.json"))

        write(composerHistory(now), to: root.appendingPathComponent("threads/\(ID.composer.uuidString).json"))
        write(finalAnswerHistory(now), to: root.appendingPathComponent("threads/\(ID.finalAnswer.uuidString).json"))
        write(pricingHistory(now), to: root.appendingPathComponent("threads/\(ID.pricing.uuidString).json"))
    }

    private static func write<Value: Encodable>(_ value: Value, to url: URL) {
        guard let data = try? JSONEncoder.storage.encode(value) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private static func project(_ id: UUID, _ name: String, _ repos: URL, _ files: [String: String]) -> Project {
        let folder = repos.appendingPathComponent(name, isDirectory: true)
        for (path, contents) in files {
            let url = folder.appendingPathComponent(path)
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? contents.write(to: url, atomically: true, encoding: .utf8)
        }
        // A real repository on `main`, so the chrome row has a branch to show.
        let git = Process()
        git.executableURL = URL(fileURLWithPath: "/bin/sh")
        git.arguments = ["-c", "git init -q -b main && git -c user.name=Tivano -c user.email=hi@tivano.app add -A && git -c user.name=Tivano -c user.email=hi@tivano.app commit -q -m 'Initial import' >/dev/null 2>&1"]
        git.currentDirectoryURL = folder
        try? git.run()
        git.waitUntilExit()
        var project = Project(name: name, path: folder.path)
        project.id = id
        return project
    }

    static let composerThreadID = ID.composer
    static let freshThreadID = ID.fresh

    static func thread(
        _ id: UUID, _ projectID: UUID, _ title: String, _ provider: ProviderKind, _ model: String?, _ effort: String?,
        age: TimeInterval, status: TurnStatus?, _ now: Date, plan: Bool = false, unread: Bool = false
    ) -> ChatThread {
        var thread = ChatThread(projectID: projectID, provider: provider, model: model, effort: effort, runtimeMode: .supervised)
        thread.id = id
        thread.title = title
        thread.hasCustomTitle = true
        thread.createdAt = now.addingTimeInterval(-age - 1_800)
        thread.updatedAt = now.addingTimeInterval(-age)
        thread.lastStatus = status
        thread.hasUnread = unread
        thread.interactionMode = plan ? .plan : .build
        thread.branch = "main"
        return thread
    }

    /// The composer thread's earlier turn: a question about the strip, answered.
    private static func composerHistory(_ now: Date) -> ThreadDocument {
        var document = ThreadDocument(threadID: ID.composer)
        var turn = TurnRecord(index: 0)
        turn.startedAt = now.addingTimeInterval(-1_500)
        turn.completedAt = now.addingTimeInterval(-1_440)
        turn.status = .completed
        let user = TimelineItem(turnID: turn.id, date: turn.startedAt, content: .user(UserMessage(
            text: "Where does the composer decide how far the draft photo sits from the edges?")))
        turn.userItemID = user.id
        let reasoning = TimelineItem(turnID: turn.id, date: turn.startedAt.addingTimeInterval(2), content: .reasoning(ReasoningBlock(
            text: "The attachment strip lives in ComposerView.swift. Its insets come from a single constant, so I should read that first.")))
        var read = ToolCall(kind: .read, title: "Read", detail: "Tivano/App/Views/Composer/ComposerView.swift")
        read.status = .completed
        read.output = composerSource
        read.startedAt = turn.startedAt.addingTimeInterval(4)
        read.finishedAt = turn.startedAt.addingTimeInterval(5)
        let tool = TimelineItem(turnID: turn.id, date: read.startedAt, content: .tool(read))
        let answer = TimelineItem(turnID: turn.id, date: turn.startedAt.addingTimeInterval(9), content: .assistant(AssistantMessage(
            text: "In `DraftAttachments`, inside **ComposerView.swift**. The strip pads its leading edge with `attachmentInset` (14pt) but leaves the top on the stack's default spacing, which is why the photo hugs the top of the pill.\n\nWant me to give the top the same 14pt?")))
        let end = TimelineItem(turnID: turn.id, date: turn.completedAt!, content: .turnEnd(TurnSummary(
            turnID: turn.id, status: .completed, duration: 58, filesChanged: 0, additions: 0, deletions: 0)))
        document.turns = [turn]
        document.items = [user, reasoning, tool, answer, end]
        document.usage = ContextUsage(usedTokens: 18_400, windowTokens: 200_000)
        return document
    }

    /// The plan-mode thread: one exchange already on screen.
    private static func finalAnswerHistory(_ now: Date) -> ThreadDocument {
        var document = ThreadDocument(threadID: ID.finalAnswer)
        var turn = TurnRecord(index: 0)
        turn.startedAt = now.addingTimeInterval(-700)
        turn.completedAt = now.addingTimeInterval(-640)
        turn.status = .completed
        let user = TimelineItem(turnID: turn.id, date: turn.startedAt, content: .user(UserMessage(
            text: "The last reply of a turn gets lost between the tool calls. What would you change?")))
        turn.userItemID = user.id
        let reply = CaptureRun.isEnabled && (CommandLine.arguments.contains("--render-cost-probe")
            || CommandLine.arguments.contains("--heavy-load-probe"))
            ? RenderCostProbe.fixtureAnswer
            : "Three things, and I would keep them small: tag the final text so the timeline knows which block is the answer, give that block the glass card the plan cards already use, and leave streaming text plain so nothing flickers while it arrives."
        let answer = TimelineItem(turnID: turn.id, date: turn.startedAt.addingTimeInterval(6), content: .assistant(AssistantMessage(
            text: reply)))
        let end = TimelineItem(turnID: turn.id, date: turn.completedAt!, content: .turnEnd(TurnSummary(
            turnID: turn.id, status: .completed, duration: 41, filesChanged: 0, additions: 0, deletions: 0)))
        document.turns = [turn]
        document.items = [user, answer, end]
        document.usage = ContextUsage(usedTokens: 9_800, windowTokens: 200_000)
        return document
    }

    /// A thread on another project, so the sidebar has a second pulse.
    private static func pricingHistory(_ now: Date) -> ThreadDocument {
        var document = ThreadDocument(threadID: ID.pricing)
        var turn = TurnRecord(index: 0)
        turn.startedAt = now.addingTimeInterval(-900)
        let user = TimelineItem(turnID: turn.id, date: turn.startedAt, content: .user(UserMessage(
            text: "Why does the site quote the India price and charge the global one?")))
        turn.userItemID = user.id
        document.turns = [turn]
        document.items = [user]
        return document
    }

    private static let composerSource = """
    import SwiftUI

    struct DraftAttachments: View {
        @Binding var attachments: [Attachment]
        private let attachmentInset: CGFloat = 14

        var body: some View {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(attachments) { attachment in
                        AttachmentPreview(attachment: attachment) {
                            attachments.removeAll { $0.id == attachment.id }
                        }
                    }
                }
                .padding(.leading, attachmentInset)
                .transition(.scale.combined(with: .opacity))
            }
        }
    }

    """

    private static let composerPatch = """
    diff --git a/Tivano/App/Views/Composer/ComposerView.swift b/Tivano/App/Views/Composer/ComposerView.swift
    --- a/Tivano/App/Views/Composer/ComposerView.swift
    +++ b/Tivano/App/Views/Composer/ComposerView.swift
    @@ -12,8 +12,10 @@ struct DraftAttachments: View {
                     }
                 }
    -            .padding(.leading, attachmentInset)
    +            .padding(.top, attachmentInset)
    +            .padding(.leading, attachmentInset)
    +            .accessibilityLabel("Draft photo")
                 .transition(.scale.combined(with: .opacity))
             }
         }
     }

    """

    // MARK: - Run

    static func run(model: AppModel) async {
        if CaptureRun.isEnabled, CommandLine.arguments.contains("--standalone-task-probe") {
            await StandaloneTaskProbe.run(model: model)
            return
        }
        if HeroSwitchProbe.isRequested {
            await HeroSwitchProbe.run(model: model)
            return
        }
        if KeepsakePreview.isRequested {
            await KeepsakePreview.run(model: model)
            return
        }
        if HeroPreview.isRequested {
            await HeroPreview.run(model: model)
            return
        }
        if DshNativeIntegrationProbe.isRequested {
            await DshNativeIntegrationProbe.run(model: model)
            return
        }
        if DshCaptureReplay.isEnabled {
            await DshCaptureReplay.run(model: model)
            return
        }
        if DshIntegrationConfiguration.isOfflineHydra {
            await DshHydraIntegrationProbe.run(model: model)
            return
        }
        if DshIntegrationConfiguration.isEnabled {
            await DshIntegrationProbe.run(model: model)
            return
        }
        if CaptureRun.isEnabled, CommandLine.arguments.contains("--text-parity-probe") {
            await TextParityProbe.run(model: model)
            return
        }
        if CaptureRun.isEnabled, CommandLine.arguments.contains("--website-captures"),
           CommandLine.arguments.contains("--settings-interaction-probe") {
            await SettingsInteractionProbe.run(model: model)
            return
        }
        if CaptureRun.isEnabled, CommandLine.arguments.contains("--website-captures"),
           CommandLine.arguments.contains("--heavy-load-probe") {
            await HeavyLoadProbe.run(model: model)
            return
        }
        if CaptureRun.isEnabled, CommandLine.arguments.contains("--render-cost-probe") {
            await RenderCostProbe.run(model: model)
            return
        }
        if CommandLine.arguments.contains("--unread-regression") {
            await UnreadRegression.run(model: model)
            return
        }
        // `--timeline-stress` is the chat-timeline jitter run. Without it, the product
        // scenes run exactly as before. Both stay on this process's `--website-captures` isolation.
        if CommandLine.arguments.contains("--timeline-stress") {
            await TimelineStress.run(model: model)
            return
        }
        await ProductCaptures.run(model: model)
    }

    /// The composer thread mid-turn: reasoning, a read, an edit, the to-dos, a build running
    /// and the reply streaming in. Ends still running, so the working line stays.
    static func editingScene(_ model: AppModel, _ stage: Stage, _ recorder: Recorder) async {
        log("scene editingScene")
        model.selectedThreadID = ID.composer
        // The sidebar's other pulse.
        let pricing = model.runtime(for: ID.pricing)
        pricing.rehearseTurn(nil)
        pricing.rehearse(.reasoningDelta(id: "pricing-r", text: "Tracing claimExpiryFromString: the expiry is field 2, not the last field."))
        try? await Task.sleep(for: .milliseconds(900))

        let runtime = model.runtime(for: ID.composer)
        try? await Task.sleep(for: .milliseconds(600))
        runtime.rehearseTurn(
            "The draft photo in the composer should sit as far from the top as it does from the left.",
            touchedPaths: ["Tivano/App/Views/Composer/ComposerView.swift"],
            providerDiff: composerPatch
        )
        try? await Task.sleep(for: .milliseconds(500))
        await stream(runtime, id: "r1", reasoning: true, "Reading ComposerView.swift and the attachment strip. The leading edge pads with attachmentInset, 14pt, while the top keeps the stack's default spacing, so the photo hugs the top of the pill. Matching the top to the leading inset is a one-line change, plus a label the strip is missing.", step: 45)
        runtime.rehearse(.reasoningCompleted(id: "r1", text: ""))
        try? await Task.sleep(for: .milliseconds(250))

        runtime.rehearse(.toolStarted(id: "t-read", call: ToolCall(kind: .read, title: "Read", detail: "Tivano/App/Views/Composer/ComposerView.swift")))
        try? await Task.sleep(for: .milliseconds(650))
        runtime.rehearse(.toolUpdated(id: "t-read", update: ToolUpdate(output: composerSource, status: .completed)))
        try? await Task.sleep(for: .milliseconds(300))

        runtime.rehearse(.toolStarted(id: "t-edit", call: ToolCall(kind: .edit, title: "Edit", detail: "ComposerView.swift · attachment padding")))
        try? await Task.sleep(for: .milliseconds(800))
        runtime.rehearse(.toolUpdated(id: "t-edit", update: ToolUpdate(
            status: .completed,
            edits: [FileEdit(path: "Tivano/App/Views/Composer/ComposerView.swift", diff: composerPatch, additions: 3, deletions: 1)]
        )))
        runtime.rehearse(.diff(composerPatch))
        try? await Task.sleep(for: .milliseconds(250))
        runtime.rehearse(.todos([
            TodoStep(text: "Find the attachment strip's insets", status: .done),
            TodoStep(text: "Match the top inset to the leading one", status: .done),
            TodoStep(text: "Build and confirm nothing else moved", status: .active),
        ]))
        try? await Task.sleep(for: .milliseconds(350))
        runtime.rehearse(.toolStarted(id: "t-build", call: ToolCall(kind: .command, title: "xcodebuild -scheme Tivano build", detail: nil)))
        try? await Task.sleep(for: .milliseconds(400))
        await stream(runtime, id: "m1", reasoning: false, "Done. The attachment strip now uses the same 14pt inset on both axes, so the draft photo sits as far from the top as from the left. The build is running to confirm nothing else moved.", step: 38)
        runtime.rehearse(.messageCompleted(id: "m1", text: ""))
        runtime.noteDiffChanged()
        try? await Task.sleep(for: .milliseconds(1_400))
        await recorder.still("editing", stage.captureRect)
    }

    /// Streams `text` into the timeline a few characters at a time, as a provider does.
    private static func stream(_ runtime: ThreadRuntime, id: String, reasoning: Bool, _ text: String, step: Int) async {
        var index = text.startIndex
        while index < text.endIndex {
            let end = text.index(index, offsetBy: 4, limitedBy: text.endIndex) ?? text.endIndex
            let chunk = String(text[index..<end])
            runtime.rehearse(reasoning ? .reasoningDelta(id: id, text: chunk) : .messageDelta(id: id, text: chunk))
            index = end
            try? await Task.sleep(for: .milliseconds(step))
        }
    }
}

// MARK: - Stage

/// The two windows a capture composites: the app window, and this run's own backdrop under
/// it, showing the fixed generated backdrop.
@MainActor
final class Stage {
    static let wide = NSSize(width: 1320, height: 860)
    static let narrow = NSSize(width: 860, height: 560)

    let model: AppModel
    private var backdrop: NSWindow?
    private var window: NSWindow?

    init(model: AppModel) {
        self.model = model
    }

    /// The app window's frame in screen coordinates, for a still's sidecar.
    var windowFrame: NSRect? { window?.frame }

    var contentWindow: NSWindow? { window }

    /// The app window with its wallpaper margin, in screen coordinates.
    var captureRect: NSRect {
        (window?.frame ?? .zero).insetBy(dx: -WebsiteCaptures.margin, dy: -WebsiteCaptures.margin)
    }

    /// The app window with the capture's 72-point surround, widened or heightened
    /// symmetrically around the window's centre until exactly 16:10.
    var productCaptureRect: NSRect {
        Self.productRect(around: window?.frame ?? .zero)
    }

    /// The capture rect around the window plus an open popover, so a slider or model
    /// switcher hanging past the window edge stays centered and uncropped at 16:10.
    /// Falls back to the window-only rect when the popover is closed or headless.
    func productCaptureRect(including popover: NSPopover?) -> NSRect {
        guard let frame = window?.frame,
              let popover,
              popover.isShown,
              let panel = popover.contentViewController?.view.window?.frame
        else { return productCaptureRect }
        return Self.productRect(around: frame.union(panel))
    }

    /// A SwiftUI global-space frame (the hosting view's flipped coordinates) as a screen
    /// rect, for a still's focus.
    func screenRect(fromGlobal frame: CGRect) -> NSRect? {
        guard let window, let content = window.contentView else { return nil }
        let local = content.isFlipped ? frame : NSRect(x: frame.minX, y: content.bounds.height - frame.maxY, width: frame.width, height: frame.height)
        return window.convertToScreen(content.convert(local, to: nil))
    }

    /// What a popover scene is about, in screen coordinates: the popover's panel and the
    /// chip it hangs from, so the screenshot can zoom on both. Nil when the popover is not
    /// showing.
    func popoverFocus(_ popover: NSPopover?) -> NSRect? {
        guard let popover, popover.isShown, let panel = popover.contentViewController?.view.window?.frame else { return nil }
        guard let anchor = popoverAnchor, let window = anchor.view.window else { return panel }
        let chip = window.convertToScreen(anchor.view.convert(anchor.rect, to: nil))
        return panel.union(chip)
    }

    /// A 16:10 rect around `frame` with at least the wallpaper margin on every side.
    static func productRect(around frame: NSRect) -> NSRect {
        var rect = frame.insetBy(dx: -WebsiteCaptures.margin, dy: -WebsiteCaptures.margin)
        let target: CGFloat = 1.6
        let ratio = rect.width / max(rect.height, 1)
        if ratio < target {
            let want = (rect.height * target - rect.width) / 2
            rect = rect.insetBy(dx: -want, dy: 0)
        } else if ratio > target {
            let want = (rect.width / target - rect.height) / 2
            rect = rect.insetBy(dx: 0, dy: -want)
        }
        return NSRect(
            x: (frame.midX - rect.width / 2).rounded(),
            y: (frame.midY - rect.height / 2).rounded(),
            width: rect.width.rounded(),
            height: rect.height.rounded()
        )
    }

    /// Replaces the backdrop window's content with a gradient view, full-screen.
    func setBackdrop<Content: View>(_ content: Content) {
        guard let backdrop, let screen = NSScreen.main else { return }
        backdrop.contentView = NSHostingView(rootView: content.ignoresSafeArea())
        backdrop.contentView?.frame = NSRect(origin: .zero, size: screen.frame.size)
    }

    func show(size: NSSize) {
        guard let screen = NSScreen.main else { return }
        let backdrop = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        backdrop.isOpaque = true
        backdrop.hasShadow = false
        backdrop.level = .normal
        backdrop.isReleasedWhenClosed = false
        backdrop.contentView = NSHostingView(rootView: BackdropWallpaper(screen: screen).ignoresSafeArea())
        self.backdrop = backdrop

        let window = WindowManager.shared.makeCaptureWindow(size: size)
        self.window = window
        place(window, size: size, on: screen)

        backdrop.orderFront(nil)
        window.makeKeyAndOrderFront(nil)
        backdrop.order(.below, relativeTo: window.windowNumber)
    }

    /// The traffic lights and every control draw active only while the app is active and the
    /// window is key, and macOS refuses activation while the person at the Mac is typing in
    /// another app. So before every capture: activate, and wait for it to have taken, for up
    /// to a few seconds.
    func ensureActive() async {
        guard let window else { return }
        var activated = false
        for _ in 0..<24 {
            if NSApp.isActive, window.isKeyWindow { break }
            activated = true
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            backdrop?.order(.below, relativeTo: window.windowNumber)
            try? await Task.sleep(for: .milliseconds(250))
        }
        if !(NSApp.isActive && window.isKeyWindow) { WebsiteCaptures.log("could not become the active app") }
        // The traffic lights and controls redraw a beat after activation lands.
        if activated { try? await Task.sleep(for: .milliseconds(450)) }
    }



    func resize(to size: NSSize) {
        guard let window, let screen = window.screen ?? NSScreen.main else { return }
        place(window, size: size, on: screen)
    }

    /// Centred, unless the pointer would sit inside the window: a hovered row or a tooltip
    /// must never end up in a capture, so the window moves out from under it.
    private func place(_ window: NSWindow, size: NSSize, on screen: NSScreen) {
        let visible = screen.visibleFrame
        var frame = NSRect(origin: .zero, size: size)
        frame.origin.x = (screen.frame.midX - size.width / 2).rounded()
        frame.origin.y = (screen.frame.midY - size.height / 2).rounded()
        let pointer = NSEvent.mouseLocation
        if frame.insetBy(dx: -24, dy: -24).contains(pointer) {
            // Wherever it goes, the whole capture, wallpaper margin included, stays on screen.
            let margin = WebsiteCaptures.margin
            let room = visible.insetBy(dx: margin, dy: margin)
            let candidates = [
                NSRect(x: room.minX, y: frame.minY, width: size.width, height: size.height),
                NSRect(x: room.maxX - size.width, y: frame.minY, width: size.width, height: size.height),
                NSRect(x: frame.minX, y: room.minY, width: size.width, height: size.height),
                NSRect(x: frame.minX, y: room.maxY - size.height, width: size.width, height: size.height),
                NSRect(x: room.minX, y: room.minY, width: size.width, height: size.height),
                NSRect(x: room.maxX - size.width, y: room.maxY - size.height, width: size.width, height: size.height),
            ]
            if let clear = candidates.first(where: { room.contains($0) && !$0.insetBy(dx: -24, dy: -24).contains(pointer) }) {
                frame = clear
            }
        }
        window.setFrame(frame, display: true)
    }

    /// Shows `content` in a popover hanging from the composer's model chip, the way the chip
    /// shows the slider. Sized to the content, as the chip's popover is.
    /// Where the last popover was hung, so `holdPopover` can hang it there again.
    private var popoverAnchor: (view: NSView, rect: NSRect)?

    /// Keeps a presented popover up for `seconds`: one that closes on its own meanwhile (a
    /// re-rendered anchor takes its popover down with it) is shown again where it was.
    func holdPopover(_ popover: NSPopover, seconds: Double) async {
        let deadline = Date.now.addingTimeInterval(seconds)
        while Date.now < deadline {
            try? await Task.sleep(for: .milliseconds(200))
            guard !popover.isShown, let anchor = popoverAnchor else { continue }
            WebsiteCaptures.log("popover closed on its own; showing it again")
            popover.show(relativeTo: anchor.rect, of: anchor.view, preferredEdge: anchor.view.isFlipped ? .minY : .maxY)
        }
    }

    func presentPopover<Content: View>(_ content: Content, width: CGFloat, chipOf threadID: UUID? = nil, at frame: CGRect? = nil) -> NSPopover {
        let popover = NSPopover()
        popover.behavior = .applicationDefined
        let probe = NSHostingView(rootView: content.frame(width: width))
        probe.frame = NSRect(x: 0, y: 0, width: width, height: 10)
        let height = probe.fittingSize.height
        popover.setFixedContent(content, size: NSSize(width: width, height: height))
        // A rect of the window's content given outright (the Hydra mark's), the same way
        // the chip's is used below.
        if let frame, let content = window?.contentView {
            let rect = content.isFlipped ? frame : NSRect(x: frame.minX, y: content.bounds.height - frame.maxY, width: frame.width, height: frame.height)
            WebsiteCaptures.log("popover \(width)x\(height) at the given frame \(rect)")
            popoverAnchor = (content, rect)
            popover.show(relativeTo: rect, of: content, preferredEdge: content.isFlipped ? .minY : .maxY)
        }
        // The chip's view is SwiftUI's to make and remake (the chip turns compact and back
        // with the composer's width, and a remade view takes a popover hung from it down),
        // so the popover hangs from the window's own content view instead, at the rect
        // where the thread's chip is right now.
        if !popover.isShown, let threadID, let frame = WebsiteCaptures.modelChipFrames[threadID], let content = window?.contentView {
            let rect = content.isFlipped ? frame : NSRect(x: frame.minX, y: content.bounds.height - frame.maxY, width: frame.width, height: frame.height)
            WebsiteCaptures.log("popover \(width)x\(height) at the chip's frame \(rect)")
            popoverAnchor = (content, rect)
            popover.show(relativeTo: rect, of: content, preferredEdge: content.isFlipped ? .minY : .maxY)
        } else if !popover.isShown, let anchor = WebsiteCaptures.modelChipAnchor?.value, anchor.window === window, !anchor.isHiddenOrHasHiddenAncestor,
           let content = window?.contentView {
            let rect = anchor.convert(anchor.bounds, to: content)
            WebsiteCaptures.log("popover \(width)x\(height) at the chip's rect \(rect)")
            popoverAnchor = (content, rect)
            popover.show(relativeTo: rect, of: content, preferredEdge: content.isFlipped ? .minY : .maxY)
        }
        // A chip that is no longer on screen refuses the popover: it hangs from where the
        // composer's chip sits instead, at the right end of the chat box.
        if !popover.isShown, let view = window?.contentView {
            WebsiteCaptures.log("popover \(width)x\(height) without a chip anchor")
            let rect = NSRect(x: view.bounds.maxX - 150, y: view.isFlipped ? view.bounds.maxY - 44 : 44, width: 10, height: 10)
            popoverAnchor = (view, rect)
            popover.show(relativeTo: rect, of: view, preferredEdge: view.isFlipped ? .minY : .maxY)
        }
        return popover
    }
}

/// A generated backdrop shared by capture scenes; never reads the user's desktop.
struct BackdropWallpaper: View {
    let screen: NSScreen
    var alignment: Alignment = .center

    var body: some View {
        LinearGradient(
            colors: [AppTheme.nord.spec.surface, AppTheme.rosePine.spec.surface],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

// MARK: - Recorder

/// Stills of this process's windows as the window server shows them: the run's
/// backdrop, the app window and any popover above it, and nothing of anyone else's.
///
@MainActor
final class Recorder {
    private let output: URL
    private weak var stage: Stage?

    init(output: URL, stage: Stage) {
        self.output = output
        self.stage = stage
    }

    /// Photographs `rect` as <name>.png. `focus`, in screen coordinates, names the part of
    /// the scene the screenshot should zoom on; it goes into the sidecar.
    func still(_ name: String, _ rect: NSRect, focus: NSRect? = nil, activate: Bool = true) async {
        guard let screen = NSScreen.main else { return }
        // Expanded popover framing can reach beyond the display or into the menu bar.
        // Clip before capture, and record that same rect in the sidecar.
        let rect = rect.intersection(screen.visibleFrame)
        guard !rect.isEmpty else { return }
        if activate { await stage?.ensureActive() }
        WebsiteCaptures.log("still \(name)")
        guard let filter = await Self.filter() else { WebsiteCaptures.log("still \(name): no filter"); return }
        let configuration = Self.configuration(for: rect)
        configuration.captureResolution = .best
        do {
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            let representation = NSBitmapImageRep(cgImage: image)
            guard let data = representation.representation(using: .png, properties: [:]) else { return }
            try data.write(to: output.appendingPathComponent("\(name).png"), options: .atomic)
            writeSidecar(for: name, rect: rect, focus: focus)
        } catch {
            WebsiteCaptures.log("still \(name) failed: \(error.localizedDescription)")
        }
    }

    /// Where the app window sits inside a still, beside it as <name>.json: the still's
    /// rect and the window's frame, both in screen points, top-left origin; the script
    /// takes the pixel scale from the PNG's width over the rect's. A still framed around
    /// an open popover is wider than the window, and the capture script cuts the window's
    /// inside out of it; guessing that box from the window's size alone cut the
    /// sidebar's edge off the welcome page.
    ///
    /// `focus`, when given, is written the same way as `window`: the part of the still the
    /// screenshot zooms on, top-left origin, points.
    private func writeSidecar(for name: String, rect: NSRect, focus: NSRect?) {
        guard let window = stage?.windowFrame else { return }
        var sidecar: [String: [Double]] = [
            "rect": [rect.minX, rect.minY, rect.width, rect.height],
            "window": [window.minX - rect.minX, rect.maxY - window.maxY, window.width, window.height],
        ]
        if let focus {
            sidecar["focus"] = [focus.minX - rect.minX, rect.maxY - focus.maxY, focus.width, focus.height]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: sidecar, options: [.sortedKeys]) else { return }
        try? data.write(to: output.appendingPathComponent("\(name).json"), options: .atomic)
    }

    private static func filter() async -> SCContentFilter? {
        guard let content = try? await SCShareableContent.currentProcess,
              let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first
        else { return nil }
        let filter = SCContentFilter(display: display, including: content.windows)
        filter.includeMenuBar = false
        return filter
    }

    private static func configuration(for rect: NSRect) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let displayHeight = CGDisplayBounds(CGMainDisplayID()).height
        configuration.sourceRect = CGRect(x: rect.minX, y: displayHeight - rect.maxY, width: rect.width, height: rect.height)
        // Keep dimensions even when the screen scale produces a fractional size.
        configuration.width = Int(rect.width * scale) & ~1
        configuration.height = Int(rect.height * scale) & ~1
        configuration.scalesToFit = false
        configuration.showsCursor = false
        return configuration
    }
}
/// Holds a disposable library open for native interaction checks after real-model checks.
@MainActor
private enum StandaloneTaskProbe {
    static func prepare() {
        guard let root = CaptureRun.storageRoot, let defaults = CaptureRun.defaults else { return }
        do {
            try FileManager.default.createDirectory(at: root.appendingPathComponent("threads"), withIntermediateDirectories: true)
            defaults.removePersistentDomain(forName: CaptureRun.suiteName)
            defaults.set(false, forKey: "notifyWhenFinished")
            defaults.set(false, forKey: "chimeWhenFinished")
            try JSONEncoder.storage.encode(Library()).write(to: root.appendingPathComponent("library.json"), options: .atomic)
        } catch {
            WebsiteCaptures.log("standalone fixture failed: \(error)")
            exit(1)
        }
    }

    static func run(model: AppModel) async {
        guard let output = CaptureRun.outputDirectory else { return }
        await model.bootstrap()
        guard model.isLibraryLoaded else { exit(1) }
        model.settings.hydraEnabled = false
        model.settings.hasSeenHydraIntro = true
        model.settings.defaultWorkspaceMode = .local
        model.settings.defaultProvider = .deepseek
        model.settings.theme = .breeze
        for provider in ProviderKind.allCases {
            model.settings.setBinaryPath("/usr/bin/true", for: provider)
        }
        model.selectedThreadID = nil
        var checks: [String: Bool] = [:]
        checks["zero-project-create"] = model.projects.isEmpty && model.newThread(affiliation: .standalone) != nil
        let folder = output.appendingPathComponent("repos/tivano")
        let otherFolder = output.appendingPathComponent("repos/second-project")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: otherFolder, withIntermediateDirectories: true)
        } catch { exit(1) }
        let project = model.addProject(at: folder)
        let second = model.addProject(at: otherFolder)
        model.updateProject(second.id) { $0.name = "用于检查窄窗口的长项目名称 · Long Project Name" }
        model.updateProject(project.id) { $0.icon = .emoji("🛠️") }
        guard let draft = model.newThread(affiliation: .project(project.id)) else { exit(1) }
        model.rename(draft.id, to: "项目会话 · 图标与归属测试")
        checks["project-default"] = model.newThread()?.projectID == project.id
        guard let task = model.newThread(affiliation: .standalone) else { exit(1) }
        model.rename(task.id, to: "独立任务 · 工作目录测试")
        checks["task-default"] = model.newThread()?.projectID == nil
        let runtime = model.runtime(for: task.id)
        await runtime.ensureLoaded()
        runtime.draft.text = "草稿应在切换归属后保留"
        checks["task-to-project"] = model.moveThread(task.id, to: .project(project.id))
        checks["project-to-task"] = model.moveThread(task.id, to: .standalone)
        checks["draft-preserved"] = runtime.draft.text == "草稿应在切换归属后保留"
        runtime.draft.text = ""
        do {
            let directory = try model.ensureExecutionDirectory(for: model.thread(task.id)!)
            let payload = URL(fileURLWithPath: directory).appendingPathComponent("task-result.txt")
            try Data("isolated task file\n".utf8).write(to: payload)
            checks["task-directory"] = directory == StoragePaths.taskWorkspace(task.id).path
            model.archive(task.id)
            checks["archive-keeps-files"] = FileManager.default.fileExists(atPath: payload.path)
            model.updateThread(task.id) { $0.isArchived = false }
            checks["task-restored"] = model.standaloneTasks.contains { $0.id == task.id }
        } catch {
            checks["task-directory"] = false
            WebsiteCaptures.log("standalone task directory: \(error)")
        }
        model.selectedThreadID = task.id
        checks["flush"] = model.flushForQuit()
        if case .success(let library) = Storage.loadLibrary() {
            checks["persist-task"] = library.threads.contains { $0.id == task.id && $0.projectID == nil }
            checks["persist-icon"] = library.projects.first { $0.id == project.id }?.icon == .emoji("🛠️")
        }
        write(checks, name: "model-checks.json", output: output)
        guard checks.values.allSatisfy({ $0 }) else { exit(1) }
        model.selectedThreadID = draft.id
        if !model.sidebar.isVisible { model.sidebar.toggle() }
        WindowManager.shared.showMain()
        NSApp.activate(ignoringOtherApps: true)
        WebsiteCaptures.log("standalone task probe ready pid=\(ProcessInfo.processInfo.processIdentifier)")
        let deadline = Date.now.addingTimeInterval(1200)
        while Date.now < deadline, !FileManager.default.fileExists(atPath: output.appendingPathComponent("finish").path) {
            let state: [String: Any] = [
                "pid": ProcessInfo.processInfo.processIdentifier,
                "selectedThread": model.selectedThreadID?.uuidString ?? "",
                "projects": model.projects.map { ["id": $0.id.uuidString, "name": $0.name, "icon": $0.icon?.storage ?? ""] },
                "threads": model.threads.map { thread in
                    ["id": thread.id.uuidString, "projectID": thread.projectID?.uuidString ?? "", "title": thread.title,
                     "directory": (try? model.executionDirectory(for: thread)) ?? "",
                     "terminals": model.terminals.sessions(for: thread.id).map(\.directory)] as [String: Any]
                }
            ]
            write(state, name: "inspection-state.json", output: output)
            try? await Task.sleep(for: .seconds(1))
        }
        model.terminals.terminateAll()
        for thread in model.threads { model.existingRuntime(for: thread.id)?.stopSession() }
        _ = model.flushForQuit()
        WebsiteCaptures.log("standalone task probe finished")
        exit(0)
    }

    private static func write(_ value: Any, name: String, output: URL) {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: output.appendingPathComponent(name), options: .atomic)
    }
}
#endif
