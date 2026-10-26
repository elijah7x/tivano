# Hydra 2 runtime and provider audit

2026-10-26 · Source inspection only; no builds or runtime checks.

**18 findings: 14 wrong behaviour, 4 quality loss, 0 cosmetic.**

## Three most important

1. **R01 — Starting another request abandons the current job.** Old reports can switch format, review is skipped, and late heads retain copies indefinitely.
2. **R02 — A waiting head is stamped with the newest job, not its batch.** It can be written into two job ledgers, with later status and brief updates applied to the wrong one.
3. **R03 — The review does not use the job's actual change set.** Shared-checkout and other-checkout work can merge unreviewed, while pre-existing or unrelated edits can be shown to the reviewer as part of the job.

## Wrong behaviour

### R01. A new request or mode flip abandons an in-flight job

**Where:** `Tivano/App/AppModel+Hydra2.swift:21-25`, `Tivano/App/AppModel+Hydra2.swift:75-99`, `Tivano/App/Runtime/ThreadRuntime.swift:1691-1699`, `Tivano/App/Runtime/ThreadRuntime.swift:3714-3718`, `Tivano/App/AppModel+Hydra.swift:826-832`.

**Failure:** With job A's heads still running, starting v2 job B closes A immediately and releases only heads that had already finished. A's late heads retain their copies after B settles because their `jobID` is not B's; A never receives its review or final settlement. If B is v1 instead, A remains open but the runtime switches to v1 report formatting and v1 settlement, so A's v2 copies are likewise left behind. This violates the rule that changing Labs only affects the next job, not the job already in flight.

**Fix:** Carry `jobID` and `mode` on every batch and report, and settle/release by that identity rather than the runtime's single current values. Until concurrent jobs are supported, queue a new user turn while an earlier job is open instead of closing it in `beginHydraJob`. A transitional cleanup must also release a head when its already-closed job finishes; closing the record alone does not clean up late heads.

### R02. Delayed dispatch uses the current job instead of the head's batch

**Where:** `Tivano/App/Runtime/ThreadRuntime.swift:3962-3964`, `Tivano/App/Runtime/ThreadRuntime.swift:4167-4192`, `Tivano/App/AppModel+Hydra.swift:628-644`.

**Failure:** Job A has tasks waiting behind `maxHeads`. Job B starts before a slot opens. `insertHydraHead` stamps the waiting head with open job B and appends a record to B, then `spawnWaitingHeads` uses `batch.jobID == A` and appends/updates a record in A. The physical head now has two ledger entries; its `info.jobID` still points to B, so A's record is not finalized and B's record lacks the batch's ownership data. On a v2-to-v1 flip, the old batch still uses its v2 packet while the new head is stamped v1, reversing the report and copy-release contracts.

**Fix:** Store an explicit mode on `HydraBatch` and pass that mode plus `batch.jobID` through `spawnTivanoHead` into `insertHydraHead`. Never infer a delayed head's job from `openHydraJob` or the runtime's current mode. Create its single ledger record from the batch identity at actual dispatch.

### R03. Review diff discovery misses job work and includes non-job work

**Where:** `Tivano/App/AppModel+Hydra2.swift:76-85`, `Tivano/App/AppModel+HydraReview.swift:29-82`, `Tivano/App/AppModel+Hydra2.swift:31-36`.

**Failure:** Three cases break the mandatory review:
- A shared-checkout head has `landing == nil`, so its edits contribute neither to `hasWork` nor to the review paths. A shared-head-only job skips review and can auto-merge anyway.
- Work routed to another project/checkout is filtered through `TouchedPaths.relative(..., root: leadCheckout)`. It disappears from the patch; with no lead-checkout edits, review records `no changes` and merge proceeds across the other checkout unreviewed.
- The patch is `git diff <job.baseCommit>` for each selected path. If a file was already dirty, or another writer touched it after the job began, those unrelated edits are included as though they were the job's.

