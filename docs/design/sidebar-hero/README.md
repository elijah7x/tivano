# Sidebar hero (Skylight) design record

Mockups are self-contained HTML files; open them in a browser. They record the decisions behind the native `Tivano/UI/Common/HeroWeatherView.swift`.

Current design references and generators remain here. Older candidates are preserved outside Git at `design-archive/sidebar-hero/skylight/`, alongside the long-lived source checkout. Resolve that archive from the source checkout's parent, not a task worktree's parent. Its README and moves.json record provenance, file sizes and preserved versions.

| File | Round | Decision |
|---|---|---|
| `g-states.html` | 3 | Five weathers as states (fail rain > awaiting > running wind > done sun > idle) and the new-chat entry. Source of the base cloth paths. |
| `v3-skylight.html` | 5 | Refined skylight at 84pt; first native port. |
| `v4-awaiting.html` | 6 | Awaiting options; the hairline thought cloud (B) was chosen. |
| `v5-hatch.html` | 7 | Chosen: hand-drawn line and hatching on translucent paper; the current native look. |
| `section-headers.html` | — | Sidebar section header audit and typography options (B was chosen). |

## Current native look (2026-10-21)

The engraved specimen plate replaced the drafting marks of `v5-hatch.html`: corner brackets and digit-free ruler ticks frame the doll, the head is shaded by a single tapered crescent (H5), the new-chat entry is the plate's title at top left (E1), the doll hangs at 0.6 of the width (composition C4) and the weather word sits on an engraved hang tag (T3). The whole plate is the hover and click target. The candidate rounds (round8–round16, including the ten-direction comparison) live in the external archive at `design-archive/sidebar-hero/skylight/`; `round15/c4-tag.html` and `round16/tag-variants.html` (T3) are the chosen references.

Scripts kept here: `gen-wind.mjs` (wind displacement model for the skirt keyframes; it writes native Swift), `gen-hatch.mjs` (hand-drawn path generator), `check-overlaps.py` (geometry check that nothing shows through the translucent doll; run it after changing any path).

## Archived rounds

Paths below are relative to the external archive, not this directory. Earlier selections remain part of the design history; archiving them does not make them the current native look.

| Archive file | Round | Decision or role |
|---|---|---|
| `process/f-sage.html` | 2 | Teru teru bozu from the app icon: faceless cloth doll plus drafting marks on a sage card. |
| `process/v2-c-skylight.html` | 4 | No card: the doll and marks sit on the sidebar glass; colour only as weather. Chosen over hanging, glass card and strip at that round. |
| `process/fabric-keyframes.json` | 5 | Rendered-cloth keyframes. |
| `process/v5-pencil.html`, `process/v5-ink.html` | 7 | Hand-drawn alternatives considered; hatch was chosen instead. |
| `process/gen-pencil.mjs`, `process/gen-ink.mjs` | 7 | Historical generators for those alternatives. |
| `process/v4-awaiting.html` | 6 | Input snapshot for both archived generators; the original remains here as design evidence. |

Archived generators are for historical reproduction only, not current app updates. They read the adjacent input snapshot and overwrite their adjacent candidate HTML outputs; preserve the archived originals before any reproduction.
