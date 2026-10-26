# Hydra 2 chat UI audit

Static, read-only audit against `docs/hydra2.md`. No build or runtime checks were run, as instructed. “Required” means needed before v2 ships; “nice” means the current behavior is understandable or the improvement can follow.

## Result

- **18 surfaces reviewed: 9 required findings, 6 nice-to-have findings.**
- **204 catalog candidates reviewed:** 177 are referenced by Swift and 27 have no Swift reference. Among the live candidates, **13 need required text or mode-specific usage changes, 7 need optional wording changes, and 157 are correct as-is**. Generic labels in the audited views were also reviewed; the keyword count is not a count of every localized string in those files.
- The v1 direct-to-head switches are not a v2 defect: `hydraSendsToHeads` and `hydraQueuesToHeads` are both false when v2 is enabled (`Tivano/App/AppSettings.swift:834-837`). Their v1 strings and controls should remain for v1.

### Three most important findings

1. **Continuation is unsafe and partly invisible (R3–R6).** Dismissing or clearing the panel can release the copy that `continue` needs; a finished head can also be restarted directly from its panel, bypassing the lead’s continuation path. An accepted continuation does not restore an auto-collapsed head to the panel, and the lead timeline counts it as a new head before erasing the evidence.
2. **The report digest does not understand the v2 format (R7).** `Flags:` precedes the landing line, but the parser only accepts landing first. Flags, landing files, file totals, and format warnings are therefore missing or buried in raw report text.
3. **The independent review has no visible running state (R8).** The user can see nothing while review runs. When findings arrive, the generic Hydra popover also exposes the lead’s instruction paragraph rather than presenting just the review.

## Required before v2 ships

### R1 — Onboarding and the composer teach v1’s size-based delegation

**Classification: wording describes v1 behavior.**

V2 does not map “big” to delegated and “small” to the lead. It keeps coupled, judgement-heavy work with the lead and can delegate a bounded piece for parallelism, context isolation, or the partner model’s strengths (`docs/hydra2.md:28-39`). These strings say the old rule:

- `Tivano/App/Views/Composer/ComposerView.swift:335-343`: “big jobs go out to a team of heads”.
- `Tivano/App/Views/Chat/HydraIntroPopover.swift:19-30` and `:130-134`: “Big jobs” and “anything bigger it splits into briefs”.
- `Tivano/App/Views/Chat/HydraButton.swift:324-328`: ask for “something big enough to split up”.
- `Tivano/App/Views/Chat/HydraIntroPopover.swift:103-107`: “One chat leads a team of heads on big jobs.”

**Exact fix:** replace these five catalog keys everywhere they are used, and update zh-Hans with them:

- `Ask %@ for anything; big jobs go out to a team of heads` (`Tivano/Resources/Localizable.xcstrings:3261`) →
  **“Ask %@ for anything; the lead decides what to do itself and what to delegate”**
- `Ask as you always do. Small things it does itself; anything bigger it splits into briefs.` (`Tivano/Resources/Localizable.xcstrings:3283`) →
  **“Ask as you always do. The lead keeps tightly coupled work and decides which independent pieces to brief to heads.”**
- `Hydra is on. Big jobs go out to a team of heads, so this chat leads instead of doing everything itself.` (`Tivano/Resources/Localizable.xcstrings:9531`) →
  **“Hydra is on. This chat leads the work, delegating independent pieces to a team of heads instead of doing everything itself.”**
- `No heads are out yet. Ask for something big enough to split up and this chat sends them out, each with a panel of its own.` (`Tivano/Resources/Localizable.xcstrings:11654`) →
  **“No heads are out yet. Send a request and the lead will decide what to do itself and what to delegate. Each head gets a panel of its own.”**
- `One chat leads a team of heads on big jobs.` (`Tivano/Resources/Localizable.xcstrings:12237`) →
  **“One chat leads a team of heads, keeping judgement and delegating independent work.”**

These replacements are valid in both versions, so v1 history does not need mode-specific copy.

### R2 — The streaming card animates brief previews as though heads are already going out

