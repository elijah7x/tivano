# Minimap latest tick

## What

On an 800-user-message thread the left minimap draws one tick per user message,
centered on the full column height. Spacing is already at the 2pt floor, so the
strip is about 3198pt tall. The rail that can take a click is only the timeline
above the composer (722pt in a 1320×860 window). The lowest click lands on tick
479 of 800 (`TICK 0479`, about 60% through the document), not on `TICK 0800`.
The drawn ticks continue through the composer card and are cut off at the
window's bottom edge. A taller composer or a shorter window moves that deepest
click toward the middle of the document. That is the same layout a long session
showed as a deepest click around 55–58%.

Measured on this baseline, before the geometry change:

```
count=800 center=816.0 rail=722.0 spacing=2.00 top=-1191.0 first=-1190.0 last=2006.0 hit=44.0..722.0 deep=478/799 "TICK 0479" lastTick="TICK 0800"
```

A brightness-lifted crop of the left edge shows the tick column starting under
the traffic lights and running the height of the timeline. A crop of the bottom
shows those ticks continuing behind the composer card until the window edge
cuts them off.

## Where

`ThreadTimeline` mounts `TimelineMinimapColumn` with
`centerHeight: max(0, columnHeight - WindowChrome.titlebarHeight)` and pads the
rail by `WindowChrome.titlebarHeight`. `columnHeight` is the whole chat column,
composer included. The rail's own frame is only the timeline.

`MinimapRailMetrics.init(centeringHeight:count:)` in `TimelineMinimap.swift`
chooses spacing and `topInset` from that centering height alone. When the ticks
do not fit, `topInset` goes negative and the strip spills the same amount above
and below the column. `hitRect` then clamps pointer hits to
`[chromeClearance, railSize.height]`. `entryID(at:)` clamps the index into
range, so the lowest Y inside the rail resolves to a middle tick.

## Why

Centering on the full column is what keeps a short thread's ticks from jumping
when the composer or the queue tab grows: that height does not change. The same
centering is still used when the strip is taller than the rail. The bottom of
the strip is then laid out through the composer, where the composer's
safe-area inset is painted over the timeline and the hit rect has already ended.

## Change

Ticks still centre on the full column height when that strip fits in the
clickable rail, so a short thread does not jump when the composer or the queue
tab grows. When the centred strip would leave the rail, spacing tightens down
to the existing 2pt floor. If the ticks still do not fit, they pack into the
clickable band, from the chrome clearance to the bottom of the rail, so the
last tick stays above the composer.
