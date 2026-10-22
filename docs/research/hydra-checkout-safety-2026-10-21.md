# Hydra checkout safety — sync overwrite and the missing write lock

2026-10-21. Research for two open problems: `syncDefaultBranch` can overwrite edits the
user makes while a merge is in flight, and nothing serializes head landings against
auto-merges writing the same checkout. Findings, prior art, and a concrete design.

## Summary

- **A.** `syncDefaultBranch` guards its write-back of three-way-merged files against
  `mergedFrom`, a working-tree snapshot taken *after* the user may already have edited —
  so the edit becomes the baseline and is overwritten. And `commitHash() == head` is a
  separate git invocation from `resetSoft`, so a terminal commit between them is
  orphaned. Both are check-then-act across process spawns; the fixes are per-file CAS on
  the bytes the merge actually consumed, and `git update-ref` with an expected old value.
- **B.** Landings serialize per lead (`hydraLanding` task chain) and merges serialize
  per app (`hasActiveHydraMerge`) plus cross-edition (`SharedLibraryLease`), but no lock
  covers landing-vs-merge or landing-vs-landing across different leads in one checkout.
  A keyed per-checkout async gate, backed by a second `SharedResourceLock` file for
  cross-edition exclusion, closes the gap.
- Prior art: every comparable tool (git, jj, GitButler, Claude Squad, Conductor, Crystal,
  Vibe Kanban) either refuses to write a dirty checkout or never writes the user's
  checkout at all. Tivano's land-into-live-checkout design is the unusual one, so it
  needs both primitives.

## A. `syncDefaultBranch` — where edits are lost

Callers: `mergeHydraProject` after a merged MR — `AppModel+HydraMerge.swift:508`
(own branch, `merged` holds the three-way results) and `:515` (squashed branch follows
the remote). The whole call runs under the repo lease taken at `:314-319`.

Sequence in `syncDefaultBranch` (`AppModel+HydraMerge.swift:1000-1040`):

1. `fetch`, `isAncestor(head, remote)` (`:1002`).
2. Read `mergedFrom[path]` = current working bytes of each merged file (`:1007-1011`).
3. `changedPaths(head→remote)`, `dirtyPaths()`, `presentPaths` (`:1012-1021`); bail if a
   remote-changed non-team file is dirty.
4. `commitHash() == head` re-check (`:1025`).
5. `resetSoft(remote)`, `resetIndex(ownPaths)`, `checkoutPaths(remote, kept)`,
   `removePaths(gone)` (`:1027-1030`).
6. Write `merged[path]` over each file still equal to `mergedFrom[path]` (`:1031-1035`).

The `merged` bytes come from `captureTree(paths:onto:from:)` (`Git.swift:467-523`), which
read the working file at `:487` — during *preparation*, before the push/MR/merge/fetch
window that can run for minutes.

Lost-update interleavings:

- **A1 — stale baseline.** User edits a contested file after `captureTree` read it
  (`Git.swift:487`) but before the write-back. `mergedFrom` at `:1009` then reads the
  *edited* bytes, the guard at `:1033` passes, and `:1034` writes merge output built
  from the pre-edit bytes. The user's edit is silently overwritten. The guard compares
  against the wrong baseline: it must compare against the bytes `captureTree` consumed,
  not a fresh read.
- **A2 — HEAD CAS gap.** `commitHash() == head` (`:1025`) and `resetSoft` (`:1027`) are
  two process spawns. A `git commit` in a terminal between them leaves the user's commit
  pointed at by nothing but reflog when `reset --soft` repoints the branch. A branch
  switch between them moves the *other* branch.
- **A3 — dirty-check window.** `dirtyPaths()` (`:1015`) precedes `checkoutPaths`/`rm`
  (`:1029-1030`) by several awaits. A user edit to a `kept` file is clobbered by
  `git checkout remote -- path`; a file in `gone` the user just rewrote is deleted.
  `resetIndex(ownPaths)` at `:1028` also silently unstages anything the user staged on
  the team's paths meanwhile.
