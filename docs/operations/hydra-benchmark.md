# Hydra benchmark

Use three layers together. Quality comes first, then cost, then time. No single score should conceal a correctness regression or missing evidence.

## Layer 1: observational scorecard

`scripts/hydra_scorecard.py` measures real work across seven dimensions: outcome, user_effort, quality, verification, coordination, reliability, and efficiency. Report efficiency last. Normalize each raw metric to a 0–100 percentile within its `task_type × size` bucket against a fixed reference cohort, reversing lower-is-better metrics. This makes unlike tasks more comparable without pretending they are identical. Preserve raw values, missingness, cohort identity and metric denominators alongside percentiles.

Report bootstrap 90% intervals, with no default composite. Resample jobs rather than treating multiple heads or judge samples as independent tasks. Freeze the reference cohort for a comparison; changing it can move percentiles without any behavior change. Use this layer to find trends and choose investigations, not to claim a causal improvement between releases.

## Layer 2: fixed regression suite

Comparing different real tasks is the main noise source. Freeze 8–12 historical tasks spanning bugfix, implementation, UI, research/review, documentation, refactor/performance and release/operations, with small, medium and large work represented. Include known failures as well as successes. Use safe, isolated substitutes for external release actions.

Replay each task from its own identical base commit for every Hydra version/configuration. Keep the request, acceptance checks, rubric, tool access and environment fixed. Record version/configuration and replicate in the run label. Compare paired results per task, using objective checks plus the blind judge. The suite removes differences in task selection; model randomness and environment differences still remain.

`scripts/hydra_suite.py` scaffolds and checks tasks; it does not replay agents, reset repositories, build implicitly or invoke the judge. The lead prepares an isolated replay checkout and retains the final reply, diff, command evidence and any visual evidence for judging. Run after each Hydra-affecting release, or approximately 50 new jobs. Repeat each suite task at least twice per configuration when practical; three replicates help reveal instability. Keep individual failures visible rather than averaging them away.

## Layer 3: blind quality judge

`scripts/hydra_judge.py` judges completeness, correctness, scope, honesty, verification, communication and overall quality, plus evidence strength, on 1–5 scales. NA is allowed when evidence is missing; it is not a zero or a pass. Use anchored rubrics for each task type: UI acceptance requires visual evidence, while research and documentation need different evidence from code changes.

Do not mix `rubric_version` values. Keep judge model/configuration fixed, use fresh exports and inspect a human-check sample. Hide implementation version/configuration from the judge; retain the mapping privately. Overall is the judge's assessment, not an automatic composite of the observational dimensions. Use the judge for evidence-based quality comparisons that objective checks cannot cover. The current export workflow consumes snapshot verdict rows; suite results need replay transcripts in that workflow or separately prepared blinded packets, not a direct `hydra_suite` import.

## Snapshots and cadence

Resolve `$ARTIFACTS` from the physical shared Git directory returned by `git rev-parse --path-format=absolute --git-common-dir`: its parent is the long-lived source checkout, and that checkout's parent is the default artifact root. `TIVANO_ARTIFACTS_ROOT` may override this with an absolute external directory. Never derive storage from a task worktree's parent. Keep outputs outside every Git work tree, source checkout and live application library.

Copy `library.json` and its sibling `threads/` tree from each host into a fresh directory:

```text
$ARTIFACTS/hydra-eval/hosts/<host>/<stamp>/library.json
$ARTIFACTS/hydra-eval/hosts/<host>/<stamp>/threads/
```

Retain indexed turn revisions and record host, edition, capture time, application version and any copy interruption. Prefer a quiescent source or consistent filesystem snapshot; do not merge snapshots in place. Treat missing revisions as missing evidence. All analysis reads the copies; never modify a live library or import production data into Dev.

With an existing V1 baseline, the analysis order is **compare → verdict → judge verdicts → judge export/run/report → scorecard**. Use fresh output directories and repeat `--library` for every snapshot:

```sh
python3 -I scripts/hydra_eval.py compare --baseline "$BASELINE" --library "$SNAPSHOT/library.json" --out "$RUN/compare"
python3 -I scripts/hydra_eval.py verdict --library "$SNAPSHOT/library.json" --out "$RUN/verdict"
python3 -I scripts/hydra_judge.py verdicts --verdict-csv "$RUN/verdict/verdict.csv" --library "$SNAPSHOT/library.json" --codex "$CODEX" --out "$RUN/reactions"
python3 -I scripts/hydra_judge.py export --verdict-csv "$RUN/reactions/verdicts.csv" --library "$SNAPSHOT/library.json" --out "$RUN/judge"
python3 -I scripts/hydra_judge.py run --dir "$RUN/judge" --codex "$CODEX" --model "$JUDGE_MODEL" --samples 2
python3 -I scripts/hydra_judge.py report --dir "$RUN/judge"
```

Then run `python3 -I scripts/hydra_scorecard.py` with the comparison, reaction and judge artifacts and a frozen reference cohort; consult its CLI help for input flags. If no V1 baseline exists, first use `hydra_eval.py baseline` on the frozen V1 snapshots. Judge execution sends blinded evidence to a model and may incur cost; inspect redaction before submission.

For observational comparisons, aim for at least 30 independent jobs per cohort and 10 reference jobs per task-type/size bucket. These are practical reporting thresholds, not power guarantees. Below them, label results exploratory and show n and intervals; do not silently pool incompatible buckets. Missing size, incomplete transcripts and absent judge evidence need explicit coverage counts. A fixed suite of 8–12 tasks detects regressions, not population-wide superiority.

## Suite specification and commands

