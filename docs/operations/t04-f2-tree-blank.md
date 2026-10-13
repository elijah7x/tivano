# T04-F2 tree work-group blank

## What

With `workGroupStyle=tree`, expanding or collapsing a work group while the reader is at the end of a long thread blanks the whole timeline for one to several frames. The title bar and the composer stay. The conversation pane is empty, then the rows return. List mode does not do this.

## Where

On the baseline, `ActivityTreeGroup` in `Tivano/App/Views/Chat/ActivityTree.swift` toggled `isCollapsed` inside `withAnimation(ActivityMetrics.fold)` (`easeOut` 0.14s). Opening also called `revealBox?.action()`, which is `ThreadTimeline.revealEnd` → `followEnd`: pin to the bottom and `scrollTo(edge: .bottom)`. The open body was inserted and removed with `.transition(.opacity)`, so the group's height animated across the whole step list (up to `ActivityMetrics.stepPage`, 60).

`ThreadTimeline.onScrollGeometryChange` then sees the viewport past the end of the content. The existing snap (`scheduleBottomSnap` when `distanceFromBottom < -1` and the content size changed) does not clear that hole while the fold animation is still driving the height. `blank.arm` runs, and the rows come back before the 300ms watch, so `blank.fire` does not.

## Why

The animated height change is about as tall as the step list. Measured on a 48-command group, the document height swings by roughly 1400–1600 points. The reader is pinned to the end (the first expand calls `followEnd`, and later toggles keep that pin). During the 0.14s ease the scroll offset stays ahead of the content that is still animating: `distanceFromBottom` reaches about −1586, `visible` drops to 0, and `showsNothing` is true. That empty region is the timeline pane. The title and composer are outside the scroll view, so they stay.

At the moment the hole opens, the trace reports `pinned=true` and `coasting=false`, `userScrolling=false`, `readerScrolling=false`. The snap is therefore allowed, but the in-flight layout animation keeps the offset in the hole for one to several frames (about 17–140ms at a 57fps capture) and eases back onto the rows. The 300ms blank watch never fires.

A reader scrolled up by more than a viewport does not hit this. `revealEnd` returns without pinning, the viewport stays on rows that are already on screen, and the same height animation does not open a hole. List mode only shows the two latest steps until earlier steps are asked for, so the height change is too small to uncover the end.

## Fix

`ActivityTreeGroup` changes the fold without an animation, and the open body uses `.transition(.identity)`. The step list still opens and closes. The scroll offset is no longer interpolated across a viewport-sized hole. List mode's own fold is unchanged.

After the change, the same pinned 30-cycle run (8 turns, 48 commands) has no empty timeline frame. During the toggles the trace stays at `showsNothing` 0, `visible` 0 count 0, and no negative `distanceFromBottom`. `blank.arm` `shrink` still runs once per collapse; `blank.fire` does not.

## Evidence

Baseline `b40f0cfd6b08c13b4cdcac43624449ba3e1026ec`, timeline sources unmodified. Isolated run: 8 finished turns, 48 commands each, `workGroupStyle=tree`, pinned at the end, 30 expand/collapse cycles (60 toggles, all presses succeeded).

- Recording: `build.noindex/evidence/before-atend/fold-motion.mp4` (2640×1720, 587 frames, ~57fps, 10.27s).
- Timeline crop (excluding title and composer) goes flat on 20 frames. Fully empty frames that were opened: 147, 269, 289, 384, 393, 492 (`frames/seq02.png`, `seq05.png`, `seq08.png`, `seq11.png`, `seq13.png`, `seq16.png`). The frame before each of those still shows turns; the frame after shows turns again. `fold-before.png` and `fold-after.png` both show the conversation.
- Trace `build.noindex/evidence/before-atend/timeline.jsonl` from the first toggle (`t` 2920) through the end of the run: `showsNothing` on 153 lines, `visible=0` on 153, negative `distanceFromBottom` on 334, minimum distance −1586. `blank.arm` 60 (`shrink` 30, `visibleEmpty` 30). `blank.fire` 0. `refresh.branch` `showing` 14, `remake` 8. No `repair` event. Sample at `t` 4067: `distanceFromBottom` −1368, `pinned` true, `coasting` false.