- **A4 — write-back TOCTOU.** Even with the right baseline, `Data(contentsOf:)` at
  `:1033` then `write` at `:1034` is check-then-act per file. Narrow, but the same
  class. Keep read-compare-write adjacent with no await between.

The repo lease does not help here: it only excludes *other Tivano merges*, not the
user's editor or terminal.

## B. No shared lock over landing vs merge

Writers into a checkout today:

- **Landing** — `applyHydraHead` (`AppModel+Hydra.swift:1006-1043`): `git apply`
  (`Git.swift:1016-1044`) writes working files, or leaves conflict markers via the
  temp-index `--3way`. Serialized only per lead through `leadRuntime.hydraLanding`
  (`:933-939`). Two *different* leads landing into one checkout run concurrently.
- **Auto-merge** — `mergeHydraProject`: `captureTree` reads working files
  (`AppModel+HydraMerge.swift:374,386`), then `syncDefaultBranch` writes them
  (`:1027-1035`), plus the project-checkout `pullFastForward` at `:522`.
- **Revert** — `Git.restore` (`Git.swift:907`, called at `ThreadRuntime.swift:2692`)
  rewrites files; guarded only per-thread (`:1008-1011`).

Coordination as it stands: the merge awaits the current landing once
(`AppModel+HydraMerge.swift:163`), and `waitForSettledCheckout`
(`AppModel+Hydra.swift:987-1004`) polls `leadRuntime.isHydraMerging` — the flag on the
*landing head's own lead*. Interleavings that still lose or corrupt:

- **B1.** A landing whose head targets checkout C waits on *its own* lead's
  `isHydraMerging`. A merge by a *different* lead covering C is invisible to it.
- **B2.** `waitForSettledCheckout` gives up after 30 min and lands anyway
  (`:985-986,993`). During a merge, a late landing's `git apply` interleaves with
  `captureTree`'s `add -A` (`Git.swift:451`): the commit can capture a half-applied
  patch, `markHydraMerged` then books the head merged though part never went out — or
  conflict markers from `--3way` land inside a captured file and get pushed, which
  `:331-338` exists to prevent.
- **B3.** A landing that starts after the one-shot `await hydraLanding?.value` at `:163`
  is never seen (the wait reads the property once).
- **B4.** Cross-edition: `SharedLibraryLease` on the git common dir (`:314-318`) is
  taken only by merges. A Release landing and a Dev merge in the same checkout —
  or two editions' landings — interleave freely.
- **B5.** `hasOperationInProgress` (`Git.swift:678-685`) only sees git's own markers
  (MERGE_HEAD etc.); a Tivano merge writes none, so it never blocks a landing.

## Prior art

- **git** refuses `checkout`/`merge` over locally modified files the operation would
  touch ("Your local changes… would be overwritten"), computing overlap at operation
  time rather than trusting a stale status. `index.lock` (O_EXCL lockfile) serializes
  index writes between processes. `update-ref <ref> <new> <old>` is atomic CAS under the
  ref lock; `--stdin` transactions add `verify`/`symref-verify`/`symref-update`, so HEAD's
  symref target and the branch value can be checked and moved in one transaction. And
  `git merge --abort` documents that uncommitted state cannot always be reconstructed —
  which is why git refuses up front instead of cleaning up after.
  Sources: https://git-scm.com/docs/git-update-ref ,
  https://git-scm.com/docs/git-merge , https://github.com/git/git/blob/master/Documentation/technical/api-lockfile.txt
- **Jujutsu** snapshots the working copy into a commit at the start of *every* command —
  there is no "dirty" state to lose — and records each mutation in the operation log;
  concurrent commands produce divergent operations that merge rather than lock.
  Sources: https://docs.jj-vcs.dev/latest/working-copy/ ,
  https://docs.jj-vcs.dev/latest/operation-log/
