#!/usr/bin/env python3
"""Replay Hydra decisions: read library.json, indexed transcripts and Git trees;
build masked payloads/index/outcomes, score them via TypeSafe using the Dev Keychain
key, and write a production-format replay ledger. Only score sends data externally.
Run with python3 -I scripts/hydra_decisions_replay.py build|score|ledger --out DIR;
build also requires --library PATH. Source libraries and Git are read-only.
"""

import argparse
from collections import Counter
import datetime as dt
import importlib.util
import json
from pathlib import Path
import re
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request
import uuid

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location('hydra_eval', Path(__file__).with_name('hydra_eval.py'))
eval = importlib.util.module_from_spec(spec)
spec.loader.exec_module(eval)
REVIEW_OPENING = '[Hydra] Review: an independent review by '


def mask(value):
    if isinstance(value, str):
        value = re.sub(r'-----BEGIN [^-]*KEY-----.*?(?:-----END [^-]*KEY-----|\Z)',
                       '[masked]', value, flags=re.S)
        value = re.sub(r'\b(?:sk-(?:ant-)?|ghp_|github_pat_|xox[abp]-|AKIA)[A-Za-z0-9_./+=-]+',
                       '[masked]', value)
        return re.sub(r'(?i)\bBearer\s+[^\s"\x27,;}]+', '[masked]', value)
    if isinstance(value, list):
        return [mask(v) for v in value]
    if isinstance(value, dict):
        return {mask(k): mask(v) for k, v in value.items()}
    return value


def capped(text, limit):
    text = (text or '').strip()
    return text[:limit] + '\n[truncated]' if len(text) > limit else text


def question(text, criteria=None):
    result = {'type': 'noul' if criteria is None else 'choice', 'instructions': text}
    if criteria is not None:
        result['criteria'] = criteria
    return result


def head_report(h, record):
    notes = h.get('reportNotes')
    if notes is None:
        notes = record.get('notes')
    landing = landed(h)
    state = dict(task=h.get('task', ''), ownedFiles=record.get('files', []),
                 landedFiles=[f['path'] for f in landing.get('files', [])],
                 conflicts=len(landing.get('conflicts', [])), report=capped(h.get('summary'), 6000),
                 notes=({k: notes.get(k) if (notes.get(k) or '').strip() else None
                         for k in ('deviations', 'unfinished', 'uncertain')} if notes is not None else None),
                 followedReportFormat=notes is not None)
    questions = {
        'gapUnreported': question("The state is one coding agent's final report on a task its lead assigned. Agents are told not to build, test or verify; the lead does that, so saying a build or test was not run is expected and is no gap. Work the lead was assigned, or that belongs to files outside `ownedFiles`, is the lead's by design and is no gap either; unfinished work in the agent's own files is a gap even when the report asks the lead to finish it. `notes` holds the agent's own Deviations / Unfinished / Uncertain lines (null when it wrote none of them). Does the report text admit something else in its own task unfinished, failed, skipped, guessed or left for later that `notes` does not mention?"),
        'completion': question('Judging by the report alone, how far did the agent get with its own task? Not running builds or tests, and leaving work outside its own files to the lead, are expected of it and do not count against completion.', {
            'complete': 'Says the task is done and leaves nothing over.',
            'partial': 'Did part of the task; says or shows that some of the task itself is left or skipped.',
            'blocked': 'Could not do the task, or stopped on a question, an error or missing access.'}),
        'reworkLikely': question('Will the lead most likely have to send this agent back to rework its part, judging by the report, the files it owned and the files that landed?')}
    return state, questions


def pre_review(job, reply, heads, files):
    flags = []
    records = {r['headID']: r for r in job.get('heads', [])}
    for head in heads:
        h = head['hydra']
        notes = h.get('reportNotes')
        if notes is None:
            notes = records.get(head['id'], {}).get('notes')
        fields = []
        if notes is not None:
            fields = [label + ' ' + notes[key] for key, label in
                      [('deviations', 'Deviations'), ('unfinished', 'Unfinished'), ('uncertain', 'Uncertain')]
                      if notes.get(key) is not None]
        if fields:
            flags.append(capped(eval.head_name(h.get('index')) + ': ' + ' / '.join(fields), 500))
    state = dict(request=capped(job.get('request'), 4000), leadReply=capped(reply, 4000),
                 headFlags=flags, heads=len(heads), leadBuilt=job.get('leadBuilt', False),
                 leadEditsAfterReports=job.get('leadEditsAfterReports', 0),
                 files=[{k: f[k] for k in ('path', 'added', 'deleted')} for f in files[:40]],
                 filesTotal=len(files), linesAdded=sum(f['added'] for f in files),
                 linesDeleted=sum(f['deleted'] for f in files))
    questions = {'defectLikely': question("The state summarises a finished multi-agent coding job just before an independent code review: the user's request, the lead's final reply, open points the agents flagged, whether a build ran, and line counts per changed file (no source). Will the review find at least one defect that would make the software behave wrongly? Judge the summary only; this is not a verdict on the code.")}
    return state, questions


