#if DEBUG


import AppKit
import Foundation
import SwiftUI

extension ProductCaptures {
    private enum HydraID {
        static let lead = UUID(uuidString: "C0000000-0000-4000-8000-000000000001")!
        static let head0 = UUID(uuidString: "C0000000-0000-4000-8000-000000000011")!
        static let head1 = UUID(uuidString: "C0000000-0000-4000-8000-000000000012")!
        static let head2 = UUID(uuidString: "C0000000-0000-4000-8000-000000000013")!
    }

    private static let tasks = [
        "Settings layout",
        "Settings sections and navigation",
        "Screenshots for every page",
    ]

    static func addHydraMocks(to library: inout Library, storageRoot: URL, repos: URL, now: Date) {
        guard let project = library.projects.first else { return }
        let leadID = HydraID.lead
        var lead = ChatThread(projectID: project.id, provider: .claude, model: "claude-fable-5-1[1m]", effort: "high", runtimeMode: .supervised)
        lead.id = leadID
        lead.title = "Settings overview for the app"
        lead.hasCustomTitle = true
        lead.createdAt = now.addingTimeInterval(-120 - 1_800)
        lead.updatedAt = now.addingTimeInterval(-120)
        lead.lastStatus = .completed
        lead.branch = "main"
        lead.hydraSpawnCount = 3
        library.threads.append(lead)

        let headIDs = [HydraID.head0, HydraID.head1, HydraID.head2]
        let briefs = [
            "Build the settings overview and its layout. Keep the pages swipeable and the window compact.",
            "Write the settings sections and wire the settings navigation. Every section reads cleanly and navigation opens it again.",
            "Take screenshots for every page. Cover each page at the capture size with nothing cropped.",
        ]
        let replies = [
            "The settings overview is built with its layout paging cleanly. The frame stays compact and every page lands centered.",
            "The settings sections are written and the settings navigation opens each section. Each page reads cleanly from first launch onward.",
            "The screenshots for every page are nearly done. I am editing ProductCaptures.swift to finish the last",
        ]
        for index in 0..<3 {
            var head = ChatThread(projectID: project.id, provider: .opencode, model: nil, effort: nil, runtimeMode: .supervised)
            head.id = headIDs[index]
            head.title = "\(HydraRoster.persona(at: index).name) · \(tasks[index])"
            head.hasCustomTitle = true
            head.parentThreadID = leadID
            head.isInPanel = true
            head.branch = "main"
            var info = HydraHeadInfo(index: index, task: tasks[index], kind: .tivano, origin: .delegated)
            info.toolUseID = "head-\(index)"
            info.toolCalls = index == 0 ? 6 : (index == 1 ? 11 : 9)
            if index == 0 {
                info.status = .completed
                info.startedAt = now.addingTimeInterval(-48 - 120)
                info.finishedAt = now.addingTimeInterval(-120)
            } else if index == 1 {
                info.status = .running
                info.startedAt = now.addingTimeInterval(-71 - 120)
                info.activity = "Wiring settings navigation"
            } else {
                info.status = .running
                info.startedAt = now.addingTimeInterval(-40)
                info.activity = "Editing ProductCaptures.swift"
            }
            head.hydra = info
            head.createdAt = info.startedAt
            head.updatedAt = info.finishedAt ?? now
            head.lastStatus = index == 0 ? .completed : .running
            library.threads.append(head)

            var document = ThreadDocument(threadID: headIDs[index])
            var turn = TurnRecord(index: 0)
            turn.startedAt = info.startedAt
            turn.completedAt = info.finishedAt
            turn.status = index == 0 ? .completed : .running
            let user = TimelineItem(turnID: turn.id, date: turn.startedAt, content: .user(UserMessage(text: briefs[index])))
            turn.userItemID = user.id
            var assistant = AssistantMessage(text: replies[index])
            if index == 2 { assistant.isStreaming = true }
            let answer = TimelineItem(turnID: turn.id, date: turn.startedAt.addingTimeInterval(20), content: .assistant(assistant))
            document.turns = [turn]
            document.items = [user, answer]
            hydraWrite(document, to: storageRoot.appendingPathComponent("threads/\(headIDs[index].uuidString).json"))
        }

        hydraWrite(hydraLeadDocument(now: now), to: storageRoot.appendingPathComponent("threads/\(leadID.uuidString).json"))
    }