**Classification: behaves wrongly under v2.**

`HydraDelegationBlock` reveals each entry as its JSON object closes, animates `delegations.count`, and says “Summoning…” (`Tivano/App/Views/Chat/TimelineRows.swift:723-786`, `:825-833`). The Markdown renderer passes only JSON and `sent`; it has no job mode with which to distinguish v2 (`Tivano/UI/Markdown/MarkdownView.swift:381-390`). V2 actually skips streaming dispatch and waits for the complete block (`Tivano/App/Runtime/ThreadRuntime.swift:3825-3829`, `:4103-4115`).

**Exact fix:**

- Thread the stamped job mode, or a `waitsForBlockEnd` Boolean derived from it, through `MarkdownDelegationCard.render` into `HydraDelegationBlock`. Do not use the current global Labs setting for historical replies.
- In v2, buffer all entry rows until `reading.isComplete`. Do not animate entry count while the block streams.
- While incomplete, show **“Preparing the delegation…”** and, if a second line is wanted, **“No heads go out until the block is complete.”**
- Only after completion and actual dispatch may the card use the existing “Summoning…” / “Summoned…” text. Keep those keys for v1; do not use them for a continuation or a refused entry (R3).

### R3 — `continue` is counted as a new head, then removed from the lead’s history

**Classification: shows something that does not happen and misses a durable v2 event.**

The card ignores `continueHead`, so a continuation gets the new-head row and is included in “Summoned N heads” (`Tivano/App/Views/Chat/TimelineRows.swift:791-833`). The whole block is marked sent before continuation outcomes are known and then fades away (`Tivano/App/Runtime/ThreadRuntime.swift:3959-3975`, `:4007-4017`, `:4063-4081`). Unlike a new dispatch, continuation creates no linked `.agent` timeline entry: `continueHydraHead` only sends a brief into the existing head (`Tivano/App/AppModel+Hydra2.swift:123-128`). The lead’s `HydraHeadsList` therefore has no lasting row for it (`Tivano/App/Views/Chat/TimelineRows.swift:1519-1533`).

**Exact fix:**

- Split new-head and continuation entries in the card and in its outcome counts. Use:
  - **“Sending Hank back to work”** / **“Sent Hank back to work”** for one continuation;
  - **“Sending 2 new heads and 1 continuation”** / **“Sent 2 new heads and 1 continuation”** for a mixed block;
  - **“Hank was not sent back”** plus the existing refusal reason when continuation fails.
- Never count a refused continuation as sent.
- Add a persistent linked timeline entry for every accepted continuation, pointing at the existing head rather than creating a new head. Its labels should be **“Sending Hank back: <task>”** while running and **“Sent Hank back: <task>”** when complete. This entry must remain after the delegation card fades and must open the existing head’s steps.

### R4 — A continued head does not return to the team panel after auto-collapse

**Classification: misses the visible running state of a v2 continuation.**

Finishing clears `isInPanel` after the hold (`Tivano/App/AppModel+Hydra.swift:789-804`). `panelHeads` and the Hydra button only read heads still in the panel (`Tivano/App/AppModel.swift:666-676`; `Tivano/App/Views/Chat/HydraButton.swift:27-35`). `continueHydraHead` flips status back to running but does not restore panel membership (`Tivano/App/AppModel+Hydra2.swift:123-128`). New-head dispatch already restores the panel and selects the head (`Tivano/App/AppModel+Hydra.swift:648-651`); continuation needs the same treatment.

**Exact fix:** after all continuation guards succeed and before `sendHydraBrief`, set the existing head’s `isInPanel = true`, set the lead runtime’s `isHydraPanelHidden = false`, and set `hydraSelectedHeadID` to that head. This restores the running badge, progress, and report location without creating a new thread.

### R5 — Dismissing or clearing the panel can delete a copy that v2 must retain

**Classification: behaves wrongly and breaks a later `continue`.**

