#!/usr/bin/env python3
"""Read-only Tivano Hydra baseline extractor, V2 comparator and replay shortlist writer.

baseline writes jobs.csv, heads.csv, summary.md and samples.md. compare reads a baseline
and V2 job ledgers, then writes v2_jobs.csv, v2_heads.csv and comparison.md.
V2 jobs include agentic/conversation classification and lead tool/edit/command/web
counts from indexed lead turn revisions. Comparison reports delegation rates by
tilt against agentic targets and up to 20 large agentic jobs without heads.
replay-candidates reads baseline jobs.csv and writes replay_candidates.md without running
replays or Git commands.

Run with python3 -I scripts/hydra_eval.py SUBCOMMAND --out EXTERNAL_DIRECTORY.
Source libraries and baseline exports are only read; no app, database, lock or Git operations.
"""

import argparse
import collections
import csv
import datetime as dt
import json
from pathlib import Path
import re
import statistics


ROSTER = 'Hank Walter Ada Otto Nova Remy Iris Milo Juno Ezra Lena Bo Kai Vera Finn Mira Odin Suki Rex Zola Pip Ivo Lux Tova Gus'.split()
DEFAULTS = [Path.home() / 'Library/Application Support' / name / 'library.json'
            for name in ('Tivano', 'Tivano Dev')]


def redact(text):
    text = str(text or '')
    text = re.sub(r'-----BEGIN [^-]*PRIVATE KEY-----.*?(?:-----END [^-]*PRIVATE KEY-----|\Z)',
                  '[REDACTED PRIVATE KEY]', text, flags=re.S)
    text = re.sub(r'(?i)\b(?:sk-|gh[pousr]_|github_pat_|xox[baprs]-|AKIA)[A-Za-z0-9_./+\-=]{8,}', '[REDACTED]', text)
    text = re.sub(r'(?i)(\b(?:api[_ -]?key|access[_ -]?token|refresh[_ -]?token|auth[_ -]?token|token|secret|password|passwd|authorization|cookie|client[_ -]?secret)\b[\s"\x27]*[:=][\s"\x27]*)([^\s"\x27,;}]+)', r'\1[REDACTED]', text)
    text = re.sub(r'(?i)\bBearer\s+\S+', 'Bearer [REDACTED]', text)
    text = re.sub(r'(?i)(https?://)[^\s/@]+:[^\s/@]+@', r'\1[REDACTED]@', text)
    # Conservatively hide opaque blobs, including unlabelled JWTs and credentials.
    text = re.sub(r'(?<![\w])[A-Za-z0-9_+/=.-]{40,}(?![\w])', '[REDACTED OPAQUE VALUE]', text)
    return text


def timestamp(value):
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        # Swift JSONEncoder's default Date strategy uses the 2001-01-01 reference date.
        return 978307200.0 + value
    if not isinstance(value, str):
        return None
    try:
        parsed = dt.datetime.fromisoformat(value.replace('Z', '+00:00'))
        return parsed.replace(tzinfo=parsed.tzinfo or dt.timezone.utc).timestamp()
    except ValueError:
        return None


def first_time(record, keys):
    for key in keys:
        value = timestamp(record.get(key))
        if value is not None:
            return value, key
    return None, 'missing'


def payload(item):
    content = item.get('content') or {}
    if not isinstance(content, dict) or not content:
        return '', {}
    kind = next(iter(content))
    value = content[kind]
    if isinstance(value, dict):
        value = value.get('_0', value)
    return kind, value if isinstance(value, dict) else {'text': str(value)}


def generated_user(value):
    text = value.get('text', '').lstrip()
    return ('hydraHeads' in value or value.get('hydraBrief') or
            text.startswith(('[Hydra]', 'Hydra reports:', '[Tivano]')))


class Reader:
    def __init__(self):
        self.issues = collections.Counter()
        self.changed = 0

    def read(self, path):
        try:
            before = path.stat()
            with path.open('r', encoding='utf-8') as handle:
                value = json.load(handle)
            after = path.stat()
            if (before.st_mtime_ns, before.st_size) != (after.st_mtime_ns, after.st_size):
                self.changed += 1
            return value
        except (OSError, ValueError):
            self.issues['missing_or_unreadable_json'] += 1
            return {}

    def transcript(self, root, thread_id):
        if not re.fullmatch(r'[A-Za-z0-9-]+', thread_id):
            self.issues['invalid_thread_id'] += 1
            return [], [], [], False
        main = self.read(root / 'threads' / (thread_id + '.json'))
        chunks = [main]
        complete = bool(main)
        for index in main.get('turnIndex', []):
            turn_id = index.get('id', '')
            if not re.fullmatch(r'[A-Za-z0-9-]+', turn_id):
                self.issues['invalid_turn_id'] += 1
                complete = False
                continue
            part = self.read(root / 'threads' / (thread_id + '.turns') / (turn_id + '.json'))
            revisions = part.get('revisions', {})
            selected = revisions.get(str(index.get('revision')))
            if selected is None:
                # Never substitute a newer revision for the library's referenced snapshot.
                self.issues['missing_referenced_turn_revision'] += 1
                complete = False
                continue
            chunks.append(selected)
        items, turns, merges = {}, {}, []
        for chunk in chunks:
            for item in chunk.get('items', []):
                items[item.get('id', 'anonymous-' + str(len(items)))] = item
            for turn in chunk.get('turns', []) + ([chunk['turn']] if chunk.get('turn') else []):
                turns[turn.get('id', 'anonymous-' + str(len(turns)))] = turn
            merges.extend(chunk.get('hydraMerges', []))
        ordered = sorted(items.values(), key=lambda i: timestamp(i.get('date')) or 0)
        return ordered, list(turns.values()), merges, complete


def classify(request):
    rules = [('release_ops', r'发版|打包|部署|发布|\brelease\b|\bpackag|\bdeploy'),
             ('bugfix', r'修复|报错|崩溃|故障|\bbug\b|\bfix\b|crash|regression'),
             ('research_review', r'调研|研究|审计|评审|分析|调查|research|review|audit|investigat|baseline'),
             ('ui_design', r'界面|设计|视觉|样式|交互|布局|\bui\b|\bux\b|design|layout'),
             ('refactor_performance', r'重构|性能|优化|refactor|performance|optimi'),
             ('docs_content', r'文档|文案|翻译|documentation|\bdocs\b|translat')]
    for name, pattern in rules:
        if re.search(pattern, request, re.I):
            return name
    return 'implementation_other' if request else 'unknown'


def head_name(index):
    if not isinstance(index, int) or index < 0:
        return 'unknown'
    return ROSTER[index % len(ROSTER)] + (f' {index // len(ROSTER) + 1}' if index >= len(ROSTER) else '')


def med(rows, field):
    values = [r[field] for r in rows if isinstance(r.get(field), (int, float))]
    return f'{statistics.median(values):.2f}' if values else 'NA'


def rate(numerator, denominator):
    return f'{numerator}/{denominator} ({numerator / denominator:.1%})' if denominator else 'NA (0 observed)'