- **GitButler** writes several virtual branches into one working directory but owns that
  directory (`gitbutler/workspace` merge commit, union index) and asks users not to run
  plain git against it — sidestepping the problem by controlling the checkout.
  Sources: https://docs.gitbutler.com/workspace-branch ,
  https://github.com/gitbutlerapp/gitbutler-docs/blob/main/content/docs/features/branch-management/virtual-branches.mdx
- **Multi-agent tools never write the user's checkout.** Claude Squad, Conductor,
  Crystal, Vibe Kanban each give the agent its own worktree+branch; integration is an
  explicit user merge or a PR. Crystal moved "rebase to main" to merge "for safer
  operations"; Vibe Kanban's merge/rebase act on the task branch inside its worktree.
  Sources: https://github.com/smtg-ai/claude-squad ,
  https://www.conductor.build/docs/concepts/git-worktrees ,
  https://github.com/stravu/crystal/blob/main/CLAUDE.md ,
  https://www.vibekanban.com/docs/workspaces/git-operations

The shared lesson: either make "the user's concurrent edits" impossible (worktree per
agent), or detect them at write time with CAS, not at check time earlier.

## Proposed design

### A1–A4. Baseline-correct, CAS-guarded sync

1. `Git.captureTree(paths:onto:from:)` returns a third field `ours: [String: Data]` —
   the working bytes read at `Git.swift:487` for each contested path (deletion case
   records nil/missing). `mergeHydraProject` carries it in `prepared` next to `merged`.
2. `syncDefaultBranch` drops `mergedFrom`. Write-back per merged path:
   `Data(contentsOf:) == ours[path]` → write `merged[path]` (adjacent statements, no
   await between). Mismatch → the file moved since capture: re-run `merge-file` once
   with current bytes as ours, `head` blob as base, remote merged blob as theirs; on
   conflict leave the file and name it in the sync line. That preserves user edits
   instead of silently absorbing them.
3. HEAD move via one `git update-ref --stdin` transaction:
   `symref-verify HEAD refs/heads/<branch>` + `update refs/heads/<branch> <remote> <head>`
   — new `Git.moveBranch(_:to:expecting:headSymref:)`. Failure → leave the checkout,
   same as today's early return. (`symref-verify` needs a recent git; if unavailable,
   `symbolic-ref` read + plain 3-arg `update-ref` still collapses the commit race to a
   micro-window for branch switch only.)
4. Replace the set-level dirty check + bulk `checkoutPaths`/`removePaths` with per-file
   CAS: for each `kept`, write remote's blob iff the file still hashes to its `head`
   blob (`hash-object` on disk vs `rev-parse head:path`); for each `gone`, unlink iff
   still equal. Files failing CAS are skipped and listed in the note. Reads are bounded
   by the remote-changed count, typically small.

### B1–B5. One write gate per checkout

- `CheckoutWriteGate` (new, `Tivano/Services/Git/`): a keyed, FIFO async gate on
  `HydraPaths.canonical(checkout)` — the wait-queue pattern `GitAdmission`
  (`Git.swift:45-95`) already implements, including cancellable waiters. Holders:
  - `applyHydraHead`: gate acquired in `landHydraHead` after patch prep, held across
    `hasOperationInProgress` + `apply` + base update (`AppModel+Hydra.swift:1006-1043`).
    Replaces the per-lead `hydraLanding` chain for exclusion (the chain can stay as the
    ordering mechanism, but exclusion moves to the gate).
  - `autoMergeHydraWork`/`mergeHydraProject`: the checkout sweep in `hydraWork`
    (`captureTree` at `:835`) is itself a working-tree read that can tear against a
    landing, so the gate must cover gathering too, not only `mergeHydraProject`.
    Restructure so each group's `hydraWork` and `mergeHydraProject` run under that
    checkout's gate (the lead's own checkout stays first for the outside-paths
    bookkeeping); one gate is held at a time — no lock ordering, no cycles.
  - `Git.restore` in revert (`ThreadRuntime.swift:2692`), and the `pullFastForward` at
    `:522`.