“Clear finished heads” and dismissing the panel both reach `clearFinishedHydraHeads` (`Tivano/App/Views/Chat/HydraPanel.swift:231-264`, `:345-350`). That method hides every finished head and unconditionally calls `releaseHydraCopy` (`Tivano/App/AppModel+Hydra.swift:1181-1199`). V2 instead requires completed copies to remain until the job settles; a later continuation explicitly refuses “its copy was already released” (`Tivano/App/AppModel+Hydra2.swift:115-127`).

**Exact fix:** put the retention guard in `releaseHydraCopy`, so every UI caller is safe: when the head is v2, its `jobID` matches the lead’s currently open job, and that job is still open, do not release the copy. Panel dismissal and “Clear finished heads” may still set `isInPanel = false`. `releaseHydraJobCopies` already runs after the job is marked finished (`Tivano/App/AppModel+Hydra2.swift:88-99`), so settlement will still release the copy normally.

### R6 — A finished head in an open v2 job can be restarted directly from its composer

**Classification: bypasses v2’s lead-owned continuation flow.**

Every Tivano head gets a composer in the team panel (`Tivano/App/Views/Chat/HydraPanel.swift:498-505`) and in the standalone head panel (`Tivano/App/Views/Chat/SubagentPanel.swift:293-298`), regardless of status. A normal send into a finished head explicitly changes it back to running (`Tivano/App/Runtime/ThreadRuntime.swift:1711-1718`). That path bypasses the open-job, ownership, copy, batch, and continuation-ledger handling in `continueHydraHead` (`Tivano/App/AppModel+Hydra2.swift:103-128`).

**Exact fix:**

- When the selected head is finished, is v2, and its `jobID` is the lead’s open job, disable the composer in the floating panel, standalone panel, and full head chat. Show **“Finished · the lead can send this head back to rework its part.”**
- Keep the composer for a running head and restore it after the job settles; this guard is specifically for a finished head whose job is open.
- Enforce the same condition in the head’s normal `startTurn` path as a backstop, so another entry point cannot bypass the UI guard.

### R7 — The v2 `Flags:` block breaks report parsing and is not surfaced as report state

**Classification: behaves wrongly and misses v2 report flags.**

V2 writes each section in this order: head header, `Flags:`, landing line, then the original report (`Tivano/Core/Models/HydraPrompts+V2.swift:155-179`). `HydraReportDigest` only recognizes a landing line if it is the first content after the header (`Tivano/App/Views/Chat/HydraReportsPopover.swift:61-73`). Consequently:

- `Flags:` and the landing line fall into the raw body; landing rows and file totals disappear (`Tivano/App/Views/Chat/HydraReportsPopover.swift:377-430`, `:552-585`).
- Multi-head reports start collapsed, so flags and format warnings are hidden behind expansion (`Tivano/App/Views/Chat/HydraReportsPopover.swift:227-234`, `:463-508`).
- The pill still says “is done” even when the head reported unfinished work (`Tivano/App/Views/Chat/TimelineRows.swift:395-411`).
- Single-head and steps popovers show only raw `summary`; neither presents `reportNotes` or a missing-format warning (`Tivano/App/Views/Chat/HydraHeadPopovers.swift:58-72`; `Tivano/App/Views/Chat/TimelineRows.swift:1861-1898`).

**Exact fix:**

- Extend the digest head with structured flags and a `reportFormatMissing` flag. Parse the `Flags:` block before the existing landing parser: `none` means no flags; `Report format not followed.` sets the warning; named `Deviations`, `Unfinished`, and `Uncertain` values populate the structured fields. Then parse landing and the report body as before.
- Render the three flags as dedicated rows, with unfinished work visually prominent. Do not show the same trailing flag lines twice in the raw report body.
- Use **“Hank reported open points”** or **“%d heads reported open points”** in the report pill when any flag is present, and **“Report format not followed.”** for the format warning. Keep “done” only for an unflagged, correctly formatted completion.
- Show the same flag rows and format warning in `HydraReportsPopover`, `HydraHeadReportPopover`, and `HydraHeadStepsPopover`, restoring the existing landing/file presentation.

### R8 — Review work is invisible, and its eventual popover includes lead-only instructions