def disposition(review, reply, findings):
    return dict(review=capped(review, 8000), leadReply=capped(reply, 4000)), {
        f'finding_{n}': question(f"The state holds an independent review's numbered findings and the lead's reply to them. How did the reply deal with Finding {n}?", {
            'accepted': 'Says it changed or fixed something for this finding.',
            'rejected': 'Argues the finding is wrong or not worth a change, and leaves it.',
            'unaddressed': 'Does not clearly respond to this finding.'})
        for n in range(1, min(findings, 8) + 1)}


def landed(h):
    landing = h.get('landing') or {}
    return landing if landing.get('files') and landing.get('patchPath') is None and landing.get('error') is None else {}


def relative(path, root):
    path = path.strip()
    if '://' in path:
        return None
    p = Path(path).expanduser()
    p = p if p.is_absolute() else Path(root) / p
    try:
        # Lexical normalization also excludes ../ paths outside this checkout.
        import os
        return str(Path(os.path.normpath(p)).relative_to(Path(root)))
    except ValueError:
        return None


def file_stats(job, next_job, heads, turns, checkout):
    roots = dict(job.get('baseTrees') or {})
    counts = {}
    for head in heads:
        h = head['hydra']
        root = h.get('targetCheckout') or checkout
        if not root:
            continue
        for f in landed(h).get('files', []):
            path = relative(f['path'], root)
            if path is not None:
                key = (root, path)
                a, d = counts.get(key, (0, 0))
                counts[key] = (a + f.get('additions', 0), d + f.get('deletions', 0))
    for turn in turns:
        for path in turn.get('touchedPaths') or []:
            candidates = sorted(set(roots) | ({checkout} if checkout else set()), key=len, reverse=True)
            if not Path(path).expanduser().is_absolute():
                candidates = [checkout] if checkout else []
            for root in candidates:
                rel = relative(path, root)
                if rel is not None:
                    counts.setdefault((root, rel), (0, 0))
                    break
    active_roots = sorted({root for root, _ in counts})
    result, sources, per_root = [], set(), {}
    for root in active_roots:
        paths = sorted(path for r, path in counts if r == root)
        stats = {p: counts[root, p] for p in paths}
        source = 'paths-only'
        end = (next_job.get('baseTrees') or {}).get(root) if next_job else None
        if roots.get(root) and end:
            try:
                stats = {}
                for offset in range(0, len(paths), 400):
                    raw = subprocess.run(['git', '-C', root, '--literal-pathspecs', 'diff', '--no-ext-diff',
                                          '--no-textconv', '--numstat', '-z', roots[root], end,
                                          '--', *paths[offset:offset + 400]], capture_output=True, check=True,
                                         timeout=20).stdout
                    entries = iter(raw.split(b'\0'))
                    for entry in entries:
                        if entry:
                            a, d, p = entry.split(b'\t', 2)
                            if not p:
                                next(entries)  # A rename's old path precedes its destination.
                                p = next(entries)
                            stats[p.decode('utf-8', errors='replace')] = (0 if a == b'-' else int(a),
                                                                      0 if d == b'-' else int(d))
                source = 'git-numstat'
            except (OSError, subprocess.SubprocessError, ValueError, StopIteration):
                stats = {p: counts[root, p] for p in paths}
        sources.add(source)
        if stats:
            per_root[root] = stats
    for root, stats in per_root.items():
        for path, (a, d) in stats.items():
            result.append(dict(path=Path(root).name + '/' + path if len(per_root) > 1 else path,
                               relativePath=path, added=a, deleted=d))
    result.sort(key=lambda f: (-(f['added'] + f['deleted']), f['path']))
    return result, '+'.join(sorted(sources)) or 'paths-only'


def read(path):
    return json.loads(path.read_text(encoding='utf-8'))


def write(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, ensure_ascii=False) + '\n', encoding='utf-8')


def rows(path):
    return [json.loads(line) for line in path.read_text(encoding='utf-8').splitlines() if line.strip()]