def baseline(args):
    libraries = list(dict.fromkeys(Path(p).expanduser().resolve() for p in (args.library or DEFAULTS)))
    protected = [p.parent.resolve() for p in list(DEFAULTS) + libraries]
    out = Path(args.out).expanduser().resolve()
    if any(out == root or root in out.parents for root in protected):
        raise SystemExit('Output must be outside every source library.')
    names = ('jobs.csv', 'heads.csv', 'summary.md', 'samples.md')
    if any((out / name).exists() or (out / name).is_symlink() for name in names):
        raise SystemExit('Output artifacts already exist; choose a fresh directory.')
    reader = Reader()
    now = dt.datetime.now(dt.timezone.utc)
    jobs, heads, samples = [], [], {}
    inventory, missing, attribution = [], collections.Counter(), collections.Counter()
    for library in libraries:
        edition = {'Tivano': 'release', 'Tivano Dev': 'dev'}.get(library.parent.name, 'custom')
        if not library.exists():
            inventory.append(f'{edition}: library absent ({library})')
            continue
        data = reader.read(library)
        threads = data.get('threads', [])
        if isinstance(threads, dict):
            threads = list(threads.values())
        by_id = {t['id']: t for t in threads if t.get('id')}
        groups = collections.defaultdict(list)
        for thread in threads:
            if isinstance(thread.get('hydra'), dict) and thread['hydra'].get('mode', 'v1') == 'v1':
                groups[thread.get('parentThreadID') or 'missing-parent'].append(thread)
        lead_ids = set(groups) | {t['id'] for t in threads
                                  if t.get('hydraSpawnCount', 0) > 0 and not t.get('hydraJobs')}
        inventory.append(f'{edition}: {len(threads)} threads, {len(lead_ids)} lead IDs, '
                         f'{sum(len(v) for v in groups.values())} heads ({library})')
        for lead_id in sorted(lead_ids):
            lead = by_id.get(lead_id, {})
            if not lead:
                missing['parent_thread_record'] += 1
            items, turns, merges, complete = reader.transcript(library.parent, lead_id)
            requests = []
            for item in items:
                kind, value = payload(item)
                if kind == 'user' and not generated_user(value):
                    requests.append({'id': item.get('id'), 'at': timestamp(item.get('date')),
                                     'text': value.get('text', ''), 'turn': item.get('turnID')})
            buckets = collections.defaultdict(list)
            batches = collections.defaultdict(list)
            for head in groups[lead_id]:
                h = head['hydra']
                batches[h.get('batchID') or ('head:' + head['id'])].append(head)
            for batch, members in sorted(batches.items()):
                times = [first_time(h['hydra'], ['queuedAt', 'startedAt', 'executionStartedAt'])[0]
                         or timestamp(h.get('createdAt')) for h in members]
                times = [t for t in times if t is not None]
                at = min(times) if times else None
                eligible = [(i, r) for i, r in enumerate(requests)
                            if at is not None and r['at'] is not None and r['at'] <= at]
                ri = eligible[-1][0] if eligible else -1
                method = 'batch_nearest_preceding_request' if eligible else 'unattributed_no_preceding_request'
                for head in members:
                    buckets[ri].append((head, method))
                    attribution[method] += 1
            if not buckets:
                buckets[-1] = []
                missing['lead_with_spawn_count_but_no_surviving_heads'] += 1
            for ri, members in sorted(buckets.items()):
                request = requests[ri] if ri >= 0 else {'id': 'unattributed', 'at': None, 'text': '', 'turn': None}
                start = request['at']
                end = requests[ri + 1]['at'] if ri >= 0 and ri + 1 < len(requests) else None
                key = f'{edition}:{lead_id}:{request["id"]}'
                # Distinguish custom libraries even if their UUIDs overlap.
                if edition == 'custom':
                    key = f'{library}:{key}'
                window = [i for i in items if start is not None and timestamp(i.get('date')) is not None
                          and timestamp(i.get('date')) >= start
                          and (end is None or timestamp(i.get('date')) < end)]
                responses = [i for i in window if payload(i)[0] == 'assistant'
                             and not payload(i)[1].get('isStreaming')
                             and not re.search(r'```hydra-(?:delegate|sent|leaving)', payload(i)[1].get('text', ''))]
                final = payload(responses[-1])[1].get('text', '') if responses else ''
                final_at = timestamp(responses[-1].get('date')) if responses else None
                head_rows, head_texts, finished = [], [], []
                for thread, method in members:
                    h = thread['hydra']
                    hi, ht, hm, hc = reader.transcript(library.parent, thread['id'])
                    brief = next((payload(i)[1].get('text', '') for i in hi if payload(i)[0] == 'user'), '')
                    report = h.get('summary')
                    report_source = 'hydra.summary'
                    if not report:
                        report = next((payload(i)[1].get('text', '') for i in reversed(hi)
                                       if payload(i)[0] == 'assistant' and not payload(i)[1].get('isStreaming')), '')
                        report_source = 'last_assistant' if report else 'missing'
                    hs, hs_source = first_time(h, ['queuedAt', 'startedAt', 'executionStartedAt'])
                    if hs is None:
                        hs, hs_source = timestamp(thread.get('createdAt')), 'thread.createdAt'
                    hf, hf_source = first_time(h, ['finishedAt', 'executionFinishedAt'])
                    if hf is not None:
                        finished.append(hf)
                    status = h.get('status', 'unknown')
                    # A stale unfinished record is a proxy, not proof of a hung process.
                    activity = max([t for t in [hs, timestamp(thread.get('updatedAt'))] if t is not None], default=None)
                    stalled = int(status == 'running' and activity is not None and now.timestamp() - activity > 3600)
                    landing = h.get('landing')
                    for field in ['batchID', 'queuedAt', 'executionStartedAt', 'executionFinishedAt', 'finishedAt', 'summary', 'landing', 'mergedAt']:
                        if h.get(field) is None:
                            missing['head.' + field] += 1
                    for field in ['provider', 'model', 'effort']:
                        if thread.get(field) is None:
                            missing['head.' + field] += 1
                    if not brief:
                        missing['head.first_user_message'] += 1
                    row = dict(job_key=key, edition=edition, lead_id=lead_id, head_id=thread['id'],
                               head_name=head_name(h.get('index')), batch_id=h.get('batchID'),
                               kind=h.get('kind'), origin=h.get('origin'), provider=thread.get('provider'),
                               model=thread.get('model'), effort=thread.get('effort'),
                               brief_chars=len(brief) if brief else None, report_chars=len(report) if report else None,
                               report_source=report_source, status=status,
                               wall_seconds=round(hf - hs, 3) if hs is not None and hf is not None and hf >= hs else None,
                               wall_start_source=hs_source, wall_end_source=hf_source,
                               landed_files_count=(len(landing.get('files', [])) if landing is not None and not landing.get('error') and not landing.get('patchPath') else (0 if landing is not None else None)),
                               conflicts=len(landing.get('conflicts', [])) if landing is not None else None,
                               landing_error=bool(landing.get('error') or landing.get('patchPath')) if landing is not None else None,
                               stalled=stalled, failure_or_stall=int(status in ('failed', 'stopped') or stalled),
                               attribution=method, transcript_complete=hc)
                    heads.append(row)
                    head_rows.append(row)
                    head_texts.append((row['head_name'], brief, report))
                returned = min(finished) if finished else None
                rework = sum(1 for i in window if returned is not None and (timestamp(i.get('date')) or 0) >= returned
                             and payload(i)[0] == 'tool'
                             and (payload(i)[1].get('edits') or payload(i)[1].get('kind') in ('edit', 'write', 'patch'))
                             and payload(i)[1].get('status') == 'completed') if complete and start is not None and returned is not None else None
                relevant_merges = [m for m in merges if start is not None and timestamp(m.get('at')) is not None
                                   and timestamp(m['at']) >= start and (end is None or timestamp(m['at']) < end)]
                relevant_merges.sort(key=lambda m: timestamp(m.get('at')))
                merge_outcomes = [m.get('outcome') for m in relevant_merges if m.get('outcome')]
                if not merge_outcomes:
                    # hydraMerged is an affirmative legacy signal only; false proves nothing.
                    merge_outcomes = ['merged' for t in turns if t.get('hydraMerged') and start is not None
                                      and (timestamp(t.get('completedAt')) or 0) >= start
                                      and (end is None or (timestamp(t.get('completedAt')) or 0) < end)]
                final_valid = final_at is not None and finished and final_at >= max(finished) and all(r['status'] != 'running' for r in head_rows)
                if not final_valid:
                    final = ''
                job = dict(job_key=key, edition=edition, lead_id=lead_id, request_id=request['id'],
                           request_at=(dt.datetime.fromtimestamp(start, dt.timezone.utc).isoformat()
                                       if start is not None else None),
                           task_type=classify(request['text']), request_excerpt=redact(request['text'])[:240],
                           provider=lead.get('provider'), model=lead.get('model'), effort=lead.get('effort'),
                           hydra_pair_id=lead.get('hydraPairID'), temporary_pair_present=bool(lead.get('temporaryHydraPair')),
                           rounds=len({h['hydra'].get('batchID') for h, _ in members if h['hydra'].get('batchID')}) or None,
                           heads=len(head_rows), job_wall_seconds=round(final_at - start, 3) if final_valid and start is not None else None,
                           rework_edits=rework, failed_or_stalled_heads=sum(r['failure_or_stall'] for r in head_rows),
                           stalled_heads=sum(r['stalled'] for r in head_rows),
                           conflict_heads=sum(bool(r['conflicts']) for r in head_rows),
                           landing_observed_heads=sum(r['conflicts'] is not None for r in head_rows),
                           merge_attempts=len(relevant_merges), merge_outcomes=';'.join(str(v) for v in merge_outcomes),
                           merge_final_outcome=merge_outcomes[-1] if merge_outcomes else None,
                           merge_success=merge_result(merge_outcomes[-1] if merge_outcomes else None),
                           transcript_complete=complete, final_reply_observed=bool(final))
                for field in ['model', 'effort', 'hydraPairID', 'temporaryHydraPair']:
                    if lead.get(field) is None:
                        missing['job.lead.' + field] += 1
                jobs.append(job)
                samples[key] = (request['text'], head_texts, final)
    out.mkdir(parents=True, exist_ok=True)
    for name, rows in [('jobs.csv', jobs), ('heads.csv', heads)]:
        with (out / name).open('x', encoding='utf-8', newline='') as handle:
            writer = csv.DictWriter(handle, fieldnames=list(rows[0]) if rows else ['job_key'])
            writer.writeheader()
            writer.writerows({k: redact(v) if isinstance(v, str) else v for k, v in row.items()} for row in rows)
    lines = ['# Hydra 1 baseline', '', f'Extracted at {now.isoformat()}; source files opened read-only.', '',
             *['- ' + line for line in inventory], '', f'Jobs: {len(jobs)}; heads: {len(heads)}.',
             'Head statuses: ' + ', '.join(f'{k}={v}' for k, v in sorted(collections.Counter(h['status'] for h in heads).items())),
             'Failure/stall rate (failed + stopped + stale running): ' + rate(sum(h['failure_or_stall'] for h in heads), len(heads)),
             'Conflict rate (heads with observed landing): ' + rate(sum(bool(h['conflicts']) for h in heads), sum(h['conflicts'] is not None for h in heads)),
             'Merge success rate (jobs with explicit merge evidence): ' + rate(sum(j['merge_success'] == 1 for j in jobs), sum(j['merge_success'] is not None for j in jobs)),
             '', '## By task type', '',
             '| Task type | Jobs | Median rounds | Median heads | Median job wall seconds | Median rework edits | Failure/stall heads | Conflict heads | Merge success jobs |',
             '|---|---:|---:|---:|---:|---:|---|---|---|']
    types = sorted({j['task_type'] for j in jobs})
    for task_type in types:
        subset = [j for j in jobs if j['task_type'] == task_type]
        lines.append('| ' + ' | '.join([task_type, str(len(subset)), med(subset, 'rounds'), med(subset, 'heads'),
                     med(subset, 'job_wall_seconds'), med(subset, 'rework_edits'),
                     rate(sum(j['failed_or_stalled_heads'] for j in subset), sum(j['heads'] for j in subset)),
                     rate(sum(j['conflict_heads'] for j in subset), sum(j['landing_observed_heads'] for j in subset)),
                     rate(sum(j['merge_success'] == 1 for j in subset), sum(j['merge_success'] is not None for j in subset))]) + ' |')
    lines += ['', '## 15 jobs for qualitative review', '', 'Ranked by (rework edit calls + failed/stalled heads), then rework calls; this is a sampling score, not quality.']
    ranked = sorted(jobs, key=lambda j: (-( (j['rework_edits'] or 0) + j['failed_or_stalled_heads']), -(j['rework_edits'] or 0), j['job_key']))
    for job in ranked[:15]:
        lines.append(f"- {job['lead_id']} / {job['request_id']} ({job['edition']}, {job['task_type']}): rework={job['rework_edits']}, failures/stalls={job['failed_or_stalled_heads']}. {job['request_excerpt'].replace(chr(10), ' ')}")
    lines += ['', '## Attribution and data caveats', '',
              '- A job is a genuine lead user request with surviving heads, bounded by the next genuine user request. Follow-up requests split jobs; this is not a semantic task identifier. Leads with spawn counts but no surviving heads get an unattributed placeholder job. Non-Hydra requests are excluded.',
              '- parentThreadID identifies the lead. Each batchID is assigned to the nearest preceding genuine request at its earliest queuedAt, falling back to startedAt, executionStartedAt, then thread.createdAt. No preceding request yields an unattributed bucket, never a guessed request. Missing batch IDs are attributed individually. Queued/direct heads and intervening user messages can make temporal attribution wrong.',
              '- Generated users are recognized by hydraHeads/hydraBrief or leading [Hydra], Hydra reports:, [Tivano]. Other synthetic provider prompts may remain; text quoting those prefixes may be excluded. Final reply is the last nonstreaming, nondelegation assistant message in the request window, only if after all recorded head finishes and no running head remains. There is no stored final-channel guarantee.',
              '- rounds counts distinct recorded batch IDs (not conversational turns); missing IDs can undercount, and all missing is NA. The lifetime hydraSpawnCount is not used as a job head count.',
              '- Rework edits is a proxy: completed lead edit/write/patch tool calls or tools with edits, after the first head returns and before the next genuine request. Includes integration/new work; misses shell edits without normalized edit metadata. No file-overlap or causal claim. Missing transcript/request/return time is NA, not zero.',
              '- Job wall time is request to qualifying final reply; includes waiting, and is NA if final completion is not observed. Head wall time is queuedAt (fallback startedAt/executionStartedAt/createdAt) to finishedAt (fallback executionFinishedAt); missing or negative durations are NA. Ongoing heads are censored, not zero.',
              '- Stalled is running with last thread update/start over one hour old at extraction; stale status can falsely flag completed work. Failed/stopped are failure proxies; manual stops are not necessarily defects. Active current research jobs are included in this live snapshot.',
              '- Conflict denominator is heads with landing metadata. Missing landing is unknown. Landed file counts exclude retained patches/errors, but a conflict count is still reported. Empty landing can mean research/no change. These are stored counts, not a filesystem inspection.',
              '- Merge success uses explicit hydraMerges outcomes or affirmative turn.hydraMerged. The last timestamp-ordered outcome is used; only merged/failed enter the remote merge success denominator. settled means no remaining merge work and is reported separately. Missing evidence is NA; landing/finished status is never treated as merge success. Prose [Hydra] claims are not promoted to structured merge evidence.',
              '- Only indexed turn revisions are read, never arbitrary newer revisions or unindexed turn files. Inline legacy items and referenced revision items are deduplicated by item ID; referenced revisions win. Missing JSON/revisions are recorded below. Orphaned/deleted threads cannot be reconstructed. No cross-edition deduplication: edition is part of job identity.',
              '- Task types use ordered keyword rules over the request only (release, bugfix, research, UI, refactor, docs, other); bilingual but heuristic, not human labels. Samples are deterministic round-robin across task types, ordered by job key, up to 12 jobs.',
              '- provider/model/effort are current thread fields, not proof of the model for every historical turn. Pair IDs cannot be resolved without settings; settings/credentials/provider histories are never read. temporaryHydraPair presence is captured, not its full content. Token usage/cost is not estimated.',
              '- No production file is written, moved or locked. JSON reads are sequential and not an atomic snapshot; changes between separate reads remain possible. No build, test, lint or verification command is run by this extractor.',
              '- Text is redacted before truncation/export using credential labels, token prefixes, bearer auth, private keys, URL credentials and opaque blobs. This is conservative heuristic redaction, may hide benign text, and cannot guarantee detection of all prose-embedded secrets. No raw tool inputs/outputs or full transcripts are exported. Lengths measure original text, including generated brief boilerplate.',
              '- CSV blanks and Markdown NA mean unknown; medians exclude unknowns. Rates display their actual denominators. Per-field missing counts below are per head or per job as named.',
              '', '### Observed coverage', '',
              f'- Attribution counts: {dict(attribution)}',
              f'- Read issues: {dict(reader.issues)}; files visibly changed during read: {reader.changed}',
              f'- Missing job wall time: {sum(j["job_wall_seconds"] is None for j in jobs)}; missing rework: {sum(j["rework_edits"] is None for j in jobs)}; missing merge outcome: {sum(j["merge_success"] is None for j in jobs)}.',
              f'- Head report sources: {dict(collections.Counter(h["report_source"] for h in heads))}',
              *[f'- Missing {field}: {count}' for field, count in sorted(missing.items())]]
    summary = '\n'.join(lines) + '\n'
    with (out / 'summary.md').open('x', encoding='utf-8') as handle:
        handle.write(redact(summary))
    selected, queues = [], {t: sorted([j for j in jobs if j['task_type'] == t], key=lambda j: j['job_key']) for t in types}
    while len(selected) < 12 and any(queues.values()):
        for task_type in types:
            if queues[task_type] and len(selected) < 12:
                selected.append(queues[task_type].pop(0))
    sample_lines = ['# Hydra job samples', '', 'Deterministic task-type spread; excerpts redacted before truncation. Missing completion is stated explicitly.']
    for job in selected:
        request, reports, final = samples[job['job_key']]
        sample_lines += ['', f"## {job['job_key']} ({job['task_type']})", '', '### User request', '', redact(request) or '(unattributed request)']
        for name, brief, report in reports:
            sample_lines += ['', f'### {name}', '', '**Brief**', '', redact(brief)[:1500] or '(missing)', '', '**Report**', '', redact(report)[:1500] or '(missing)']
        sample_lines += ['', '### Lead final reply', '', redact(final)[:1500] or '(no qualifying final reply observed in this request window)']
    with (out / 'samples.md').open('x', encoding='utf-8') as handle:
        handle.write('\n'.join(sample_lines) + '\n')
    print('\n'.join(lines[:12]))
    print(f'Output: {out}; samples: {len(selected)}')
    print('Coverage: ' + json.dumps({'missing': missing, 'read_issues': reader.issues,
                                   'unknown_job_wall': sum(j['job_wall_seconds'] is None for j in jobs),
                                   'unknown_rework': sum(j['rework_edits'] is None for j in jobs),
                                   'unknown_merge': sum(j['merge_success'] is None for j in jobs)}))


