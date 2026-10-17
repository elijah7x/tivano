# Incremental timeline entry binding

## Finding and change

`ThreadRuntime.entries.didSet` constructed complete old/new ID sets and walked both arrays on every structural mutation. A new tool/message row therefore scanned all loaded history, even though only the new row needed its dirty callback. This code was already in the Release candidate baseline; it is not established as a recent regression or the sole cause of the reported stutter. Appending text to an existing row does not itself run this array path.

The observer is replaced by explicit `bindEntry` calls at append, history installation, recovered turn-end insertion, recovered Codex insertion and the Debug rehearsal insertion. Removal and revert go through `removeEntries`, which clears callbacks of removed rows and marks their turns dirty. Sorting keeps existing bindings. Save scheduling, snapshot construction, providers and presentation are unchanged.

## Component measurement

The harness extracts the actual baseline observer/append/remove/revision methods from `4fc87d1ee`, and the candidate methods from the working source. Both use real Swift Observation and UUID-shaped row IDs, with the same 128 precreated appends after seeding each history length. Both are compiled with `swiftc -O`; model payload and `endStreaming` are stubbed. History seeding is outside the measured region. The app build had ended before the sequential baseline/candidate runs. Other owner applications were left running.

| Loaded rows | Baseline append median (ms) | Candidate append median (ms) | Baseline CPU for 128 appends (s) | Candidate CPU (s) |
| --- | --- | --- | --- | --- |
| 1,000 | 1.636 | 0.002 | 0.208233 | 0.000386 |
| 5,000 | 9.076 | 0.003 | 1.129562 | 0.000452 |
| 20,000 | 61.523 | 0.002 | 7.400625 | 0.000403 |

The candidate removes this history-length-dependent scan. Sub-millisecond candidate totals are near timer resolution and should not be presented as precise speedup ratios. These numbers are component work, not application frame times, model throughput, input latency or physical-wheel performance. The long baseline tail also includes scheduler effects; process CPU is recorded separately.

Artifacts: `build.noindex/entry-append-benchmark/baseline.swift`, `candidate-current.swift`, the four extracted baseline declarations, executables and `*-cpu-results.json`. The final candidate includes the scalar save-position invalidation observer; the earlier pre-invalidation candidate is preserved separately.

## Correctness validation

The extracted candidate helpers passed checks for callbacks after loading and appending, turn/save revisions, observable array invalidation, removed-row callback cleanup, nil-turn records and weak owner lifetime. The lead reviewed every structural mutation in `ThreadRuntime.swift`, including load, revert and recovery. These focused checks are not an end-to-end persistence or real-provider test; the full Debug build and isolated three-session final-state reconciliation supplement them.

No visual parameter, visible animation rate, feature limit or background-process priority was changed by this fix. No package was installed or production session restarted.
