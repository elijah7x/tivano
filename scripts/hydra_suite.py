#!/usr/bin/env python3
"""Frozen Hydra regression checks (Python 3 standard library).

python3 -I scripts/hydra_suite.py new --job-csv v2_jobs.csv --job-id ID --out SPEC.json
python3 -I scripts/hydra_suite.py check --spec SPEC.json --worktree PATH --label dev-A --out DIR
python3 -I scripts/hydra_suite.py check --spec SPEC.json --worktree PATH --head REF --run-commands --out DIR
python3 -I scripts/hydra_suite.py summary --results DIR_A DIR_B --out DIR

See docs/operations/hydra-benchmark.md for the JSON schema. Git access is limited
to rev-parse/diff. Sources are read-only unless --run-commands explicitly enables
spec commands (arbitrary programs, no sandbox). Outputs must be fresh and external.
Without --head, tracked working-tree content is compared with base_commit;
untracked files are not visible to git diff. With --head only committed content counts.
"""

import argparse
import csv
import datetime as dt
import fnmatch
import hashlib
import importlib.util
import json
import math
import os
from pathlib import Path
import re
import subprocess
import sys


sys.dont_write_bytecode = True
_loader = importlib.util.spec_from_file_location('hydra_eval_loaders', Path(__file__).with_name('hydra_eval.py'))
eval_data = importlib.util.module_from_spec(_loader)
_loader.loader.exec_module(eval_data)
ROOT = Path(__file__).resolve().parent.parent
KINDS = ('allowed_paths', 'required_paths', 'forbidden_paths', 'diff_must_match',
         'diff_must_not_match', 'commands')


def git(repo, command, *args):
    if command not in ('rev-parse', 'diff'):
        raise ValueError('Disallowed Git operation')
    env = {k: v for k, v in os.environ.items() if not k.startswith('GIT_')}
    env.update(GIT_OPTIONAL_LOCKS='0', GIT_TERMINAL_PROMPT='0')
    result = subprocess.run(['git', '-C', str(repo), command, *args],
                            capture_output=True, env=env, timeout=60)
    if result.returncode:
        raise ValueError(eval_data.redact(result.stderr.decode('utf-8', 'replace')))
    return result.stdout.decode('utf-8', 'replace')


def output_path(value, sources=()):
    common = Path(git(ROOT, 'rev-parse', '--path-format=absolute', '--git-common-dir').strip()).resolve()
    source = common.parent
    override = os.environ.get('TIVANO_ARTIFACTS_ROOT')
    artifacts = Path(override) if override is not None else source.parent
    if not artifacts.is_absolute():
        raise ValueError('TIVANO_ARTIFACTS_ROOT must be an absolute external path')
    protected = [ROOT, source, *[Path(p).resolve() for p in sources],
                 *[p.parent.resolve() for p in eval_data.DEFAULTS],
                 Path.home() / '.tivano', Path.home() / '.tivano-dev']
    for candidate in (artifacts, Path(value).expanduser().absolute()):
        if any(p.is_symlink() for p in (candidate, *candidate.parents)):
            raise ValueError('Output paths must not contain symlinks')
        candidate = candidate.resolve()
        if any(candidate == p or p in candidate.parents for p in protected):
            raise ValueError('Outputs must be outside source checkouts and app/source data')
        if any((p / '.git').exists() or (p / '.git').is_symlink()
               for p in (candidate, *candidate.parents)):
            raise ValueError('Outputs must be outside every Git work tree')
    path = Path(value).expanduser().absolute()
    if path.exists() or path.is_symlink():
        raise ValueError('Output already exists; choose a fresh path')
    return path


def write_json(path, value):
    with path.open('x', encoding='utf-8') as handle:
        json.dump(value, handle, ensure_ascii=False, indent=2, allow_nan=False)
        handle.write('\n')


def new(args):
    source = Path(args.job_csv).expanduser().resolve()
    with source.open(encoding='utf-8-sig', newline='') as handle:
        rows = [{re.sub(r'[\s-]+', '_', k.strip().lower()): v for k, v in row.items() if k}
                for row in csv.DictReader(handle)]
    rows = [r for r in rows if args.job_id in
            (r.get('job_key'), r.get('job_id'), r.get('request_id'))]
    if len(rows) != 1:
        raise ValueError('Expected exactly one job; use job_key to disambiguate')
    row = rows[0]
    spec = {'schema_version': 1, 'id': row.get('job_key') or args.job_id,
            'task_type': row.get('task_type') or 'unknown',
            'base_commit': row.get('base_commit') or '',
            'request': eval_data.redact(row.get('request') or row.get('request_excerpt')),
            'request_is_excerpt': not bool(row.get('request')),
            'checks': {}, 'rubric_notes': ''}
    if row.get('size'):
        spec['size'] = row['size']
    out = output_path(args.out, [source.parent])
    out.parent.mkdir(parents=True, exist_ok=True)
    write_json(out, spec)
    print('Scaffold written. Restore the full redacted request, pin base_commit and add checks before freezing.')