V2_JOB_FIELDS = [
    'job_key', 'edition', 'lead_id', 'job_id', 'turn_id', 'task_type', 'request_excerpt',
    'job_class', 'lead_tool_calls', 'lead_edit_calls', 'lead_command_calls', 'lead_web_calls',
    'lead_provider', 'lead_model', 'lead_effort', 'heads_provider', 'heads_model',
    'heads_effort', 'heads_note', 'pair_id', 'pair_same_model',
    'base_commit', 'base_dirty', 'base_trees', 'ending', 'is_open',
    'review_pending_delivery', 'review_outcome', 'heads', 'single_head', 'rounds', 'job_wall_seconds',
    'failed_or_stalled_heads', 'failure_observed_heads', 'stalled_heads',
    'conflicts', 'conflict_heads', 'conflict_observed_heads',
    'lead_edits_after_reports', 'lead_built', 'continuations_total',
    'report_format_compliant_heads', 'report_format_observed_heads',
    'flagged_heads', 'flags_observed_heads', 'review_engine', 'review_findings',
    'review_accepted', 'review_skipped_reason', 'merge_outcome', 'merge_success', 'same_model', 'tilt'
]
V2_HEAD_FIELDS = [
    'job_key', 'edition', 'lead_id', 'job_id', 'head_id', 'head_name',
    'provider', 'model', 'effort', 'brief_chars', 'owned_files_count', 'status',
    'execution_seconds', 'landed_files_count', 'conflicts', 'followed_report_format',
    'flags_something', 'continuations', 'stalled', 'failure_or_stall'
]


