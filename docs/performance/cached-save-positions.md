# Reuse stable save positions

## Product change

ThreadRuntime already stores numeric positions for history rows. Previously every snapshot allocated a nextPositions array, scanned all entries backwards, then scanned forwards, even when only existing text changed and every position remained valid.

The runtime now invalidates these existing positions when the entries array changes or the positions dictionary is written. updateItemPositionsIfNeeded uses the identical original assignment algorithm only while invalid. snapshotForSave still flushes deltas before checking the flag, and the flag is cleared only after the complete position pass. Remaining head/dirty-turn snapshot construction, disk scheduling, retry and quit behavior are unchanged. This adds an invalidation flag, not another retained copy of history.

## Lead review

The entries observer performs one scalar assignment and never reads oldValue or scans IDs. The dictionary observer also covers merged loaded positions and recovery insertion. In-place item text changes leave the flag alone; structural append/removal/sort and loaded-array replacement invalidate it. A pending delta that appends during flush is therefore seen before the snapshot uses positions. Writes by the assignment pass mark it invalid temporarily, and the completed pass clears it without suspension or reentrancy.

## Validation

The lead extracts the baseline complete snapshotForSave method from 4fc87d1ee and the current method/helper from this checkout into one Swift 6 optimized executable, retaining real Observation and reduced metadata/row types. There are 250 complete snapshot equivalence checks: sparse positions, repeated unchanged snapshots, active and finished-turn content changes, append, removal, reorder, dictionary replacement/write, absent legacy positions and an append flushed immediately before snapshot.

All passed. The check compares the entire head and dirty-turn values, not counts alone. DiskWriter, providers and rendering are absent; this is not end-to-end disk durability or GUI acceptance. No actual-app RuntimeCostProbe has landed; these measurements remain explicitly component-only.

Artifacts: build.noindex/snapshot-position-checks/generate.py, checks.swift, source-provenance.json and correctness-results.txt. A preliminary timing run was made while the independent optimization build was active; it is preserved separately as preliminary-results.json and excluded from the final percentages. The completed quiet measurements are below.

No visual style, visible animation rate, text, normal feature, process priority or installed app changed.


## Quiet component measurement

The app optimization build had ended and no compiler was running. Eighty snapshots per variant reuse completed history plus ten active rows, changing the active tail text. The whole extracted snapshot assembly is timed, not just its position helper. Row and metadata types remain reduced; other owner apps remained open.

| Loaded rows | Original snapshot median (ms) | Cached snapshot median (ms) | Process CPU reduction |
| --- | --- | --- | --- |
| 1,000 | 0.908 | 0.315 | 60.6% |
| 5,000 | 4.943 | 1.707 | 67.3% |
| 20,000 | 27.030 | 5.419 | 78.8% |

CPU includes the same O(1) tail edit in both variants; reported medians time only snapshot assembly. These are per-component savings, not presentation FPS, end-to-end persistence or actual app throughput. Structural edits invalidate the positions and still run the original assignment pass, so these savings apply to repeated content-only updates. Artifacts: quiet-results.json and quiet-run.log.
