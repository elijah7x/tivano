# Hydra 2.0 settings audit

Scope: every Hydra-named `AppSettings` property, pair and cookbook configuration, every Hydra-related row in `HydraSettingsPage.swift`, `HydraCookbookPanel.swift`, and `AlphaSettingsPage.swift`, the pair editor, and per-project pair rules. Values were traced across `Tivano/`; v2 behavior was checked against `docs/hydra2.md` and `HydraPrompts+V2.swift`. Line numbers refer to this worktree. This was a read-only code audit; no build or runtime checks were run.

## Result

**69 items: (a) 54, (b) 6, (c) 3, (d) 6.** The count is one per row below, not one per underlying defect. A conditional no-op or design conflict is counted as (c) or (d); P13 has both and is counted once as (d). Recipe rows are counted as construction UI; pair-resolver defects are counted once on the responsible setting and cross-referenced on affected recipes.

- **(a) Works the same:** the value has the intended effect under v2.
- **(b) Works, but its wording is stale or misleading:** includes v1 size-based delegation copy and incomplete v2 explanations.
- **(c) Has no effect:** includes values ignored in all v2 jobs and values ignored in an identified v2 configuration.
- **(d) Conflicts with v2's design:** actual behavior differs from the documented model-aware delegation or handoff design.

The 41 global/pair/project/schema items split as **(a) 27, (b) 5, (c) 3, (d) 6**. The 28 remaining UI and recipe rows split as **(a) 27, (b) 1**.

### Most important findings

1. **Effort incorrectly changes v2's delegation strategy.** `headsMatchLead` compares effort as well as provider and model (`Tivano/App/AppModel+Hydra.swift:256-258`), while the design defines same-model solely by provider and model (`docs/hydra2.md:33-36`). Thus a same-model pair at two efforts—and the global tempering switch—can be treated as a partner-model team. The three same-model/two-effort cookbook presets hit this directly.
2. **`headsNote` is silently ignored for same-model pairs, and cookbook recipes cannot supply it.** The only prompt insertion is inside `if !launch.headsMatchLead` (`Tivano/Core/Models/HydraPrompts+V2.swift:19-23`), although the design says a nonempty note goes into the lead policy (`docs/hydra2.md:37`). `HydraPairRecipe` has no `headsNote`, and resolution never sets one (`Tivano/Core/Models/HydraCookbook.swift:19-25`, `Tivano/App/HydraCookbook+Resolve.swift:35-43`).
3. **Saved advanced head profiles still change v2 execution but have no editor.** V2 advertises them (`Tivano/Core/Models/HydraPrompts+V2.swift:25`) and spawning applies their provider, model, and effort (`Tivano/App/AppModel+Hydra.swift:579,592-598`). Yet the editor comment promises profiles “at the end” (`Tivano/App/Views/Settings/HydraSettingsPage.swift:502-505`) while the actual last setting is `Heads at once per chat` (`Tivano/App/Views/Settings/HydraSettingsPage.swift:712-729`). Existing users cannot inspect or change this behavior from Settings.

A related prompt defect: a same-provider pair with a different head model sets `headsMatchLead = false`, but `headsLabel` is only built for another provider (`Tivano/App/AppModel+Hydra.swift:241-245`). V2 therefore says “the selected partner model” instead of naming the model (`Tivano/Core/Models/HydraPrompts+V2.swift:9,19-20`), contrary to `docs/hydra2.md:36`.

## Exact behavioral fixes

These are the fixes referenced as F1–F5 below. Controls should remain; the defects are in resolution or missing data flow, not in having effort/model/profile settings. F1–F4 must leave v1 prompt text and session signatures unchanged (`docs/hydra2.md:9`).