def number(value):
    if value is None or isinstance(value, bool):
        return None
    if isinstance(value, int):
        return value
    try:
        result = float(value)
    except (TypeError, ValueError):
        return None
    if result != result or abs(result) == float('inf'):
        return None
    return int(result) if result.is_integer() else result


def boolean(value):
    if isinstance(value, bool):
        return value
    if isinstance(value, (int, float)) and value in (0, 1):
        return bool(value)
    if isinstance(value, str):
        lowered = value.strip().lower()
        if lowered in ('true', '1'):
            return True
        if lowered in ('false', '0'):
            return False
    return None


def read_csv(path):
    try:
        with path.open('r', encoding='utf-8', newline='') as handle:
            return list(csv.DictReader(handle))
    except (OSError, csv.Error) as error:
        raise SystemExit(redact(f'Could not read {path}: {error}'))


def load_baseline(root):
    jobs = read_csv(root / 'jobs.csv')
    heads = read_csv(root / 'heads.csv')
    for job in jobs:
        for field in ('heads', 'rounds', 'job_wall_seconds', 'rework_edits', 'merge_success'):
            job[field] = number(job.get(field))
        # Older baseline exports used a different success definition and may not
        # preserve chronological ordering. Do not reinterpret their aggregate.
        job['merge_success'] = merge_result(job.get('merge_final_outcome'))
    for head in heads:
        for field in ('conflicts', 'failure_or_stall', 'stalled'):
            head[field] = number(head.get(field))
    return jobs, heads


def prepare_output(value, names, libraries=()):
    out = Path(value).expanduser().resolve()
    protected = [p.parent.resolve() for p in list(DEFAULTS) + list(libraries)]
    if any(out == root or root in out.parents for root in protected):
        raise SystemExit('Output must be outside every source library.')
    if any((out / name).exists() or (out / name).is_symlink() for name in names):
        raise SystemExit('Output artifacts already exist; choose a fresh directory.')
    return out


def write_rows(path, fieldnames, rows):
    with path.open('x', encoding='utf-8', newline='') as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows({k: export_value(k, v) for k, v in row.items()}
                         for row in rows)



def merge_result(outcome):
    return 1 if outcome == 'merged' else (0 if outcome == 'failed' else None)


def export_value(field, value):
    # Preserve only validated Git object IDs; arbitrary text still gets redacted.
    if field == 'base_commit' and isinstance(value, str) and re.fullmatch(r'[0-9a-fA-F]{40}', value):
        return value
    if field == 'base_trees':
        return value
    return redact(value) if isinstance(value, str) else value


def base_trees_export(value):
    if value is None:
        return None

    def scrub(item):
        if isinstance(item, dict):
            return {redact(key): scrub(val) for key, val in item.items()}
        if isinstance(item, list):
            return [scrub(val) for val in item]
        if isinstance(item, str):
            return item if re.fullmatch(r'[0-9a-fA-F]{40}', item) else redact(item)
        return item

    return json.dumps(scrub(value), ensure_ascii=False, sort_keys=True)


def complete_sum(rows, field, known=True):
    values = [row.get(field) for row in rows]
    return sum(values) if known and all(value is not None for value in values) else None


def pending_delivery(record):
    value = record.get('pendingReview')
    if isinstance(value, str):
        return bool(value.strip())
    return boolean(value)


def review_outcome(record):
    pending = pending_delivery(record)
    if pending is True:
        return 'pending'
    reason = record.get('reviewSkipped')
    if isinstance(reason, str) and reason.strip():
        if re.search(r'fail|error|timed? ?out|timeout', reason, re.I):
            return 'failed'
        return 'skipped'
    if record.get('reviewEngine') and (pending is False or number(record.get('reviewAccepted')) is not None):
        return 'delivered'
    return 'unknown'