def write_rows(path, values):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(''.join(json.dumps(v, ensure_ascii=False) + '\n' for v in values), encoding='utf-8')


def iso(value):
    stamp = eval.timestamp(value)
    if stamp is None:
        raise ValueError('missing_started_at')
    return dt.datetime.fromtimestamp(stamp, dt.timezone.utc).isoformat().replace('+00:00', 'Z')


def build(args):
    library = Path(args.library).expanduser().resolve()
    out = args.out
    if out == library.parent or library.parent in out.parents:
        raise SystemExit('Output must be outside the source library.')
    if (out / 'index.jsonl').exists() or (out / 'payloads').exists():
        raise SystemExit('Build requires a fresh output directory.')
    data = read(library)
    threads = data.get('threads', [])
    threads = list(threads.values()) if isinstance(threads, dict) else threads
    projects = data.get('projects', [])
    projects = list(projects.values()) if isinstance(projects, dict) else projects
    project_paths = {p['id']: p.get('path') for p in projects}
    reader = eval.Reader()
    index, outcomes = [], []
    def emit(point, lead, job, pair, head_id=None, source=None):
        state, questions = pair
        body = mask(dict(model='jev-latest', state=state, questions=questions))
        ident = str(uuid.uuid5(uuid.NAMESPACE_URL, f"{library}:{lead['id']}:{job['id']}:{point}:{head_id}"))
        write(out / 'payloads' / point / (ident + '.json'), body)
        index.append(dict(id=ident, point=point, leadID=lead['id'], jobID=job['id'], headID=head_id,
                          startedAt=iso(job['startedAt']), statsSource=source,
                          chars=len(json.dumps(body, ensure_ascii=False))))
    for lead in threads:
        jobs = sorted([j for j in lead.get('hydraJobs', []) if j.get('mode', 'v2') == 'v2'],
                      key=lambda j: eval.timestamp(j.get('startedAt')) or 0)
        if not jobs:
            continue
        items, turns, _, _ = reader.transcript(library.parent, lead['id'])
        checkout = lead.get('worktreePath') or project_paths.get(lead.get('projectID'))
        for ji, job in enumerate(jobs):
            next_job = jobs[ji + 1] if ji + 1 < len(jobs) else None
            start = eval.timestamp(job['startedAt'])
            ends = [eval.timestamp(j.get(k)) for j, k in [(job, 'finishedAt'), (next_job or {}, 'startedAt')]]
            end = min((t for t in ends if t is not None), default=float('inf'))
            window = [i for i in items if start <= (eval.timestamp(i.get('date')) or 0) < end]
            review_item = next((i for i in window if eval.payload(i)[0] == 'user'
                                and eval.payload(i)[1].get('text', '').startswith(REVIEW_OPENING)), None)
            review = eval.payload(review_item)[1].get('text', '') if review_item else ''
            before = window[:window.index(review_item)] if review_item else window
            reply = next((eval.payload(i)[1].get('text', '') for i in reversed(before)
                          if eval.payload(i)[0] == 'assistant'), '')
            heads = [t for t in threads if (t.get('hydra') or {}).get('jobID') == job['id']]
            by_id = {h['id']: h for h in heads}
            for record in job.get('heads', []):
                head = by_id.get(record['headID'])
                if record.get('status') == 'completed' and head:
                    emit('headReport', lead, job, head_report(head['hydra'], record), head['id'])
            findings = job.get('reviewFindings')
            if findings is None:
                continue
            turn_ids = {i.get('turnID') for i in window}
            job_turns = [t for t in turns if t.get('id') == job.get('turnID') or t.get('id') in turn_ids or
                         start <= (eval.timestamp(t.get('startedAt')) or 0) < end]
            files, source = file_stats(job, next_job, heads, job_turns, checkout)
            emit('preReview', lead, job, pre_review(job, reply, heads, files), source=source)
            visible = files[:40]
            names = Counter(Path(f['relativePath']).name for f in visible)
            paths = [f['path'] for f in visible if f['relativePath'] in review or
                     (names[Path(f['relativePath']).name] == 1 and Path(f['relativePath']).name in review)]
            outcomes.append(mask(dict(v=1, kind='outcome', at=iso(job['startedAt']), point='preReview',
                                      leadID=lead['id'], jobID=job['id'], reviewer=job.get('reviewEngine'),
                                      findings=findings, findingPaths=paths if findings else [])))
            if findings > 0 and review_item:
                # The lead's reply can fall outside the job's time window; its turn cannot.
                responses = [i for i in items if i.get('turnID') == review_item.get('turnID')
                             and eval.payload(i)[0] == 'assistant']
                review_reply = eval.payload(responses[-1])[1].get('text', '') if responses else ''
                emit('reviewDisposition', lead, job, disposition(review, review_reply, findings))
    write_rows(out / 'index.jsonl', index)
    write_rows(out / 'outcomes.jsonl', outcomes)
    print(json.dumps({'points': dict(Counter(r['point'] for r in index)),
                      'statsSource': dict(Counter(r['statsSource'] for r in index if r['statsSource']))}))