**Fix:** Build one job-owned change set grouped by checkout from the lead's tool edits and every job head's timeline, including shared heads and foreign checkouts. Snapshot a base tree per checkout, not only the lead's HEAD, and diff that base to the reviewed candidate while excluding pre-existing and sibling-owned changes. Trigger review from that actual diff, not `landedFiles` and lead `touchedPaths` proxies.

### R04. Voice never enters the v2 job/runtime path

**Where:** `Tivano/App/AppModel+Voice.swift:43-50`, `Tivano/Services/Providers/CodexSession.swift:281-292`, `Tivano/App/Runtime/VoiceController.swift:264-316`, `Tivano/App/Runtime/ThreadRuntime.swift:3125-3155`, `Tivano/App/Runtime/ThreadRuntime.swift:1691-1699`.

**Failure:** `voiceCallContext` leaves `HydraLaunch.mode` at its v1 default, and Codex replaces its normal developer policy with voice instructions containing that v1 policy. Voice-driven provider turns open through `openBackgroundTurn`, not `startTurn`, so no v2 mode or job is stamped. With Labs v2 enabled, a fresh voice lead therefore gets delegate-first/stream-as-written v1 behaviour, no `files` requirement, no v2 ledger, and no v2 review/settlement. If an older v2 job is open, the mismatch instead produces v1 briefs whose blocks v2 rejects for missing `files`.

**Fix:** Add a voice-turn boundary equivalent to `startTurn` that stamps and begins the job before any assistant delta is handled, with the spoken request and attachments captured for its packet. Build both `voiceContext` and `voiceInstructions` from that stamped launch; do not independently default a second launch to v1.

### R05. Direct and queued head dispatch reads live settings, not the stamped job mode

**Where:** `Tivano/App/AppSettings.swift:834-837`, `Tivano/App/Runtime/ThreadRuntime.swift:1418-1430`, `Tivano/App/Views/Composer/ComposerView.swift:339-355`.

**Failure:** Under v2 every user message must reach the lead; direct-to-head and queued-to-head routing are suppressed through `hydraQueuesToHeads` / `hydraSendsToHeads`. Those gates read the live Labs switch, not the mode stamped on the lead's current job. Turning Hydra 2.0 off mid-job re-enables v1 routing while a v2 job is still open, so a message can reach a head with a v1 `queuedHeadPrompt` and no v2 packet; turning it on mid-job does the reverse for a v1 job.