def weight(value):
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value) or value <= 0:
        raise ValueError('Check weights must be finite positive numbers')
    return value


def validate(spec):
    if not isinstance(spec, dict) or spec.get('schema_version') != 1:
        raise ValueError('Expected spec schema_version 1')
    for key in ('id', 'task_type', 'request'):
        if not isinstance(spec.get(key), str) or not spec[key].strip():
            raise ValueError('Missing spec field: ' + key)
    if not re.fullmatch(r'[0-9a-fA-F]{40}|[0-9a-fA-F]{64}', spec.get('base_commit', '')):
        raise ValueError('base_commit must be a full frozen commit ID')
    if spec.get('request_is_excerpt', False):
        raise ValueError('Restore the full request and set request_is_excerpt to false before checking')
    checks = spec.get('checks')
    if not isinstance(checks, dict) or set(checks) - set(KINDS):
        raise ValueError('Unknown or invalid checks')
    for kind, entries in checks.items():
        if not isinstance(entries, list):
            raise ValueError(kind + ' must be a list')
        for entry in entries:
            if not isinstance(entry, dict):
                raise ValueError('Each check must be an object')
            weight(entry.get('weight', 1))
            if kind == 'allowed_paths':
                patterns = entry.get('patterns')
                if not isinstance(patterns, list) or not all(isinstance(p, str) and p for p in patterns):
                    raise ValueError('allowed_paths needs a patterns list')
            elif kind == 'commands':
                argv = entry.get('argv')
                if not isinstance(argv, list) or not argv or not all(isinstance(a, str) and '\0' not in a for a in argv) or not argv[0]:
                    raise ValueError('commands needs a nonempty argv string list')
                if not isinstance(entry.get('name'), str) or not entry['name']:
                    raise ValueError('commands needs a name')
                if not isinstance(entry.get('cwd_relative', '.'), str):
                    raise ValueError('cwd_relative must be a string')
            else:
                if not isinstance(entry.get('pattern'), str) or not entry['pattern']:
                    raise ValueError(kind + ' needs a pattern')
                if kind.startswith('diff_'):
                    re.compile(entry['pattern'], re.MULTILINE)


def cell(value):
    return str(value).replace('|', '\\|').replace('\n', ' ').replace('\r', ' ')


def check(args):
    spec_path = Path(args.spec).expanduser().resolve()
    spec = json.loads(spec_path.read_text(encoding='utf-8'))
    validate(spec)
    repo = Path(args.worktree).expanduser().resolve()
    top = Path(git(repo, 'rev-parse', '--show-toplevel').strip()).resolve()
    if repo != top:
        raise ValueError('--worktree must be the repository root')
    repo_common = Path(git(repo, 'rev-parse', '--path-format=absolute', '--git-common-dir').strip()).resolve()
    out = output_path(args.out, [repo, repo_common.parent, spec_path])
    base = git(repo, 'rev-parse', '--verify', '--end-of-options', spec['base_commit'] + '^{commit}').strip()
    head = git(repo, 'rev-parse', '--verify', '--end-of-options', (args.head or 'HEAD') + '^{commit}').strip()
    refs = [base, head] if args.head else [base]
    options = ['--no-ext-diff', '--no-textconv', '--no-color', '--no-renames']
    diff = git(repo, 'diff', *options, *refs, '--')
    paths = git(repo, 'diff', *options, '--name-only', '-z', *refs, '--').split('\0')
    paths = sorted(p for p in paths if p)
    results = []
    commands = []
    for kind, entries in spec['checks'].items():
        for index, entry in enumerate(entries, 1):
            if kind == 'commands':
                relative = Path(entry.get('cwd_relative', '.'))
                cwd = (repo / relative).resolve()
                if relative.is_absolute() or (cwd != repo and repo not in cwd.parents) or not cwd.is_dir():
                    raise ValueError('Command cwd must be an existing directory inside the worktree')
                commands.append((entry, cwd))
                continue
            pattern = entry.get('pattern', '')
            detail = pattern
            if kind == 'allowed_paths':
                violations = [p for p in paths if not any(fnmatch.fnmatchcase(p, g) for g in entry['patterns'])]
                passed, detail = not violations, 'Scope violations: ' + ', '.join(violations)
            elif kind in ('required_paths', 'forbidden_paths'):
                matched = [p for p in paths if fnmatch.fnmatchcase(p, pattern)]
                passed = bool(matched) if kind == 'required_paths' else not matched
                detail = pattern + '; matching changed paths: ' + ', '.join(matched)
            else:
                matched = bool(re.search(pattern, diff, re.MULTILINE))
                passed = matched if kind == 'diff_must_match' else not matched
            results.append({'name': f'{kind}:{index}', 'status': 'pass' if passed else 'fail',
                            'weight': entry.get('weight', 1), 'detail': eval_data.redact(detail)})
    # Validate every command before executing any. Explicit opt-in is not a sandbox.
    for entry, cwd in commands:
        status, detail = 'skipped', 'Requires --run-commands'
        if args.run_commands:
            try:
                completed = subprocess.run(entry['argv'], cwd=cwd, capture_output=True,
                                           text=True, errors='replace', timeout=300)
                status = 'pass' if completed.returncode == 0 else 'fail'
                detail = f'Exit {completed.returncode}\n' + completed.stdout[-8000:] + completed.stderr[-8000:]
            except (OSError, subprocess.TimeoutExpired) as error:
                status, detail = 'fail', str(error)
        results.append({'name': entry['name'], 'status': status, 'weight': entry.get('weight', 1),
                        'detail': eval_data.redact(detail)})
    total = sum(r['weight'] for r in results)
    passed = sum(r['weight'] for r in results if r['status'] == 'pass')
    result = {'schema_version': 1, 'spec_id': spec['id'],
              'spec_sha256': hashlib.sha256(json.dumps(spec, sort_keys=True, ensure_ascii=False).encode()).hexdigest(),
              'label': args.label or head[:12], 'base_commit': base, 'head_commit': head,
              'comparison': 'committed_head' if args.head else 'tracked_worktree',
              'timestamp': dt.datetime.now(dt.timezone.utc).isoformat(),
              'task_type': spec['task_type'], 'size': spec.get('size'),
              'diff_sha256': hashlib.sha256(diff.encode()).hexdigest(), 'changed_paths': paths,
              'checks': results, 'passed_weight': passed, 'total_weight': total,
              'objective_score': 100 * passed / total if total else None,
              'complete': bool(results) and all(r['status'] != 'skipped' for r in results),
              'rubric_notes': eval_data.redact(spec.get('rubric_notes', '')),
              'limits': 'Untracked files excluded. Commands can mutate files; diff captured before commands.'}
    out.mkdir(parents=True)
    write_json(out / 'result.json', result)
    lines = ['# Hydra suite result', '', f"Spec: {cell(spec['id'])}; run: {cell(result['label'])}", '',
             f"Objective score: {result['objective_score'] if total else 'NA'}; complete: {result['complete']}.", '',
             '| Check | Status | Weight | Detail |', '|---|---|---:|---|']
    lines += ['| ' + ' | '.join(cell(r[k]) for k in ('name', 'status', 'weight', 'detail')) + ' |' for r in results]
    lines += ['', result['limits'], 'Skipped weights remain in the denominator; an empty spec scores NA.', '']
    (out / 'result.md').write_text('\n'.join(lines), encoding='utf-8')
    return 0 if result['complete'] and all(r['status'] == 'pass' for r in results) else 1