def terminal_job(job, v2):
    if not v2:
        return boolean(job.get('final_reply_observed')) is True
    return (job.get('is_open') is False and
            job.get('review_pending_delivery') is not True and
            job.get('review_outcome') in ('delivered', 'skipped', 'failed') and
            job.get('ending') == 'completed')


def med_observed(rows, field):
    values = [r.get(field) for r in rows
              if isinstance(r.get(field), (int, float)) and not isinstance(r.get(field), bool)]
    if not values:
        return 'NA (0 observed)'
    return f'{statistics.median(values):.2f} (n={len(values)})'


def mean_observed(rows, field):
    values = [r.get(field) for r in rows
              if isinstance(r.get(field), (int, float)) and not isinstance(r.get(field), bool)]
    if not values:
        return 'NA (0 observed)'
    return f'{statistics.mean(values):.2f} (n={len(values)})'


def one_line(value):
    return re.sub(r'\s+', ' ', str(value or '')).strip()


def lead_job_activity(items, turns, records, complete, reader):
    ordered = sorted(turns, key=lambda turn: (number(turn.get('index')) or 0,
                                             timestamp(turn.get('startedAt')) or 0))
    positions = {turn['id']: index for index, turn in enumerate(ordered) if turn.get('id')}
    starts = {record.get('turnID') for record in records if isinstance(record, dict)}
    if not complete or not starts.issubset(positions):
        reader.issues['incomplete_lead_job_windows'] += 1
        return {}
    boundaries = sorted(positions[turn_id] for turn_id in starts)
    calls = collections.defaultdict(list)
    for item in items:
        kind, value = payload(item)
        if kind == 'tool' and item.get('turnID') in positions:
            calls[positions[item['turnID']]].append(value)
    activity = {}
    for index, start in enumerate(boundaries):
        end = boundaries[index + 1] if index + 1 < len(boundaries) else len(ordered)
        tools = [tool for position in range(start, end) for tool in calls[position]]
        edits = sum(bool(tool.get('edits')) or tool.get('kind') == 'edit' for tool in tools)
        commands = sum(tool.get('kind') == 'command' for tool in tools)
        activity[ordered[start]['id']] = dict(
            job_class='agentic' if edits or commands else 'conversation',
            lead_tool_calls=len(tools), lead_edit_calls=edits,
            lead_command_calls=commands,
            lead_web_calls=sum(tool.get('kind') == 'web' for tool in tools))
    return activity


def extract_v2(libraries, now):
    reader = Reader()
    jobs, heads, inventory = [], [], []
    for library in libraries:
        edition = {'Tivano': 'release', 'Tivano Dev': 'dev'}.get(library.parent.name, 'custom')
        if not library.exists():
            inventory.append(f'{edition}: library absent ({library})')
            continue
        before_jobs = len(jobs)
        data = reader.read(library)
        threads = data.get('threads', [])
        if isinstance(threads, dict):
            threads = list(threads.values())
        by_id = {t['id']: t for t in threads if t.get('id')}
        for lead in threads:
            if not lead.get('id'):
                continue
            lead_id = lead['id']
            records = lead.get('hydraJobs') or []
            if not isinstance(records, list):
                continue
            if not any(isinstance(record, dict) and record.get('mode') == 'v2' for record in records):
                continue
            items, turns, _, complete = reader.transcript(library.parent, lead_id)
            job_activity = lead_job_activity(items, turns, records, complete, reader)
            for job_index, record in enumerate(records):
                if not isinstance(record, dict) or record.get('mode') != 'v2':
                    continue
                job_id = str(record.get('id') or f'missing-{job_index}')
                key = f'{edition}:{lead_id}:{job_id}'
                if edition == 'custom':
                    key = f'{library}:{key}'
                request = record.get('request') or ''
                start = timestamp(record.get('startedAt'))
                finish = timestamp(record.get('finishedAt'))
                head_rows = []
                stored_heads = record.get('heads')
                heads_known = isinstance(stored_heads, list) and all(isinstance(h, dict) for h in stored_heads)
                for head in stored_heads if isinstance(stored_heads, list) else []:
                    if not isinstance(head, dict):
                        continue
                    head_id = head.get('headID')
                    live = by_id.get(head_id, {})
                    live_h = live.get('hydra') or {}
                    if (live_h.get('mode') != 'v2' or
                            str(live_h.get('jobID')) != job_id):
                        live_h = {}
                    status = live_h.get('status') or head.get('status') or 'unknown'
                    activity = None
                    if live_h:
                        started = first_time(live_h, ['queuedAt', 'startedAt', 'executionStartedAt'])[0]
                        if started is None:
                            started = timestamp(live.get('createdAt'))
                        activity = max([value for value in (started, timestamp(live.get('updatedAt')))
                                        if value is not None], default=None)
                    if status == 'running':
                        stalled = (int(activity is not None and now.timestamp() - activity > 3600)
                                   if activity is not None else None)
                    elif status in ('completed', 'failed', 'stopped'):
                        stalled = 0
                    else:
                        stalled = None
                    if status in ('failed', 'stopped'):
                        failure = 1
                    elif status == 'completed':
                        failure = 0
                    elif status == 'running' and stalled is not None:
                        failure = stalled
                    else:
                        failure = None
                    followed = boolean(head.get('followedReportFormat'))
                    notes = head.get('notes')
                    if isinstance(notes, dict):
                        flags = any(notes.get(field) is not None
                                    for field in ('deviations', 'unfinished', 'uncertain'))
                    else:
                        flags = None
                    seconds = number(head.get('seconds'))
                    if seconds is not None and seconds < 0:
                        seconds = None
                    row = dict(
                        job_key=key, edition=edition, lead_id=lead_id, job_id=job_id,
                        head_id=head_id, head_name=head.get('name'), provider=head.get('provider'),
                        model=head.get('model'), effort=head.get('effort'),
                        brief_chars=number(head.get('briefChars')),
                        owned_files_count=len(head['files']) if isinstance(head.get('files'), list) else None, status=status,
                        execution_seconds=seconds,
                        landed_files_count=number(head.get('landedFiles')),
                        conflicts=number(head.get('conflicts')),
                        followed_report_format=followed, flags_something=flags,
                        continuations=number(head.get('continuations')),
                        stalled=stalled, failure_or_stall=failure)
                    heads.append(row)
                    head_rows.append(row)
                # Only this identified ledger job owns its merge result. Never use
                # the lead's latest merge or another job's recovery outcome.
                merge = record.get('merge') if record.get('id') else None
                merge_success = merge_result(merge)
                model_fields = ('leadProvider', 'leadModel', 'headsProvider', 'headsModel')
                pair_same_model = (record.get('leadProvider') == record.get('headsProvider') and
                              record.get('leadModel') == record.get('headsModel')
                              if all(record.get(field) for field in model_fields) else None)
                actual_models_known = (heads_known and bool(head_rows) and
                                       bool(record.get('leadProvider')) and bool(record.get('leadModel')) and
                                       all(h.get('provider') and h.get('model') for h in head_rows))
                same_model = (all(h['provider'] == record['leadProvider'] and
                                  h['model'] == record['leadModel'] for h in head_rows)
                              if actual_models_known else None)
                known_conflicts = [h['conflicts'] for h in head_rows if h['conflicts'] is not None]
                job = dict(
                    job_key=key, edition=edition, lead_id=lead_id, job_id=job_id,
                    turn_id=record.get('turnID'), task_type=classify(request),
                    request_excerpt=redact(request)[:240],
                    lead_provider=record.get('leadProvider'), lead_model=record.get('leadModel'),
                    lead_effort=record.get('leadEffort'),
                    heads_provider=record.get('headsProvider'), heads_model=record.get('headsModel'),
                    heads_effort=record.get('headsEffort'), heads_note=record.get('headsNote'),
                    pair_same_model=pair_same_model,
                    pair_id=record.get('pairID'), base_commit=record.get('baseCommit'),
                    base_dirty=boolean(record.get('baseDirty')),
                    base_trees=base_trees_export(record.get('baseTrees')), ending=record.get('ending'),
                    is_open=(False if finish is not None else
                             (True if start is not None and record.get('finishedAt') is None else None)),
                    review_pending_delivery=pending_delivery(record), review_outcome=review_outcome(record),
                    heads=len(head_rows) if heads_known else None,
                    single_head=(len(head_rows) == 1) if heads_known else None, rounds=number(record.get('rounds')),
                    job_wall_seconds=(round(finish - start, 3) if start is not None and
                                      finish is not None and finish >= start else None),
                    failed_or_stalled_heads=complete_sum(head_rows, 'failure_or_stall', heads_known),
                    failure_observed_heads=sum(h['failure_or_stall'] is not None for h in head_rows),
                    stalled_heads=complete_sum(head_rows, 'stalled', heads_known),
                    conflicts=complete_sum(head_rows, 'conflicts', heads_known),
                    conflict_heads=(sum(value > 0 for value in known_conflicts) if known_conflicts else None),
                    conflict_observed_heads=len(known_conflicts),
                    lead_edits_after_reports=number(record.get('leadEditsAfterReports')),
                    lead_built=boolean(record.get('leadBuilt')),
                    continuations_total=complete_sum(head_rows, 'continuations', heads_known),
                    report_format_compliant_heads=(sum(h['followed_report_format'] is True for h in head_rows)
                                                   if any(h['followed_report_format'] is not None for h in head_rows) else None),
                    report_format_observed_heads=sum(h['followed_report_format'] is not None for h in head_rows),
                    flagged_heads=(sum(h['flags_something'] is True for h in head_rows)
                                   if any(h['flags_something'] is not None for h in head_rows) else None),
                    flags_observed_heads=sum(h['flags_something'] is not None for h in head_rows),
                    review_engine=record.get('reviewEngine'),
                    review_findings=number(record.get('reviewFindings')),
                    review_accepted=number(record.get('reviewAccepted')),
                    review_skipped_reason=record.get('reviewSkipped'),
                    merge_outcome=merge, merge_success=merge_success, same_model=same_model,
                    tilt=record.get('tilt') or '')
                job.update(job_activity.get(record.get('turnID'), dict(
                    job_class=None, lead_tool_calls=None, lead_edit_calls=None,
                    lead_command_calls=None, lead_web_calls=None)))
                jobs.append(job)
        inventory.append(f'{edition}: {len(threads)} threads, {len(jobs) - before_jobs} v2 jobs, '
                         f'{len(heads)} cumulative v2 heads ({library})')
    return jobs, heads, inventory, reader