- **F1 — remove effort from v2's same-model classification (G18, P5, P9; affects R10–R12).** Add a v2-only launch-finalization step wherever the runtime currently stamps `launch.mode = hydraJobMode`. Given the lead's provider and model, set `headsMatchLead = headsProvider == lead.provider && (workerModel ?? lead.model) == lead.model`. Do not unconditionally change the shared v1 launch value or signature. Effort remains execution configuration only, implementing `docs/hydra2.md:36`.
- **F2 — name every different head model in v2 (P8; affects same-provider recipes).** In `v2Policy`, use `launch.headsLabel ?? launch.workerModel ?? "the selected partner model"`; in `v2DelegationRequest`, use `launch.headsLabel ?? launch.workerModel ?? "partner-model"`. This names a same-provider override by its model ID without changing v1's shared `headsLabel` policy. A catalog short name may be supplied through the v2-only finalization instead.
- **F3 — apply `headsNote` to the pair actually running (P13).** Move the nonblank-note block outside `if !launch.headsMatchLead` in `v2Policy`, so same-model pairs are covered. In the v2-only launch finalization, suppress the note when `keepsModel` is false: an unavailable external heads provider has fallen back to the lead provider, so model-specific strengths must not be attributed to different fallback heads. Keep the editor field visible for every v2 pair; do not fold it into the presentation-only tagline.
- **F4 — let cookbook recipes carry the documented default note (P20).** Add `let headsNote: String?` to `HydraPairRecipe` and `pair.headsNote = recipe.headsNote` in `HydraCookbook.resolve`. Keep all recipe rows. Exact useful defaults are: `claude-opus-gemini-flash`: “fast, for parallel and mechanical work”; `claude-opus-deepseek`: “low-cost routine work”; `claude-opus-glm`: “low-cost routine work”; `claude-fable-composer`: “fast mechanical edits”; `astra-sol`: “complex implementation”; `sol-luna`: “quick routine work”. Leave the other six notes nil unless their taglines are intentionally meant as routing instructions. Carry the note into the lead policy only through F3's v2-only path, and keep recipe-added notes out of v1 session signatures.
- **F5 — restore visible control of advanced profiles (P12; UI gap, not an extra category).** Re-add an Advanced section to `HydraPairEditor` after `Heads at once per chat`, with add/remove and Name, Provider, Model, and Effort controls bound to `pair.headProfiles`; include profile names in the pair summary. Keep the existing v1/v2 prompt and spawn paths. This is preferable to silently retiring persisted overrides.

## Exact copy fixes

Use the v2 strings when `settings.isHydra2Enabled` is true; retain existing strings for v1 so the Labs switch remains the only behavior change.

- **C1 — Hydra subtitle (G3, U1).** Replace “One chat leads a team of heads on big jobs.” with:
  > One chat leads a team of heads and decides what to delegate.
- **C2 — delegation intro step (G5, U1).** Replace “Ask as you always do. Small things it does itself; anything bigger it splits into briefs.” with:
  > Ask as you always do. The lead keeps judgement and coupled work, and gives heads self-contained pieces.
- **C3 — Alpha master explanation (G1).** Replace the whole detail at `AlphaSettingsPage.swift:31` with:
  > Features here are early versions and may be unstable. Turning Alpha off ends the current voice call, disables local control and remote MCP, and returns new Hydra requests to the current Hydra. Individual feature choices are kept.
- **C4 — Hydra 2.0 Labs row (G2).** Replace the whole detail at `AlphaSettingsPage.swift:70` with:
  > Every new request in a Hydra chat runs the new team design: the lead keeps judgement and coupled work, heads get your request and the team's file split, report deviations and open points, and can resume for rework. When changes exist and another vendor's model is available, it reviews the final diff once; a skipped or failed review does not block completion or automatic merging. Turning it off returns new requests to the current Hydra.
- **C5 — Proactive tilt detail (G10).** Replace the active-branch detail at `HydraSettingsPage.swift:192` with:
  > The lead prefers to hand heads work that fits a self-contained brief, including single bounded edits, and splits larger work to run in parallel. It keeps judgement, cross-file design, integration, and trivial or delicate pieces.
  This removes the current contradiction between “single edits included” and keeping “small … pieces”; the prompt only reserves *trivial* edits for the lead (`HydraPrompts+V2.swift:17`).
- **C6 — first-run Hydra subtitle (G5).** Replace `HydraIntroPopover.swift:21` with:
  > Hydra is on. This chat leads a team of heads, keeping judgement and coupled work itself.

## 1. Global and Labs settings