**Classification: misses the v2 review phase and presents its turn incorrectly.**

The review performs Git work and awaits an external model before it calls `sendHydraReview` (`Tivano/App/AppModel+HydraReview.swift:88-117`). No timeline state represents that interval; the timeline only adds head, background-task, and merge states (`Tivano/App/Views/Chat/ThreadTimeline.swift:167-186`, `:3200-3214`). When findings arrive, `[Hydra] Review` becomes a generic Hydra note (`Tivano/App/Views/Chat/TimelineRows.swift:303-360`). Its popover includes “For each finding, write…” and the rest of the lead’s instructions (`Tivano/Core/Models/HydraPrompts+V2.swift:280-288`), rather than just the reviewer and findings.

**Exact fix:**

- Set observable review UI state before the external review starts and clear it on every exit. Add a timeline pill while it runs: **“Independent review by %@…”**. Do not add the reviewer to the team panel; the design explicitly excludes it from that batch.
- Render `[Hydra] Review` as a review-specific row titled **“Independent review by %@”**, with the findings in its popover. Separate the final lead-instruction paragraph from the user-facing findings, just as head-report parsing removes lead-only closing instructions.
- Preserve the designed no-findings/skip behavior: clear the running indicator and continue to merge without inventing a blocking error. A no-findings or skip note in the ledger does not require a new chat message.

### R9 — The Labs description promises review on every changed job

**Classification: wording overstates v2 behavior.**

The catalog says “another vendor's model reviews the changes before they merge” (`Tivano/Resources/Localizable.xcstrings:7914`; used at `Tivano/App/Views/Settings/AlphaSettingsPage.swift:68-72`). Review can be skipped when no other-vendor CLI is available, when there are no changes, or when review fails (`Tivano/App/AppModel+HydraReview.swift:17-22`, `:51-53`, `:99-109`). Automatic merge can also be off. The user brief’s “may run” is the accurate contract.

**Exact replacement:**

> Every new request in a Hydra chat runs the new team design: the lead keeps judgement and does coupled work itself, heads get your request and the team's file split, report deviations and open points, can be sent back to rework their part, and another vendor's model may review the changes before the job settles and any automatic merge. Turning it off returns new requests to the current Hydra.

Update zh-Hans with the key. This is a catalog finding; it does not require changing the review algorithm.

## Nice to have

### N1 — Intro and history copy still implies one brief for the head’s whole lifetime

**Classification: v1 wording and incomplete v2 explanation.** V2 continuation sends another brief into the same head. Six live intro strings should say “initial” or “new head” rather than “one brief” (`Tivano/App/Views/Chat/HydraIntroPopover.swift:37-43`, `:103-178`). The Codex-history subtitle’s “continue” can also be confused with v2 continuation.

**Exact replacements:**

- `A head gets a self-contained brief…` (`Tivano/Resources/Localizable.xcstrings:2084`) → **“A head starts with a self-contained brief and has its own panel beside the chat, on the model its pair names or the chat's own.”**
- `Each head gets one brief…all working at the same time.` (`Tivano/Resources/Localizable.xcstrings:7474`) → **“Each new head gets a brief and a panel of its own beside the chat, all working at the same time.”**
- The longer variant (`Tivano/Resources/Localizable.xcstrings:7485`) → **“Each new head gets a brief and a panel of its own beside the chat, all working at the same time. Heads use the selected models to do their tasks, then return their reports to the lead chat. A finished head can be sent back to rework its part.”**
- The Hank/Walter/Ada variant (`Tivano/Resources/Localizable.xcstrings:7496`) → **“Each new head gets a brief and a panel of its own beside the chat. Hank, Walter, Ada and the rest work at the same time; a finished head can be sent back to rework its part.”**
- `One brief, one panel` (`Tivano/Resources/Localizable.xcstrings:12226`) → **“One head, one panel”**
- `The helpers a chat sends out, one brief each.` (`Tivano/Resources/Localizable.xcstrings:17594`) → **“The helpers a chat sends out, starting with one brief each.”**
- `Archive completed heads and keep the option to continue.` (`Tivano/Resources/Localizable.xcstrings:3151`) → **“Archive completed Codex heads and keep the option to resume them.”**