def metric_values(jobs, heads, v2):
    keys = {j.get('job_key') for j in jobs}
    related_heads = [h for h in heads if h.get('job_key') in keys]
    single_known = [j for j in jobs if j.get('heads') is not None]
    terminal = [j for j in jobs if terminal_job(j, v2)]
    terminal_keys = {j.get('job_key') for j in terminal}
    finished_heads = [h for h in related_heads if h.get('job_key') in terminal_keys]
    failures = [h for h in finished_heads if h.get('failure_or_stall') is not None]
    conflicts = [h for h in finished_heads if h.get('conflicts') is not None]
    merges = [j for j in terminal if j.get('merge_success') is not None]
    return [
        ('Jobs', str(len(jobs))),
        ('Observed completed jobs', str(len(terminal))),
        ('Jobs with exactly one head', rate(sum(j.get('heads') == 1 for j in single_known), len(single_known))),
        ('Median heads', med_observed(jobs, 'heads')),
        ('Median rounds (completed jobs)', med_observed(terminal, 'rounds')),
        ('Head failure/stall rate (completed jobs)', rate(sum(h['failure_or_stall'] for h in failures), len(failures))),
        ('Conflict rate (completed jobs)', rate(sum(h['conflicts'] > 0 for h in conflicts), len(conflicts))),
        ('Final remote merge success (completed jobs)', rate(sum(j['merge_success'] == 1 for j in merges), len(merges))),
        ('No new merge needed (completed jobs)', str(sum(j.get('merge_outcome', j.get('merge_final_outcome')) in ('nothing', 'settled') for j in terminal)))
    ]


def comparison_table(v1_jobs, v1_heads, v2_jobs, v2_heads):
    v1_values = dict(metric_values(v1_jobs, v1_heads, False))
    v2_values = dict(metric_values(v2_jobs, v2_heads, True))
    lines = ['| Metric | V1 | V2 |', '|---|---:|---:|']
    for label in v1_values:
        lines.append(f'| {label} | {v1_values[label]} | {v2_values[label]} |')
    return lines


