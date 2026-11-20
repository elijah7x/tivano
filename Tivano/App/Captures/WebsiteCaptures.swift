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
        static let mentionDemoProject = UUID(uuidString: "A0000000-0000-4000-8000-000000000020")!
        static let mentionDemoThread = UUID(uuidString: "B0000000-0000-4000-8000-000000000020")!
        static let reviewDemoProject = UUID(uuidString: "A0000000-0000-4000-8000-000000000021")!
        static let reviewDemoThread = UUID(uuidString: "B0000000-0000-4000-8000-000000000021")!
        static let reviewDemoFailedThread = UUID(uuidString: "B0000000-0000-4000-8000-000000000022")!
    }

    /// Writes the library, the thread histories and the project folders the run opens, and
    /// resets the run's defaults. Called before anything reads settings or the library.
    static func prepare() {
        guard let output = CaptureRun.outputDirectory, let root = CaptureRun.storageRoot, let defaults = CaptureRun.defaults else { return }
        let files = FileManager.default
        try? files.removeItem(at: root)
        try? files.createDirectory(at: root.appendingPathComponent("threads"), withIntermediateDirectories: true)
        try? files.createDirectory(at: output, withIntermediateDirectories: true)

        defaults.removePersistentDomain(forName: CaptureRun.suiteName)
        // `--blank-home`: a fresh install, so no settings and no library at all.
        if CommandLine.arguments.contains("--blank-home") {
            defaults.synchronize()
            return
        }
        let isMentionDemo = CommandLine.arguments.contains("--mention-demo")
        let isReviewDemo = CommandLine.arguments.contains("--review-demo")
        defaults.set("system", forKey: "appTheme")
        defaults.set("dark", forKey: "appearanceMode")
        defaults.set(false, forKey: "chimeWhenFinished")
        defaults.set(true, forKey: "showReasoning")
        defaults.set(true, forKey: "sidebarActivityView")
        defaults.set("supervised", forKey: "defaultRuntimeMode")
        defaults.set("claude", forKey: "defaultProvider")
        let initialProjectID = isReviewDemo ? ID.reviewDemoProject : (isMentionDemo ? ID.mentionDemoProject : ID.tivanoApp)
        defaults.set(initialProjectID.uuidString, forKey: "lastProjectID")
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
        }
        let repos = output.appendingPathComponent("repos", isDirectory: true)
        if isMentionDemo {
            var library = Library()
            library.projects = [
                project(ID.mentionDemoProject, "星河笔记", repos, mentionDemoFiles),
            ]
            let now = Date.now
            library.threads = [
                thread(ID.mentionDemoThread, ID.mentionDemoProject, "新手引导文案", .claude, "opus", "high", age: 180, status: .completed, now),
            ]
            write(library, to: root.appendingPathComponent("library.json"))
            write(mentionDemoHistory(now), to: root.appendingPathComponent("threads/\(ID.mentionDemoThread.uuidString).json"))
            return
        }
        if isReviewDemo {
            var library = Library()
            library.projects = [
                project(ID.reviewDemoProject, "星河笔记", repos, reviewDemoFiles),
            ]
            let now = Date.now
            var failedThread = thread(
                ID.reviewDemoFailedThread, ID.reviewDemoProject, "独立审查中断示例",
                .claude, "opus", "high", age: 3_600, status: .completed, now
            )
            failedThread.providerSessionID = "review-demo-failed-session"
            library.threads = [
                thread(ID.reviewDemoThread, ID.reviewDemoProject, "导出功能修复", .claude, "opus", "high", age: 180, status: .completed, now),
                failedThread,
            ]
            write(library, to: root.appendingPathComponent("library.json"))
            write(reviewDemoHistory(now), to: root.appendingPathComponent("threads/\(ID.reviewDemoThread.uuidString).json"))
            write(reviewDemoFailedHistory(now), to: root.appendingPathComponent("threads/\(ID.reviewDemoFailedThread.uuidString).json"))
            return
        }
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
        let answer = TimelineItem(turnID: turn.id, date: turn.startedAt.addingTimeInterval(6), content: .assistant(AssistantMessage(
            text: "Three things, and I would keep them small: tag the final text so the timeline knows which block is the answer, give that block the glass card the plan cards already use, and leave streaming text plain so nothing flickers while it arrives.")))
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

    private static let mentionDemoFiles: [String: String] = [
        "Docs/产品/新手引导/欢迎.md": """
            # 欢迎来到星河笔记

            ## 第一节：创建你的第一条笔记
            按下快捷键即可随时记下想法，无需先想好分类。

            ## 第二节：快速构建个人知识库
            使用双向链接和标签整理零散内容，让每次记录都能在需要时被重新发现。

            """,
        "Docs/营销/欢迎.md": """
            # 星河笔记，让好想法不再走丢

            轻巧、顺手的跨端笔记工具，从随手记一笔到系统整理项目资料都能胜任。

            """,
        "Docs/Q4 规划.md": """
            # Q4 产品规划

            - 优化首次打开的新手引导体验，缩短上手路径
            - 上线移动端离线同步与快速搜索
            - 统一产品文档与官网营销页的语气风格

            """,
        "Docs/会议纪要/2026-11-18 周会.md": """
            # 2026-11-18 产品周会纪要

            - 新手引导文案将在本周完成口语化改写
            - 前端同步更新欢迎页顶部导航和主按钮文案

            """,
        "src/components/Header.tsx": """
            import React from "react";

            export function Header({ title = "星河笔记" }: { title?: string }) {
              return (
                <header className="app-header">
                  <h1>{title}</h1>
                </header>
              );
            }

            """,
        "src/components/Button.tsx": """
            import React from "react";

            type ButtonProps = {
              label: string;
              onClick?: () => void;
            };

            export function Button({ label, onClick }: ButtonProps) {
              return <button onClick={onClick}>{label}</button>;
            }

            """,
        "src/pages/welcome.tsx": """
            import React from "react";
            import { Header } from "../components/Header";
            import { Button } from "../components/Button";

            export function WelcomePage() {
              return (
                <main>
                  <Header title="欢迎使用星河笔记" />
                  <Button label="开始记第一笔" />
                </main>
              );
            }

            """,
        "README.md": """
            # 星河笔记

            一款面向个人与小团队的轻量知识笔记应用。

            """,
        "package.json": """
            {
              "name": "xinghe-notes",
              "version": "0.4.0",
              "private": true
            }

            """,
    ]

    /// The mention-demo thread: one finished Chinese exchange.
    private static func mentionDemoHistory(_ now: Date) -> ThreadDocument {
        var document = ThreadDocument(threadID: ID.mentionDemoThread)
        var turn = TurnRecord(index: 0)
        turn.startedAt = now.addingTimeInterval(-240)
        turn.completedAt = now.addingTimeInterval(-180)
        turn.status = .completed
        let user = TimelineItem(turnID: turn.id, date: turn.startedAt, content: .user(UserMessage(
            text: "把新手引导第二节改得更口语一点")))
        turn.userItemID = user.id
        let answer = TimelineItem(turnID: turn.id, date: turn.startedAt.addingTimeInterval(6), content: .assistant(AssistantMessage(
            text: "好，我把第二节里的“快速构建个人知识库”改成了更自然的“随手记下灵感，慢慢长成你的知识库”，读起来会轻快很多。按钮文案也顺手收短了一点，方便新用户一眼看懂下一步。你可以先看看整体语气，有想再调整的地方直接告诉我。")))
        let end = TimelineItem(turnID: turn.id, date: turn.completedAt!, content: .turnEnd(TurnSummary(
            turnID: turn.id, status: .completed, duration: 14, filesChanged: 0, additions: 0, deletions: 0)))
        document.turns = [turn]
        document.items = [user, answer, end]
        document.usage = ContextUsage(usedTokens: 6_400, windowTokens: 200_000)
        return document
    }

    private static let reviewDemoFiles: [String: String] = [
        "src/export/imagePathResolver.ts": """
            import path from "node:path";

            export function resolveImagePath(rawSrc: string, noteDir: string, assetsDir: string): string {
              if (/^(https?:|data:)/i.test(rawSrc)) return rawSrc;
              const decoded = decodeURIComponent(rawSrc.trim());
              const absolute = path.resolve(noteDir, decoded);
              const relative = path.relative(assetsDir, absolute).split(path.sep).join("/");
              return relative.split("/").map(encodeURIComponent).join("/");
            }

            """,
        "src/export/markdownExporter.ts": """
            import path from "node:path";
            import { copyExportAsset } from "./assetCopier";
            import { resolveImagePath } from "./imagePathResolver";

            export async function exportMarkdown(markdown: string, notePath: string, outDir: string): Promise<string> {
              const noteDir = path.dirname(notePath);
              const assetsDir = path.join(outDir, "assets");
              const matches = [...markdown.matchAll(/!\\[([^\\]]*)\\]\\(([^)]+)\\)/g)];
              let result = markdown;
              for (const match of matches) {
                const src = match[2];
                if (/^(https?:|data:)/i.test(src)) continue;
                const copied = await copyExportAsset(path.resolve(noteDir, decodeURIComponent(src)), assetsDir);
                const rewritten = resolveImagePath(copied, noteDir, outDir);
                result = result.replace(match[0], `![${match[1]}](${rewritten})`);
              }
              return result;
            }

            """,
        "src/export/assetCopier.ts": """
            import crypto from "node:crypto";
            import fs from "node:fs/promises";
            import path from "node:path";

            export async function copyExportAsset(sourcePath: string, assetsDir: string): Promise<string> {
              await fs.mkdir(assetsDir, { recursive: true });
              const data = await fs.readFile(sourcePath);
              const parsed = path.parse(sourcePath);
              let target = path.join(assetsDir, parsed.base);
              try {
                const existing = await fs.readFile(target);
                if (!existing.equals(data)) {
                  const hash = crypto.createHash("sha256").update(data).digest("hex").slice(0, 8);
                  target = path.join(assetsDir, `${parsed.name}-${hash}${parsed.ext}`);
                }
              } catch {
                // Destination does not exist yet.
              }
              await fs.writeFile(target, data);
              return target;
            }

            """,
        "README.md": """
            # 星河笔记

            一款面向个人与小团队的轻量知识笔记应用。

            """,
        "package.json": """
            {
              "name": "xinghe-notes",
              "version": "0.4.0",
              "private": true
            }

            """,
    ]

    private static let reviewDemoTurn0Patch = """
    diff --git a/src/export/imagePathResolver.ts b/src/export/imagePathResolver.ts
    --- a/src/export/imagePathResolver.ts
    +++ b/src/export/imagePathResolver.ts
    @@ -1,4 +1,6 @@
     import path from "node:path";
    -export function resolveImagePath(rawSrc: string, assetsDir: string): string {
    -  return path.join(assetsDir, rawSrc);
    +export function resolveImagePath(rawSrc: string, noteDir: string, assetsDir: string): string {
    +  if (/^(https?:|data:)/i.test(rawSrc)) return rawSrc;
    +  const absolute = path.resolve(noteDir, rawSrc);
    +  return path.relative(assetsDir, absolute).split(path.sep).join("/");
     }
    diff --git a/src/export/markdownExporter.ts b/src/export/markdownExporter.ts
    --- a/src/export/markdownExporter.ts
    +++ b/src/export/markdownExporter.ts
    @@ -10,6 +10,6 @@ export async function exportMarkdown(markdown: string, notePath: string, outDir:
       for (const match of matches) {
         const src = match[2];
         if (/^(https?:|data:)/i.test(src)) continue;
    -    const rewritten = resolveImagePath(src, outDir);
    +    const rewritten = resolveImagePath(src, path.dirname(notePath), outDir);
         result = result.replace(match[0], `![${match[1]}](${rewritten})`);
       }
    """

    private static let reviewDemoTurn1Patch = """
    diff --git a/src/export/imagePathResolver.ts b/src/export/imagePathResolver.ts
    --- a/src/export/imagePathResolver.ts
    +++ b/src/export/imagePathResolver.ts
    @@ -3,5 +3,7 @@ import path from "node:path";
     export function resolveImagePath(rawSrc: string, noteDir: string, assetsDir: string): string {
       if (/^(https?:|data:)/i.test(rawSrc)) return rawSrc;
    -  const absolute = path.resolve(noteDir, rawSrc);
    -  return path.relative(assetsDir, absolute).split(path.sep).join("/");
    +  const decoded = decodeURIComponent(rawSrc.trim());
    +  const absolute = path.resolve(noteDir, decoded);
    +  const relative = path.relative(assetsDir, absolute).split(path.sep).join("/");
    +  return relative.split("/").map(encodeURIComponent).join("/");
     }
    diff --git a/src/export/assetCopier.ts b/src/export/assetCopier.ts
    --- a/src/export/assetCopier.ts
    +++ b/src/export/assetCopier.ts
    @@ -6,5 +6,14 @@ export async function copyExportAsset(sourcePath: string, assetsDir: string): Pr
       const data = await fs.readFile(sourcePath);
       const parsed = path.parse(sourcePath);
       let target = path.join(assetsDir, parsed.base);
    +  try {
    +    const existing = await fs.readFile(target);
    +    if (!existing.equals(data)) {
    +      const hash = crypto.createHash("sha256").update(data).digest("hex").slice(0, 8);
    +      target = path.join(assetsDir, `${parsed.name}-${hash}${parsed.ext}`);
    +    }
    +  } catch {
    +    // Destination does not exist yet.
    +  }
       await fs.writeFile(target, data);
       return target;
     }
    diff --git a/src/export/markdownExporter.ts b/src/export/markdownExporter.ts
    --- a/src/export/markdownExporter.ts
    +++ b/src/export/markdownExporter.ts
    @@ -11,5 +11,6 @@ export async function exportMarkdown(markdown: string, notePath: string, outDir:
         const src = match[2];
         if (/^(https?:|data:)/i.test(src)) continue;
    -    const rewritten = resolveImagePath(src, path.dirname(notePath), outDir);
    +    const copied = await copyExportAsset(path.resolve(noteDir, decodeURIComponent(src)), assetsDir);
    +    const rewritten = resolveImagePath(copied, noteDir, outDir);
         result = result.replace(match[0], `![${match[1]}](${rewritten})`);
       }
    """

    /// The review-demo main thread: a normal fix turn, a folded Hydra independent-review turn
    /// with 4 findings and mixed verdicts, and a short follow-up turn below it.
    private static func reviewDemoHistory(_ now: Date) -> ThreadDocument {
        var document = ThreadDocument(threadID: ID.reviewDemoThread)

        // Turn 0: normal exchange fixing Markdown image export paths.
        var turn0 = TurnRecord(index: 0)
        turn0.startedAt = now.addingTimeInterval(-1_200)
        turn0.completedAt = now.addingTimeInterval(-1_082)
        turn0.status = .completed
        turn0.providerDiff = reviewDemoTurn0Patch
        let user0 = TimelineItem(turnID: turn0.id, date: turn0.startedAt, content: .user(UserMessage(
            text: "导出 Markdown 时图片路径会错，帮我修一下")))
        turn0.userItemID = user0.id
        var cmd0 = ToolCall(kind: .command, title: "rg -n \"resolveImagePath\" src/export", detail: nil)
        cmd0.status = .completed
        cmd0.exitCode = 0
        cmd0.output = "src/export/imagePathResolver.ts:3:export function resolveImagePath(rawSrc: string, assetsDir: string): string {\nsrc/export/markdownExporter.ts:13:    const rewritten = resolveImagePath(src, outDir);\n"
        cmd0.startedAt = turn0.startedAt.addingTimeInterval(6)
        cmd0.finishedAt = turn0.startedAt.addingTimeInterval(8)
        let tool0Cmd = TimelineItem(turnID: turn0.id, date: cmd0.startedAt, content: .tool(cmd0))
        var edit0 = ToolCall(kind: .edit, title: "Edit", detail: "src/export/imagePathResolver.ts")
        edit0.status = .completed
        edit0.edits = [
            FileEdit(path: "src/export/imagePathResolver.ts", diff: reviewDemoTurn0Patch, additions: 18, deletions: 6),
        ]
        edit0.startedAt = turn0.startedAt.addingTimeInterval(24)
        edit0.finishedAt = turn0.startedAt.addingTimeInterval(30)
        let tool0Edit = TimelineItem(turnID: turn0.id, date: edit0.startedAt, content: .tool(edit0))
        let answer0 = TimelineItem(turnID: turn0.id, date: turn0.startedAt.addingTimeInterval(96), content: .assistant(AssistantMessage(
            text: "已修复导出时的图片路径拼接问题。原来 `resolveImagePath` 直接把图片名拼在导出目录后，忽略了笔记所在子目录并保留了平台分隔符；现在改为先按笔记目录解析再计算相对路径并统一为 POSIX 斜杠。你导出嵌套目录里的笔记时，图片链接会正确指向导出后的资源位置。")))
        let changes0 = FileChangeSummary(
            files: [
                FileChangeSummary.File(path: "src/export/imagePathResolver.ts", additions: 18, deletions: 6, isBinary: false),
                FileChangeSummary.File(path: "src/export/markdownExporter.ts", additions: 8, deletions: 3, isBinary: false),
            ],
            additions: 26,
            deletions: 9
        )
        let end0 = TimelineItem(turnID: turn0.id, date: turn0.completedAt!, content: .turnEnd(TurnSummary(
            turnID: turn0.id, status: .completed, duration: 118, filesChanged: 2, additions: 26, deletions: 9, changes: changes0)))

        // Turn 1: Hydra independent review turn.
        var turn1 = TurnRecord(index: 1)
        turn1.startedAt = now.addingTimeInterval(-780)
        turn1.completedAt = now.addingTimeInterval(-378)
        turn1.status = .completed
        turn1.providerDiff = reviewDemoTurn1Patch
        let reviewFindings = """
        Finding 1: src/export/imagePathResolver.ts:42 — Image filenames containing spaces or non-ASCII characters are returned raw without percent-encoding, breaking CommonMark image links (`![alt](assets/架构 图.png)`). Percent-encode each path segment after normalizing separators.
        Finding 2: src/export/markdownExporter.ts:88 — External `https://` and inline `data:` image URLs may be passed into the local asset rewriter and mangled into broken relative paths. Short-circuit remote and data URIs before rewriting.
        Finding 3: src/export/imagePathResolver.ts:67 — Relative image paths such as `./assets/diagram.png` inside nested note folders are resolved against the workspace root instead of the source note's directory, causing missing-file errors on export. Resolve relative paths against `noteDir`.
        Finding 4: src/export/assetCopier.ts:53 — Exporting two notes that each reference a different `cover.png` overwrites the first image in `outDir/assets/cover.png` silently. Detect content collisions and append a short content hash suffix while returning the final path to the exporter.
        """
        let user1 = TimelineItem(turnID: turn1.id, date: turn1.startedAt, content: .user(UserMessage(
            text: HydraPrompts.v2ReviewMessage(reviewer: "Codex GPT-6.2-Sol · Medium", findings: reviewFindings),
            hydraHeads: [])))
        turn1.userItemID = user1.id
        let narration1 = TimelineItem(turnID: turn1.id, date: turn1.startedAt.addingTimeInterval(14), content: .assistant(AssistantMessage(
            text: "Let me check how the exporter resolves relative paths:")))
        var cmd1Read = ToolCall(kind: .command, title: "sed -n '35,85p' src/export/imagePathResolver.ts", detail: nil)
        cmd1Read.status = .completed
        cmd1Read.exitCode = 0
        cmd1Read.output = "35: export function resolveImagePath(rawSrc: string, noteDir: string, assetsDir: string): string {\n36:   if (/^(https?:|data:)/i.test(rawSrc)) return rawSrc;\n42:   return path.relative(assetsDir, absolute).split(path.sep).join(\"/\");\n67:   const absolute = path.resolve(workspaceRoot, rawSrc);\n"
        cmd1Read.startedAt = turn1.startedAt.addingTimeInterval(22)
        cmd1Read.finishedAt = turn1.startedAt.addingTimeInterval(25)
        let tool1Read = TimelineItem(turnID: turn1.id, date: cmd1Read.startedAt, content: .tool(cmd1Read))
        var edit1 = ToolCall(kind: .edit, title: "Edit", detail: "src/export/imagePathResolver.ts · relative path, encoding & collision handling")
        edit1.status = .completed
        edit1.edits = [
            FileEdit(path: "src/export/imagePathResolver.ts", diff: reviewDemoTurn1Patch, additions: 64, deletions: 11),
            FileEdit(path: "src/export/assetCopier.ts", diff: reviewDemoTurn1Patch, additions: 52, deletions: 7),
            FileEdit(path: "src/export/markdownExporter.ts", diff: reviewDemoTurn1Patch, additions: 25, deletions: 4),
        ]
        edit1.startedAt = turn1.startedAt.addingTimeInterval(120)
        edit1.finishedAt = turn1.startedAt.addingTimeInterval(165)
        let tool1Edit = TimelineItem(turnID: turn1.id, date: edit1.startedAt, content: .tool(edit1))
        var cmd1Test = ToolCall(kind: .command, title: "npm test -- src/export", detail: nil)
        cmd1Test.status = .completed
        cmd1Test.exitCode = 0
        cmd1Test.output = "PASS src/export/imagePathResolver.test.ts\nPASS src/export/assetCopier.test.ts\nPASS src/export/markdownExporter.test.ts\nTest Suites: 3 passed, 3 total\nTests:       14 passed, 14 total\n"
        cmd1Test.startedAt = turn1.startedAt.addingTimeInterval(250)
        cmd1Test.finishedAt = turn1.startedAt.addingTimeInterval(310)
        let tool1Test = TimelineItem(turnID: turn1.id, date: cmd1Test.startedAt, content: .tool(cmd1Test))
        let verdicts1 = TimelineItem(turnID: turn1.id, date: turn1.startedAt.addingTimeInterval(345), content: .assistant(AssistantMessage(
            text: """
            Finding 1: accepted - 对包含空格和中文的文件名补上了分段百分比编码，导出后的 Markdown 图片链接不再被空格截断。
            Finding 2: rejected - 远程 `https://` 与内联 `data:` 链接在 `markdownExporter.ts:84` 已经提前短路跳过，不会进入本地资源改写流程。
            Finding 3: accepted - **相对路径** 改为基于文档目录解析，确保嵌套子目录笔记里的 `./assets/...` 不会错误落到仓库根目录。
            Finding 4: accepted - 资源拷贝器检测到同名异内容图片时改为追加 8 位内容哈希后缀，并把最终文件名回写到导出链接，避免互相覆盖。
            """)))
        let summary1 = TimelineItem(turnID: turn1.id, date: turn1.startedAt.addingTimeInterval(372), content: .assistant(AssistantMessage(
            text: "独立审查提出的 4 项问题已核对完毕，采纳 3 项并驳回 1 项。已补齐分段路径编码、按笔记目录解析相对路径以及同名资源哈希去重，导出模块全部 14 项测试通过。")))
        let changes1 = FileChangeSummary(
            files: [
                FileChangeSummary.File(path: "src/export/imagePathResolver.ts", additions: 64, deletions: 11, isBinary: false),
                FileChangeSummary.File(path: "src/export/assetCopier.ts", additions: 52, deletions: 7, isBinary: false),
                FileChangeSummary.File(path: "src/export/markdownExporter.ts", additions: 25, deletions: 4, isBinary: false),
            ],
            additions: 141,
            deletions: 22
        )
        let end1 = TimelineItem(turnID: turn1.id, date: turn1.completedAt!, content: .turnEnd(TurnSummary(
            turnID: turn1.id, status: .completed, duration: 402, filesChanged: 3, additions: 141, deletions: 22, changes: changes1)))

        // Turn 2: short normal follow-up after the review card.
        var turn2 = TurnRecord(index: 2)
        turn2.startedAt = now.addingTimeInterval(-220)
        turn2.completedAt = now.addingTimeInterval(-180)
        turn2.status = .completed
        let user2 = TimelineItem(turnID: turn2.id, date: turn2.startedAt, content: .user(UserMessage(
            text: "如果笔记里引用了外链图片，导出时还会下载到本地吗？")))
        turn2.userItemID = user2.id
        let answer2 = TimelineItem(turnID: turn2.id, date: turn2.startedAt.addingTimeInterval(12), content: .assistant(AssistantMessage(
            text: "不会。`http://`、`https://` 和内联 `data:` 图片在路径改写前就会直接跳过，导出后的 Markdown 会原样保留外链地址，只拷贝并重排本地图片文件。")))
        let end2 = TimelineItem(turnID: turn2.id, date: turn2.completedAt!, content: .turnEnd(TurnSummary(
            turnID: turn2.id, status: .completed, duration: 14, filesChanged: 0, additions: 0, deletions: 0)))

        document.turns = [turn0, turn1, turn2]
        document.items = [
            user0, tool0Cmd, tool0Edit, answer0, end0,
            user1, narration1, tool1Read, tool1Edit, tool1Test, verdicts1, summary1, end1,
            user2, answer2, end2,
        ]
        document.usage = ContextUsage(usedTokens: 34_200, windowTokens: 200_000)
        return document
    }

    /// The review-demo failed thread: a normal exchange followed by an independent-review turn
    /// that failed with only an error notice and no process steps.
    private static func reviewDemoFailedHistory(_ now: Date) -> ThreadDocument {
        var document = ThreadDocument(threadID: ID.reviewDemoFailedThread)

        // Turn 0: normal exchange.
        var turn0 = TurnRecord(index: 0)
        turn0.startedAt = now.addingTimeInterval(-4_200)
        turn0.completedAt = now.addingTimeInterval(-4_148)
        turn0.status = .completed
        let user0 = TimelineItem(turnID: turn0.id, date: turn0.startedAt, content: .user(UserMessage(
            text: "给导出任务加上进度回调，方便界面显示百分比")))
        turn0.userItemID = user0.id
        let answer0 = TimelineItem(turnID: turn0.id, date: turn0.startedAt.addingTimeInterval(38), content: .assistant(AssistantMessage(
            text: "已为 `exportMarkdown` 新增可选的 `onProgress` 回调，每处理完一张资源图片就会上报已完成数量与总数，未传回调时保持原有行为不变。")))
        let end0 = TimelineItem(turnID: turn0.id, date: turn0.completedAt!, content: .turnEnd(TurnSummary(
            turnID: turn0.id, status: .completed, duration: 52, filesChanged: 0, additions: 0, deletions: 0)))

        // Turn 1: failed review turn with only an error notice and no steps.
        var turn1 = TurnRecord(index: 1)
        turn1.startedAt = now.addingTimeInterval(-3_720)
        turn1.completedAt = now.addingTimeInterval(-3_600)
        turn1.status = .failed
        let failedFindings = """
        Finding 1: src/export/markdownExporter.ts:31 — When a note has zero images, `total` is `0` and `onProgress` receives `completed / total` (`NaN`), stalling the progress bar. Emit a single completion event `(1, 1)` or guard against `total === 0`.
        Finding 2: src/export/assetCopier.ts:19 — Progress callbacks fire before `fs.writeFile` finishes, so a failed copy can report 100% completion. Advance the counter only after the write resolves.
        """
        let user1 = TimelineItem(turnID: turn1.id, date: turn1.startedAt, content: .user(UserMessage(
            text: HydraPrompts.v2ReviewMessage(reviewer: "Claude Opus · High", findings: failedFindings),
            hydraHeads: [])))
        turn1.userItemID = user1.id
        let notice1 = TimelineItem(turnID: turn1.id, date: turn1.startedAt.addingTimeInterval(118), content: .notice(Notice(
            level: .error,
            message: "与模型服务的连接在响应前中断（upstream stream reset），本次独立审查未能完成处理。")))
        let end1 = TimelineItem(turnID: turn1.id, date: turn1.completedAt!, content: .turnEnd(TurnSummary(
            turnID: turn1.id, status: .failed, duration: 120, filesChanged: 0, additions: 0, deletions: 0)))

        document.turns = [turn0, turn1]
        document.items = [user0, answer0, end0, user1, notice1, end1]
        document.usage = ContextUsage(usedTokens: 12_800, windowTokens: 200_000)
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

    private static var blankHomeWindow: NSWindow?
    private static var mentionDemoWindow: NSWindow?
    private static var reviewDemoWindow: NSWindow?

    static func run(model: AppModel) async {
        if WeatherPreview.isPreviewRequested {
            await WeatherPreview.runPreview(model: model)
            return
        }
        if WeatherPreview.isCapturesRequested {
            await WeatherPreview.runCaptures(model: model)
            return
        }
        // Interactive: an empty isolated library left open, to look at the blank first launch.
        if CaptureRun.isEnabled, CommandLine.arguments.contains("--blank-home") {
            await model.bootstrap()
            let window = WindowManager.shared.makeCaptureWindow(size: NSSize(width: 1280, height: 800))
            window.center()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            blankHomeWindow = window
            return
        }
        // Interactive: one seeded project and thread with inline @file mention chips in the composer.
        if CaptureRun.isEnabled, CommandLine.arguments.contains("--mention-demo") {
            await model.bootstrap()
            model.settings.hasSeenHydraIntro = true
            model.selectedThreadID = ID.mentionDemoThread
            model.runtime(for: ID.mentionDemoThread).draft.text =
                "帮我看下 @Docs/产品/新手引导/欢迎.md 第二节的措辞，再对照 @Docs/营销/欢迎.md 和 @src/components/Header.tsx 的写法，顺便参考 @Docs/Q4 规划.md "
            let window = WindowManager.shared.makeCaptureWindow(size: NSSize(width: 1280, height: 800))
            window.center()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            mentionDemoWindow = window
            return
        }
        // Interactive: one seeded project and two threads showcasing the folded Hydra independent-review card.
        if CaptureRun.isEnabled, CommandLine.arguments.contains("--review-demo") {
            await model.bootstrap()
            model.settings.hasSeenHydraIntro = true
            model.selectedThreadID = ID.reviewDemoThread
            let window = WindowManager.shared.makeCaptureWindow(size: NSSize(width: 1280, height: 900))
            window.center()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            reviewDemoWindow = window
            return
        }
        if CaptureRun.isEnabled, CommandLine.arguments.contains("--hydra-panels-preview") {
            await ProductCaptures.panelsPreview(model: model)
            return
        }
        if CaptureRun.isEnabled, CommandLine.arguments.contains("--dsh-routes-preview") {
            await ProductCaptures.dshRoutesPreview(model: model)
            return
        }
        if CaptureRun.isEnabled, CommandLine.arguments.contains("--settings-page-preview") {
            await ProductCaptures.settingsPagePreview(model: model)
            return
        }
        if CaptureRun.isEnabled, CommandLine.arguments.contains("--history-scroll") {
            await TimelineStress.runHistory(model: model)
            return
        }
        if CaptureRun.isEnabled, CommandLine.arguments.contains("--history-flick") {
            await TimelineStress.runHistoryFlick(model: model)
            return
        }
        if CaptureRun.isEnabled, [
            "--mid-scroll",
            "--mid-scroll-cold",
            "--mid-scroll-history",
            "--mid-scroll-mix",
            "--mid-scroll-resize",
            "--mid-scroll-serif",
        ].contains(where: CommandLine.arguments.contains) {
            await TimelineStress.runMidScroll(model: model)
            return
        }
        if CaptureRun.isEnabled, CommandLine.arguments.contains("--held-drag") {
            await TimelineStress.runHeldDrag(model: model)
            return
        }
        if CaptureRun.isEnabled, CommandLine.arguments.contains("--fold-repro") {
            await FoldReplyRepro.run(model: model)
            return
        }
        if CaptureRun.isEnabled, CommandLine.arguments.contains("--subagent-panel-loop") {
            await TimelineStress.runSubagentPanelLoop(model: model)
            return
        }
        if CaptureRun.isEnabled, CommandLine.arguments.contains("--subagent-pill-demo") {
            await TimelineStress.runSubagentPillDemo(model: model)
            return
        }
        if CaptureRun.isEnabled, CommandLine.arguments.contains("--split-reply-demo") {
            await TimelineStress.runSplitReplyDemo(model: model)
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

    /// Rehearses a complete local turn for interactive `--blank-home` previews: reasoning,
    /// a read tool call, a streamed Chinese markdown answer, and normal turn completion.
    static func rehearseReply(to text: String, runtime: ThreadRuntime) async {
        let prefix = UUID().uuidString.prefix(8)
        let reasoningID = "\(prefix)-r"
        let readID = "\(prefix)-read"
        let messageID = "\(prefix)-m"

        runtime.rehearseTurn(text)
        runtime.rehearseTitle(text)
        let turn = runtime.rehearsalTurnID
        let live = { runtime.isRunning && runtime.rehearsalTurnID == turn }
        try? await Task.sleep(for: .milliseconds(350))
        guard live() else { return }

        await stream(
            runtime,
            id: reasoningID,
            reasoning: true,
            alive: live,
            "正在理解你的请求，并快速检查当前工作区的上下文。确认目标后，我会整理一份清晰的处理步骤与演示回复。",
            step: 35
        )
        guard live() else { return }
        runtime.rehearse(.reasoningCompleted(id: reasoningID, text: ""))
        try? await Task.sleep(for: .milliseconds(250))
        guard live() else { return }

        runtime.rehearse(.toolStarted(id: readID, call: ToolCall(kind: .read, title: "Read", detail: "README.md")))
        try? await Task.sleep(for: .milliseconds(450))
        guard live() else { return }
        runtime.rehearse(.toolUpdated(id: readID, update: ToolUpdate(
            output: "# Preview Workspace\n\nDemo context loaded for the preview instance.\n",
            status: .completed
        )))
        try? await Task.sleep(for: .milliseconds(250))
        guard live() else { return }

        let summary = TextCleanup.singleLine(text, limit: 36)
        let requestNote = summary.isEmpty ? "你的消息" : "「\(summary)」"
        let answer = """
        已收到\(requestNote)，我先梳理了当前上下文，接下来可以按下面三步推进：

        - 确认需求边界与受影响的文件范围，避免改动扩散到无关区域。
        - 按最小改动完成核心实现，并同步补齐必要的交互状态。
        - 运行本地验证并逐项核对渲染与边界表现。

        这是一条来自预览实例的演示回复（未连接真实服务商）。
        """
        await stream(runtime, id: messageID, reasoning: false, alive: live, answer, step: 28)
        guard live() else { return }
        runtime.rehearse(.messageCompleted(id: messageID, text: ""))
        runtime.rehearse(.turnCompleted(status: .completed, error: nil))
    }

    /// Streams `text` into the timeline a few characters at a time, as a provider does.
    private static func stream(_ runtime: ThreadRuntime, id: String, reasoning: Bool, alive: (() -> Bool)? = nil, _ text: String, step: Int) async {
        var index = text.startIndex
        while index < text.endIndex {
            guard alive?() ?? runtime.isRunning else { return }
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

    static func filter() async -> SCContentFilter? {
        guard let content = try? await SCShareableContent.currentProcess,
              let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first
        else { return nil }
        let filter = SCContentFilter(display: display, including: content.windows)
        filter.includeMenuBar = false
        return filter
    }

    static func configuration(for rect: NSRect) -> SCStreamConfiguration {
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
#endif
