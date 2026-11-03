#if DEBUG
import AppKit

@MainActor
enum PredictionPreview {
    nonisolated static var isRequested: Bool {
        CaptureRun.isEnabled && CommandLine.arguments.contains("--prediction-preview")
    }

    struct Case {
        let id: UUID
        let title: String
        let reply: String
        let prediction: String

        var userText: String {
            switch title {
            case "1 短预测": return "导出的 JSON 里带了账号信息，帮我修一下。"
            case "2 一行内": return "帮我选一下会话导出的默认格式。"
            case "5 两行": return "导出功能首版怎么做？把边界也定一下。"
            case "6 超长截断": return "整理一份完整的会话导出实施方案。"
            case "7 English": return "Help me design conversation export for Tivano."
            default: return "帮我设计 Tivano 的会话导出功能"
            }
        }
    }

    static let cases: [Case] = [
        Case(id: WebsiteCaptures.ID.composer, title: "1 短预测", reply: """
        建议在导出转换层过滤账号字段。

        - 移除账号 ID 和邮箱。
        - 保留 provider 与模型名称，方便理解上下文。
        - 不改动本地保存的原始会话。

        这样分享文件时不会夹带账号信息，现有会话也不受影响。
        """, prediction: "就这么改吧。"),
        Case(id: UUID(uuidString: "C7000000-0000-4000-8000-000000000002")!, title: "2 一行内", reply: """
        推荐把 Markdown 作为默认导出格式。

        - 阅读和分享时不需要额外工具。
        - 代码块保持原有语言标记。
        - 工具结果只保留摘要，避免正文太长。
        - JSON 作为第二个选项，供后续处理。

        两种格式共用一份会话快照，确认后即可开始实施。
        """, prediction: "按推荐做，然后开 worktree 开始实施。"),
        Case(id: UUID(uuidString: "C7000000-0000-4000-8000-000000000003")!, title: "3 刚好换行",
             reply: reply,
             prediction: "按推荐做：附件不打包、顺带做复制 transcript、JSON 剔除账号字段，然后开 worktree 开始实施。"),
        Case(id: UUID(uuidString: "C7000000-0000-4000-8000-000000000004")!, title: "4 换行 +2 字",
             reply: reply,
             prediction: "按推荐做：附件不打包、顺带做复制 transcript、JSON 剔除账号字段，然后开 worktree 开始实施吧好。"),
        Case(id: UUID(uuidString: "C7000000-0000-4000-8000-000000000005")!, title: "5 两行", reply: """
        首版建议只覆盖当前会话，先把分享和归档做好。

        - 默认导出 Markdown，同时提供 JSON。
        - 附件只列文件名，不打包，也不暴露本地路径。
        - JSON 移除账号字段，保留模型和回合状态。
        - 复制 transcript 与文件导出共用转换逻辑。
        - 保存失败时显示错误，并允许重试。

        暂时不做批量导出；完成后用包含代码块和附件的会话验收。
        """, prediction: "按推荐方案实施：默认导出 Markdown，同时保留 JSON 选项；附件只列文件名，不打包也不暴露本地路径。复制 transcript 复用同一份转换逻辑，移除账号字段，补上保存失败后的重试提示，然后开 worktree 开始做。"),
        Case(id: UUID(uuidString: "C7000000-0000-4000-8000-000000000006")!, title: "6 超长截断", reply: """
        建议按数据转换、菜单入口和失败处理三个部分实施。

        - 只读取当前会话的快照，保持消息顺序。
        - Markdown 保留角色、时间与代码块。
        - JSON 加入版本号，保留回合状态和工具摘要。
        - 附件只列名称，不复制文件或导出本地路径。
        - 账号 ID、邮箱和凭证都不进入导出内容。
        - 复制 transcript 复用 Markdown 转换。
        - 使用系统保存面板，取消保存时不改变会话。
        - 保存失败保留上下文，提供重试入口。

        验收覆盖空会话、长代码块、中文、附件与工具失败。
        确认这些范围后，就可以开 worktree 分步实施。
        """, prediction: "按这份方案开始实施：首版只导出当前会话，默认使用 Markdown，同时提供带版本号的 JSON；保留角色、时间、消息顺序、代码块和工具结果摘要。附件只显示文件名，不打包、不复制，也不要暴露本地路径；账号 ID、邮箱和凭证全部剔除，保留模型信息。复制 transcript 与文件导出共用转换逻辑，读取固定快照，避免混入新消息。使用系统保存面板，取消时保持原状，失败时提供明确提示和重试入口。再覆盖空会话、长代码块、中文、附件和工具失败这些情况，完成后汇报改动与验证结果，现在开 worktree 开始做吧。"),
        Case(id: UUID(uuidString: "C7000000-0000-4000-8000-000000000007")!, title: "7 English", reply: """
        I recommend starting with export for a single conversation.

        - Make Markdown the default for reading and sharing.
        - Offer JSON for structured processing.
        - Include attachment names without bundling local files.
        - Remove account identifiers from the exported data.
        - Reuse the Markdown formatter for copying the transcript.
        - Use the system save panel and allow retrying failed saves.

        These defaults keep the first version focused and ready to implement.
        """, prediction: "Ship it with the recommended defaults, then open a worktree and start the export implementation.")
    ]

