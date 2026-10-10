# AGENTS.md — Tivano agent workflow

## Worktrees (mandatory for coding)

- Never code directly in the main checkout; every coding task gets its own
  worktree first.
- Setup per task:
  1. `git fetch origin --prune`
  2. `git worktree add -b <branch> <worktrees-dir>/agent-<slug> origin/main`
     (or from the agreed base branch instead of `origin/main`)
  3. Do all edits, builds and `scripts/quick_run.sh` runs inside that worktree.
- Cleanup only when the task is done/merged:
  `git worktree remove --force <worktrees-dir>/agent-<slug>` + `git worktree prune`.
- Never delete the main checkout, never touch another agent's worktree.

## Layout (four layers, one way)

- `Tivano/Core` (models, pure support) reaches into nothing else in the app.
  `Tivano/Services` (Git, Store, Providers) and `Tivano/UI` (Chrome, Common,
  Markdown, Theme, Sound) reach only into Core. `Tivano/App` (entry, model, runtime,
  windows, captures and every feature view) reaches into everything.
- New code goes in the lowest layer whose dependencies it has. A Core file that needs
  the provider registry, the settings or a view is in the wrong layer: split the part
  that needs them into an extension in the layer above (see `App/HydraCookbook+Resolve.swift`).
- There is no test target and no test scripts; the build is the check
  (`xcodebuild -project Tivano.xcodeproj -scheme Tivano -configuration Debug build`).

## Hydra heads (the chat team)

- A head never builds or otherwise verifies: no `xcodebuild`, no `scripts/quick_run.sh`, no check command. It edits the files the lead briefed it on and reports, nothing more.
- The lead runs the one build that proves the change, in the checkout, after the heads report.

## Relaunching (never unprompted)

- NEVER run `scripts/quick_run.sh` or otherwise relaunch Tivano unless the owner explicitly asks for it in that moment. Quitting for an explicit Dev package request is preauthorized below.
- Agent-initiated build-only verification inside the worktree is fine and does not install. An explicit owner request to build/package an app also authorizes updating the requested edition(s) in `/Applications` via `scripts/package_local.sh`, unless the owner explicitly asks for build-only.
- An explicit request to package Tivano Dev authorizes the agent to quit the running Dev app before packaging, even if it has active work; do not ask again. Verify it has exited before replacing its bundle. This does not authorize launching it afterward.
- For Release, packaging alone does not authorize quitting or launching. If it is running, request an explicit quit; do not overwrite its running bundle.
- "Finish", "merge", "done" or "test it" do not imply relaunch — only an explicit request to run/relaunch the app does.

## Local packaging, editions and shared data

- Package locally only on an explicit owner request; a merge or a release never packages or installs. A requested package must update `/Applications/Tivano.app` and/or `/Applications/Tivano Dev.app`; do not leave the new build only in DerivedData. Use `scripts/package_local.sh --release|--dev|--both`. Release is normally updated by the owner through the in-app updater, which keeps that path tested.
- Release owns production data: `~/Library/Application Support/Tivano`, `~/.tivano` and Keychain service `Tivano`. Dev owns test data: `~/Library/Application Support/Tivano Dev`, `~/.tivano-dev` and Keychain service `Tivano Dev`. Never import production data/preferences/credentials into Dev automatically or share either edition’s store with Droppy Code.
- Separate old shared installations offline with `scripts/separate_data.py --apply`, after all Tivano/Droppy apps exit. Keep backups; never retain compatibility aliases into a live library. Preserve Git worktree registrations via repair and rewrite stored attachment/state paths. Compatible isolated editions may run together; keep edition leases, the cross-edition repository lock for Hydra merges and isolated capture storage. Each edition is its library's only writer, so stores are written directly, without cross-process merges or polling. Provider CLI credentials and user-owned project folders remain external, not edition-owned.
- Release uses `config/release.xcconfig`; Dev uses `config/dev.xcconfig`. Versions are set in their respective xcconfig files; Dev displays a `dev-` prefix. Keep Apple's bundle version numeric; Dev's prefix is presentation metadata.
- Versions follow dev's code. Every merge into dev advances Dev's patch version in the same commit (`scripts/set_version.py dev x.y.z`), so one Dev version is one dev revision and Dev always leads or equals Release. Packaging never changes a version.
- Release never chooses its own version: a release takes Dev's (`scripts/ship.sh` runs `set_version.py release catch-up-dev`). If Dev is not newer than the last release, the fix is a missed Dev bump, never a Release-only bump.
- The DEV badge is a derived icon; never modify the approved v1 original or the release icon.
- Local Release and Dev packages use the same Developer ID Application team, with stable bundle IDs and hardened runtime. Do not fall back to local/ad-hoc signing. Public distribution also requires notarization and must not relax the updater's production verification.