Specs contain real requests and stay private, outside the repository under `$ARTIFACTS/hydra-eval/suite/`. Heuristic credential redaction does not remove all personal or customer information. Inspect each spec manually before freezing or sharing it.

```sh
python3 -I scripts/hydra_suite.py new --job-csv "$RUN/compare/v2_jobs.csv" --job-id "$JOB_ID" --out "$ARTIFACTS/hydra-eval/suite/task.json"
python3 -I scripts/hydra_suite.py check --spec "$ARTIFACTS/hydra-eval/suite/task.json" --worktree "$REPLAY" --head "$FINAL_COMMIT" --label version-A-repeat-1 --out "$RUN/suite-A"
python3 -I scripts/hydra_suite.py summary --results "$RUN/suite-A" "$RUN/suite-B" --out "$RUN/suite-summary"
```

`new` accepts V2 `v2_jobs.csv` or V1 `jobs.csv`. Select by `job_key`, `job_id` or V1 `request_id`; ambiguous IDs are rejected. Exports generally contain only an excerpt, and V1 may lack a base commit or size. Restore the complete redacted request, pin the full commit ID, set `request_is_excerpt` to false and add checks before freezing. The tool does not invent missing history.

Schema version 1:

```json
{
  "schema_version": 1,
  "id": "stable-private-task-id",
  "task_type": "bugfix",
  "size": "small",
  "base_commit": "<full 40- or 64-character commit ID>",
  "request": "Complete redacted historical request",
  "request_is_excerpt": false,
  "checks": {
    "allowed_paths": [{"patterns": ["Tivano/Core/*", "docs/*"], "weight": 1}],
    "required_paths": [{"pattern": "Tivano/Core/Example.swift", "weight": 2}],
    "forbidden_paths": [{"pattern": "config/*"}],
    "diff_must_match": [{"pattern": "^\\+.*expectedExpression", "weight": 1}],
    "diff_must_not_match": [{"pattern": "^\\+.*forbiddenExpression"}],
    "commands": [{"name": "acceptance", "argv": ["python3", "-I", "scripts/acceptance.py"], "cwd_relative": ".", "weight": 3}]
  },
  "rubric_notes": "Task-specific acceptance evidence for the blind judge"
}
```

`size` is optional. All check categories are optional lists; every entry has a positive finite `weight`, default 1. Each allowed-path entry is one check whose patterns form a union: every changed path must match that union. Normally use one such entry. An empty union forbids all changes. Required-path entries must each match at least one changed path; forbidden-path entries must match none. Globs use Python `fnmatchcase` on repository-relative paths (`*` can span `/`). Renames are treated as deletion plus addition, so both paths are checked. Regex checks use Python multiline matching on the complete diff, including context and headers; anchor to `^\+` or `^-` when only additions or removals matter.

Without `--head`, the checker compares the frozen base with tracked working-tree content, including tracked staged and unstaged edits. Untracked files are excluded; use a committed replay result for complete added-file evidence. With `--head REF`, it compares the base with that committed ref and ignores local edits. Git reads use only `rev-parse` and `diff`, with external diff drivers and text conversion disabled.

Commands run only with `--run-commands`, as argv without a shell, with a 300-second timeout per command. Their working directory must resolve inside the replay worktree. They are arbitrary programs, can mutate files or access the network, and are not sandboxed; review them before opting in. The diff is captured before commands run. Exit zero passes; other exits, launch errors and timeouts fail. Captured output is truncated and redacted.

`check` writes `result.json` and `result.md`, with status and weight per check. Objective score is `100 × passed weight / total configured weight`; skipped commands retain their weight and mark the run incomplete. No checks means NA, never 100. Exit status is 0 only for a complete all-pass result, 1 for failures/incomplete results, and 2 for input or operational errors. `summary` writes JSON plus a spec-by-run-label Markdown table, rejecting duplicate labels for a spec and changed spec fingerprints or bases under the same ID. Use a new spec ID when acceptance changes. It does not aggregate objective and judge scores.

Outputs must be fresh paths, without symlink components. The checker refuses outputs inside repositories, source data or live app storage, and never overwrites an earlier result. It does not choose or create a default artifact directory when `--out` is supplied.

## Known gaps and tracked weaknesses

Review outcomes need a stable reason vocabulary: `no changes`, `independent review is off`, `no review model available`, `not applicable: no checkout`, `not run: <ending>`, and `review failed...`. Keep these separate from a completed review and from unknown legacy values; absence of a review record does not prove review was disabled. Ledgers written before this vocabulary record every failure as a bare `review failed`, including conversations without a checkout; the thread's current paths cannot prove which, so those legacy records stay `failed`.

V1 job wall time runs from the request to the qualifying final reply, V2 from the job's `startedAt` to `finishedAt`. Do not compare efficiency across V1 and V2; compare it between V2 periods or suite runs only. V2 jobs join user reactions by thread and time window (the request may precede `startedAt` by up to 120 seconds); check the reported join rate before reading outcome or user_effort.

Track these weaknesses as explicit rates with eligible denominators and unknown counts:

- Dispatch capability preflight failures per attempted dispatch; distinguish detected preflight rejection from failure after dispatch.
- Stale-state continuations per continuation opportunity, using evidence of reused outdated task/review state.
- Acceptance mismatched to task per evaluable task, including UI changes accepted without a visual check.

There is no token/cost data, so time and tool counts cannot establish cost savings. There is no structured visual-check evidence field, so visual verification remains unknown unless supported by retained evidence. Missing fields must not become successful checks. Keep these coverage gaps visible beside the scorecard until instrumentation exists.