Optionally add a v2-only intro sentence: **“Reports include deviations, unfinished work and uncertainties. The lead can send a finished head back to rework its part, and another vendor's model may review the changes before the job settles.”** Use the current setting only for this pre-job intro, not for historical timelines.

### N2 — The delegating badge can open an idle popover and advertise “0 heads working”

**Classification: misleading intermediate state.** While a block is being written, `isDelegating` can be true with no heads (`Tivano/App/Views/Chat/HydraButton.swift:30-37`). Clicking then opens the idle popover because `heads.isEmpty`, and the sending badge’s fallback help formats the running count as “0 heads working” (`Tivano/App/Views/Chat/HydraButton.swift:53-57`, `:634-657`).

**Exact fix:** when `isDelegating && heads.isEmpty`, show **“Preparing a delegation. No heads go out until the whole block is ready.”** instead of the idle prompt. When the badge is sending with `running == 0`, use **“Preparing the delegation · Show or hide the Hydra panel”** instead of a numeric zero.

### N3 — The delegation plan does not show v2 file ownership

**Classification: misses useful v2 information.** The card shows task and project but not `files` (`Tivano/App/Views/Chat/TimelineRows.swift:791-820`), although ownership and overlap rejection are central to v2 (`docs/hydra2.md:43-48`).

**Exact fix:** add a second, truncated line to each completed preview row: **“Owns: path/one, path/two”**. Show all paths in its help or popover. This also makes the plan understandable before any overlap refusal.

### N4 — Refusals use the generic Hydra note rather than a clear refusal state

**Classification: present but under-specified UI.** Missing files, overlap, and failed continuation messages are already visible through `HydraReportRow`; this is not a missing error (`Tivano/App/Views/Chat/TimelineRows.swift:303-360`). However, the title is truncated and the claims/reason are hidden behind a generic chevron. The refusal formats are at `Tivano/Core/Models/HydraPrompts+V2.swift:242-258`.

**Exact fix:** recognize these prefixes and use a warning pill titled **“Delegation refused”** or **“Continuation refused”**. Put the affected paths, owners, and reason directly in the popover; omit the lead-only “resend” instruction from the user presentation. Keep the current full message available to the lead.

### N5 — `headsNote` is invisible in the composer’s pair summaries

**Classification: misses a v2 pairing detail.** The pair editor records what heads are good at (`Tivano/App/Views/Settings/HydraSettingsPage.swift:559-574`), but the composer tooltip only includes the pair title and the picker detail only includes models, providers, and effort (`Tivano/App/Views/Composer/EffortSlider.swift:166-175`, `:677-683`).

**Exact fix:** when v2 applies and `headsNote` is non-empty, append **“Heads: <note>”** to `ModelEffortButton.helpText` and the pair row’s `detail`. Keep the model title unchanged.

### N6 — Head-level status does not expose report flags

**Classification: useful secondary surfacing of v2 data.** Panel and hover status only say done/working (`Tivano/App/Views/Chat/HydraPanel.swift:567-601`; `Tivano/UI/Markdown/HydraHeadHoverPopover.swift:82-88`). R7 is the required fix in actual report views; this is the optional at-a-glance version.

**Exact fix:** append **“ · open points”** when `reportNotes.flagsSomething`, and **“ · report format missing”** for a completed v2 head whose notes could not be parsed. Extend `HydraMentionTarget` with the report state so the hover card can show the same wording.

## Surface coverage

