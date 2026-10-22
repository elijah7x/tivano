# Chat timeline and Markdown audit — 2026-10-21

Scope: `Tivano/App/Views/Chat/` and `Tivano/UI/Markdown/`. Source review only; no build, test, lint, application launch, visual comparison or performance measurement was run. The lead owns validation.

## Fixed

| File:line | What | Why | Risk |
| --- | --- | --- | --- |
| `Tivano/UI/Markdown/ProseRunView.swift:58`, `Tivano/UI/Markdown/LinkParagraphView.swift:93` | Retain and compare the actual `[MarkdownBlock]` input in the native prose coordinator instead of a joined string of leaf text. | The old key discarded heading levels, list ordering/start/check state, quote nesting and block boundaries. For example, replacing `# Same` with `## Same`, or toggling a task checkbox without changing its text, could skip `render` and leave stale formatting. The new comparison also avoids allocating the joined source on each representable update. Link-asset source collection remains unchanged. | Low: unchanged block arrays still skip rendering; only previously missed structural changes invalidate the native text. Retains one block-array value per mounted prose coordinator. Lead should exercise same-text heading/list/quote edits and an unchanged update. |
| `Tivano/App/Views/Chat/ThreadTimeline.swift:549` | Stop collecting finished assistant messages once `MarkdownView.warmCandidateLimit` is reached. | `warmTexts` already examines only the first 96 candidate strings. Previously the caller read and retained every finished message before that truncation. This preserves exactly the same candidates and order while avoiding the remaining history walk and temporary references once the limit is reached. | Low: histories with fewer than 96 eligible messages still require the full walk. No change to warming budgets, parsing, cancellation or displayed content. No measured speedup claimed. |

## Proposed but not done

1. **Give visible/recent replies priority when warming.** `ThreadTimeline.swift:549` and `MarkdownView.swift:269`: the candidate prefix is taken before cached entries are filtered. Once the first 96 finished messages are cached, later calls can find nothing to warm even when newer visible replies are uncached. Expected impact: fewer synchronous cache misses when entering long histories. Risk: changing priority can trade recent-message responsiveness against scrollback responsiveness; concurrent warm requests also need coordination. Owner decision: choose a visible-window/recent-first policy and authorize a separate measured change. This audit only removes work whose result was already discarded.

2. **Make settled-block equality robust to source rewrites.** `MarkdownView.swift:345`: two settled blocks compare equal without inspecting content. This is valid for append-only streaming, but the parser explicitly supports non-prefix rewrites (`MarkdownParser.swift:79`); a rewrite that leaves an earlier index settled can therefore retain an old block until streaming ends. Expected impact: correct intermediate text during such rewrites. Risk: blindly replacing the shortcut with full equality adds repeated comparisons across every settled block. Owner decision: establish whether same-message streaming rewrites are supported and select either a parse-generation invalidation or the simpler content comparison, with append-stream performance coverage. No change made to this established optimization without that evidence.

## Observations

- Read the seven requested prior reports. The native append path, incremental entry binding, incremental veil state, hidden-wheel suppression and ordinary selectable-text routing are preserved. The rejected draw-opacity and native-plain-text experiments are not proposed again.
- Reviewed `git log -8 --stat` and the relevant recent patches: standalone affiliation/directory routing in ChatView/HydraPanel/NewThreadPrompt, the sidebar-toggle argument, removal of the clone action and Cursor Origin handling. No definite new timeline-rendering defect was established in those changes. The local-control commit has no edits in the assigned directories.
- `ThreadTimeline.body` builds from entries and structural/runtime flags, while message content is read in rows. `DisplayBlockView` is equatable and the visible `ForEach` uses block identity. Merely receiving a broad observable object does not establish that every token invalidates this parent.
- Geometry handling already uses generation-aware measurements, guarded state writes and deferred/coalesced bottom snaps. `ScrollPosition` remains local view state. No feedback-loop rewrite or eager-to-lazy stack conversion was made.
- Finished Markdown blocks, inline attributed strings and table cells already have bounded source-keyed caches. Streaming parses and inline strings have separate slots. Bare-domain regex compilation is static; code blocks display monospaced text without a syntax-highlighting pass.
- `LinkParagraphView.updateNSView` already checks rendering inputs; `LinkTextView` caches width-dependent height and retains the strict attributed-prefix append guard. The prose structural key was the definite missed-input defect found in these paths.
- Link tasks use stable asset keys rather than the entire streaming source. Their fetch stores deduplicate requests. This is not proof that all cancellation or asset-completion races are closed.
- Table cells guard short rows, list markers are limited to nine digits, and the reviewed mounted-window resolution clamps its lower bound and falls back when its identity disappears. No reachable anchoring crash was established; this is not an exhaustive crash-safety claim.
- Large final/history parses and main-actor inline work remain existing investigation areas, not new findings or validated release blockers from this audit.
- Nowledge CLI thread search `Tivano Markdown timeline render` returned zero threads. Conclusions above use the supplied reports and current source, not inferred prior history.

The edits require lead validation, especially structural prose updates and preservation of the warm candidate sequence. No public signatures, UI controls, localization strings or rendering styles were changed.
