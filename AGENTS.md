# AGENTS.md — Tivano agent workflow

## Worktrees (mandatory for coding)

- Keep one long-lived source checkout, normally on local `dev`. Never code
  directly in that checkout, regardless of its branch; every coding task gets
  its own worktree first.
- Owner-host setup per task:
  1. `git fetch origin --prune`
  2. `git worktree add -b <branch> <worktrees-dir>/<task> dev`
     (or use the explicitly agreed base instead of local `dev`)
  3. Do all edits, builds and explicitly authorized `scripts/quick_run.sh` runs
     inside that worktree. Build-host tasks follow the base rules below.
- After a task is done/merged, ask before discarding its worktree. Preserve
  unfinished work; remove only an authorized, safe worktree with
  `git worktree remove <path>`, then prune stale registrations as needed.
  Do not force removal to bypass unfinished work.
- Never delete the long-lived source checkout or another agent's worktree.

## Workspace hygiene

- Keep maintained source, active application/installer assets, useful design decisions
  and the generators needed to maintain them in Git. Store exploratory mockups,
  rejected candidates, recordings, ad hoc deliveries and recovery archives outside
  source checkouts; do not use `.gitignore` as their filing system.
- Resolve the external artifact root from the physical Git common-dir: the parent
  of the shared `.git` is the long-lived source checkout; its parent is the default
  artifact root. `TIVANO_ARTIFACTS_ROOT` may select another absolute external root.
  Never derive shared storage from a task worktree's parent or hardcode a host path.
- Use `design-archive/` for versioned design process files, `promo/` for promotional
  images/videos and their source projects, `local-packages/<edition>/` for local
  ZIPs, `private-artifacts/` for captures, release evidence and install backups,
  and `worktree-archives/` for recovery archives. Keep version/selection evidence
  and a path manifest when relocating originals; unknown approval stays unknown.
- Normal DerivedData and build logs may remain in ignored `build.noindex/`. Do not
  mix unique evidence or rollback bundles into disposable caches, or move active
  caches and release temporary worktrees merely for tidiness.
- Captures use a fresh `private-artifacts/product-captures/<run-id>/` directory;
  never clear or reuse an archive root. See `docs/operations/product-captures.md`
  and `docs/packaging.md` for output paths and authorization boundaries.
- When relocating files used by another process, record old/new paths, preserve
  safe read compatibility where needed, and hand off the change before old tools
  write again. Compatibility symlinks are not output roots or permission to delete
  their targets. Never execute historical runners as a migration or restore tool.

## Build host

- The build host does heavy builds and runs dispatched tasks. The owner host is
  the only machine that reviews, merges, packages or releases; `dev` lives there.
  SSH aliases, repository roots and worktree roots are supplied by the task's
  local configuration, never hardcoded in public documentation.
- The build host fetches, never pushes. Configure `origin` for GitHub and an
  `owner` remote for the owner host's repository root. Before every task run
  `git fetch origin --prune && git fetch owner`, then branch from the named base
  (default `owner/dev`; `origin/main` only when told). If the base is behind
  `origin/main`'s tree, report it instead of guessing.
- One task, one worktree under `<worktrees-dir>/<slug>` on `build/<slug>`.
  Commit the result there (one commit, plain message); the owner host fetches
  its configured build-host remote and squashes the task into `dev`.
- A rework request ("打回") continues on the same task branch with a new commit;
  never rebase or force-reset a branch the owner host has already fetched.
- The build host may build, run and debug its own Dev build within task authorization;
  it never runs `scripts/package_local.sh`, `scripts/ship.sh`, pushes, or touches
  GitHub beyond fetch. When working remotely on Thor, the owner's independent
  build environment, quitting, launching and relaunching task-related app
  instances for builds or validation is preauthorized; do not ask again.
  This exception does not extend to apps on the owner host.
- Each task ends with a short report: base commit, branch, what changed, build result
  with the first errors verbatim, and anything left unverified.
- Decisions that should outlive a task go into this file or `docs/` on the owner
  host, never only into one machine's agent memory.

## Layout (four layers, one way)

