# Native text layout: measured candidate and acceptance boundary

## Evidence

The optimized stationary streaming sample `build.noindex/stationary-profile-20261017-013506/streaming-main.sample.txt` contains 172 main-thread observations. Sixty-eight pass through window layout; 36 of those include SwiftUI AppKitTextInteractionView/TextSelection layout preparation. These nested observations are not independent percentages of CPU, and the sample does not prove the original production hang's root cause. They identify a concrete selectable-text layout path worth measuring.

A capture-only `--native-plain-text-probe` routes link-free InlineText through the existing selectable LinkParagraphView. It does not disable selection, animation or glass. Ordinary Debug and Release paths are unchanged. In the same optimized binary, three-thread text-only A/B/A runs reconciled all 240 deltas per thread, with no scroll injection, UI automation, provider, compiler or persistence during timing.

Artifact: `build.noindex/stationary-native-plain-text-comparison-20261017-013906` (manifest, source/binary hashes, raw reports and screenshots).

| Load-phase metric | A1 original routing | B native diagnostic | A2 original routing | B reduction from A mean |
| --- | --- | --- | --- | --- |
| Process CPU seconds | 41.811 | 20.384 | 35.689 | 47.4% |
| Input loop seconds | 50.691 | 23.460 | 44.930 | 50.9% |
| Load phase seconds | 53.899 | 26.360 | 46.469 | 47.5% |
| Main-actor driver callback p95 ms | 541.897 | 127.027 | 473.865 | 75.0% |

Callback intervals are not presentation FPS. The fixture is one ASCII streaming message per thread, one visible chat, with fixed ordinary glass and controls. It is not an actual compiler/provider throughput benchmark or a general application speedup. Other owner applications remained open; the bracketed baselines show environmental variation. No target interval catch-up or content dropping is used.

The lead viewed both final screenshots. The explicitly compared final image crop (x 390–1820, y 140–1090 in the 2642×1694 captures) has zero differing pixels. This crop is not proof of all typography or intermediate frames.

## Candidate rejected for default routing

`TextParityProbe` renders the actual MarkdownView to native view bitmaps: six fixtures, two widths, two font sizes and light/dark appearance, 48 cases per variant. The corrected run is `build.noindex/text-parity-live-20261017-015152`. It bootstraps only the isolated capture library and exits normally. The earlier 01:48 run omitted capture-model bootstrap, generated its images but stalled in the application's unloaded-library exit protection; the lead stopped only that runner and probe and excluded the run.

Plain ASCII has identical dimensions and a maximum 1/255 channel difference in all eight cases. Broader cases exposed differences: emoji/combining text heights, bold+italic collapsing to bold, missing strikethrough and some quoted/list typography. The native selection check also found that full replacement resets a selected range. These are reasons to keep the diagnostic route opt-in; the 47.4% figure is **not an adopted product optimization**.

The static probe records successful capture/geometry checks, not automatic old/new visual acceptance. Its pixel-comparisons.json and the lead's image inspection determine parity. No formatting was removed to make those comparisons pass.

## Narrow product change being validated

The existing native paragraph's render method now appends a suffix only if the previous UTF-16 text and every attribute in its prefix are unchanged. Rewrites and old-range restyling keep full replacement. Selected text is restored only when its old text is a literal prefix of the new value. Routing, fonts, colors, links, head decorations, line wrapping and the AppKit fade painter remain unchanged.

Foundation can internally substitute fonts, particularly for emoji. Those storage attributes may differ from the incoming attributes; the strict prefix guard then deliberately falls back. The first mixed-emoji component run found no speed benefit in that regime. Do not extrapolate append-path savings to all text or relax the attribute guard merely to improve a benchmark.

The extracted original/candidate render and height methods passed 2,038 exact stored-attributed-text and two-width native layout comparisons, covering edits, restyling, links, emoji sequences, combining marks, rewrites and repeated changes. Font fixing also changes the original method's stored attributes relative to its input; the reference is therefore the actual original storage/layout, not a false requirement that TextKit leave its input attributes untouched. Artifact: `build.noindex/native-append-checks`.

