# Incremental fade state, unchanged drawing

`StreamVeil.advance` formerly expanded the entire source into `[Character]` and compared its common prefix on every append. It retained that array between updates as well as retaining the source string. This work is on the main actor and is shared by both SwiftUI and AppKit fade consumers.

The replacement still verifies an exact UTF-8 prefix; this check remains proportional to source bytes. It only re-segments the old last grapheme plus the appended tail, updating the cached character count. Rewrites use the original character-equality prefix semantics. Re-segmenting the last grapheme is necessary for a combining mark, ZWJ sequence, flag, keycap or CRLF arriving in a later delta. Fade timing, ranges, clocks, frames, rendering and styles are unchanged. This is not a constant-time append claim or a new text renderer.

## Validation

`build.noindex/veil-append-checks/generate.py` extracts the complete original and candidate classes into one optimized Swift 6 executable. It compares spans, exact alpha values, ranges, fading state and deadlines at identical timestamps. There are 170,493 passing state comparisons: explicit CJK/Arabic/Indic/Hangul, decomposed/composed forms, emoji joiners/modifiers/flags, CRLF, random append/rewrite/reset streams, and all 853 strings downloaded from the official Unicode GraphemeBreakTest file. Every scalar cut is used as an append/rewrite boundary with empty, ASCII and regional-indicator prefixes.

The official data exercises the platform's own `Character` behavior; this checks equivalence to the existing app, not conformance of the platform to a particular Unicode revision. Source URL and hash are in `unicode-source.json`. Rule reference: [Unicode grapheme cluster boundaries](https://www.unicode.org/reports/tr29/#Grapheme_Cluster_Boundary_Rules); byte view: [Swift String.UTF8View](https://developer.apple.com/documentation/swift/string/utf8view).

## Component timing

No app build or capture was running. Two alternating baseline/candidate rounds feed 240 growing strings to each complete class and request its spans, with identical fixed timestamps. Inputs are prebuilt outside timing. Average process CPU seconds:

| Payload | Final bytes | Original | Candidate | CPU reduction |
| --- | --- | --- | --- | --- |
| ASCII | 12,480 | 0.048331 | 0.013621 | 71.8% |
| CJK/Arabic/emoji/combining text | 30,080 | 0.173984 | 0.036385 | 79.1% |

Artifact: `quiet-results.json`. This saves tens to hundreds of milliseconds over 240 updates in this component; it is not a 72–79% improvement in whole-app CPU, scrolling or input latency.

## Rejected drawing experiment

An isolated Debug-only opt-in `TextRenderer` experiment attempted to retain styled `Text` and vary drawing opacity. Its 384 rendered pairs had unchanged sizes and at most a 1/255 channel difference; color-emoji paragraphs used the original renderer. Exact source and pixel results remain in `build.noindex/text-draw-production-builder`, and the experimental source is preserved as `veil-append-checks/before.swift.txt`.

The optimized app comparison is `build.noindex/stationary-text-comparison-20261017-012624/manifest.json`. All three A/B/A runs reconciled 240 deltas per thread, three threads, with persistence disabled, no scroll writes, native input, provider, compiler or UI automation during timing. The same binary served all three runs; only B enabled the opt-in renderer. Process CPU was 38.491, 43.664 and 39.119 seconds during load: B used **12.5% more CPU** than the A mean. Load-phase elapsed times were 47.665, 57.463 and 53.324 seconds. Driver callback p95 values were 425.919, 439.407 and 473.248 ms; these are not presentation FPS.

The experiment was rejected and removed from product source. The final code retains the original drawing path and adopts only the equivalent fade-state calculation above. No installed app, background-process priority, visible frame rate, animation duration, glass or feature was changed.