`Key.*` string constants are storage aliases, not independent settings, and are counted with their corresponding property. `hydraDefaultEnabledKey` is likewise grouped with `hydraDefaultEnabled`. Pair CRUD and lookup methods are not settings.

| ID | Setting and UI surface | v2 read and proving code | Category | Fix |
|---|---|---|---|---|
| G1 | `alphaEnabled` (`AppSettings.swift:375`); Alpha master row (`AlphaSettingsPage.swift:21-49`) | `isHydra2Enabled` is `alphaEnabled && alphaHydra2Enabled` (`AppSettings.swift:395`). The master detail names voice, local control, and MCP but not Hydra (`AlphaSettingsPage.swift:31`). | **b** | **C3.** Keep the master switch; disclose the Hydra fallback. |
| G2 | `alphaHydra2Enabled` and computed `isHydra2Enabled` (`AppSettings.swift:389-395`); Hydra 2.0 row (`AlphaSettingsPage.swift:68-76`) | A user turn stamps `.v2` from this gate (`ThreadRuntime.swift:1691-1695`). Review can skip with “no other-vendor CLI available” or “review failed” (`AppModel+HydraReview.swift:17-21,99-100`), contrary to the row's unconditional “another vendor's model reviews”. | **b** | **C4.** Keep “new request” wording; make review availability and nonblocking failure explicit. |
| G3 | `hydraEnabled` (`AppSettings.swift:797-801`); Hydra master row (`HydraSettingsPage.swift:26-52`) | Runtime requires both app and chat switches: `settings.hydraEnabled && thread.hydraEnabled && !thread.isHelper` (`AppModel+Hydra.swift:171-173`). The subtitle still says “on big jobs” (`HydraSettingsPage.swift:41`), while v2 splits by context, not size (`docs/hydra2.md:32`). | **b** | **C1.** |
| G4 | `hydraDefaultEnabledKey` and `hydraDefaultEnabled` (`AppSettings.swift:147-149,803-807`) | New threads initialize with `hydraEnabled = Self.hydraDefaultEnabled()` (`Library.swift:294`); per-chat flips save the default (`AppModel+Hydra.swift:281-293`). No v1/v2 branch. | a | — |
| G5 | `hasSeenHydraIntro` (`AppSettings.swift:810-812`) | It gates the intro (`HydraButton.swift:37,89-94`), so storage works. The intro says “Big jobs go out” and “anything bigger it splits” (`HydraIntroPopover.swift:21,30`), which is v1's size rule (`Hydra.swift:817`), not v2's context rule. | **b** | **C6 and C2.** Do not reset the stored receipt; only update copy. |
| G6 | `hydraQueueHeads` (`AppSettings.swift:815-819`); v1 Messages row (`HydraSettingsPage.swift:206`) | Under v2, `hydraQueuesToHeads` is forced false (`AppSettings.swift:835`), so the raw value cannot route queued messages. The row is already in the v1-only `else` (`HydraSettingsPage.swift:184-211`). | **c** | Keep hidden under v2 and preserve the stored value for v1; no further change. |
| G7 | `hydraAlwaysHeads` (`AppSettings.swift:821-826`); v1 Messages row (`HydraSettingsPage.swift:208`) | Both derived routing gates include `!isHydra2Enabled` (`AppSettings.swift:835-837`), so every v2 message stays with the lead. Row already hidden with G6. | **c** | Keep hidden under v2 and preserve the stored value for v1; no further change. |
| G8 | Computed `hydraQueuesToHeads` (`AppSettings.swift:834-835`) | `dispatchQueuedHead` guards on it (`ThreadRuntime.swift:1418-1420`); its explicit v2 false is the compatibility mechanism that keeps queued follow-ups with the lead. | a | — |
| G9 | Computed `hydraSendsToHeads` (`AppSettings.swift:836-837`) | `dispatchSentHead` guards on it (`ThreadRuntime.swift:1426-1430`); false under v2 correctly prevents direct-to-head sends. Composer hints use the same gate (`ComposerView.swift:339-355`). | a | — |
| G10 | `hydraTilt` (`AppSettings.swift:828-832`); v2 Delegation row (`HydraSettingsPage.swift:184-202`) | `hydraLaunch` carries it (`AppModel+Hydra.swift:274`) and both v2 policy paths switch on it (`HydraPrompts+V2.swift:13-18,51-56`). The Proactive detail says both “single edits included” and that the lead keeps “small … pieces” (`HydraSettingsPage.swift:191-193`). | **b** | **C5.** Keep both tilt values. |
| G11 | `hydraIsolateHeads` (`AppSettings.swift:839-844`); Checkout row (`HydraSettingsPage.swift:145-154`) | Copied into every launch (`AppModel+Hydra.swift:268`) and used to make a head copy (`AppModel+Hydra.swift:688-690`). V2 explicitly reuses copies/landing (`docs/hydra2.md:8,92`). | a | — |
| G12 | `hydraMaxHeads` (`AppSettings.swift:846-856`); global Heads-at-once row (`HydraSettingsPage.swift:156-164`) | The lower global/pair cap is selected (`AppModel+Hydra.swift:265-266`) and enforced by `hasRoom` (`Hydra.swift:187-190`) for v2 as well as v1. | a | — |
| G13 | `hydraAutoMerge` (`AppSettings.swift:858-862`); reworded commit/merge row (`HydraSettingsPage.swift:220`) | V2 gets merge instructions from the launch (`HydraPrompts+V2.swift:27`) and settling calls auto-merge only when enabled (`AppModel+Hydra2.swift:88-90`). The new Off/On wording matches this path. | a | — |
| G14 | `hydraReviewHeads` (`AppSettings.swift:864-868`); v1-only review row (`HydraSettingsPage.swift:214-219`) | V1 passes it to `reportMessage`; v2 selects `v2ReportMessage` without it (`ThreadRuntime.swift:3714-3716`). V2 instead always tells the lead to read flagged files and spot-check (`HydraPrompts+V2.swift:41,227`). | **c** | Keep hidden under v2 and preserve the stored value for v1; the existing hide is correct. |
| G15 | `hydraArchivesCodexHeads` (`AppSettings.swift:870-873`); Codex history row (`HydraSettingsPage.swift:227-239`) | Archive eligibility reads the setting (`ThreadRuntime.swift:2279-2287`), and a later session can restore archived history (`ThreadRuntime.swift:2075-2081`). This is compatible with v2 continue-head; archiving is not deletion. | a | — |
| G16 | `hydraShowsHeadDetails` (`AppSettings.swift:875-880`); Head panel row (`HydraSettingsPage.swift:166-170`) | The same setting chooses progress versus steps (`SubagentPanel.swift:273`, `HydraPanel.swift:471`) regardless of decision mode. | a | — |
| G17 | `hydraAutoPopsHeads` (`AppSettings.swift:882-886`); Heads' panels row (`HydraSettingsPage.swift:172-179`) | Layout reads it directly to pop out later heads (`ChatView.swift:879-880`). V2 does not alter panel layout. | a | — |
| G18 | `hydraTempersHeadEffort` (`AppSettings.swift:888-894`); effort switch (`HydraSettingsPage.swift:181`) | It resolves worker effort (`AppModel+Hydra.swift:246-254`), but that resolved effort is also compared in `headsMatchLead` (`AppModel+Hydra.swift:256-258`). On a same-model pair, tempering can therefore switch v2 to partner-model delegation, contrary to `docs/hydra2.md:36`. | **d** | **F1.** Keep the effort switch; remove its accidental decision-layer effect. |
| G19 | `hydraPairs` (`AppSettings.swift:918-922`); Pairs list and reorder (`HydraSettingsPage.swift:24,106-137,248-264`) | Available pairs come from this ordered array (`AppModel+HydraPairs.swift:15-16`), and the chat's selected pair feeds `hydraLaunch` (`AppModel+Hydra.swift:186-190,234-275`). V2 uses the same configuration. | a | — |
| G20 | `lastHydraPairID` (`AppSettings.swift:749-754`) | New-chat creation resolves it through available pairs (`AppModel.swift:1031-1035`) and attaches the pair (`AppModel.swift:1069-1076`), independent of v1/v2. | a | — |
| G21 | `lastNewChatPair` (`AppSettings.swift:786-795`) | It restores a saved or temporary pair in Recent (`EffortSlider.swift:569-575`); pair fields then follow the normal launch path. No decision-layer branch. | a | — |

