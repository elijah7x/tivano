<img src="docs/icon.png" width="128" alt="Tivano icon">

# Tivano

[English](README.md) · **简体中文**

为你的编码 Agent 打造的 macOS 原生之家 —— 使用 Swift 与 SwiftUI 编写，采用 Liquid Glass 设计，适用于运行 macOS 26 及以上版本的 Apple silicon Mac。

Tivano fork 自 Jordy Spruit 的 [Droppy Code](https://getdroppycode.app)，使用新名称独立维护。

## 为什么 fork

Droppy Code 是一件出色的作品，我真心喜欢用它。用得越多，想法就越多——想尝试的功能、想探索的方向。fork 出来自己动手，是顺理成章的事。

遵循作者的商标政策，本 fork 使用了自己的名称、图标与品牌。Tivano 与 Droppy 无任何关联，也未获得其背书。

## 名字

Tivano 是一阵风——科莫湖上清晨的微风。图标里，它吹起一只小小的晴天娃娃，那种挂起来祈求晴空的吉祥物。这也是我们希望编码拥有的感觉：惬意，从容，风在背后。即使身处与 Agent 协作的深水区，Tivano 也希望让新一代的 coder 享受 AI 编码本来的乐趣。

## 功能

Tivano 驱动你本机已安装并登录的编码 Agent，使用你自己的提供商订阅或 API 凭证：Codex、Claude、Cursor、OpenCode Zen、OpenCode Go、Grok、Antigravity、Copilot、Command Code、Pi、omp、Kimi Code、DeepSeek、Z.ai、Meta 与 Devin。

- 玻璃质感侧栏管理项目与线程，支持搜索、置顶与归档沉降。
- 流式对话，完整呈现推理过程、工具调用、计划与行内审批。
- 每个线程可选计划模式、模型与推理强度，以及四档权限模式。
- 二十九款着色玻璃主题，从 System 到 Catppuccin、Dracula、Claude 与 Codex。
- 每一轮对话都有 diff，以隐藏的 git 检查点保存，可随时回退。
- 每个线程内嵌终端，新线程可开在自己的 git worktree 中。
- 提交、推送与创建 PR，提交信息与线程标题均可自动生成。
- Hydra：一个对话，多个头脑——主 Agent 为助手团队撰写任务简报，各自在项目副本中并行工作，成果合并回你的检出。
- 发送按钮旁的额度环，展示每个已接入计划的用量上限与余额。

Tivano 将对话库保存在本机。提供商请求、CLI 更新及应用更新检查会访问相应服务；这些服务有各自的数据政策。可选的本地诊断保存在指定输出目录。

## 环境要求

- 运行 macOS 26 及以上版本的 Apple silicon Mac
- 至少安装并登录一个提供商——`codex login`、`claude auth login`、`copilot login`、`cmd login`，或 `pi` 后执行 `/login`
- Git；GitHub PR 使用 `gh`，GitLab MR 使用 `glab`

## 构建

```bash
brew install xcodegen
xcodegen generate
open Tivano.xcodeproj
```

唯一的依赖 SwiftTerm 由 Swift Package Manager 拉取。

本地 Debug 构建请先运行一次 `scripts/setup_local_signing.sh`；详见 [docs/local-development.md](docs/local-development.md) 与 [docs/packaging.md](docs/packaging.md)。`scripts/release.sh` 可完成发布构建的归档、签名与公证。

## 代码结构

源码分为四层，依赖单向。`Tivano/Core` 承载模型与纯工具层，不依赖应用内任何其他部分。`Tivano/Services`——Git 与 worktree、磁盘存储、统一事件模型背后的各提供商适配器——仅依赖 Core；`Tivano/UI`（窗口框架、Markdown 渲染、主题与音效）同样仅依赖 Core。`Tivano/App` 承载入口、线程运行时与全部功能视图，依赖以上各层。

## 致谢

Tivano 最初是 T3 Tools Inc. [T3 Code](https://github.com/pingdotgg/t3code) 的原生 Swift 重写，基于 MIT 许可。终端来自 Miguel de Icaza 的 [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm)。工作状态指示器及其轮转文案移植自 Wing 的 [Zeron](https://github.com/zeronsh/zeron)。Codex 账户储备重置的使用方式参考了 [MonoCode](https://github.com/hardbeat920/monocode)。Copilot 提供商图标来自 GitHub 的 [Octicons](https://github.com/primer/octicons)。详见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)；应用内在 设置 › 关于 › 许可 中附有相同声明。

## 许可证

GNU AGPL v3.0 及附加署名条款——见 [LICENSE](LICENSE)。你可以使用、学习、修改与分享 Tivano。任何分发修改版本、或通过网络向他人提供修改版本的人，都须以相同许可公开源码、注明已修改，并保留署名 "Droppy Code by Jordy Spruit (Droppy), https://getdroppycode.app"。

"Droppy" 与 "Droppy Code" 名称及其图标不在许可范围内，见 [TRADEMARK.md](TRADEMARK.md)。部分代码源自 MIT 许可的 T3 Code，其声明保留于 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

如果你基于本项目构建，请在你的关于页面、README 与源码头部保留上述署名，并保留 THIRD_PARTY_NOTICES.md。仅此而已。