def score(args):
    try:
        key = subprocess.run(['security', 'find-generic-password', '-s', 'Tivano Dev',
                              '-a', 'TypeSafe API Key', '-w'], capture_output=True, text=True,
                             check=True).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        key = ''
    counts, first = Counter(), {}
    called = False
    for row in rows(args.out / 'index.jsonl'):
        target = args.out / 'answers' / (row['id'] + '.json')
        if target.exists():
            counts['existing'] += 1
            continue
        if called:
            time.sleep(0.2)
        started = time.monotonic()
        error, status, response = None, None, None
        if not key:
            error = 'missing_key'
        else:
            called = True
            request = urllib.request.Request('https://api.typesafe.ai/v1/systemone',
                data=(args.out / 'payloads' / row['point'] / (row['id'] + '.json')).read_bytes(),
                headers={'Authorization': 'Bearer ' + key, 'Content-Type': 'application/json',
                         'Accept': 'application/json', 'User-Agent': 'Tivano'}, method='POST')
            try:
                with urllib.request.urlopen(request, timeout=20) as result:
                    status = result.status
                    try:
                        response = json.loads(result.read())
                    except (ValueError, UnicodeError):
                        error = 'provider_error'
                    answers = response.get('answers') if isinstance(response, dict) else None
                    if not isinstance(answers, dict) or not all(isinstance(v, dict) and
                            isinstance(v.get('type'), str) for v in answers.values()):
                        error = 'provider_error'
            except urllib.error.HTTPError as exc:
                status = exc.code
                error = {401: 'auth_rejected', 403: 'auth_rejected', 422: 'invalid_request',
                         429: 'rate_limited', 408: 'timeout'}.get(status, 'provider_error')
            except (TimeoutError, socket.timeout):
                error = 'timeout'
            except urllib.error.URLError as exc:
                error = 'timeout' if isinstance(exc.reason, (TimeoutError, socket.timeout)) else 'network_error'
            except OSError:
                error = 'network_error'
        result = dict(status='failed' if error else 'ok', error=error, httpStatus=status,
                      latencyMs=int((time.monotonic() - started) * 1000), response=response)
        write(target, result)
        counts[result['status']] += 1
        first.setdefault(result['status'], error)
        if error == 'auth_rejected':
            break
    print(json.dumps({'counts': dict(counts), 'firstError': first}))


def ledger(args):
    records = []
    for row in rows(args.out / 'index.jsonl'):
        path = args.out / 'answers' / (row['id'] + '.json')
        if not path.exists():
            continue
        answer = read(path)
        body = read(args.out / 'payloads' / row['point'] / (row['id'] + '.json'))
        response = answer.get('response') or {}
        response = response if isinstance(response, dict) else {}
        usage = response.get('usage') or {}
        record = dict(v=1, kind='decision', id=row['id'], at=row['startedAt'], point=row['point'],
                      leadID=row['leadID'], jobID=row['jobID'], engine='typesafe', model='jev-latest',
                      responseModel=response.get('model'), status=answer['status'], error=answer.get('error'),
                      latencyMs=answer.get('latencyMs'), inputTokens=usage.get('input_tokens'),
                      outputTokens=usage.get('output_tokens'), state=body['state'], questions=body['questions'],
                      answers=response.get('answers') if answer['status'] == 'ok' else None)
        if row.get('headID'):
            record['headID'] = row['headID']
        records.append(record)
    records.extend(rows(args.out / 'outcomes.jsonl'))
    write_rows(args.out / 'replay-ledger.jsonl', records)
    print(json.dumps(dict(Counter(r['kind'] for r in records))))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    for name in ('build', 'score', 'ledger'):
        command = commands.add_parser(name)
        command.add_argument('--out', required=True, type=lambda s: Path(s).expanduser().resolve())
        if name == 'build':
            command.add_argument('--library', required=True)
    args = parser.parse_args()
    globals()[args.command](args)


if __name__ == '__main__':
    main()