The accepted comparison below uses normal product routing and one fixed local file link per message, so both variants already use the same native renderer. A Debug capture-only `--legacy-native-render-probe` restores the exact old full-replacement path; per-phase counters distinguish append-branch mutations and replacements. Local file links in fixtures are not opened and do not fetch network assets.

## Adopted change: app-level A/B/A

Artifact: `build.noindex/stationary-native-storage-comparison-20261017-020432`. Same optimized binary, source hashes, fixed normal glass/theme/window, 240 text deltas per thread, three threads and one visible chat. Both variants use the existing native linked paragraph. No native-plain-text diagnostic flag, UI automation, provider, compiler, scroll input or persistence is present during timing. All final text and completion states reconciled in each run. Other owner apps remained open.

| Load-phase metric | A1 full replacement | B incremental | A2 full replacement | B reduction from A mean |
| --- | --- | --- | --- | --- |
| Process CPU seconds | 24.083 | 18.639 | 22.463 | 19.9% |
| Input loop seconds | 26.006 | 21.228 | 25.763 | 18.0% |
| Load phase seconds | 28.463 | 23.320 | 27.299 | 16.4% |
| Main-actor driver callback p95 ms | 129.945 | 110.017 | 129.931 | 15.3% |

Load-phase counters recorded 216 full replacements in A1 and 194 append-branch mutations in B. Append counts include empty-storage initialization; differing view-update counts reflect existing framework coalescing and elapsed time, not dropped inputs. Exact final text still contains all 240 numbered deltas per thread. The A/B/A is one measured sequence, not a confidence interval, whole-app speedup, frame-rate measurement or an actual compiler benchmark. Mixed emoji can take the strict fallback and was not shown to benefit by the component test.

## Final correctness and visual checks

The adopted native storage change has **48/48 pixel-identical before/after images**, with zero geometry differences, using the original native formatter in both variants. This comparison includes light/dark, two widths/sizes, CJK, emoji, combining text, styles, lists and quotes. Artifacts: `text-parity-live-20261017-015152/native`, `text-parity-live-20261017-021132/native` and the latter's `pixel-comparisons.json`. This preserves the existing native appearance; it does not make the rejected plain-text rerouting visually equivalent.

`build.noindex/native-final-acceptance-20261017-022249` completed normally with the final optimized Developer ID build. The native view retained its selected range/text across append and exported the expected selection through a private pasteboard. The initial copy probe incorrectly requested a modern format absent from this system's advertised writable types; an ordinary NSTextView control reproduced that failure. The corrected probe uses `writablePasteboardTypes` and `writeSelection(to:types:)` as documented. It does not alter the user's general clipboard. See `build.noindex/native-copy-api-checks/supported-types-results.txt`.

The lead also clicked the isolated native text view and used Command-A through CUA, verifying the full fixture selection and highlight. When the bounded hold expired, a later AX refresh relaunched the DerivedData executable without capture arguments. The lead made no further library UI changes, quit that new instance normally and verified its PID exited. Never refresh a CUA binding after its bounded app has exited. The installed Release was not quit or replaced. Details: `text-parity-live-20261017-021132/owner-ui-check.json`.

The final tool-interleaving fixture completes each assistant message before its tool group and starts a new message afterwards. Each of three threads reconciled 240 deltas, 20 assistant messages, 20 completed tools and 321 events, totaling 963. All three idle/load/idle phases completed. This is a correctness run, not an old/new performance percentage. The earlier resumed-ID stress remains available only through `--resumed-id-stress-probe` and must be labeled separately.

The four measured product source hashes (LinkParagraphView, StreamVeil, ThreadRuntime and MarkdownView) match the final source. The final binary UUID is `E8128C4D-0DAC-31B9-B586-636400657928` (arm64); strict Developer ID verification passed. No package was installed.

API contracts: [NSTextStorage change notifications](https://developer.apple.com/documentation/appkit/nstextstorage), [attributed substring preserves characters and attributes](https://developer.apple.com/documentation/foundation/nsattributedstring/attributedsubstring(from:)), [advertised writable types](https://developer.apple.com/documentation/appkit/nstextview/writablepasteboardtypes) and [selection export](https://developer.apple.com/documentation/appkit/nstextview/writeselection(to:types:)).