def comparison_markdown(now, v1_jobs, v1_heads, v2_jobs, v2_heads, inventory, reader):
    delegated_v1 = [j for j in v1_jobs if (j.get('heads') or 0) > 0]
    delegated_v2 = [j for j in v2_jobs if (j.get('heads') or 0) > 0]
    no_heads = [j for j in v2_jobs if j.get('heads') == 0]
    heads_observed = [j for j in v2_jobs if j.get('heads') is not None]
    lines = ['# Hydra 1 vs Hydra 2 comparison', '',
             f'Compared at {now.isoformat()}; sources opened read-only.', '',
             "These are operational health metrics, not task-quality or cost results. They cannot rank Hydra 2 against the owner's quality > cost > time priority. Use matched same-task, same-base replays and blind result review for quality; report provider-observed token/credit/cost only with coverage and units; report time last.", '',
             '## Delegated-work operational comparison (not whole-policy effectiveness)', '',
             'Both cohorts require at least one dispatched head. Terminal metrics require a V1 qualifying final reply or a V2 completed ending, finished timestamp and resolved review delivery. Unknown legacy completion evidence is excluded, not filled in.', '']
    lines += comparison_table(delegated_v1, v1_heads, delegated_v2, v2_heads)
    lines += ['', '## By task type (delegated work)', '']
    types = sorted({j.get('task_type') or 'unknown' for j in delegated_v1 + delegated_v2})
    for task_type in types:
        a = [j for j in delegated_v1 if (j.get('task_type') or 'unknown') == task_type]
        b = [j for j in delegated_v2 if (j.get('task_type') or 'unknown') == task_type]
        lines += [f'### {task_type}', ''] + comparison_table(a, v1_heads, b, v2_heads) + ['']

    lines += ['## V2 no-head jobs and delegation rate', '',
              '- Delegation rate: ' + rate(len(delegated_v2), len(heads_observed)) + '.',
              '- No-head share: ' + rate(len(no_heads), len(heads_observed)) + '.',
              f'- Unknown head count: {len(v2_jobs) - len(heads_observed)} jobs.',
              'The V1 baseline has no whole-policy denominator; no V1 delta is inferred here.', '',
              '| Task type | No-head jobs | Observed completed | Open | Pending review |',
              '|---|---:|---:|---:|---:|']
    for kind in sorted({j.get('task_type') or 'unknown' for j in no_heads}):
        subset = [j for j in no_heads if (j.get('task_type') or 'unknown') == kind]
        lines.append(f"| {kind} | {len(subset)} | {sum(terminal_job(j, True) for j in subset)} | {sum(j['is_open'] is True for j in subset)} | {sum(j['review_outcome'] == 'pending' for j in subset)} |")

    format_observed = [h for h in v2_heads if h['followed_report_format'] is not None]
    flags_observed = [h for h in v2_heads if h['flags_something'] is not None]
    built_observed = [j for j in v2_jobs if j['lead_built'] is not None]
    delivered = [j for j in v2_jobs if j['review_outcome'] == 'delivered']
    handled = [j for j in delivered if terminal_job(j, True) and j['review_accepted'] is not None]
    acceptance_jobs = [j for j in handled if j['review_findings'] is not None]
    findings = sum(j['review_findings'] for j in acceptance_jobs)
    accepted = sum(j['review_accepted'] for j in acceptance_jobs)
    lines += ['', '## Hydra 2 mechanisms and review outcomes (all jobs)', '',
              '- Report-format compliance: ' + rate(sum(h['followed_report_format'] is True for h in format_observed), len(format_observed)),
              '- Heads with flags: ' + rate(sum(h['flags_something'] is True for h in flags_observed), len(flags_observed)),
              '- Continuations per job: mean ' + mean_observed(v2_jobs, 'continuations_total') + '; median ' + med_observed(v2_jobs, 'continuations_total') + '.',
              '- Lead built (observed command proxy): ' + rate(sum(j['lead_built'] is True for j in built_observed), len(built_observed)),
              f"- Open jobs: {sum(j['is_open'] is True for j in v2_jobs)}; unknown open state: {sum(j['is_open'] is None for j in v2_jobs)}.", '',
              '| Review outcome | Jobs | Share |', '|---|---:|---:|']
    for outcome in ('delivered', 'pending', 'skipped', 'failed', 'unknown'):
        count = sum(j['review_outcome'] == outcome for j in v2_jobs)
        lines.append(f'| {outcome} | {count} | {rate(count, len(v2_jobs))} |')
    lines += ['', '- Findings per delivered review: mean ' + mean_observed(delivered, 'review_findings') + '.',
              '- Findings per completed, handled review: mean ' + mean_observed(handled, 'review_findings') + '.',
              f'- Review acceptance: {rate(accepted, findings)}; both counts present on {len(acceptance_jobs)}/{len(handled)} completed, handled jobs.',
              'Delivered does not by itself mean handled. Pending/open jobs never enter acceptance. Engine presence alone does not prove delivery; absent delivery evidence remains unknown.', '',
              '### Review skip / failure reasons', '']
    reasons = collections.Counter((j['review_outcome'], one_line(j['review_skipped_reason']))
                                  for j in v2_jobs if j['review_outcome'] in ('skipped', 'failed'))
    lines += [f'- {outcome}: {reason}: {count} jobs' for (outcome, reason), count in sorted(reasons.items())] or ['- None recorded.']
    lines += ['', 'No changes is a skipped/not-applicable reason, not a failed review. Failure/timeout classification uses the recorded reason text; unknown reasons are not guessed.', '',
              '### Job endings', '']
    endings = collections.Counter(str(j.get('ending') or 'unknown') for j in v2_jobs)
    lines += [f'- {ending}: {count}' for ending, count in sorted(endings.items())]

    labels = [label for label, _ in metric_values([], [], True)]
    for title, field in [('Actual head models', 'same_model'), ('Shared pair snapshot', 'pair_same_model')]:
        lines += ['', f'## V2 {title} (delegated work)', '',
                  '| Group | ' + ' | '.join(labels) + ' |', '|---|' + '|'.join(['---:'] * len(labels)) + '|']
        for label, value in [('Same-model', True), ('Paired', False), ('Unknown', None)]:
            subset = [j for j in delegated_v2 if j.get(field) is value]
            values = dict(metric_values(subset, v2_heads, True))
            lines.append('| ' + label + ' | ' + ' | '.join(values[name] for name in labels) + ' |')
    lines += ['', 'Actual same-model requires every head provider/model to match the lead; any missing model makes it unknown. Shared pair settings may differ from profiles. Effort is exported separately.', '',
              '## Delegation rate by tilt', '',
              'Jobs where the user explicitly asked for sub-agents count like any other.', '',
              'Rates use jobs with known head counts; job totals include unknown head counts. Unknown tilt includes missing and unrecognised values. Jobs with unavailable lead windows are excluded from both classes.', '',
              '| Tilt | Agentic jobs | Agentic jobs that sent heads | Conversation jobs | Conversation jobs that sent heads | Owner target for agentic |',
              '|---|---:|---:|---:|---:|---:|']
    for label, value, target in [('Restrained', 'restrained', '30%'), ('Proactive', 'active', '55%'),
                                 ('Aggressive', 'aggressive', '75%'), ('Unknown', None, '')]:
        subset = [j for j in v2_jobs if (j.get('tilt') == value if value is not None
                                       else j.get('tilt') not in ('restrained', 'active', 'aggressive'))]
        agentic = [j for j in subset if j.get('job_class') == 'agentic']
        conversation = [j for j in subset if j.get('job_class') == 'conversation']
        agentic_known = [j for j in agentic if j.get('heads') is not None]
        conversation_known = [j for j in conversation if j.get('heads') is not None]
        agentic_rate = rate(sum(j['heads'] > 0 for j in agentic_known), len(agentic_known))
        conversation_rate = rate(sum(j['heads'] > 0 for j in conversation_known), len(conversation_known))
        lines.append(f'| {label} | {len(agentic)} | {agentic_rate} | {len(conversation)} | {conversation_rate} | {target} |')
    lines += ['', f"Unclassified jobs with unavailable lead windows: {sum(j.get('job_class') is None for j in v2_jobs)}.", '',
              '## Large agentic jobs without heads', '',
              'Up to 20 jobs, ranked by lead tool calls for qualitative review of missed delegation.', '']
    large_jobs = sorted([j for j in no_heads if j.get('job_class') == 'agentic'],
                        key=lambda j: (-j['lead_tool_calls'], j['job_key']))[:20]
    for job in large_jobs:
        excerpt = one_line(redact(job.get('request_excerpt')))[:60]
        tilt = {'restrained': 'Restrained', 'active': 'Proactive', 'aggressive': 'Aggressive'}.get(
            job.get('tilt'), 'Unknown')
        lines.append(f"- {one_line(redact(job['job_key']))} ({tilt}): lead tools={job['lead_tool_calls']}, "
                     f"edits={job['lead_edit_calls']}, commands={job['lead_command_calls']}, "
                     f"web={job['lead_web_calls']}. {excerpt}")
    if not large_jobs:
        lines.append('- None observed.')
    lines += ['',
              '## V2 by delegation tilt (delegated work)', '',
              'Restrained delegates only parts that would crowd one context (audits, broad research, parallel pieces). Proactive delegates any briefable part taking more than a few tool calls. Aggressive delegates nearly everything briefable. Missing tilt is unknown; unrecognised values remain separate.', '',
              '| Tilt | ' + ' | '.join(labels) + ' |', '|---|' + '|'.join(['---:'] * len(labels)) + '|']
    for label, value in [('Restrained', 'restrained'), ('Proactive', 'active'), ('Aggressive', 'aggressive'), ('Unknown', ''), ('Unrecognised', None)]:
        subset = [j for j in delegated_v2 if ((j.get('tilt') or '') == value if value is not None
                                            else j.get('tilt') not in (None, '', 'restrained', 'active', 'aggressive'))]
        values = dict(metric_values(subset, v2_heads, True))
        lines.append('| ' + label + ' | ' + ' | '.join(values[name] for name in labels) + ' |')

    lines += ['', '## Version-specific timing and edit proxies (completed jobs only)', '',
              'These rows have different boundaries and must not be interpreted as version deltas.', '',
              '| Measurement | Median |', '|---|---:|']
    for label, rows, field in [
            ('V1 request to qualifying final reply (seconds)', [j for j in delegated_v1 if terminal_job(j, False)], 'job_wall_seconds'),
            ('V2 start to settle including review/merge (seconds)', [j for j in delegated_v2 if terminal_job(j, True)], 'job_wall_seconds'),
            ('V1 edits after first head finish', [j for j in delegated_v1 if terminal_job(j, False)], 'rework_edits'),
            ('V2 edits in report/review turns', [j for j in delegated_v2 if terminal_job(j, True)], 'lead_edits_after_reports')]:
        lines.append(f'| {label} | {med_observed(rows, field)} |')
    lines += ['', '## Coverage and limits', '',
              f'- V1: {len(v1_jobs)} baseline jobs, {len(v1_heads)} heads; delegated cohort: {len(delegated_v1)}.',
              f'- V2: {len(v2_jobs)} ledger jobs, {len(v2_heads)} heads; delegated cohort: {len(delegated_v2)}.',
              *['- ' + one_line(line) for line in inventory],
              f'- Read issues: {dict(reader.issues)}; files visibly changed during read: {reader.changed}.',
              '- V1 uses surviving heads and temporal request windows, not durable job IDs; intervening messages can split a task. V2 follow-ups stay in an open job. Different requests and this attribution bias prevent causal or whole-policy claims.',
              '- V1 final merge outcomes require a newly exported merge_final_outcome column; old aggregate success columns are ignored. V1 attribution remains a time-window proxy. V2 uses only the owning job ID record, never the latest lead merge; historical misattribution cannot be repaired by this reader.',
              '- Remote merge success includes only merged/failed; nothing/settled are separate. Missing outcomes do not reveal whether auto-merge was disabled, deferred or unfinished. Attempt and setting snapshots are unavailable, so there is no first-attempt success claim.',
              '- Medians exclude unknowns and show observed n; rates show denominators. Missing counts are not zeros. Terminal comparisons conservatively exclude legacy V2 jobs without completed ending or resolved review evidence.',
              '- V1 rounds count batch IDs; V2 records dispatch rounds. Head failure/stall and conflict rows use completed cohorts; manual stops are not necessarily defects. Running V2 head activity requires a matching live hydra.mode=v2 and jobID, otherwise stall status is unknown.',
              '- Only stored notes establish flags; a failed report parser does not establish no flags. Review engine alone proves neither successful completion nor delivery. No timestamps distinguish queued, running and not-yet-started reviews.',
              '- Head execution_seconds excludes queue/landing time and is not V1 wall_seconds. Stage timestamps and matched edit windows are unavailable. Build/edit counts are observed tool-call proxies, not quality scores.',
              '- Valid 40-hex base commit/tree IDs are preserved; free text uses heuristic redaction, which cannot detect every secret. A dirty base needs its tree/patch and environment restored before replay; a commit alone is insufficient.',
              '- Dates accept ISO strings or Swift seconds since 2001-01-01. Negative/incomplete durations are unknown. JSON reads are sequential, not an atomic snapshot.',
              '- Agentic means at least one lead tool call with kind=edit or non-empty edits, or kind=command; otherwise conversation. Web counts use kind=web. All recorded call statuses count. These are observed activity proxies, not intent or task-quality labels.',
              '- Lead windows use turn order from each job turnID up to (excluding) the next job turn in the same lead thread, or the end of the transcript. Only indexed revisions and inline legacy data are read. Missing transcript revisions or job boundaries leave that lead thread’s classifications/counts unknown rather than zero; read issues report these omissions.',
              '- compare reads library job ledgers, lead transcripts and baseline CSV, not settings, credentials, provider histories or Git state. It writes only fresh external reports; no replay or app operation runs.']
    return '\n'.join(lines) + '\n'


