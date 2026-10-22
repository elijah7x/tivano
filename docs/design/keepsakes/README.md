# Keepsakes (信物)

Design record for the Settings page that keeps a user's keepsakes, and the first keepsake,
Early Supporter. Approved by the owner on 2026-10-20. Exploration rounds stay outside the
repository in `design-archive/badges/2.0/`.

## Early Supporter

- A frosted sage glass hang tag with a laser-etched teru teru bozu, a light ribbon behind
  the doll, a ruler-tick border and a slim ribbon through a polished eyelet.
- Front: EARLY SUPPORTER, footer WITH THANKS FOR USING AND SUPPORTING TIVANO.
- Back: the doll mirrored and smaller; motto "May intelligence enrich imagination, / create
  the future, / and benefit humankind."; footer TIVANO · ELIJAH.
- `early-supporter/`: front and back, light and dark, and the unlit line drawing.
  Export bitmaps at each display size for the app; dense hatching shows interference when an
  SVG is scaled down live.

## Regenerating

- `generator/final.py` (Python standard library) writes `early-supporter/`.
- Text is outlined from SIL OFL fonts (Cinzel, Cormorant Garamond; licences in
  `generator/fonts/`) by `generator/outline_text.py` into `text_outlines.py`. Rerun it only
  when wording changes; it needs `fonttools` and `uharfbuzz`.

## Page

`page/keepsakes.html` is the approved static mockup: title 信物, subtitle 保存一路相伴的信物。,
a hand-drawn branch with the keepsake hanging from it, swaying ±3° over 6 s (transform only,
paused when hidden or when the enlarged view is open, still under Reduce Motion), two falling
leaves, a faint sketch and dot-field background. Clicking enlarges the keepsake with its name,
earned date and description; clicking again flips it. The description copy is a placeholder.

Light-up (2026-10-21): clicking the keepsake always opens the enlarged view first, so the unlit line drawing can be seen in full. A quiet Light it pill floats above the card; pressing it turns the pill into a drop that falls onto the doll's head and reveals the lit face in one uneven pass of feathered blobs (about 2.6 s), then the card turns over once and back. The chosen reference is `design-archive/badges/2.0/lightup-v4/drop-button.html`; earlier rounds (lightup-v2, lightup-v3) sit beside it. The unlit drawing no longer carries the 440 dimension line.
