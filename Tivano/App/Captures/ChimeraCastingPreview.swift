#if DEBUG
import AppKit

/// `--website-captures <folder> --chimera-casting-preview`: click Casting to review
/// long roles, task text and an unassigned model in isolated storage.
@MainActor
enum ChimeraCastingPreview {
    nonisolated static var isRequested: Bool {
        CaptureRun.isEnabled && CommandLine.arguments.contains("--chimera-casting-preview")
    }

    private static var window: NSWindow?

    static func run(model: AppModel) async {
        await model.bootstrap()
        model.settings.hasSeenHydraIntro = true
        model.settings.theme = .system
        model.settings.alphaEnabled = true
        model.settings.alphaChimeraEnabled = true

        // Capture mode supplies installed status; use its seeded catalogs so every
        // prefilled pick passes the normal availability checks.
        let presets = [
            preset(model: model, provider: .claude, specialty: "存储架构调研与数据一致性分析"),
            preset(model: model, provider: .deepseek, specialty: "并发写入、异常恢复与边界条件审计"),
            preset(model: model, provider: .zai, specialty: "界面细节打磨与可访问性检查"),
        ]
        model.settings.chimeraPresets = presets
        let threadID = WebsiteCaptures.ID.composer
        model.updateThread(threadID) {
            $0.chimeraEnabled = true
            $0.hydraEnabled = false
        }
        model.selectedThreadID = threadID
        let window = WindowManager.shared.makeCaptureWindow(size: NSSize(width: 1200, height: 760))
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
        if !model.sidebar.isVisible { model.sidebar.toggle() }

        model.runtime(for: threadID).previewChimeraCasting(ChimeraCasting(batchID: UUID(), rows: [
            ChimeraCastingRow(
                id: UUID(), role: "存储层调研员", task: "调研 web-app 存储层结构",
                prefill: presets[0].pick
            ),
            ChimeraCastingRow(
                id: UUID(), role: "错误处理与边界条件审计员（重点关注并发写入与断电恢复）",
                task: "审查存储层在多个窗口同时编辑同一记录时的写入顺序、锁的作用范围和冲突处理方式，追踪保存中途断电、磁盘写满及权限变化后的恢复路径。重点核对临时文件替换是否原子化、事务失败能否完整回滚，以及重启后是否可能读取半写入的数据。为每个风险记录触发条件、受影响的数据和最小复现步骤，并区分已经确认的问题与仍需验证的假设，给出沿用现有架构的修复建议。",
                prefill: presets[1].pick
            ),
            ChimeraCastingRow(
                id: UUID(), role: "Frontend polish",
                task: "Tighten spacing and contrast on the settings sidebar and the casting card footer, matching existing Chrome components.",
                prefill: presets[2].pick
            ),
            ChimeraCastingRow(
                id: UUID(), role: "文档撰写", task: "把调研结论整理成一页 README",
                prefill: nil
            ),
            ChimeraCastingRow(
                id: UUID(), role: "性能剖析", task: "测量首次加载耗时", prefill: presets[0].pick
            ),
        ]))
    }

    private static func preset(model: AppModel, provider: ProviderKind, specialty: String) -> ChimeraPreset {
        model.settings.setEnabled(true, for: provider)
        let option = model.providers.models(for: provider).first
        return ChimeraPreset(specialty: specialty, pick: ChimeraPick(
            provider: provider, model: option?.id, effort: option?.defaultEffort
        ))
    }
}
#endif
