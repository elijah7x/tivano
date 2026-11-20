<img src="docs/icon.png" width="128" alt="Tivano icon">

# Tivano

**English** · [简体中文](README.zh-CN.md)

**Website and download: [tivano.app](https://tivano.app/)**

A native macOS home for your coding agents — written in Swift and SwiftUI for Apple silicon Macs on macOS 15 Sequoia and later (with Liquid Glass on macOS 26 and later).

## What Tivano believes

- **Bring the agents you already pay for.** Tivano drives the agent CLIs you have installed and signed in, alongside direct API providers, inside one native macOS workspace. Your subscriptions, your keys, no middleman plan.
- **One lead, a team of sub-agents, on your terms.** A chat can stay single-threaded, run a saved lead-and-sub-agent combo across providers, or let the lead cast specialist roles on the fly. You decide whether to confirm each team first or turn on Auto-dispatch.
- **Calm, glanceable status instead of notification noise.** Rather than pinging you for every event, the weather window folds every open chat and waiting sub-agent into one quiet scene: wind when a chat waits on you, sunlight when work finishes, rain when something fails.
- **Know what your tokens cost.** Plan limits and remaining credits sit right beside the composer, and Settings › Token usage reads your local history from the companion app [Token Taken](https://elijah.ac.cn/tt) so you can see where tokens and spend actually go.
- **Local-first by default.** Your conversation library lives on your Mac. Worktrees isolate concurrent edits automatically when two chats touch the same repository, and diffs stay backed by hidden Git checkpoints you can revert.

## The name

Tivano is a wind — a gentle morning breeze off Lake Como. In the icon, that breeze lifts a small weather doll, the kind hung by a window to wish for clear skies. The same idea runs through the weather window inside the app: clear signals, quiet company, and the wind at your back while your agents work.

## Highlights

### Sub-agents

Configured in **Settings › Sub-agents & Combos**:

- **Three modes:** Same-model sub-agents (split work on the current model), Preset sub-agents (saved lead + sub-agent combos, including cross-provider pairs), and Adaptive sub-agents.
- **Adaptive sub-agents with identities:** Six built-in identities (`Scout`, `Builder`, `Reviewer`, `Designer`, `Researcher`, `Writer`) plus your own custom identities with a prompt and model; turn on **Auto-dispatch** to let the lead send teams out without waiting for confirmation.
- **Isolated or shared work:** Run each sub-agent in its own Git worktree copy (**Own copy**) or in the chat's checkout (**Shared**), with per-chat concurrency caps and adjustable delegation (`Restrained`, `Proactive`, `Aggressive`).
- **Floating panels:** Choose **Single panel**, **One per sub-agent**, or **Off** (keeping sub-agents running quietly behind a status pill), and switch panel content between a compact **Progress bar** and **Live steps**.
- **Independent review:** Have a second model (ideally from another provider) review the team's diff and send findings back to the lead; the result folds into an expandable review card before optional auto-commit and merge.

### Weather window

Configured in **Settings › Appearance › Weather window**:

- **Three modes:** **Porthole** (default — a quiet ink scene above the thread list whose sky follows the time of day, on Liquid Glass and Texture), **Full window** (behind-the-glass weather across the window on macOS 26 Liquid Glass), or **Off**.
- **Glanceable cues:** Wind blows when a chat or sub-agent waits for your approval or answer; sunlight appears when a turn finishes (a full moon at night in Porthole); rain falls when a turn fails.
- **Quiet in the background:** Animations pause automatically whenever Tivano is inactive, minimized, or out of view.

### Token usage

Configured in **Settings › Token usage**:

- **Companion-powered, local-only:** Reads token history locally from [Token Taken](https://elijah.ac.cn/tt) ([GitHub](https://github.com/elijah7x/token-taken)); Tivano does not collect or upload usage telemetry itself.
- **Clear summary and trends:** One-sentence overview of total tokens and API-equivalent cost across the last 7, 30, 90 days, or year, paired with a daily trend line.
- **Flexible breakdown:** Share bar grouped **By tool** or **By model**, plus a collapsible breakdown of fresh input, cache reads, cache writes, and output tokens.

### Themes and icons

Configured in **Settings › Appearance**:

- **Three themes:** **Liquid Glass** (macOS 26 and later), **Texture** (macOS 15 and later), and **Creation** (solid near-white surfaces, serif type, and hand-drawn icons).
- **Twelve accents:** `System Accent`, `Avocado`, `Coral Red`, and nine other dynamic light/dark accents, paired with Match System, Light, or Dark appearance.
- **Adaptive app icon:** **Match Theme** (default) switches the Dock and Finder app icon to match Liquid Glass, Texture, or Creation, or lets you pin any of the three.
- **Six languages:** English, 简体中文, 繁體中文, 日本語, 한국어, and Français.

### Everyday workflow

- **Workspace Auto:** New chats edit your project folder directly when it is idle and spin up an isolated Git worktree automatically when another chat is already active in that repository (or lock to **Local** or **New worktree** in **Settings › Conversation**).
- **Diffs, checkpoints, and terminal:** Per-turn diffs stored as hidden Git checkpoints with revert, an embedded terminal per thread, and commit/push/PR flows with generated commit messages and titles.
- **Composer controls:** Plan mode, model and reasoning effort pickers, inline `@` file chips, and four permission modes per thread (`Supervised`, `Auto-accept edits`, `Auto`, `Full access`).
- **Limits and voice:** Plan limits, remaining quotas, and balances in a usage ring beside the composer; optional **Codex realtime voice** calls from Codex chats.
- **Quick chat:** Opt in under **Settings › Shortcuts** (`⇧⌘Space` by default) to open a floating chat box over any app and send straight into a new chat or sub-agent preset.
- **What's new after updates:** **Settings › Version** highlights a one-time summary after updates (including silent automatic updates) and keeps an expandable **What's new** log for every version since your last run.

## Supported providers

Tivano drives **18 providers** using your own subscriptions or API keys:

- **Agent CLIs:** Antigravity, Claude, Codex, Command Code, Copilot, Cursor, DeepSeek Harness, Devin, Grok, Kimi Code, MiniMax Code, omp, OpenCode, Pi, and ZCode.
- **Built-in API harness (Tivano Code):** DeepSeek, Meta, and Z.ai.

## Privacy and local data

Tivano keeps its conversation library locally on your Mac. Token usage in **Settings › Token usage** is read locally from Token Taken's helper CLI; nothing leaves your computer for it. Provider requests, CLI updates, and app update checks talk directly to their respective services under those services' own data policies. Optional local diagnostics stay in the output directory you choose.

## Requirements

- A Mac with Apple silicon running **macOS 15 Sequoia or later** (macOS 26 or later for Liquid Glass and Full window weather)
- At least one provider CLI installed and signed in (for example `codex login`, `claude auth login`, `copilot login`, `cmd login`, or `pi`), or an API key for DeepSeek, Meta, or Z.ai
- Git, plus `gh` (GitHub), `glab` (GitLab), `origin` (Cursor Origin), or `tea` (Gitea) for pull and merge requests
- Optional: [Token Taken](https://elijah.ac.cn/tt) for **Settings › Token usage**

## Build

```bash
brew install xcodegen
xcodegen generate
open Tivano.xcodeproj
```

SwiftTerm is the only external Swift Package Manager dependency.

Local builds use Developer ID signing; setup details live in [docs/local-development.md](docs/local-development.md) and [docs/packaging.md](docs/packaging.md). `scripts/release.sh` archives, signs, notarizes, and packages a release DMG.

## Layout

The sources sit in four layers with a one-way rule. `Tivano/Core` holds models and pure support and depends on nothing else in the app. `Tivano/Services` — Git and worktrees, the on-disk store, local token usage, and the provider adapters behind one event model — depends only on Core, as does `Tivano/UI` with its window chrome, Markdown rendering, themes, and chimes. `Tivano/App` carries the entry point, the per-thread runtime, and every feature view, and depends on all of the above.

## Origins

Tivano started as a fork of [Droppy Code](https://getdroppycode.app) by Jordy Spruit, and is now maintained independently with its own direction. Following the author's trademark policy, Tivano carries its own name, icon, and branding. Tivano is not affiliated with or endorsed by Droppy.

## Acknowledgements

Tivano began as a native Swift rewrite of [T3 Code](https://github.com/pingdotgg/t3code) by T3 Tools Inc., under the MIT License. Its responsive chat architecture follows principles studied in [Synara](https://github.com/Emanuele-web04/synara) by T3 Tools Inc. and Emanuele Di Pietro. The embedded terminal is [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) by Miguel de Icaza. Working indicators, streaming fade, sounds, and voice agent mode are ported from [Zeron](https://github.com/zeronsh/zeron) by Wing, building on [mugen-markdown](https://github.com/wingleeio/mugen) by Wing Lee, the voice orb from Bezel / [gpui-thinking-orbs](https://github.com/FrancoEscob/gpui-thinking-orbs) / [thinking-orbs](https://github.com/Jakubantalik/thinking-orbs), and OpenAI Codex's realtime voice protocol (Apache-2.0). Spending a Codex account's banked resets follows [MonoCode](https://github.com/hardbeat920/monocode). The built-in concise reply guidance for Tivano's API harness is adapted from ideas in [anti-slop](https://github.com/miqdadbadjuber/anti-slop). Marks include GitHub's [Octicons](https://github.com/primer/octicons), the omp monogram from [oh-my-pi](https://github.com/can1357/oh-my-pi), [Simple Icons](https://simpleicons.org), and the [Git Logo](https://git-scm.com/downloads/logos) by Jason Long. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md); the app carries the same notices under **Settings › Credits**.

## License

GNU AGPL v3.0 with additional attribution terms — see [LICENSE](LICENSE). You may use, study, change, and share Tivano. Anyone who distributes a modified version, or runs one for others over a network, must publish the source under the same license, say it is modified, and keep the attribution "Droppy Code by Jordy Spruit (Droppy), https://getdroppycode.app".

The names "Droppy" and "Droppy Code" and their icons are not part of the license; see [TRADEMARK.md](TRADEMARK.md). Portions descend from T3 Code under the MIT License, whose notice is preserved in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

If you build on this work, keep that attribution in your About screen, your README, and your source headers, and keep THIRD_PARTY_NOTICES.md. That is the whole ask.