**Fix:** Do not add a v2 direct-dispatch path; that would bypass lead-owned delegation. Gate `dispatchQueuedHead`, `dispatchSentHead` and the composer hints on the stamped job mode (`hydraJobMode`, or the open job's mode) as well as the setting, so any message arriving while a v2 job is open goes to the lead. See `docs-data.md` D03.

### R06. Relaunch has no v2 recovery and can merge before review

**Where:** `Tivano/App/AppModel.swift:380-392`, `Tivano/App/AppModel.swift:421-433`, `Tivano/App/AppModel+HydraMerge.swift:75-106`, `Tivano/App/Runtime/ThreadRuntime.swift:3548-3556`.

**Failure:** Relaunch marks running head threads stopped but does not update their `HydraJobHeadRecord`s, rebuild batches, emit reports, or close open jobs. The only settlement call is at the end of a newly completed lead turn, so the job and retained copies can remain open indefinitely. If the last lead turn is merge-ready, `resumeHydraMerges` instead calls the generic v1 merge directly, bypassing v2 review and still leaving the job open and its ledger heads marked running.

**Fix:** Recover open v2 jobs before `resumeHydraMerges`: load their histories, reconcile stopped head records and outstanding batches, preserve or explicitly fail waiting work, deliver the required reports, then run review/merge/settlement by job ID. Generic merge recovery must skip an open v2 job until that path finishes. Persist enough batch state to recover, or record the unrecoverable batch explicitly instead of leaving it running forever.

### R07. Turning Hydra off strands the open job

**Where:** `Tivano/App/AppModel+Hydra.swift:281-286`, `Tivano/App/AppSettings.swift:797-801`, `Tivano/App/AppModel+Hydra.swift:230-231`, `Tivano/App/Runtime/ThreadRuntime.swift:3548-3556`.

**Failure:** Turning Hydra off per chat or globally makes `hydraLaunch` nil and makes the settlement guard fail. Existing heads can finish, but the job gets no v2 review, close, or copy release; re-enabling Hydra does not itself resume settlement. The generic merge path also requires `hydraIsOn`, so it does not provide a safe fallback.

**Fix:** Give the off transition an explicit job-finalization path independent of the current switch. Either drain the stamped job under its snapshotted launch before disabling new delegation, or cancel it explicitly, record that outcome, stop/drain its heads, and release copies with unlanded work preserved. Do not leave `openHydraJob` dependent on Hydra being switched back on.

### R08. A failed or stopped final lead turn never finalizes the job

**Where:** `Tivano/App/Runtime/ThreadRuntime.swift:3512-3524`, `Tivano/App/Runtime/ThreadRuntime.swift:3544-3556`, `Tivano/App/AppModel+Hydra2.swift:21-25`.

**Failure:** Settlement requires `status == .completed`. If the final report/integration turn fails while finished v2 heads are retained and no head or batch remains active, nothing else closes the job or releases those copies. A later v2 request merely stamps `finishedAt` on the old record; a later v1 request leaves it open. Stopping the lead has the same unresolved state once pending reports are drained.

**Fix:** Add a terminal failed/interrupted settlement path after outstanding reports and landings drain. Record the interrupted outcome, skip automatic merge unless the job reached a valid final response, and release copies with unfinished work preserved. If the intended state is instead “awaiting user recovery,” represent and recover it explicitly rather than leaving an undocumented permanent open job.

### R09. Dismiss/Clear releases copies while continuation is still promised

**Where:** `Tivano/App/AppModel+Hydra.swift:1181-1199`, `Tivano/App/AppModel+Hydra2.swift:97-100`, `Tivano/App/AppModel+Hydra2.swift:118-127`.

**Failure:** While a v2 job is open, dismissing the panel or choosing Clear finished heads calls `releaseHydraCopy` immediately. Once that asynchronous release finishes, a lead entry with `continue: "<head>"` is refused with `its copy was already released`, although v2 says finished heads remain continuable until settlement.

**Fix:** In `clearFinishedHydraHeads`, remove finished heads from the panel without releasing copies whose `jobID` belongs to an open v2 job. Let `releaseHydraJobCopies` remain the single release point for those heads.

### R10. Continuations bypass the cap and disappear from running-head accounting

**Where:** `Tivano/App/Runtime/ThreadRuntime.swift:3973-4005`, `Tivano/App/AppModel+Hydra2.swift:123-128`, `Tivano/App/AppModel+Hydra.swift:791-804`, `Tivano/App/AppModel+Hydra.swift:312-319`, `Tivano/App/AppModel+Hydra.swift:1174-1178`.

**Failure:** Every continuation in a block is started directly without `launch.hasRoom`; several continued heads can exceed `maxHeads`, including a cap of one. Finished heads are also removed from the panel after a short hold, and continuation does not set `isInPanel` again. Because running counts and Stop all use panel heads rather than `hydraTeam`, a continued head can be invisible to the cap, working-head guards, and Stop all while it is actually running.

**Fix:** Put continuations through the same waiting scheduler as new heads, preserving their target and batch, and admit them only when `hasRoom` succeeds. Restore the continued head to the panel, and make runtime running/stop accounting use all team heads rather than panel visibility.

### R11. A pending review is treated as permission to close

**Where:** `Tivano/App/AppModel+HydraReview.swift:105-118`, `Tivano/App/AppModel+Hydra2.swift:83-93`.

**Failure:** If the lead becomes busy while the external review runs, `reviewHydraJob` stores `pendingReview` and returns `false`. `settleHydraJob` interprets that as “no review turn started,” proceeds to its merge/close section, marks the job finished, and releases copies before the findings are delivered. Merge usually refuses the busy runtime, leaving a closed job with a pending review and no completed merge result.

**Fix:** Distinguish “review skipped, settle now” from “review pending, wait.” Return immediately whenever `pendingReview` was written or a review turn started; close only after that review turn completes and settlement runs again.

### R12. Merge results are written to whichever v2 job is last, and settlement does not await a terminal result

**Where:** `Tivano/App/AppModel+HydraMerge.swift:1148-1150`, `Tivano/App/AppModel+HydraMerge.swift:546-557`, `Tivano/App/AppModel+Hydra2.swift:88-93`.

**Failure:** `recordHydraJobMerge` ignores the job that initiated the merge. A later v1 auto-merge therefore overwrites the latest historical v2 job's merge result; a retry after another v2 job starts can do the same to that newer job. Separately, `settleHydraJob` awaits a `Void` merge call and closes even when it returned early or deferred with a retry outstanding, leaving `merge == nil` until an unscoped retry updates some job later.

**Fix:** Pass an optional job ID through `autoMergeHydraWork`, all retry/activity state, and `recordHydraJobMerge`; v1 calls carry nil and must never update a v2 record. Return an explicit merged/failed/deferred/no-work result and keep settlement pending on deferred work, or persist a merge-pending state tied to that same job until its retry finishes.

### R13. Path aliases bypass duplicate-ownership validation

**Where:** `Tivano/App/Runtime/ThreadRuntime.swift:3935-3947`, `Tivano/App/Runtime/ThreadRuntime.swift:4057-4060`.

**Failure:** Overlap detection only trims and removes leading `./`. One entry can claim `Tivano/App/A.swift` and another `Tivano/App/../App/A.swift`, or one can use the relative path and the other the absolute path. Both entries pass and two parallel heads receive ownership of the same physical file.

**Fix:** Resolve every ownership path against its delegation's target checkout and compare standardized canonical identities, including absolute-versus-relative and `..` forms; reject empty/unresolvable paths and paths outside the checkout. Perform overlap validation on those identities before charging or dispatching.

### R14. Continuations are charged and added to the handoff before they are validated

**Where:** `Tivano/App/Runtime/ThreadRuntime.swift:3950-3964`, `Tivano/App/Runtime/ThreadRuntime.swift:3973-4005`.

**Failure:** The round and `job.rounds` are charged before target existence, completion, job membership, and copy availability are checked. Three invalid `continue` blocks can therefore exhaust the delegation budget without sending any head. If the block also contains valid new heads, their already-snapshotted team packet includes the refused continuation as a working sibling with file ownership, so those heads plan around work that nobody is doing.

**Fix:** Resolve all continuation targets without mutating batch or head state first. Build the packet only from operations that can run, charge only when at least one new or continued head is admitted, and leave both budgets unchanged when every continuation is invalid. Update the batch packet after any partial refusal before spawning new heads.

## Quality loss

### R15. OpenAI-compatible retry protection mistakes undispatched v2 blocks for dispatched work

**Where:** `Tivano/Services/Providers/OpenAICompatibleSession.swift:506-557`, `Tivano/Services/Providers/OpenAICompatibleSession.swift:704-712`, `Tivano/App/Runtime/ThreadRuntime.swift:4113-4117`.

**Failure:** This provider code does not dispatch heads; it suppresses transport retry whenever streamed text contains a parseable delegation. In v2 the runtime's streaming dispatcher is disabled, so no head has gone out when that error occurs. A transient disconnect after one complete entry therefore fails the turn unnecessarily instead of safely retrying the request.

**Fix:** Apply the no-retry guard only when `configuration.hydra?.mode == .v1` and a parseable streamed entry exists. Keep v2 on the normal transient-retry path; its dispatch happens only after a completed reply.

### R16. Budget recovery still asks v2 heads for v1-style reports

**Where:** `Tivano/Core/Models/Hydra.swift:215-217`, `Tivano/Services/Providers/OpenAICompatibleSession.swift:315-337`, `Tivano/App/Runtime/ThreadRuntime.swift:3528-3536`, `Tivano/Core/Models/HydraPrompts+V2.swift:106-110`.

**Failure:** The pacing, wrap-up, and especially final-budget notes ask “what you changed, how far it got, and what is left” but never preserve the exact `Deviations`/`Unfinished`/`Uncertain` trailer. On an API head the budget note is appended after the original brief; on a CLI head it becomes a fresh final-report turn. A head following the latest instruction can omit the required lines, after which Tivano records a format failure and the lead/reviewer loses structured flags.

**Fix:** Carry the head's mode into the budget path and append the v2 report contract to pacing, wrap-up, and final-report notes, ideally by reusing one shared report-format constant. Keep the existing watchdog prefix; the parser can still find the three later lines.

### R17. Previous edits disable the stall watchdog on continued turns

**Where:** `Tivano/App/Runtime/ThreadRuntime.swift:1719-1729`, `Tivano/App/Runtime/ThreadRuntime.swift:4483-4487`, `Tivano/App/AppModel+Hydra.swift:1334-1337`.

**Failure:** `hydraEditCount` accumulates for the runtime's lifetime and is not reset when a head starts another turn. Once a head has edited, a later v2 continuation can sit quiet with no tools and no new edits without satisfying the watchdog's `hydraEditCount == 0` stall condition. The 35-minute hard budget eventually intervenes, but the intended 10-minute stall recovery is lost.

**Fix:** Track edits per turn and reset that counter at every head turn start, including continuations; keep a separate cumulative counter if the UI needs lifetime totals. Reset the activity timestamp at the same boundary for manually steered turns as well as brief-driven turns.

### R18. Shared-checkout continuations are told they have their own copy

**Where:** `Tivano/App/AppModel+Hydra2.swift:115-127`, `Tivano/Core/Models/HydraPrompts+V2.swift:114-121`.

**Failure:** A shared head correctly passes the continuation guard because it has no landing/copy record, and it resumes in the lead's checkout. Its new instruction nevertheless says “You keep your own copy and files,” contradicting its original shared-workplace rules. This can make a continued head assume isolation it does not have.

**Fix:** Pass the actual workplace into `v2ContinuePrompt`. For `.shared`, say explicitly that it continues in the lead's shared checkout and must leave others' changes alone; use the own-copy wording only for `.ownCopy`.

## Checked paths with no additional finding

- `OpenAICompatibleSession` does not itself spawn heads, and no other provider session parses delegation blocks for dispatch. Actual streaming dispatch is `ThreadRuntime.scanStreamedDelegations`, guarded to v1 at `Tivano/App/Runtime/ThreadRuntime.swift:4113-4117`; complete-reply dispatch selects v2 at `Tivano/App/Runtime/ThreadRuntime.swift:3893-3895`.
- All ordinary `hydraLaunch(for:)` callers in `ThreadRuntime` stamp the job mode before use (`1437`, `1839`, `2053`, `3824`, `4117`, `4160`). `AppModel+Hydra2.beginHydraJob` and `insertHydraHead` use launch only for configuration, and `EffortSlider` uses it only for display. Voice is the policy caller missing the stamp (R04).
- Profile selection still resolves through the pair launch and records the effective provider/model/effort on the head (`Tivano/App/AppModel+Hydra.swift:575-644`). The v2-specific cap bypass is continuation-specific (R10), not a separate profile-routing bypass.
- Shared heads are not inherently refused by `continueHydraHead`; the defect is their continuation wording (R18). Own-copy refusal after an actual release is correct, except when Clear causes that release prematurely (R09).
- Normal Stop all still routes stopped-head reports through the existing batch flow. Its blind spot for continued heads is R10; off, failed-turn, and relaunch abandonment are covered separately above.
