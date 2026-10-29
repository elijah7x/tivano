#!/usr/bin/env python3
"""Read-only, standard-library Hydra per-job profiles; no model calls or app operations.

python3 -I scripts/hydra_scorecard.py scorecard --compare DIR --out EXTERNAL_DIR \
    [--baseline DIR] [--verdicts DIR] [--judge DIR] \
    [--split-at ISO_DATE ...] [--reference v1|v2|first-period] \
    [--weights 'quality=3,outcome=3,user_effort=2,verification=2,reliability=2,coordination=1,efficiency=1']

Inputs are CSV exports and optional judge manifest/scores, opened read-only.
Outputs are scorecard.csv and scorecard.md in a fresh external directory.
Missing fields and inapplicable dimensions remain NA, never zero.
"""

import argparse
import bisect
import collections
import csv
import datetime as dt
import importlib.util
import json
import math
from pathlib import Path
import random
import re
import statistics
import sys

sys.dont_write_bytecode = True
_spec = importlib.util.spec_from_file_location('hydra_eval_loaders', Path(__file__).with_name('hydra_eval.py'))
eval_data = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(eval_data)

REQUEST_LEAD_SECONDS = 120
DIMENSIONS = ('outcome', 'user_effort', 'quality', 'verification', 'coordination', 'reliability', 'efficiency')
METRICS = {
    'outcome': ('outcome', 1),
    'turns_to_accept': ('user_effort', -1), 'corrections': ('user_effort', -1),
    'overall': ('quality', 1), 'correctness': ('quality', 1),
    'lead_built': ('verification', 1), 'visual_evidence': ('verification', 1),
    'review_verified': ('verification', 1),
    'failed_or_stalled_heads': ('coordination', -1), 'conflicts': ('coordination', -1),
    'lead_edits_after_reports': ('coordination', -1), 'continuations_total': ('coordination', -1),
    'flagged_heads': ('coordination', -1),
    'ending_problem': ('reliability', -1), 'review_failed': ('reliability', -1),
    'job_wall_seconds': ('efficiency', -1), 'rounds': ('efficiency', -1), 'heads': ('efficiency', -1),
}
ALIASES = {
    'thread': ('lead_id', 'thread_id'), 'request': ('request_id',), 'turn': ('turn_id',),
    'start': ('started_at', 'started', 'request_at', 'start_time'),
    'end': ('finished_at', 'finished', 'ended_at', 'end_time'),
    'size': ('size', 'size_bucket'), 'cohort': ('era', 'cohort'),
    'corrections': ('corrections_in_window', 'corrections', 'correction_count'),
    'visual_evidence': ('visual_evidence', 'visual_evidence_exists', 'has_visual_evidence'),
    'lead_edits_after_reports': ('lead_edits_after_reports', 'rework_edits'),
}


def number(value):
    if str(value).lower() in ('true', 'false'):
        return float(str(value).lower() == 'true')
    try:
        value = float(value)
        return value if math.isfinite(value) else None
    except (TypeError, ValueError):
        return None


def read_csv(path, mappings):
    with path.open(encoding='utf-8-sig', newline='') as handle:
        source = csv.DictReader(handle)
        headers = source.fieldnames or []
        normalized = {re.sub(r'[\s-]+', '_', h.strip().lower()): h for h in headers}
        if len(normalized) != len(headers):
            raise ValueError(f'Duplicate normalized headers: {path.name}')
        mapping = {key: next((normalized[a] for a in ALIASES.get(key, (key,)) if a in normalized), None)
                   for key in set(ALIASES) | set(METRICS) | {'job_key', 'task_type', 'model_verdict', 'ending', 'review_outcome'}}
        mappings.append((str(path), mapping))
        rows = []
        for original in source:
            row = {key: original[header] for key, header in normalized.items()}
            row.update({key: original[header] for key, header in mapping.items() if header})
            rows.append(row)
        return rows


def stamp(row, field):
    return eval_data.timestamp(row.get(field))


def compatible(job, row):
    return (bool(job.get('thread')) and job.get('thread') == row.get('thread')
            and (not row.get('cohort') or row['cohort'] == job['cohort'])
            and all(not job.get(k) or not row.get(k) or job[k] == row[k] for k in ('host', 'edition')))


