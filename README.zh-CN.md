<img src="docs/icon.png" width="128" alt="Tivano icon">

# Tivano

[English](README.md) · **简体中文**

**官网与下载：[tivano.app](https://tivano.app/)**

为你的编码 Agent 打造的 macOS 原生工作空间 —— 使用 Swift 与 SwiftUI 编写，适用于运行 macOS 15 Sequoia 及以上版本的 Apple silicon Mac（液态玻璃主题需 macOS 26 及以上版本）。

## 理念

- **直接驱动你已有的 Agent。** Tivano 在一个 macOS 原生工作空间里接入你本机已安装并登录的 Agent CLI，以及自带 API 密钥的服务商。用你自己的订阅和密钥，不另收中间层费用。
- **一个主代理，一支子代理团队，尺度由你决定。** 既可以单模型推进，也可以选用跨服务商的预设模型搭配，或让主代理按任务分工自动挑角色；是否先确认再派出、还是打开「自动派发」，都由你控制。
- **用安静的天气代替通知轰炸。** 天气窗把所有对话和子代理的状态收进一幅小景里：有对话等你确认或回复时起风，回合完成时出太阳，出错时下雨，扫一眼就知道。
- **清楚自己的 token 花在哪。** 输入框旁的额度环实时显示各服务商的计划上限与余额；「设置 › 词元用量」在本地读取配套应用 [Token Taken](https://elijah.ac.cn/tt) 的记录，长期用量和估算开销一目了然。
- **默认本地优先。** 对话库保存在你的 Mac 上。同一仓库里有多个对话并行时自动切入独立 Git worktree，每轮改动都有隐藏 Git 检查点兜底，随时可回退。

## 名字

Tivano 是一阵风——科莫湖上清晨的微风。图标里，它吹起一只小小的晴天娃娃，那种挂在窗边祈求晴空的吉祥物。应用里的天气窗延续了同一份心思：信号清楚、安静陪伴，让你在和 Agent 协作时，背后一直有风。

## 亮点

### 子代理

在 **设置 › 子代理与组合** 中配置：

- **三种模式：** 同模型子代理（当前模型拆活并派发同模型子代理）、模型搭配（保存主模型与子代理模型组合，支持跨服务商搭配），以及自适应子代理。
- **带角色的自适应子代理：** 内置六个角色（`侦察`、`实现`、`评审`、`设计`、`调研`、`文案`），也支持编写自定义角色、提示词和指定模型；打开 **自动派发** 后，主代理选好角色即可直接派出，无需逐步确认。
- **独立或共用工作目录：** 可为每个子代理分配 **独立副本**（独立 Git worktree）或与主对话 **共用** 检出目录，并可配置单对话并发上限与委派倾向（`克制`、`主动`、`激进`）。
- **悬浮面板：** **悬浮面板排布** 支持 **单个面板**、**独立面板** 或 **关闭**（不自动弹窗，对话中保留状态指示与可点击胶囊）；**悬浮面板内容** 可切换 **进度条** 与 **实时步骤**。
- **独立审查：** 团队收尾后可由另一模型（建议选不同服务商）独立审查改动并将意见交回主代理，结果折叠成可展开的审查卡片，再决定是否自动提交合并。

### 天气窗

在 **设置 › 外观 › 天气窗** 中配置：

- **三种形态：** **舷窗**（默认——侧栏对话列表上方的一幅墨线小景，天色随时间变化，支持液态玻璃与质感主题）、**落地窗**（macOS 26 液态玻璃主题下的整窗柔和天气效果），或 **关闭**。
- **一眼可读的状态：** 对话或子代理等你审批、回答时起风；回合完成时出太阳（舷窗在夜晚转为满月与星光）；回合失败时下雨。
- **后台自动静默：** 应用切到后台、最小化或窗口不可见时自动暂停动画，不空耗资源。

### 词元用量

在 **设置 › 词元用量** 中查看：

- **本地配套数据源：** 在本机直接读取配套应用 [Token Taken](https://elijah.ac.cn/tt)（[GitHub](https://github.com/elijah7x/token-taken)）汇总的数据；Tivano 本身不采集也不上传用量。
- **一句话总览与趋势：** 汇总近 7 天、30 天、90 天或一年的总 token 数与按 API 折算的估算费用，并附每日趋势线。
- **按维度拆解：** 支持按工具或按模型查看占比条，并可展开查看新输入、缓存读取、缓存写入与输出 token 构成。

### 主题与图标

在 **设置 › 外观** 中配置：

- **三套主题：** **液态玻璃**（macOS 26 及以上）、**质感**（macOS 15 及以上），以及 **创作**（纯净近白实色表面、衬线排版与手绘图标）。
- **十二款强调色：** 包含系统强调色、牛油果绿、珊瑚红等十二款动态明暗强调色，搭配跟随系统、浅色与深色外观。
- **跟随主题的应用图标：** **应用图标** 默认 **跟随主题**，切换液态玻璃、质感或创作主题时自动同步程序坞与访达图标，也可固定其中一款。
- **六种界面语言：** English、简体中文、繁體中文、日本語、한국어、Français。

### 日常工作流

- **工作区自动分流：** **设置 › 对话 › 工作区** 默认为 **自动**——仓库空闲时直接编辑项目目录，同一仓库已有其他对话在跑时自动新建独立 Git worktree；也可固定为 **本地** 或 **新建 worktree**。
- **Diff、检查点与终端：** 每轮改动都以隐藏 Git 检查点记录 diff 并支持回退；每个线程内嵌终端；支持提交、推送与创建 PR/MR，提交信息与线程标题可自动生成。
- **趁手的对话控制：** 计划模式、模型与推理强度选择、输入框内联 `@` 文件标签，以及每线程四档权限模式（`需确认`、`自动接受编辑`、`自动`、`完全访问`）。
- **额度环与实时语音：** 发送按钮旁的额度环展示计划上限、余额与可用重置；Codex 对话可选开启 **Codex 实时语音** 直接语音协作。
- **快速对话：** 在 **设置 › 快捷键** 开启全局快捷键（默认 `⇧⌘Space`），在任意应用上方呼出快捷输入框，直接发往默认模型或子代理预设。
- **更新内容回看：** 每次更新（含静默自动更新）后，**设置 › 版本** 会给出一次更新提示，并保留可展开的更新内容列表，汇总自上次运行以来所有版本的改动。

## 支持的服务商

Tivano 使用你自己的订阅或 API 密钥，支持 **18 个服务商**：

- **Agent CLI：** Antigravity、Claude、Codex、Command Code、Copilot、Cursor、DeepSeek Harness、Devin、Grok、Kimi Code、MiniMax Code、omp、OpenCode、Pi、ZCode。
- **内置 API 运行时（Tivano Code）：** DeepSeek、Meta、Z.ai。

## 隐私与本地数据

Tivano 将对话库保存在你的 Mac 本地。**设置 › 词元用量** 通过 Token Taken 的本地命令行助手读取统计数据，不会将用量数据传出本机。提供商请求、CLI 更新与应用更新检查直接访问各自服务，并受其数据政策约束。可选的本地诊断文件仅保存在你指定的输出目录中。

## 环境要求

- 运行 **macOS 15 Sequoia 及以上版本** 的 Apple silicon Mac（液态玻璃主题与落地窗天气需 macOS 26 及以上版本）
- 至少安装并登录一个 Agent CLI（如 `codex login`、`claude auth login`、`copilot login`、`cmd login` 或 `pi`），或配置 DeepSeek、Meta、Z.ai 的 API 密钥
- Git；创建 PR/MR 需要对应的 CLI：`gh`（GitHub）、`glab`（GitLab）、`origin`（Cursor Origin）或 `tea`（Gitea）
- 可选：[Token Taken](https://elijah.ac.cn/tt)（用于 **设置 › 词元用量**）

## 构建

```bash
brew install xcodegen
xcodegen generate
open Tivano.xcodeproj
```

SwiftTerm 是唯一的外部 Swift Package Manager 依赖。

本地构建使用 Developer ID 签名，配置详见 [docs/local-development.md](docs/local-development.md) 与 [docs/packaging.md](docs/packaging.md)。`scripts/release.sh` 可完成发布构建的归档、签名、公证与 DMG 打包。

## 代码结构

源码分为四层，依赖单向。`Tivano/Core` 承载模型与纯工具层，不依赖应用内任何其他部分。`Tivano/Services`——Git 与 worktree、磁盘存储、本地词元统计，以及统一事件模型背后的各服务商适配器——仅依赖 Core；`Tivano/UI`（窗口框架、Markdown 渲染、主题与音效）同样仅依赖 Core。`Tivano/App` 承载入口、线程运行时与全部功能视图，依赖以上各层。

## 缘起

Tivano 最初 fork 自 Jordy Spruit 的 [Droppy Code](https://getdroppycode.app)，现已独立维护并沿着自己的产品方向持续演进。遵循原作者的商标政策，Tivano 使用自己的名称、图标与品牌，与 Droppy 无任何关联，也未获得其背书。

## 致谢

Tivano 最初是 T3 Tools Inc. [T3 Code](https://github.com/pingdotgg/t3code) 的原生 Swift 重写，基于 MIT 许可。对话流畅度架构参考了 T3 Tools Inc. 与 Emanuele Di Pietro 的 [Synara](https://github.com/Emanuele-web04/synara)。内嵌终端来自 Miguel de Icaza 的 [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm)。工作状态指示器、流式渐隐、提示音与语音模式移植自 Wing 的 [Zeron](https://github.com/zeronsh/zeron)，并承接自 Wing Lee 的 [mugen-markdown](https://github.com/wingleeio/mugen)、Bezel / [gpui-thinking-orbs](https://github.com/FrancoEscob/gpui-thinking-orbs) / [thinking-orbs](https://github.com/Jakubantalik/thinking-orbs) 的语音球动画，以及 OpenAI Codex 的实时语音协议（Apache-2.0）。Codex 账户储备重置的使用方式参考了 [MonoCode](https://github.com/hardbeat920/monocode)。内置 API 运行时的简洁回复指引改编自 [anti-slop](https://github.com/miqdadbadjuber/anti-slop) 的思路。图标来源包括 GitHub 的 [Octicons](https://github.com/primer/octicons)、[oh-my-pi](https://github.com/can1357/oh-my-pi) 的 omp 徽标、[Simple Icons](https://simpleicons.org)，以及 Jason Long 的 [Git Logo](https://git-scm.com/downloads/logos)。完整声明见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)；应用内 **设置 › 致谢** 附有相同内容。

## 许可证

GNU AGPL v3.0 及附加署名条款——见 [LICENSE](LICENSE)。你可以使用、学习、修改与分享 Tivano。任何分发修改版本、或通过网络向他人提供修改版本的人，都须以相同许可公开源码、注明已修改，并保留署名 "Droppy Code by Jordy Spruit (Droppy), https://getdroppycode.app"。

"Droppy" 与 "Droppy Code" 名称及其图标不在许可范围内，见 [TRADEMARK.md](TRADEMARK.md)。部分代码源自 MIT 许可的 T3 Code，其声明保留于 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

如果你基于本项目构建，请在你的关于页面、README 与源码头部保留上述署名，并保留 THIRD_PARTY_NOTICES.md。仅此而已。