## 2. Pair, project, and cookbook schema

Pair fields are defined at `Tivano/Core/Models/Hydra.swift:18-131`; the editor rows are at `HydraSettingsPage.swift:506-729`. Computed `headsProvider` and `sendsHeadsElsewhere` are grouped with `workerProvider`; `customName` is grouped with `name`. Each `HydraHeadProfile` field is grouped with `headProfiles`.

| ID | Setting and UI surface | v2 read and proving code | Category | Fix |
|---|---|---|---|---|
| P1 | `HydraPair.id` (`Hydra.swift:60`) | Pair identity attaches chats and project rules (`AppModel+HydraPairs.swift:21-22,166-167`) and is recorded in the v2 job (`AppModel+Hydra2.swift:27,46`). | a | — |
| P2 | `name` / `customName`; pair Name field (`HydraSettingsPage.swift:535-558`) | The field writes `pair.name` (`HydraSettingsPage.swift:539-542`) and is explicitly “Shown in the picker and the composer” (`:551`); it does not alter delegation. | a | — |
| P3 | `provider`; Lead Provider row (`HydraSettingsPage.swift:579-609`) | Entering a pair applies its lead provider (`AppModel+HydraPairs.swift:56-70`); v2 also uses the lead provider to choose another-vendor review (`AppModel+HydraReview.swift:16-18,132-136`). | a | — |
| P4 | `orchestratorModel`; Lead Model row (`HydraSettingsPage.swift:610-626`) | `hydraLead` resolves and applies it (`AppModel+HydraPairs.swift:90-111`), and v2 records the resulting lead model (`AppModel+Hydra2.swift:43-45`). | a | — |
| P5 | `orchestratorEffort`; Lead Effort row (`HydraSettingsPage.swift:627-638`) | It correctly configures the lead (`AppModel+HydraPairs.swift:102-108`), but through tempering and the effort comparison in `headsMatchLead` it can also change v2's same/partner strategy (`AppModel+Hydra.swift:246-258`). | **d** | **F1.** Keep lead effort as execution configuration only. |
| P6 | `orchestratorDshMode`; Lead Agent mode row (`HydraSettingsPage.swift:639-649`) | Entering/editing a pair applies the lead DSH mode (`AppModel+HydraPairs.swift:109-111,128-135`); v2 replaces no provider execution mode. | a | — |
| P7 | `workerProvider`, `headsProvider`, `sendsHeadsElsewhere`; Heads Provider row (`HydraSettingsPage.swift:650-671`) | Installed/enabled provider resolution feeds the launch (`AppModel+Hydra.swift:194-200,234-245`), and v2 labels cross-provider heads (`HydraPrompts+V2.swift:19-20`). Fallback remains explicit (`AppModel+Hydra.swift:203-209`). | a | — |
| P8 | `workerModel`; Heads Model row (`HydraSettingsPage.swift:672-688`) | It configures spawned heads (`AppModel+Hydra.swift:255,597`). But a different model on the same provider gets no `headsLabel` (`:241-245`), so v2 falls back to “the selected partner model” (`HydraPrompts+V2.swift:9`) instead of naming it as `docs/hydra2.md:36` requires. | **d** | **F2.** Keep the model picker; supply the missing same-provider label. |
| P9 | `workerEffort`; Heads Effort row (`HydraSettingsPage.swift:689-700`) | It correctly configures execution (`AppModel+Hydra.swift:246-254,598`), but any difference from lead effort also makes `headsMatchLead` false (`:256-258`), contrary to the provider/model-only design. | **d** | **F1.** Keep head effort; remove it from strategy classification. |
| P10 | `workerDshMode`; Heads Agent mode row (`HydraSettingsPage.swift:701-711`) | It enters the launch (`AppModel+Hydra.swift:264`) and is applied to DSH heads (`AppModel+Hydra.swift:607`) in either decision mode. | a | — |
| P11 | Pair `maxHeads`; pair Heads-at-once row (`HydraSettingsPage.swift:712-720`) | It is clamped on update (`AppSettings.swift:1095-1101`) and combined with the global cap (`AppModel+Hydra.swift:265-266`), which v2 enforces unchanged. | a | — |
| P12 | `headProfiles` and each profile's `name`, `provider`, `model`, `effort`; advanced mode | V2 advertises profile routing (`HydraPrompts+V2.swift:25`), resolves the named profile (`AppModel+Hydra.swift:579`), and applies its overrides (`:592-598,619-624`). Runtime therefore works, but the editor controls described at `HydraSettingsPage.swift:502-505` are absent; `:712-729` ends with cap/catalog rows. | a (runtime); UI gap | **F5.** Make the still-active persisted configuration visible and editable. |
| P13 | `headsNote`; v2-only “What the heads are good at” field (`HydraSettingsPage.swift:559-578`) | Launch preserves the note (`AppModel+Hydra.swift:272`), but the sole prompt read is inside `if !launch.headsMatchLead` (`HydraPrompts+V2.swift:19-23`). It does nothing for same-model pairs, despite `docs/hydra2.md:37` requiring every nonempty note. On external-provider fallback, the configured model/effort is discarded but the note is retained (`AppModel+Hydra.swift:237-255,272`); if tempering makes `headsMatchLead` false, the note can instead describe the wrong fallback heads. | **c** (same-model); **d** (fallback; counted as d) | **F3.** Keep the field; include every nonempty note only for the configured pair actually running. |
| P14 | `Project.hydraPairID` (`Library.swift:64-67`); per-project pair rule | New-chat creation gives the project pair priority (`AppModel.swift:1010-1011,1053-1065`). Removal clears the rule (`AppModel+HydraPairs.swift:148-152`). V2 needs no separate project rule. | a | — |
| P15 | `ChatThread.hydraPairID` and `temporaryHydraPair` (`Library.swift:210-215`); temporary pair editor (`EffortSlider.swift:266-270`) | Resolution prefers a valid temporary pair, then the saved pair (`AppModel+Hydra.swift:186-191`). Both feed the same v2 launch and session signature (`ThreadRuntime.swift:2052-2067`). | a | — |
| P16 | Recipe `id`, `title`, `tagline` (`HydraCookbook.swift:19-21`) | Used for row identity and display (`HydraCookbookPanel.swift:39-40,88-93`). Taglines are not read by the lead; runtime guidance must use P13/F4. | a | — |
| P17 | Recipe `lead.providers`, `lead.models`, `lead.effort` (`HydraCookbook.swift:8-17,22`) | Resolution assigns lead provider, model, and supported effort (`HydraCookbook+Resolve.swift:33-38`), then the ordinary pair path applies. | a | — |
| P18 | Recipe `heads.providers`, `heads.models`, `heads.effort` (`HydraCookbook.swift:8-17,23`) | Resolution assigns head provider, model, and supported effort (`HydraCookbook+Resolve.swift:39-42`). F1/F2 cover the resulting v2 resolver issues. | a | — |
| P19 | Recipe `maxHeads` (`HydraCookbook.swift:24`) | Resolution copies it (`HydraCookbook+Resolve.swift:43`), after which P11/G12 enforce it. | a | — |
| P20 | Missing recipe `headsNote` default | The recipe schema ends at `maxHeads` (`HydraCookbook.swift:19-25`), and resolution assigns only model/effort/provider/cap (`HydraCookbook+Resolve.swift:35-43`). This makes the cookbook default described at `docs/hydra2.md:37` impossible. | **d** | **F4.** Keep recipes and add the missing data flow. |