- Cross-edition: after acquiring the in-process gate, take `SharedLibraryLease` on
  `SharedResourceLock.url(resource: canonicalCheckoutPath)` — a second lock file beside
  the repo one, keyed to the working tree rather than the common dir. Held for the same
  span. flock is released by the kernel if the app dies mid-write.
- Ordering/cancellation: FIFO so queued landings don't starve; a cancelled task is
  removed from the wait queue (mirror `GitAdmission.cancel`). No re-entrancy —
  `syncDefaultBranch` and `apply` never acquire the gate themselves; callers hold it.
- Timeout: keep today's semantics — a landing that cannot get the gate within 30 min
  proceeds anyway (`AppModel+Hydra.swift:993`), because losing head work is worse. The
  gate makes that path rare instead of routine.
- The repo-common-dir lease (`:314-318`) stays: linked worktrees share refs, so ref
  mutations keep serializing at repository granularity while working-tree writes
  serialize at checkout granularity.

## Code changes

- `Tivano/Services/Git/Git.swift`: `ours` field out of `captureTree(onto:from:)`
  (`:467-523`); new `moveBranch` (update-ref transaction); new `writeIfMatches`/`removeIfMatches`
  per-file CAS helpers (or inline in sync); unchanged `updateRef(expecting:)` already
  exists (`:565`).
- `Tivano/Services/Git/CheckoutWriteGate.swift` (new): keyed gate + lease composition.
- `Tivano/App/AppModel+HydraMerge.swift`: `prepared` tuple gains `ours`
  (`:359,374,430`); `syncDefaultBranch` rewrite (`:1000-1040`); gate acquisition in
  `mergeHydraProject` (`:292`); gate around `:522` fast-forward.
- `Tivano/App/AppModel+Hydra.swift`: gate acquisition in `landHydraHead`/`applyHydraHead`
  (`:911-1043`); `waitForSettledCheckout` keeps the turn-file check, drops the merge
  wait (the gate supersedes it).
- `Tivano/App/Runtime/ThreadRuntime.swift`: gate around `Git.restore` (`:2692`).
- `Tivano/Core/Support/SharedResourceLock.swift`: no change needed — reuse
  `url(resource:)` with the canonical checkout path.

## Risks

- Merge holds the checkout gate for minutes (push, MR open/merge). Matches today's
  effective behavior — landings already wait — but makes the 30-min escape hatch the
  failure mode to watch. Consider releasing the gate between "MR merged" and sync start
  once per-file CAS lands, since CAS makes a late landing safe.
- `apply` under the gate while a *user's* git op (rebase) starts mid-apply: unchanged
  risk; `hasOperationInProgress` is still checked inside the gate.
- Quit mid-sync: branch may be moved while some `kept` writes are pending → checkout
  shows a honest dirty diff; next sweep reaches `.alreadyOnMain` and never re-syncs —
  same gap as today (`:408` early-return). Worth a note; fixing it means re-checking
  sync state in the alreadyOnMain path.
- Per-file `hash-object` cost scales with remote-changed files; batch via
  `hash-object --stdin-paths` if profiling shows it matters.
- Revert now queues behind a merge; `revert` already refuses while `isHydraMerging`
  (`ThreadRuntime.swift:1008-1011`), so behavior mostly holds.

## Test plan

- User edits a contested file between MR merge and sync → file keeps the edit; sync
  reports the file left alone; next merge offers it again.
- `git commit` from a terminal during the sync window → `update-ref` CAS fails,
  checkout untouched, user's commit stays reachable. `git switch` mid-sync likewise.
- Landing triggered while a merge holds the gate → lands after, patch applied whole;
  `markHydraMerged` never books a torn landing.
- Two leads' heads landing the same checkout → serialized, no interleaved writes.
- Dev merge + Release landing on one checkout → flock serializes them.
- SIGKILL mid-`checkoutPaths` → lease released by kernel; relaunch sweep completes the
  merge record; checkout left dirty-but-honest, no silent loss.
- `git apply` failure inside the gate → patch file kept (`keepHydraPatch`), gate
  released, next landing proceeds.