def summary(args):
    sources = [Path(p).expanduser().resolve() for p in args.results]
    out = output_path(args.out, sources)
    rows, identities, seen = [], {}, set()
    for source in sources:
        row = json.loads((source / 'result.json').read_text(encoding='utf-8'))
        identity = (row['spec_sha256'], row['base_commit'])
        if row['spec_id'] in identities and identities[row['spec_id']] != identity:
            raise ValueError('Cannot compare changed specs or bases under the same spec ID')
        identities[row['spec_id']] = identity
        key = (row['spec_id'], row['label'])
        if key in seen:
            raise ValueError('Duplicate spec/run label; use distinct replicate labels')
        seen.add(key)
        rows.append(row)
    labels = sorted({r['label'] for r in rows})
    lookup = {(r['spec_id'], r['label']): r for r in rows}
    lines = ['# Hydra suite comparison', '', 'Scores are comparable only within a frozen spec. Missing runs are NA.', '',
             '| Spec | ' + ' | '.join(cell(v) for v in labels) + ' |',
             '|---|' + '---:|' * len(labels)]
    for spec_id in sorted(identities):
        values = []
        for label in labels:
            row = lookup.get((spec_id, label))
            value = 'NA' if not row or row['objective_score'] is None else f"{row['objective_score']:.1f}"
            if row and not row['complete']:
                value += ' (incomplete)'
            values.append(value)
        lines.append('| ' + cell(spec_id) + ' | ' + ' | '.join(values) + ' |')
    out.mkdir(parents=True)
    write_json(out / 'summary.json', rows)
    (out / 'summary.md').write_text('\n'.join(lines) + '\n', encoding='utf-8')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(required=True)
    command = sub.add_parser('new')
    command.add_argument('--job-csv', required=True)
    command.add_argument('--job-id', required=True)
    command.add_argument('--out', required=True)
    command.set_defaults(handler=new)
    command = sub.add_parser('check')
    command.add_argument('--spec', required=True)
    command.add_argument('--worktree', required=True)
    command.add_argument('--head')
    command.add_argument('--label')
    command.add_argument('--run-commands', action='store_true')
    command.add_argument('--out', required=True)
    command.set_defaults(handler=check)
    command = sub.add_parser('summary')
    command.add_argument('--results', nargs='+', required=True)
    command.add_argument('--out', required=True)
    command.set_defaults(handler=summary)
    args = parser.parse_args()
    try:
        return args.handler(args) or 0
    except (OSError, ValueError, KeyError, TypeError, re.error, subprocess.TimeoutExpired) as error:
        parser.exit(2, eval_data.redact(str(error)) + '\n')


if __name__ == '__main__':
    sys.exit(main())