    private static var window: NSWindow?

    static func run(model: AppModel) async {
        await model.bootstrap()
        model.settings.hasSeenHydraIntro = true
        model.selectedThreadID = cases.first?.id
        let window = WindowManager.shared.makeCaptureWindow(size: NSSize(width: 1200, height: 800))
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
        if !model.sidebar.isVisible { model.sidebar.toggle() }
        model.settings.promptPredictionsEnabled = true
        if model.settings.textGeneration == .off { model.settings.textGeneration = .claude }
        for previewCase in cases {
            let runtime = model.runtime(for: previewCase.id)
            await runtime.ensureLoaded()
            runtime.promptPrediction = previewCase.prediction
        }
        try? await Task.sleep(for: .seconds(1))
        for previewCase in cases {
            model.runtime(for: previewCase.id).promptPrediction = previewCase.prediction
        }
    }

    static func history(for previewCase: Case, now: Date) -> ThreadDocument {
        var document = ThreadDocument(threadID: previewCase.id)
        var turn = TurnRecord(index: 0)
        turn.startedAt = now.addingTimeInterval(-60)
        turn.completedAt = now
        turn.status = .completed
        let user = TimelineItem(turnID: turn.id, date: turn.startedAt, content: .user(UserMessage(
            text: previewCase.userText)))
        turn.userItemID = user.id
        let answer = TimelineItem(turnID: turn.id, date: now.addingTimeInterval(-1), content: .assistant(AssistantMessage(text: previewCase.reply)))
        let end = TimelineItem(turnID: turn.id, date: now, content: .turnEnd(TurnSummary(
            turnID: turn.id, status: .completed, duration: 60, filesChanged: 0, additions: 0, deletions: 0)))
        document.turns = [turn]
        document.items = [user, answer, end]
        return document
    }

    private static let reply = """
    建议先做单场会话导出，入口放在会话菜单，覆盖分享和本地归档两种用途。

    ## 导出格式

    - **Markdown**：默认选项，保留角色、时间、代码块和工具结果摘要，适合阅读与分享。
    - **JSON**：保留消息顺序、回合状态和结构化工具结果，适合后续处理。
    - 两种格式都只导出当前会话，不包含其他会话或应用设置。

    附件先保留文件名与引用说明；本地路径不作为可分享链接。
    JSON 增加 `schemaVersion`，便于以后兼容字段变化。

    ## 实施落点

    - 在 `Tivano/Services/Export/ThreadExporter.swift` 实现格式转换，让导出逻辑独立于界面。
    - 从已加载的会话文档生成快照，避免导出时混入正在追加的消息。
    - 会话菜单提供 Markdown 和 JSON 入口，通过系统保存面板选择位置。
    - 保存失败时保留当前会话，并显示可重试的错误提示。
    - 复制整场 transcript 复用 Markdown 转换，避免两套内容规则。

    ## 待你拍板（各带推荐）

    1. **附件打包（建议不打包）**：首版只列附件说明，避免大文件和路径权限增加复杂度。
    2. **顺带做「复制整场 transcript」（建议做）**：分享时少一步保存文件，复用同一份导出内容。
    3. **JSON 剔除账号标识字段（建议剔除）**：保留 provider 与模型信息，移除账号 ID 等身份字段。

    确认方案后可直接开 worktree 排实施。
    """
}
#endif