## 3. Remaining settings-panel and project rows

This table covers rows not already represented by a setting above, including informational, empty, loading, and dynamic issue states. Dividers and purely decorative glyphs are not separate Hydra settings rows.

| ID | Row | v2 behavior and evidence | Category | Fix |
|---|---|---|---|---|
| U1 | “How Hydra works” info (`HydraSettingsPage.swift:39`) | Its subtitle repeats “big jobs” and its first step repeats “anything bigger” (`HydraIntroPopover.swift:103-105,130-134`), the v1 rule rather than v2's split-by-context rule. | **b** | **C1 and C2.** |
| U2 | “Switch Hydra on to set up its heads.” (`HydraSettingsPage.swift:55-59`) | Pure disabled-state explanation for G3; remains true under v2. | a | — |
| U3 | Pairs intro, “One leads, the others build” (`HydraSettingsPage.swift:65-94`) | Generic pair explanation; it does not impose v1 routing, and v2 heads still build delegated pieces. | a | — |
| U4 | “No pairs yet” and Add pair (`HydraSettingsPage.swift:95-100`) | Correctly says heads use the chat model without a pair; Add creates `HydraPair(provider:)` (`:330-343`). | a | — |
| U5 | “Another pair” and Add pair (`HydraSettingsPage.swift:123-126`) | Adds to the same `hydraPairs` collection; “One per provider is enough” is advice, not a v2 behavior claim. | a | — |
| U6 | Saved pair summary, edit, reorder, remove (`HydraSettingsPage.swift:347-447`) | Summary resolves model/effort/effective cap and provider fallback (`:417-433`); editing and removal use the ordinary pair paths (`:373-392`). Profile invisibility is tracked separately in F5. | a | — |
| U7 | Pairs footnote, including project rules (`HydraSettingsPage.swift:138-141`) | Matches picker placement and the actual project context menu (`SidebarView.swift:1446-1457`); unchanged by v2. | a | — |
| U8 | “How heads work” info (`HydraSettingsPage.swift:143`) | Brief, checkout, and report explanations (`HydraIntroPopover.swift:148-163`) still describe v2's mechanical layer. | a | — |
| U9 | Pair-editor catalog loading / no-models rows (`HydraSettingsPage.swift:721-729`) | These reflect catalog state only and retain visible loading/empty feedback; no v2 branch is needed. | a | — |
| U10 | Codex history info and per-head provider-history issue rows (`HydraSettingsPage.swift:227-239,298-308`) | History explanations include restore and exclusions (`HydraIntroPopover.swift:164-179`); issues come from live head state (`HydraSettingsPage.swift:302-304`). Both remain valid for v2 continue-head. | a | — |
| U11 | Cookbook “Pair presets” header (`HydraCookbookPanel.swift:17-30`) | “Add a preset to your model picker” accurately describes construction, not a v1 decision policy. | a | — |
| U12 | Cookbook no-ready-providers empty state (`HydraCookbookPanel.swift:33-38`) | Correctly directs the user to Providers when no recipe resolves. | a | — |
| U13 | “Needs a provider” and waiting recipe rows (`HydraCookbookPanel.swift:43-54,106-109`) | Missing-provider resolution is mode-independent (`HydraCookbook+Resolve.swift:21-27`), and the row names what to set up. | a | — |
| U14 | Cookbook Add / Added state (`HydraCookbookPanel.swift:122-141`) | Add stores the resolved pair; Added compares provider/model identity (`HydraCookbook.swift:50-53`). No v2-specific routing switch is hidden here. | a | — |
| U15 | Project context menu “Start new chats on” (`SidebarView.swift:1451-1457`) | Writes P14 through `setHydraPair` (`AppModel+HydraPairs.swift:164-167`); new v2 chats inherit the same pair. | a | — |
| U16 | Project fallback “The chat's last pair” (`SidebarView.swift:1542-1549`) | Nil clears the project override (`:1542-1544`), exposing the normal remembered-pair fallback (`AppModel.swift:1031-1035`). Accurate under v2. | a | — |