def join_rows(jobs, rows):
    """Reject ambiguous identities; temporal matching requires a bounded job window."""
    result, counts = {}, collections.Counter()
    for index, job in enumerate(jobs):
        candidates = [r for r in rows if compatible(job, r)]
        ids = {job.get(k) for k in ('request', 'turn')} - {None, ''}
        exact = [r for r in candidates if ids & ({r.get(k) for k in ('request', 'turn')} - {None, ''})]
        if len(exact) == 1:
            result[index] = exact[0]
            counts['exact'] += 1
            continue
        if exact:
            counts['ambiguous'] += 1
            continue
        start, end = stamp(job, 'start'), stamp(job, 'end')
        if start is not None and end is not None:
            timed = [(abs(stamp(r, 'start') - start), r) for r in candidates
                     # The user's message precedes the job's startedAt by the lead's spin-up.
                     if stamp(r, 'start') is not None and start - REQUEST_LEAD_SECONDS <= stamp(r, 'start') <= end]
            # A follow-up inside the window cannot be told from the original request by time alone.
            if len(timed) == 1:
                result[index] = timed[0][1]
                counts['window'] += 1
                continue
            if timed:
                counts['ambiguous_window'] += 1
                continue
        counts['unmatched'] += 1
    # A single reaction/packet cannot stand in for multiple jobs.
    uses = collections.Counter(id(row) for row in result.values())
    for index in list(result):
        if uses[id(result[index])] > 1:
            del result[index]
            counts['reused_rejected'] += 1
    return result, f'{len(result)}/{len(jobs)} jobs matched; {dict(counts)}'


def judge_rows(directory, mappings, gaps):
    rows = read_csv(directory / 'manifest.csv', mappings)
    versions = set()
    for path in (directory / 'scores').glob('*.json'):
        try:
            value = json.loads(path.read_text(encoding='utf-8'))
        except (OSError, ValueError):
            continue
        if isinstance(value, dict):
            versions.add(value.get('rubric_version') or 'legacy')
    if len(versions) > 1:
        raise ValueError('Judge scores mix rubric versions ' + ', '.join(sorted(versions))
                         + '; pass a judge directory scored with one rubric')
    for row in rows:
        packet = row.get('packet_id', '')
        if not re.fullmatch(r'[A-Za-z0-9_-]+', packet):
            gaps.append('Invalid judge packet ID excluded.')
            continue
        scores = collections.defaultdict(list)
        for path in sorted((directory / 'scores').glob(packet + '.*.json')):
            if not re.fullmatch(re.escape(packet) + r'\.\d+\.json', path.name):
                continue
            try:
                value = json.loads(path.read_text(encoding='utf-8'))
                if not isinstance(value, dict):
                    raise ValueError('Expected score object')
                for key in ('overall', 'correctness'):
                    raw = value.get(key)
                    if isinstance(raw, dict):
                        raw = raw.get('score')
                    score = number(raw)
                    if score is not None and not isinstance(raw, bool) and 1 <= score <= 5:
                        scores[key].append(score)
            except (OSError, ValueError):
                gaps.append('Unreadable or invalid judge score: ' + path.name)
        for key in ('overall', 'correctness'):
            row[key] = statistics.mean(scores[key]) if scores[key] else None
    return rows


def safe_output(value, sources):
    raw = Path(value).expanduser().absolute()
    if any(p.is_symlink() for p in (raw, *raw.parents)):
        raise ValueError('Output paths must not contain symlinks')
    out = raw.resolve()
    protected = sources + [p.parent.resolve() for p in eval_data.DEFAULTS]
    protected += [Path.home() / '.tivano', Path.home() / '.tivano-dev']
    if any(out == p or p in out.parents or out in p.parents for p in protected):
        raise ValueError('Output must be separate from source directories and app data')
    if any((p / '.git').exists() for p in (out, *out.parents)):
        raise ValueError('Output must be outside repositories')
    if out.exists() and any(out.iterdir()):
        raise ValueError('Choose a fresh, empty output directory')
    return out


def mean(values):
    values = [v for v in values if v is not None]
    return statistics.mean(values) if values else None


def profile(values):
    values = [v for v in values if v is not None]
    n = len(values)
    if not n:
        return 'NA (n=0)'
    rng = random.Random(1)
    samples = sorted(statistics.mean(rng.choices(values, k=n)) for _ in range(1000))
    return f'{statistics.mean(values):.1f} [{samples[49]:.1f}, {samples[949]:.1f}] n={n}' + ('; too few' if n < 10 else '')