    private static func hydraLeadDocument(now: Date) -> ThreadDocument {
        var document = ThreadDocument(threadID: HydraID.lead)
        var turn = TurnRecord(index: 0)
        turn.startedAt = now.addingTimeInterval(-300)
        turn.completedAt = now.addingTimeInterval(-120)
        turn.status = .completed
        let user = TimelineItem(turnID: turn.id, date: turn.startedAt, content: .user(UserMessage(
            text: "Add a settings overview: a settings overview with a page for Hydra, one for the effort slider, and a Help menu item to open it again.")))
        turn.userItemID = user.id
        let bq = "\u{60}\u{60}\u{60}"
        let fenceOpen = bq + "hydra"
        let assistantText = "Three heads are out: one builds the settings overview, one writes the pages and wires the settings navigation, one photographs every page. I keep the design and the integration.\n\n"
            + fenceOpen + "\n"
            + "[{\"task\": \"" + tasks[0] + "\", \"prompt\": \"Build the settings overview and its layout.\"}, "
            + "{\"task\": \"" + tasks[1] + "\", \"prompt\": \"Write the settings sections and wire the settings navigation.\"}, "
            + "{\"task\": \"" + tasks[2] + "\", \"prompt\": \"Take screenshots for every page.\"}]\n"
            + bq
        let answer = TimelineItem(turnID: turn.id, date: turn.startedAt.addingTimeInterval(10), content: .assistant(AssistantMessage(text: assistantText)))
        let checklist = TimelineItem(turnID: turn.id, date: turn.startedAt.addingTimeInterval(11), content: .todos([
            TodoStep(text: "Port the layout to the app's glass", status: .done),
            TodoStep(text: "Write the six pages and wire the settings navigation", status: .done),
            TodoStep(text: "Photograph every page over its backdrop", status: .active),
        ]))
        let names = ["Hank", "Walter", "Ada"]
        var tools: [TimelineItem] = []
        for index in 0..<3 {
            var call = ToolCall(kind: .agent, title: tasks[index], detail: "Delegated to \(names[index])")
            call.status = index == 0 ? .completed : .running
            call.startedAt = turn.startedAt.addingTimeInterval(TimeInterval(12 + index * 2))
            if index == 0 { call.finishedAt = turn.startedAt.addingTimeInterval(TimeInterval(60 + index * 20)) }
            tools.append(TimelineItem(id: "head-\(index)", turnID: turn.id, date: call.startedAt, content: .tool(call)))
        }
        let end = TimelineItem(turnID: turn.id, date: turn.completedAt!, content: .turnEnd(TurnSummary(
            turnID: turn.id, status: .completed, duration: 180, filesChanged: 0, additions: 0, deletions: 0)))
        let report = TimelineItem(turnID: nil, date: now.addingTimeInterval(-100), content: .user(UserMessage(
            text: "## Hank: Settings layout\nThe window pages cleanly and stays compact.\nThe layout lands every page centered.",
            hydraHeads: [0])))
        document.turns = [turn]
        document.items = [user, answer, checklist] + tools + [end, report]
        document.usage = ContextUsage(usedTokens: 12_000, windowTokens: 200_000)
        return document
    }

    private static func hydraWrite<Value: Encodable>(_ value: Value, to url: URL) {
        guard let data = try? JSONEncoder.storage.encode(value) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func hydraScene(_ model: AppModel, _ stage: Stage, _ recorder: Recorder) async {
        WebsiteCaptures.log("scene hydraScene")
        stage.setBackdrop(ProductCaptures.backdropView(.hydra))
        // 16:10 stage, sidebar hidden so the lead's conversation and the team's
        // panel fill the frame with the running heads centered and uncropped.
        stage.resize(to: NSSize(width: 960, height: 600))
        if model.sidebar.isVisible { model.sidebar.toggle() }
        let leadID = HydraID.lead
        model.selectedThreadID = leadID
        let runtime = model.runtime(for: leadID)
        runtime.rehearseHydraHead(toolID: "head-0", headID: HydraID.head0)
        runtime.rehearseHydraHead(toolID: "head-1", headID: HydraID.head1)
        runtime.rehearseHydraHead(toolID: "head-2", headID: HydraID.head2)
        // The app marks a head that was running when it last quit as stopped on launch;
        // Walter and Ada are at work in this picture.
        model.updateHydraHead(HydraID.head1) {
            $0.status = .running
            $0.finishedAt = nil
            $0.activity = "Wiring settings navigation"
        }
        model.updateThread(HydraID.head1) { $0.lastStatus = .running }
        model.updateHydraHead(HydraID.head2) {
            $0.status = .running
            $0.finishedAt = nil
            $0.activity = "Editing ProductCaptures.swift"
        }
        model.updateThread(HydraID.head2) { $0.lastStatus = .running }
        runtime.isHydraPanelHidden = false
        runtime.hydraSelectedHeadID = HydraID.head2
        runtime.hydraPanelDock = .bottomTrailing
        await stage.ensureActive()
        try? await Task.sleep(for: .seconds(2))
        // The whole window: the heads going out on the left and the team's panel on the
        // right are the picture together, and a crop on the panel alone lost the left.
        // The stage is narrow instead (see above), so everything draws large.
        await recorder.still("capture-hydra", stage.productCaptureRect)
        runtime.isHydraPanelHidden = true
    }

    /// The team panel and a detached head beside the lead conversation.
    static func panelsScene(_ model: AppModel, _ stage: Stage, _ recorder: Recorder) async {
        WebsiteCaptures.log("scene panelsScene")
        stage.setBackdrop(ProductCaptures.backdropView(.panels))
        // 16:10 stage, tall enough that the first message sits clear of the chrome
        // row's title and both floating panels stay centered and uncropped.
        stage.resize(to: NSSize(width: 1280, height: 800))
        if model.sidebar.isVisible { model.sidebar.toggle() }
        model.selectedThreadID = HydraID.lead
        let runtime = model.runtime(for: HydraID.lead)
        runtime.isDiffVisible = false
        runtime.isTerminalVisible = false
        model.updateHydraHead(HydraID.head1) {
            $0.status = .running
            $0.finishedAt = nil
            $0.activity = "Wiring settings navigation"
        }
        model.updateThread(HydraID.head1) { $0.lastStatus = .running }
        model.updateHydraHead(HydraID.head2) {
            $0.status = .running
            $0.finishedAt = nil
            $0.activity = "Editing ProductCaptures.swift"
        }
        model.updateThread(HydraID.head2) { $0.lastStatus = .running }
        runtime.isHydraPanelHidden = false
        runtime.hydraSelectedHeadID = HydraID.head2
        runtime.hydraPanelDock = .bottomTrailing
        runtime.hydraPoppedHeadID = HydraID.head0
        runtime.hydraPoppedPanelDock = .bottomLeading
        await stage.ensureActive()
        try? await Task.sleep(for: .seconds(2))
        await recorder.still("capture-panels", stage.productCaptureRect)
        runtime.hydraPoppedHeadID = nil
        runtime.isHydraPanelHidden = true
    }
}
#endif
