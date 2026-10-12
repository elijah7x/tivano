<img src="docs/icon.png" width="128" alt="Tivano icon">

# Tivano

**English** · [简体中文](README.zh-CN.md)

A native macOS home for your coding agents — written in Swift and SwiftUI with Liquid Glass, for Apple silicon Macs on macOS 26 and later.

Tivano is a fork of [Droppy Code](https://getdroppycode.app) by Jordy Spruit, renamed and maintained independently.

## Why this fork

Droppy Code is a wonderful piece of work, and I genuinely love using it. The more I lived in it, the more ideas I had — features I wanted to try, directions I wanted to explore. Forking it was the natural way to chase them.

Following the author's trademark policy, the fork carries its own name, icon and branding. Tivano is not affiliated with or endorsed by Droppy.

## The name

Tivano is a wind — a gentle morning breeze off Lake Como. In the icon, that wind lifts a little weather doll, the kind hung out to wish for clear skies. That is the feeling we want for coding: at ease, with the wind at your back. Even deep in a session with your agents, Tivano is here so a new generation of coders can enjoy what AI coding can be.

## What it does

Tivano drives the coding agents you already have installed and signed in, using your own provider subscriptions or API credentials: Codex, Claude, Cursor, OpenCode Zen, OpenCode Go, Grok, Antigravity, Copilot, Command Code, Pi, omp, Kimi Code, DeepSeek, Z.ai, Meta and Devin.

- Projects and threads in a glass sidebar, with search, pinning and settling.
- Streaming conversations with reasoning, tool calls, plans and inline approvals.
- Plan mode, model and reasoning selection, four permission modes per thread.
- Twenty-nine tinted-glass themes, from System to Catppuccin, Dracula, Claude and Codex.
- A diff for every turn, captured as hidden git checkpoints, with revert.
- An embedded terminal per thread, and new threads in their own git worktree.
- Commit, push and pull requests, with generated commit messages and titles.
- Hydra: one chat, many heads — the lead agent briefs a team of helpers, each working in its own copy of the project, and their work lands back as one merge.
- Usage limits and credits beside the composer, for every plan that exposes them.

Tivano keeps its conversation library locally. Provider requests, CLI updates and app update checks use their respective services; those services have their own data policies. Optional local diagnostics stay in the selected output directory.

## Requirements

- A Mac with Apple silicon running macOS 26 or later
- At least one provider installed and signed in — `codex login`, `claude auth login`, `copilot login`, `cmd login`, or `pi` then `/login`
- Git, plus `gh` for GitHub pull requests or `glab` for GitLab merge requests

## Build

```bash
brew install xcodegen
xcodegen generate
open Tivano.xcodeproj
```

SwiftTerm, the only dependency, is fetched by Swift Package Manager.

Local builds use Developer ID signing; setup details live in [docs/local-development.md](docs/local-development.md) and [docs/packaging.md](docs/packaging.md). `scripts/release.sh` archives, signs and notarizes a release build.

## Layout

The sources sit in four layers with a one-way rule. `Tivano/Core` holds models and pure support and depends on nothing else in the app. `Tivano/Services` — Git and worktrees, the on-disk store, and the provider adapters behind one event model — depends only on Core, as does `Tivano/UI` with its window chrome, Markdown rendering, themes and chimes. `Tivano/App` carries the entry point, the per-thread runtime and every feature view, and depends on all of the above.

## Acknowledgements

Tivano began as a native Swift rewrite of [T3 Code](https://github.com/pingdotgg/t3code) by T3 Tools Inc., under the MIT License. The terminal is [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) by Miguel de Icaza. The working indicators and their rotating words are ported from [Zeron](https://github.com/zeronsh/zeron) by Wing. Spending a Codex account's banked resets follows [MonoCode](https://github.com/hardbeat920/monocode). The Copilot provider icon comes from GitHub's [Octicons](https://github.com/primer/octicons); the omp monogram comes from [oh-my-pi](https://github.com/can1357/oh-my-pi). See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md); the app carries the same notices under Settings › About › Licenses.

## License

GNU AGPL v3.0 with additional attribution terms — see [LICENSE](LICENSE). You may use, study, change and share Tivano. Anyone who distributes a modified version, or runs one for others over a network, must publish the source under the same license, say it is modified, and keep the attribution "Droppy Code by Jordy Spruit (Droppy), https://getdroppycode.app".

The names "Droppy" and "Droppy Code" and their icons are not part of the license; see [TRADEMARK.md](TRADEMARK.md). Portions descend from T3 Code under the MIT License, whose notice is preserved in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

If you build on this work, keep that attribution in your About screen, your README and your source headers, and keep THIRD_PARTY_NOTICES.md. That is the whole ask.