- `Tivano/Core` (models, pure support) reaches into nothing else in the app.
  `Tivano/Services` (Git, Store, Providers) and `Tivano/UI` (Chrome, Common,
  Markdown, Theme, Sound) reach only into Core. `Tivano/App` (entry, model, runtime,
  windows, captures and every feature view) reaches into everything.
- New code goes in the lowest layer whose dependencies it has. A Core file that needs
  the provider registry, the settings or a view is in the wrong layer: split the part
  that needs them into an extension in the layer above (see `App/HydraCookbook+Resolve.swift`).
- There is no test target. The lead runs the build
  (`xcodebuild -project Tivano.xcodeproj -scheme Tivano -configuration Debug build`)
  and existing acceptance scripts as appropriate within the owner's authorization;
  heads never run checks.

## Hydra heads (the chat team)

- A head never builds or otherwise verifies: no `xcodebuild`, no `scripts/quick_run.sh`, no check command. It edits the files the lead briefed it on and reports, nothing more.
- The lead runs the one build that proves the change, in the checkout, after the heads report.

## Relaunching

- On the owner host, NEVER run `scripts/quick_run.sh` or otherwise relaunch Tivano unless the owner explicitly asks for it in that moment. Remote work on Thor follows the standing quit/launch/relaunch authorization above. Quitting for an explicit Dev package request is preauthorized below.
- Agent-initiated build-only verification inside the worktree is fine and does not install. An explicit owner request to build/package an app also authorizes updating the requested edition(s) in `/Applications` via `scripts/package_local.sh`, unless the owner explicitly asks for build-only.
- An explicit request to package Tivano Dev authorizes the agent to quit the running Dev app before packaging, even if it has active work; do not ask again. Verify it has exited before replacing its bundle. This does not authorize launching it afterward.
- For Release, packaging alone does not authorize quitting or launching. If it is running, request an explicit quit; do not overwrite its running bundle.
- On the owner host, "finish", "merge", "done" or "test it" do not imply relaunch — only an explicit request to run/relaunch the app does. Thor's standing authorization also covers isolated capture instances used for validation.

## Local packaging, editions and shared data

- Package locally only on an explicit owner request; a merge or a release never packages or installs. A requested package must update `/Applications/Tivano.app` and/or `/Applications/Tivano Dev.app`; do not leave the new build only in DerivedData. Use `scripts/package_local.sh --release|--dev|--both`. Release is normally updated by the owner through the in-app updater, which keeps that path tested.
- Local Dev packaging does not require a separate source directory.
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
- Outside pull requests never merge on GitHub: main must stay dev's exact tree.
  Fetch one with `git fetch origin pull/<N>/head:pr-<N>`, test it in a worktree
  based on `dev`, and if accepted squash it into dev like any task integration.
  Keep the contributor's identity from their PR commits
  (`git log pr-<N> --format='%an <%ae>'`): they are the author
  (`git commit --author=...`) when the change is mostly theirs, otherwise a
  `Co-authored-by:` trailer. Then close the PR with a note that it ships in the
  next release. `scripts/ship.sh` carries these authors onto main's release commit.

## Releasing (credit every contributor)

- An explicit owner request to release ("发版") authorizes `scripts/ship.sh`, which does the whole release: Release takes Dev's version and `[Unreleased]` becomes it on dev, the DMG is built and notarized, a squash-merged PR makes main dev's exact tree, and the tag and GitHub Release are published. A release is always all of dev; never assemble main from selected commits. ship.sh stops if Dev's version is not newer or main's tree differs from dev's. It does not install Release.
- `scripts/ship.sh` does not require a permanent `main` checkout. It may reuse
  an existing clean `main` checkout without claiming ownership or cleaning it;
  otherwise it creates a temporary one. Release worktrees live under
  `$COMMON_DIR/tivano-worktrees.noindex`, derived from the physical Git
  common-dir, not Git's `$COMMON_DIR/worktrees` registration directory. This
  does not change how the app manages ordinary Hydra worktrees. On success,
  remove only worktrees created by this run that are safe to remove; on failure,
  preserve remaining worktrees and artifacts. Never auto-clean reused worktrees.
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