def scorecard(args):
    sources = [Path(p).expanduser().resolve() for p in (args.compare, args.baseline, args.verdicts, args.judge) if p]
    out = safe_output(args.out, sources)
    mappings, gaps, jobs = [], [], []
    for cohort, directory, prefix in [('v1', args.baseline, ''), ('v2', args.compare, 'v2_')]:
        if not directory:
            continue
        directory = Path(directory).expanduser().resolve()
        cohort_jobs = read_csv(directory / (prefix + 'jobs.csv'), mappings)
        heads = read_csv(directory / (prefix + 'heads.csv'), mappings)
        by_job = collections.defaultdict(list)
        for head in heads:
            by_job[head.get('job_key')].append(head)
        for job in cohort_jobs:
            job['cohort'] = cohort
            related = by_job.get(job.get('job_key'), [])
            count = number(job.get('heads'))
            if count is not None and count == len(related) and count > 0:
                for key, source in [('failed_or_stalled_heads', 'failure_or_stall'), ('conflicts', 'conflicts'),
                                    ('continuations_total', 'continuations'), ('flagged_heads', 'flags_something')]:
                    values = [number(h.get(source)) for h in related]
                    if all(v is not None for v in values):
                        job[key] = sum(values)
                    elif key == 'flagged_heads':
                        job[key] = None
            elif number(job.get('flags_observed_heads')) != count:
                job['flagged_heads'] = None
            start, wall = stamp(job, 'start'), number(job.get('job_wall_seconds'))
            if not job.get('end') and start is not None and wall is not None and wall >= 0:
                job['end'] = dt.datetime.fromtimestamp(start + wall, dt.timezone.utc).isoformat()
            jobs.append(job)
    verdicts = read_csv(Path(args.verdicts).expanduser() / 'verdicts.csv', mappings) if args.verdicts else []
    verdict_matches, verdict_rate = join_rows(jobs, verdicts)
    for index, row in verdict_matches.items():
        # The matched request ID lets judge packets join by identity; manifests carry no times.
        for key in ('size', 'start', 'request'):
            if not jobs[index].get(key) and row.get(key):
                jobs[index][key] = row[key]
    judges = judge_rows(Path(args.judge).expanduser(), mappings, gaps) if args.judge else []
    judge_matches, judge_rate = join_rows(jobs, judges)
    boundaries = [eval_data.timestamp(s) for group in args.split_at for s in group]
    if any(v is None for v in boundaries):
        raise ValueError('--split-at requires ISO dates')
    boundaries = sorted(set(boundaries))
    for index, job in enumerate(jobs):
        verdict, judge = verdict_matches.get(index, {}), judge_matches.get(index, {})
        start = stamp(job, 'start')
        job['period'] = ('all' if not boundaries else ('undated' if start is None else f'period-{bisect.bisect_right(boundaries, start) + 1}'))
        job['size'] = job.get('size') or judge.get('size') or 'unknown'
        job['task_type'] = job.get('task_type') or 'unknown'
        job['stratum'] = job['task_type'] + ' x ' + job['size']
        job['verdict_match'] = index in verdict_matches
        job['judge_match'] = index in judge_matches
        raw = {key: number(job.get(key)) for key in METRICS}
        raw['outcome'] = {'accept': 1, 'refine': 0.5, 'correction': 0}.get(verdict.get('model_verdict'))
        for key in ('turns_to_accept', 'corrections'):
            raw[key] = number(verdict.get(key, job.get(key)))
        for key in ('overall', 'correctness'):
            raw[key] = number(judge.get(key))
        if job['task_type'] != 'ui_design':
            raw['visual_evidence'] = None
        review = job.get('review_outcome')
        raw['review_verified'] = 1 if review in ('clean', 'delivered') else (0 if review == 'failed' else None)
        raw['review_failed'] = 1 if review == 'failed' else (0 if review in ('clean', 'delivered', 'skipped', 'not_applicable', 'not_run') else None)
        ending = job.get('ending')
        raw['ending_problem'] = 1 if ending in ('interrupted', 'recovered', 'unknown') else (0 if ending == 'completed' else None)
        for key, (dimension, _) in METRICS.items():
            if dimension == 'coordination':
                count = raw['heads']
                raw[key] = raw[key] / count if count is not None and count > 0 and raw[key] is not None else None
        job['raw'] = raw
    first = 'period-1' if boundaries else 'all'
    reference = [j for j in jobs if j['period'] == first] if args.reference == 'first-period' else [j for j in jobs if j['cohort'] == args.reference]
    for job in jobs:
        scores, fallback = {}, {}
        for key, (_, direction) in METRICS.items():
            if job['raw'][key] is None:
                scores[key], fallback[key] = None, 'NA'
                continue
            candidates = [r for r in reference if r['raw'][key] is not None]
            strata = [r for r in candidates if r['stratum'] == job['stratum']] if job['size'] != 'unknown' else []
            level = 'task_type x size'
            if len(strata) < 5:
                strata = [r for r in candidates if r['task_type'] == job['task_type']]
                level = 'task_type'
            if len(strata) < 5:
                strata, level = candidates, 'global'
            fallback[key] = level + f' (n={len(strata)})'
            values = [r['raw'][key] * direction for r in strata]
            value = job['raw'][key] * direction
            scores[key] = (100 * (sum(v < value for v in values) + 0.5 * sum(v == value for v in values)) / len(values)) if values else None
        job['scores'], job['fallback'] = scores, fallback
        job['dimensions'] = {d: mean([scores[k] for k in METRICS if METRICS[k][0] == d]) for d in DIMENSIONS}
    weights = {}
    if args.weights:
        for part in args.weights.split(','):
            key, value = part.split('=', 1)
            value = float(value)
            if key not in DIMENSIONS or not math.isfinite(value) or value < 0 or key in weights:
                raise ValueError('Weights require unique dimension names and finite nonnegative numbers')
            weights[key] = value
        if not any(weights.values()):
            raise ValueError('At least one weight must be positive')
        for job in jobs:
            present = {k: w for k, w in weights.items() if job['dimensions'][k] is not None and w > 0}
            job['weighted_index'] = sum(job['dimensions'][k] * w for k, w in present.items()) / sum(present.values()) if present else None
    lines = ['# Hydra scorecard', '', 'Percentile profiles, not a causal comparison or absolute quality rating. Higher is better; 50 is typical against the chosen reference.', '',
             f'Reference: {args.reference}; {len(reference)} jobs. Splits (UTC, boundary belongs to later period): {args.split_at or "none"}.',
             f'Verdict join: {verdict_rate}. Judge join: {judge_rate}.', '',
             'Each cell: mean [seeded bootstrap 90% interval], observed job n; too few means n < 10. Efficiency is reported last.']
    def table(title, groups):
        lines.extend(['', '## ' + title, '', '| Group | ' + ' | '.join(DIMENSIONS) + (' | Weighted index' if weights else '') + ' |',
                      '|---|' + '---|' * (len(DIMENSIONS) + bool(weights))])
        for label, subset in groups:
            cells = [profile([j['dimensions'][d] for j in subset]) for d in DIMENSIONS]
            if weights:
                cells.append(profile([j['weighted_index'] for j in subset]))
            lines.append('| ' + label.replace('|', '\\|') + ' | ' + ' | '.join(cells) + ' |')
    groups = sorted({(j['cohort'], j['period']) for j in jobs})
    table('Cohort / period', [(f'{c} / {p}', [j for j in jobs if (j['cohort'], j['period']) == (c, p)]) for c, p in groups])
    types = sorted({(j['cohort'], j['period'], j['task_type']) for j in jobs})
    table('Per task type', [(' / '.join(g), [j for j in jobs if (j['cohort'], j['period'], j['task_type']) == g]) for g in types])
    lines.extend(['', '## Data gaps', ''])
    for cohort in sorted({j['cohort'] for j in jobs}):
        subset = [j for j in jobs if j['cohort'] == cohort]
        for key in METRICS:
            missing = sum(j['raw'][key] is None for j in subset)
            if missing:
                lines.append(f'- {cohort} {key}: NA {missing}/{len(subset)} (missing or inapplicable).')
        lines.append(f'- {cohort}: missing size {sum(j["size"] == "unknown" for j in subset)}; missing start {sum(stamp(j, "start") is None for j in subset)}.')
    lines.extend('- ' + gap for gap in sorted(set(gaps)))
    lines.extend(['', '## Field mappings', ''])
    for path, mapping in mappings:
        lines.append('- ' + path + ': ' + '; '.join(f'{key} ← {value or "NA (absent)"}' for key, value in sorted(mapping.items())))
    lines.extend(['- Head aggregation: complete matching head rows supply failure_or_stall, conflicts, continuations and flags_something totals; coordination divides each total by heads.',
                  '', '## Limits', '',
                  '- No overall score by default. Dimension scores equally average their observed metric percentiles; missing metrics are excluded. Differing coverage can change the meaning of a dimension across cohorts.',
                  '- Percentiles use midranks (half credit for ties), independently for each metric. Reference n < 5 falls back from task type × size to task type to global. Empty reference gives NA; a small global reference remains small. Per-metric fallback and n are exported.',
                  '- Bootstrap resamples jobs 1000 times with seed 1; jobs in the same thread may be dependent. Intervals omit model and task-classification uncertainty. Reference jobs include themselves.',
                  '- Exact joins require thread plus request/turn identity; temporal fallback requires a start inside a known job window. Ambiguous and reused matches are excluded. Missing V2 timestamps cannot be reconstructed from duration alone. No excerpt matching.',
                  '- Outcome uses only model_verdict, excluding neutral/missing. turns_to_accept is the exported window proxy and may originate from keyword labels; corrections require an explicit count column, never inferred from a single next-message verdict.',
                  '- Quality averages valid 1–5 samples within each packet; NA judge dimensions are excluded. No judge models are called. Unmatched packets do not contribute.',
                  '- Lead build and visual evidence are recorded evidence proxies. UI visual evidence is NA without a column. Clean/delivered review scores verified; failed scores unverified. Skipped, not_run, not_applicable and pending are not proof of verification.',
                  '- Reliability treats interrupted/recovered/explicit unknown endings as adverse; missing ending is NA. not_applicable is not review failure. Coordination applies only to delegated jobs and rework_edits is the V1 proxy for lead_edits_after_reports; the windows differ.',
                  '- Size is supplied metadata only, not inferred from heads or duration. Undated jobs cannot enter split periods. Different tasks, selection effects and missing cohorts prevent causal claims.',
                  '- Inputs are read-only, not atomic snapshots. Exports contain only IDs, metrics and redacted metadata; heuristic redaction cannot guarantee detection of all secrets.'])
    if weights:
        lines.append('- Optional weighted index (not an objective composite): ' + str(weights) + '; weights renormalize over observed dimensions per job. Coverage differs; compare with caution.')
    identifiers = ['cohort', 'period', 'job_key', 'thread', 'request', 'turn', 'task_type', 'size', 'stratum', 'verdict_match', 'judge_match']
    columns = identifiers + [f'raw_{k}' for k in METRICS] + [f'percentile_{k}' for k in METRICS] + [f'fallback_{k}' for k in METRICS] + [f'score_{d}' for d in DIMENSIONS]
    if weights:
        columns.append('weighted_index')
    out.mkdir(parents=True, exist_ok=True)
    with (out / 'scorecard.csv').open('x', encoding='utf-8', newline='') as handle:
        writer = csv.DictWriter(handle, fieldnames=columns)
        writer.writeheader()
        for job in jobs:
            row = {k: job.get(k) for k in identifiers}
            for prefix, values in [('raw', job['raw']), ('percentile', job['scores']), ('fallback', job['fallback']), ('score', job['dimensions'])]:
                row.update({f'{prefix}_{k}': v for k, v in values.items()})
            if weights:
                row['weighted_index'] = job['weighted_index']
            writer.writerow({k: eval_data.redact(v) if isinstance(v, str) else v for k, v in row.items()})
    with (out / 'scorecard.md').open('x', encoding='utf-8') as handle:
        handle.write(eval_data.redact('\n'.join(lines)) + '\n')


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest='command', required=True)
    command = sub.add_parser('scorecard')
    command.add_argument('--compare', required=True)
    command.add_argument('--baseline')
    command.add_argument('--verdicts')
    command.add_argument('--judge')
    command.add_argument('--split-at', nargs='+', action='append', default=[])
    command.add_argument('--reference', choices=('v1', 'v2', 'first-period'), default='first-period')
    command.add_argument('--weights')
    command.add_argument('--out', required=True)
    args = parser.parse_args()
    try:
        scorecard(args)
    except (ValueError, OSError) as exc:
        parser.error(eval_data.redact(str(exc)))


if __name__ == '__main__':
    main()
