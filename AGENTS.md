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

- Every owner-requested local build/package must produce the requested package **and** update `/Applications/Tivano.app` and/or `/Applications/Tivano Dev.app`; do not leave the new build only in DerivedData. Use `scripts/package_local.sh --release|--dev|--both`.
- Release owns production data: `~/Library/Application Support/Tivano`, `~/.tivano` and Keychain service `Tivano`. Dev owns test data: `~/Library/Application Support/Tivano Dev`, `~/.tivano-dev` and Keychain service `Tivano Dev`. Never import production data/preferences/credentials into Dev automatically or share either edition’s store with Droppy Code.
- Separate old shared installations offline with `scripts/separate_data.py --apply`, after all Tivano/Droppy apps exit. Keep backups; never retain compatibility aliases into a live library. Preserve Git worktree registrations via repair and rewrite stored attachment/state paths. Compatible isolated editions may run together; keep edition leases, the cross-edition repository lock for Hydra merges and isolated capture storage. Each edition is its library's only writer, so stores are written directly, without cross-process merges or polling. Provider CLI credentials and user-owned project folders remain external, not edition-owned.
- Release uses `config/release.xcconfig`; Dev uses `config/dev.xcconfig`. Versions are set in their respective xcconfig files; Dev displays a `dev-` prefix. Keep Apple's bundle version numeric; Dev's prefix is presentation metadata.
- Every package of an edition advances that edition's version first (`scripts/set_version.py <dev|release> x.y.z`, patch by default), so no two packaged builds share a version. A version already set but not yet packaged is used as is. Packaging Dev never advances Release, and the reverse.
- When `main` is brought up to `dev`'s features, `main` takes `dev`'s version: `scripts/set_version.py release catch-up-dev`, then build the agreed code revision and package Release. A version change alone is not a code promotion.
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
- Keep the local main-only pre-push guard; do not bypass it. Do not promote to
  `main` unless explicitly requested. When GitHub integration is separately
  authorized, use `gh` and squash; never push straight to `main`.
- Do not rewrite existing history or force-push unless the owner explicitly
  authorizes a specific history migration. Squash applies to ordinary task
  integrations. The public-history migration was explicitly authorized on
  2026-10-08; that authorization does not apply to future rewrites.

## Releasing (credit every contributor)

- Every `## [x.y.z]` entry in CHANGELOG.md that ships outside work carries a `### Thanks` section, one bullet per person in the form `- Name (@github-handle): what they did (#PR).`, after Refinements.
- `python3 scripts/release_credits.py` prints the block for everything merged since the previous `v*` tag (run it while writing the entry).
- `scripts/publish_release.sh` runs `scripts/release_credits.py --check` on the notes and refuses to publish while anyone is missing.
- The app's About cards ignore the Thanks heading, so it changes nothing there.
- When a pull request from outside merges between releases, add the person to the `## [Unreleased]` entry's Thanks right away rather than at release time.

## Project contracts

- UI: always reuse ChromeSection, ChromeCard, ChromeRow, GlassPickerButton, ChromeVisualPicker and SettingsSwitch. Never invent styles, colors, fonts, spacing or custom controls.
- Localization: English text is the key in `Tivano/Resources/Localizable.xcstrings`. Every new user-facing string needs a zh-Hans entry. Translate faithfully, clearly and naturally; keep English for product names, provider/model names, MCP, Git, worktree, token and anything that reads worse translated. Native language names stay native.
- Follow `docs/i18n/CONVENTIONS.md` for catalog lookup and translation fragments.