| Surface | V2 verdict | Findings |
|---|---|---|
| `HydraButton.swift` | Size-based idle copy is wrong; delegating state can be clearer | R1; N2 |
| `HydraIntroPopover.swift` (intro, info, history) | Size-based copy is wrong; lifecycle copy can be more precise | R1; N1 |
| `HydraPanel.swift` | Finished-head composer and copy-clearing actions are unsafe | R4–R6; N6 |
| `HydraMergePopover.swift` | **Correct:** merge content and head landing cards are unchanged by v2 | — |
| `TimelineRows.swift` (reports, briefs, delegation, heads, merge) | Delegation/continue and report-format handling need fixes | R2, R3, R7; N3, N4, N6 |
| `ComposerView.swift` | Placeholder is v1; direct/queued routing itself is correctly suppressed under v2 | R1 |
| `EffortSlider.swift` | Pair/model/effort UI is correct; pair note can be exposed | N5 |
| `HydraFusedPairIcon.swift` | **Correct:** decorative pair identity, reduced-motion handling intact | — |
| `HydraHeadHoverPopover.swift` | Status and opening the same head work; flags are optional additions | N6 |
| `HydraPairMark.swift` | **Correct:** lead/head meaning and accessibility remain valid | — |
| `HydraReportsPopover.swift` | V2 `Flags:` layout is incompatible with the parser | R7 |
| `HydraHeadPopovers.swift` | Brief is correct; single report needs structured flags/warnings | R7 |
| `HydraProgressBar.swift` | **Correct:** progress is mode-neutral; a continued turn adds new activity normally | — |
| `ThreadTimeline.swift` | No review-running state; no persistent continuation entry | R3, R8 |
| `ChatView.swift` | Panel membership hides a continued head; dismiss reaches copy release | R4, R5 |
| `SubagentPanel.swift` | Standalone finished-head composer needs the same guard | R6 |
| `MarkdownView.swift` | Delegation renderer lacks the stamped mode needed for v2 presentation | R2, R3 |
| `ChatBadge.swift` | **Correct:** generic badge/popover behavior; suitable reuse for review | — |

Mention scanning, head links, and opening a head by name were also checked. Continuing uses the same thread, so those paths do not need a new target or persona.

## String coverage and counting

The catalog sweep used Hydra/head/lead/team/brief/delegation terminology and then checked reachability in Swift. Some matches are generic rather than Hydra-exclusive; they were judged in their actual surfaces, not treated as stale merely because they contain a keyword.

- **13 live keys with required changes:** the five replacements in R1, the seven delegation labels below, and the Labs description in R9.
- **7 live keys with optional changes:** the seven replacements in N1.
- **157 other live candidates are correct under v2.** This includes `Writing the next brief…`, which remains literally true; R2 changes when rows appear, not that sentence.
- **27 candidates have no Swift reference.** They are not live v2 UI and need no ship fix. This group includes old native-provider and direct-routing copy; its presence in the catalog is not evidence that the behavior still occurs.

The seven delegation keys that need mode-specific use are `Summoned %@`, `Summoned %d heads`, `Summoned a head`, `Summoning %@`, `Summoning %d heads`, `Summoning a head`, and `Summoning heads` (`Tivano/Resources/Localizable.xcstrings:16802-16877`). Keep them for actual new-head dispatch and v1; add the v2 preparing/continuation strings from R2–R3 rather than deleting these keys.

Twelve correct live keys are explicitly v1-only and are hidden or suppressed under v2:

- Composer: `Goes to a head; %@ leads and reports back`, `Heads are at work: your message goes to a head`, `Send to a head`, and `Send to a head (Return) · the lead reports back`.
- Settings routing: `Every message goes to a head`, `Heads are already preferred for messages.`, `Prefer heads for messages`, `Send queued follow-ups to heads`, `Each one goes to a head as soon as there is room, instead of waiting for the lead.`, and `Use heads when there is room. Commands and messages that cannot be delegated stay with the lead.`
- V1 review switch: `Ask the lead to review heads' changes` and `Adds a review step before the lead finishes. This uses additional time and tokens.`

The v1 settings branch is excluded when v2 is on (`Tivano/App/Views/Settings/HydraSettingsPage.swift:184-217`), and the computed routing getters suppress the composer/runtime paths (`Tivano/App/AppSettings.swift:834-837`). Do not remove these twelve keys or their zh-Hans translations while v1 remains supported.

All replacement or newly introduced user-facing strings above need English keys and faithful zh-Hans entries under the project’s localization rules.