## 4. Every cookbook recipe row

All rows are built by `HydraCookbookRow` (`HydraCookbookPanel.swift:72-119`) from `HydraCookbook.recipes` (`HydraCookbook.swift:29-42`). Their titles, taglines, model/effort choices, caps, and Add controls still work under v2. They are **(a)** as recipe rows; the warnings below point to the single responsible fix rather than counting the same resolver defect again. F4's missing note capability is likewise counted once at P20.

| ID | Recipe row (`HydraCookbook.swift`) | v2 assessment | Category |
|---|---|---|---|
| R1 | `claude-fable-opus` — “Fable 5.1 leads Opus 5.5” (`:30`) | Resolves through P17–P19. When both sides resolve to Claude/CommandCode, the different same-provider model needs **F2** so v2 names Opus rather than “partner model”. | a |
| R2 | `claude-opus-gemini-flash` — “Opus 5.5 leads Gemini 3.8 Flash” (`:31`) | Six-head cap still applies. The “wide, fast team” tagline is compatible with v2 parallel/mechanical delegation. Same-provider CommandCode fallback needs **F2**; suggested note in **F4**. | a |
| R3 | `claude-opus-deepseek` — “Opus 5.5 leads DeepSeek V4.1” (`:32`) | Routine-work positioning fits v2's partner-model rule (`docs/hydra2.md:34`). Same-provider CommandCode fallback needs **F2**; suggested note in **F4**. | a |
| R4 | `claude-opus-glm` — “Opus 5.5 leads GLM-5.3 Flash” (`:33`) | Cost/routine positioning remains valid; model and high effort resolve normally. Same-provider CommandCode fallback needs **F2**; suggested note in **F4**. | a |
| R5 | `claude-fable-composer` — “Fable 5.1 leads Composer 2.5” (`:34`) | Cross-provider fast/mechanical role fits v2. The provider label is already built on this path; **F4** can expose the speed note explicitly. | a |
| R6 | `astra-spark` — “Astra 6 leads Spark 1.3 Contributor” (`:35`) | Lead/high and head/medium execution remain intact. Same-provider CommandCode fallback needs **F2**. | a |
| R7 | `astra-terra` — “Astra 6 leads Terra 5.6” (`:36`) | Normally a same-provider/different-model pair, so **F2** is needed for v2 to name Terra. The planning/building tagline does not force v1 routing. | a |
| R8 | `astra-sol` — “Astra 6 leads Sol 5.6” (`:37`) | Normally same-provider/different-model, so **F2** applies. “Complex building” is suitable **F4** routing guidance. | a |
| R9 | `sol-luna` — “Sol 5.6 leads Luna 5.6” (`:38`) | Normally same-provider/different-model, so **F2** applies. Quick routine work fits v2 and the suggested **F4** note. | a |
| R10 | `astra-astra` — “Astra 6 high, Astra 6 medium” (`:39`) | Same provider and model must remain same-model under v2 even at different efforts; currently **F1** is required. Recipe execution values themselves are valid. | a |
| R11 | `claude-opus-opus` — “Opus 5.5 max, Opus 5.5 medium” (`:40`) | Same-model/two-effort preset directly triggers the effort comparison fixed by **F1**. | a |
| R12 | `claude-fable-fable` — “Fable 5.1 high, Fable 5.1 medium” (`:41`) | Same-model/two-effort preset directly triggers **F1**. Its long/hard-job tagline does not change the provider/model classification. | a |

## Notes and boundaries

- The already-handled v2 changes are correct: both Messages switches are hidden and their derived gates force lead routing (G6–G9), `hydraReviewHeads` is hidden because v2 always performs its own lead check (G14), `hydraTilt` reaches both v2 prompt paths (G10), and auto-merge remains an independent mechanical setting with accurate new copy (G13).
- The mode is stamped once per user request (`ThreadRuntime.swift:1691-1699`) and put into the session signature (`ThreadRuntime.swift:2052-2067`). Settings copy should therefore say “new requests”, not imply that flipping Labs rewrites an active job.
- `reviewsHeads` is still copied into `HydraLaunch` (`AppModel+Hydra.swift:270`) even though v2 prompts ignore it. That is latent signature noise, not a user-facing review effect; it does not change G14's (c) classification. Normalizing v2-only launch fields would be cleanup, not a prerequisite for the fixes above.
- No evidence supports hiding checkout, concurrency, panel, history, pair model/provider, DSH mode, project-rule, or auto-merge controls under v2. They all feed shared mechanical or presentation paths.
- This audit does not duplicate the parallel chat-UI, provider-runtime, evaluation, or data audits. It only follows those paths far enough to prove what each setting does.
