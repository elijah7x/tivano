#if DEBUG
import AppKit

@MainActor
enum QuotePreview {
    nonisolated static var isRequested: Bool {
        CaptureRun.isEnabled && CommandLine.arguments.contains("--quote-preview")
    }

    private static var window: NSWindow?

    static func run(model: AppModel) async {
        await model.bootstrap()
        model.settings.hasSeenHydraIntro = true
        model.settings.theme = .cursor
        model.selectedThreadID = WebsiteCaptures.ID.composer
        let window = WindowManager.shared.makeCaptureWindow(size: NSSize(width: 1200, height: 800))
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
        if !model.sidebar.isVisible { model.sidebar.toggle() }
    }

    static func history(_ now: Date) -> ThreadDocument {
        var document = ThreadDocument(threadID: WebsiteCaptures.ID.composer)
        var turn = TurnRecord(index: 0)
        turn.startedAt = now.addingTimeInterval(-60)
        turn.completedAt = now
        turn.status = .completed
        let user = TimelineItem(turnID: turn.id, date: turn.startedAt, content: .user(UserMessage(
            text: "为什么我这里突然产生了一个Hydra-3的文件夹")))
        turn.userItemID = user.id
        let answer = TimelineItem(turnID: turn.id, date: now.addingTimeInterval(-1), content: .assistant(AssistantMessage(text: reply)))
        let end = TimelineItem(turnID: turn.id, date: now, content: .turnEnd(TurnSummary(
            turnID: turn.id, status: .completed, duration: 60, filesChanged: 0, additions: 0, deletions: 0)))
        document.turns = [turn]
        document.items = [user, answer, end]
        return document
    }

    private static let reply = """
    **这两个文件夹是怎么来的**

    lead 用 `"project": "<绝对路径>"` 把 head 派到了侧栏里还没有的目录。`Tivano/App/AppModel+Hydra.swift` 里 `routeHydraHead` 的规则写得很明确（约 480 行）：

    > Linked Git worktrees reuse their repository's project; other Git and non-Git folders join the sidebar.

    也就是说，指向另一个仓库或普通文件夹时，Tivano 会自动把它注册成侧栏项目。这是当时有意保留的行为。

    | 侧栏项目 | 路径 | 加入时间（北京时间） | 来源 |
    |---|---|---|---|
    | hydra-v3 | `…/tivano/promo/video/hydra-v3` | 10-29 21:57 | 宣传片任务；它是一个独立的 Git 仓库 |
    | tivano（第二个） | `…/forked/tivano`（源码仓库外面那层父目录，不是 Git 仓库） | 10-29 23:32 | 官网任务 |

    > 第二段引用：用来确认多行引用
    > 在深色主题下也清楚可读。
    """
}
#endif