## Merging (local dev, always squash)

- The history inherited from upstream is already bloated: thousands of tiny
  Hydra head commits plus one merge commit per MR. Every task integration MUST
  land as exactly one new commit on the requested target branch.
- "Merge" and "package" authorize local work only. Pushing, creating a GitHub PR
  or publishing requires a separate explicit owner instruction; never infer it
  from a local merge request.
- `dev` stays local. Squash task changes in an integration worktree based on
  `dev`, then fast-forward the local `dev` checkout to that single commit.
- A merge into dev ("合入 dev") is one commit holding the change, its
  `## [Unreleased]` CHANGELOG entry for anything user-facing, and Dev's version
  bump. It does not package. Afterwards ask the owner whether to discard the
  task worktree.
- Keep the local pre-push guard; do not bypass it. It allows main and `v*`
  tags pointing at `origin/main`. Do not promote to `main` unless explicitly
  requested. When GitHub integration is separately authorized, use `gh` and
  squash; never push straight to `main`.
- Do not rewrite existing history or force-push unless the owner explicitly
  authorizes a specific history migration. Squash applies to ordinary task
  integrations. The public-history migration was explicitly authorized on
  2026-10-08; that authorization does not apply to future rewrites.

## Releasing (credit every contributor)

- An explicit owner request to release ("发版") authorizes `scripts/ship.sh`, which does the whole release: Release takes Dev's version and `[Unreleased]` becomes it on dev, the DMG is built and notarized, a squash-merged PR makes main dev's exact tree, and the tag and GitHub Release are published. A release is always all of dev; never assemble main from selected commits. ship.sh stops if Dev's version is not newer or main's tree differs from dev's. It does not install Release.
- Public GitHub Releases contain exactly one uploaded app installer: the notarized `Tivano-<version>.dmg`. Never upload an App ZIP as a second download, including from one-off completion scripts. Local package ZIPs and notarization submission ZIPs stay local. GitHub's automatic Source code archives are platform-generated; do not delete release tags to remove them.

- Every `## [x.y.z]` entry in CHANGELOG.md that ships outside work carries a `### Thanks` section, one bullet per person in the form `- Name (@github-handle): what they did (#PR).`, after Refinements.
- `python3 scripts/release_credits.py` prints the block for everything merged since the previous `v*` tag (run it while writing the entry).
- `scripts/publish_release.sh` runs `scripts/release_credits.py --check` on the notes and refuses to publish while anyone is missing.
- The app's About cards ignore the Thanks heading, so it changes nothing there.
- When a pull request from outside merges between releases, add the person to the `## [Unreleased]` entry's Thanks right away rather than at release time.

## Project contracts

- UI: always reuse ChromeSection, ChromeCard, ChromeRow, GlassPickerButton, ChromeVisualPicker and SettingsSwitch. Never invent styles, colors, fonts, spacing or custom controls.
- Localization: English text is the key in `Tivano/Resources/Localizable.xcstrings`. Every new user-facing string needs a zh-Hans entry. Translate faithfully, clearly and naturally; keep English for product names, provider/model names, MCP, Git, worktree, token and anything that reads worse translated. Native language names stay native.
- Follow `docs/i18n/CONVENTIONS.md` for catalog lookup and translation fragments.