def compare(args):
    libraries = list(dict.fromkeys(Path(p).expanduser().resolve() for p in (args.library or DEFAULTS)))
    out = prepare_output(args.out, ('v2_jobs.csv', 'v2_heads.csv', 'comparison.md'), libraries)
    baseline_dir = Path(args.baseline).expanduser().resolve()
    v1_jobs, v1_heads = load_baseline(baseline_dir)
    now = dt.datetime.now(dt.timezone.utc)
    v2_jobs, v2_heads, inventory, reader = extract_v2(libraries, now)
    summary = comparison_markdown(now, v1_jobs, v1_heads, v2_jobs, v2_heads, inventory, reader)
    out.mkdir(parents=True, exist_ok=True)
    write_rows(out / 'v2_jobs.csv', V2_JOB_FIELDS, v2_jobs)
    write_rows(out / 'v2_heads.csv', V2_HEAD_FIELDS, v2_heads)
    with (out / 'comparison.md').open('x', encoding='utf-8') as handle:
        handle.write(redact(summary))
    print(redact(f'Output: {out}; V1 jobs: {len(v1_jobs)}; V2 jobs: {len(v2_jobs)}; V2 heads: {len(v2_heads)}'))


def replay_candidates(args):
    if args.n < 0:
        raise SystemExit('--n must be non-negative')
    out = prepare_output(args.out, ('replay_candidates.md',))
    baseline_dir = Path(args.baseline).expanduser().resolve()
    jobs = read_csv(baseline_dir / 'jobs.csv')

    def rank(job):
        final = boolean(job.get('final_reply_observed')) is True
        complete = boolean(job.get('transcript_complete')) is True
        return (-(int(final) + int(complete)), -int(final), -int(complete), str(job.get('job_key') or ''))

    types = sorted({j.get('task_type') or 'unknown' for j in jobs})
    queues = {task_type: sorted([j for j in jobs if (j.get('task_type') or 'unknown') == task_type],
                                key=rank) for task_type in types}
    selected = []
    while len(selected) < args.n and any(queues.values()):
        for task_type in types:
            if queues[task_type] and len(selected) < args.n:
                selected.append(queues[task_type].pop(0))
    lines = ['# Hydra 1 same-task replay candidates', '',
             'No replay or Git command was run. This list only selects candidates for operator approval.', '',
             'Selection is deterministic round-robin across task types. Within each type, jobs with a final reply and complete transcript rank first, followed by final-reply-only, transcript-only, then other jobs.', '',
             'V1 records have no base commit. For every replay, the operator must choose the repository commit from git history by the original request date; do not use current HEAD by default. New baseline exports include request_at. If it is blank or absent, use the job key and request ID to recover the original date from source records first.', '']
    for index, job in enumerate(selected, 1):
        final = boolean(job.get('final_reply_observed'))
        complete = boolean(job.get('transcript_complete'))
        lines += [f"## {index}. {one_line(job.get('job_key')) or '(missing job key)'}", '',
                  f"- Lead ID: {one_line(job.get('lead_id')) or '(missing)'}",
                  f"- Request ID: {one_line(job.get('request_id')) or '(missing)'}",
                  f"- Task type: {one_line(job.get('task_type')) or 'unknown'}",
                  f"- Request date: {one_line(job.get('request_at')) or '(unknown; recover from source)'}",
                  f"- Final reply observed: {'unknown' if final is None else ('yes' if final else 'no')}; transcript complete: {'unknown' if complete is None else ('yes' if complete else 'no')}.",
                  f"- Request excerpt: {one_line(job.get('request_excerpt')) or '(missing)'}",
                  '- Replay base: operator must select the repository commit from git history by the original request date; V1 has no recorded base commit.', '']
    if not selected:
        lines.append('No candidates selected.')
    lines += ['', '## Result template (fill only after an authorised replay)', '',
              '- Matched request / base commit / restored dirty tree or patch / environment:',
              '- quality_score / quality_notes / reviewer_blind:',
              '- lead_tokens / head_tokens / review_tokens (unknown stays blank):',
              '- provider_credit_or_cost / unit / coverage (tokens are not currency):',
              '- lead response / review / merge / total duration, with stage boundaries:',
              'Review quality first, observed cost second and time last. This command does not run a replay.']
    out.mkdir(parents=True, exist_ok=True)
    with (out / 'replay_candidates.md').open('x', encoding='utf-8') as handle:
        handle.write(redact('\n'.join(lines) + '\n'))
    print(redact(f'Output: {out}; replay candidates: {len(selected)}'))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    command = sub.add_parser('baseline', help='Extract a read-only Hydra baseline')
    command.add_argument('--out', required=True)
    command.add_argument('--library', action='append', help='library.json; repeat to combine libraries')
    command.set_defaults(handler=baseline)
    command = sub.add_parser('compare', help='Compare a Hydra baseline with V2 job ledgers')
    command.add_argument('--baseline', required=True, help='directory containing baseline jobs.csv and heads.csv')
    command.add_argument('--out', required=True)
    command.add_argument('--library', action='append', help='library.json; repeat to combine libraries')
    command.set_defaults(handler=compare)
    command = sub.add_parser('replay-candidates', help='Select V1 jobs for same-task replay without running them')
    command.add_argument('--baseline', required=True, help='directory containing baseline jobs.csv')
    command.add_argument('--out', required=True)
    command.add_argument('--n', type=int, default=10, help='maximum candidates (default: 10)')
    command.set_defaults(handler=replay_candidates)
    args = parser.parse_args()
    args.handler(args)


if __name__ == '__main__':
    main()
