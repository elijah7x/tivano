import argparse
import contextlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
sys.dont_write_bytecode = True
SOURCE = Path(__file__).resolve().parent.parent
_temporary = tempfile.TemporaryDirectory(prefix='tivano-consolidation-checks-')
ROOT = Path(_temporary.name).resolve()

def load(name):
    spec = importlib.util.spec_from_file_location(name, SOURCE / 'scripts' / (name + '.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module

worker = load('consolidate_checkout')
controller = load('consolidate_checkout_job')
worker.processes = lambda roots: []

def git(path, *args):
    return subprocess.check_output(['git', '-C', str(path), *args], stderr=subprocess.PIPE).decode().strip()

def fixture(name, dirty=False, unknown=False, occupied=False):
    base = Path(tempfile.mkdtemp(prefix=name + ' ', dir=ROOT))
    source, dest, state, home = [base / n for n in ('source.dev', 'source', 'state', 'home')]
    source.mkdir();home.mkdir()
    git(source, 'init', '-q', '-b', 'task')
    git(source, 'config', 'user.name', 'Fixture')
    git(source, 'config', 'user.email', 'fixture@example.invalid')
    git(source, 'config', 'commit.gpgsign', 'false')
    (source / 'file.txt').write_text('baseline\n')
    (source / '.gitignore').write_text('ignored/\n')
    git(source, 'add', '.')
    git(source, 'commit', '-q', '-m', 'Baseline')
    git(source, 'branch', 'main')
    git(source, 'branch', 'dev')
    git(source, 'worktree', 'add', '-q', str(dest), 'main')
    git(source, 'switch', '-q', 'dev')
    (source / 'file.txt').write_text('integrated dev version\n')
    git(source, 'add', 'file.txt')
    git(source, 'commit', '-q', '-m', 'Dev changes')
    git(source, 'switch', '-q', 'task')
    other = base / 'other worktree'
    git(source, 'worktree', 'add', '--detach', '-q', str(other), 'HEAD')
    if occupied:
        git(source, 'worktree', 'add', '-q', str(base / 'occupied dev'), 'dev')
    if dirty:
        (source / 'file.txt').write_text('staged\n')
        git(source, 'add', 'file.txt')
        (source / 'file.txt').write_text('staged\nunstaged\n')
        (source / 'untracked.bin').write_bytes(bytes(range(256)))
        (source / 'untracked.bin').chmod(0o640)
        (source / 'file.txt').chmod(0o600)
        (source / 'nested').mkdir(mode=0o755)
        (source / 'nested' / 'private.txt').write_text('private untracked')
        (source / 'nested' / 'private.txt').chmod(0o600)
        (source / 'private-script').write_text('#!/bin/sh\nexit 0\n')
        (source / 'private-script').chmod(0o750)
    (source / 'ignored').mkdir()
    (source / 'ignored' / 'local.bin').write_bytes(b'keep ignored')
    (source / 'original empty directory').mkdir(mode=0o777)
    (source / 'original empty directory').chmod(0o777)
    libraries = []
    support = home / 'Library/Application Support'
    support.mkdir(parents=True)
    for edition in ('Tivano', 'Tivano Dev'):
        root = support / edition;root.mkdir()
        data = {'projects': [{'id':'dev-project', 'path':str(source), 'name':'keep name'},
                             {'id':'main-project', 'path':str(dest), 'name':'keep old name'}],
                'threads': [{'id':'one', 'projectID':'dev-project', 'providerSessionID':'keep-native',
                             'title': str(source), 'hydra':{'targetCheckout':str(source)}},
                            {'id':'two', 'projectID':'main-project', 'worktreePath':str(dest), 'branch':'main'},
                            {'id':'three', 'worktreePath':str(other)}]}
        if unknown:
            data['threads'][0]['hydra']['ownedCodexWorkingDirectory'] = str(source)
        path = root / 'library.json'
        path.write_text(json.dumps(data))
        libraries.append((path, path.read_bytes()))
    for name in ('.tivano-library.lock','.tivano-migration.lock','.tivano-release-library.lock','.tivano-dev-library.lock'):
        (support / name).touch()
    before = {k:v for k,v in worker.inventory(source).items() if k != '.git' and not k.startswith('.git/')}
    worker.prepare(argparse.Namespace(source=str(source), destination=str(dest), state_dir=str(state), home=str(home)))
    plan = worker.load_plan(state)
    return base, source, dest, state, home, other, libraries, before, plan

for dirty, mask in ((False, 0o022), (True, 0o022), (False, 0o077), (True, 0o077)):
    base, source, dest, state, home, other, libraries, before, plan = fixture('dirty' if dirty else 'clean', dirty=dirty)
    previous_umask = os.umask(mask)
    try:
        worker.apply(plan, 0)
    finally:
        os.umask(previous_umask)
    assert not source.exists()
    assert git(dest, 'branch', '--show-current') == 'dev'
    assert git(other, 'rev-parse', '--path-format=absolute', '--git-common-dir') == str(dest / '.git')
    for path, original in libraries:
        data = json.loads(path.read_bytes())
        assert data['projects'][0]['path'] == str(dest)
        assert data['projects'][1]['path'] == plan['preserved_main']
        assert data['threads'][0]['hydra']['targetCheckout'] == str(dest)
        assert data['threads'][0]['providerSessionID'] == 'keep-native'
        assert data['threads'][0]['title'] == str(source)
        assert data['threads'][2]['worktreePath'] == str(other)
    if dirty:
        recovered = Path(plan['recovery_worktree'])
        assert (recovered / 'file.txt').read_text() == 'staged\nunstaged\n'
        assert (recovered / 'untracked.bin').read_bytes() == bytes(range(256))
        assert git(recovered, 'show', ':file.txt') == 'staged'
        assert worker.file_entry(recovered / 'untracked.bin') == before['untracked.bin']
        assert worker.file_entry(recovered / 'file.txt') == before['file.txt']
        assert worker.file_entry(recovered / 'nested/private.txt') == before['nested/private.txt']
        assert worker.file_entry(recovered / 'private-script') == before['private-script']
        index = Path(worker.text_git(recovered, 'rev-parse', '--absolute-git-dir')) / 'index'
        cached = index.read_bytes()
        (recovered / '.gitignore').chmod((recovered / '.gitignore').stat().st_mode & 0o777)
        worker.git(recovered, 'diff', '--no-ext-diff', '--no-textconv', '--binary')
        assert index.read_bytes() == cached, 'Read-only verification refreshed the Git index'
    previous_umask = os.umask(mask)
    try:
        worker.rollback(plan)
    finally:
        os.umask(previous_umask)
    assert source.is_dir() and (dest / '.git').is_file()
    for path, original in libraries: assert path.read_bytes() == original
    after = {k:v for k,v in worker.inventory(source).items() if k != '.git' and not k.startswith('.git/')}
    assert after == before
    print('PASS', 'dirty' if dirty else 'clean', oct(mask), 'migration and exact working-data rollback')

base, source, dest, state, home, other, libraries, before, plan = fixture('interrupted after stash', dirty=True)
interrupted = False
original_quiet = worker.require_quiet
def interrupt_after_stash(plan, message):
    global interrupted
    path = state / 'journal.json'
    if path.exists() and worker.read_json(path).get('steps') == ['stash'] and not interrupted:
        interrupted = True
        raise worker.Stopped('A related process restarted (fixture interruption)')
    original_quiet(plan, message)
worker.require_quiet = interrupt_after_stash
try:
    worker.apply(plan, 0)
except worker.Stopped as error:
    assert 'related process restarted' in str(error), str(error)
else:
    raise AssertionError('Injected interruption was ignored')
finally:
    worker.require_quiet = original_quiet
assert worker.read_json(state / 'progress.json')['phase'] == 'rolled_back'
assert not Path(plan['recovery_worktree']).exists()
assert {k:v for k,v in worker.inventory(source).items() if k != '.git' and not k.startswith('.git/')} == before
for path, original in libraries: assert path.read_bytes() == original
print('PASS interruption after stash rolls back without a recovery worktree')

observations = iter([[(123, 'brief directory access')], []])
worker.processes = lambda roots: next(observations)
worker.require_quiet(plan, 'Transient observer should finish')
worker.processes = lambda roots: []
print('PASS transient access ends before the offline check continues')

for name, kwargs, expected in [('unknown metadata', {'unknown':True}, 'Unmapped'),
                                ('occupied dev', {'occupied':True}, 'occupied')]:
    base, source, dest, state, home, other, libraries, before, plan = fixture(name, **kwargs)
    try: worker.apply(plan, 0)
    except worker.Stopped as error: assert expected in str(error), str(error)
    else: raise AssertionError(name + ' was not blocked')
    assert source.is_dir() and (dest / '.git').is_file() and not (state / 'backup').exists()
    print('PASS', name, 'blocked before backup')

base, source, dest, state, home, other, libraries, before, plan = fixture('cancel')
worker.atomic_json(state / 'cancel-request.json', {'version':1})
try: worker.apply(plan, 0)
except worker.Stopped: pass
else: raise AssertionError('Cancellation was ignored')
assert worker.read_json(state / 'progress.json')['phase'] == 'cancelled'
assert not (state / 'backup').exists()
print('PASS cancellation before backup')

base, source, dest, state, home, other, libraries, before, plan = fixture('rollback guard')
worker.apply(plan, 0)
(dest / 'new-user-work').write_text('preserve')
try: worker.rollback(plan)
except worker.Stopped as error: assert 'State changed' in str(error)
else: raise AssertionError('Rollback overwrote newer work')
assert (dest / 'new-user-work').read_text() == 'preserve'
print('PASS rollback rejects newer work')

# Preparation stages and seals the external runtime without registering a job.
base, source, dest, state, home, other, libraries, before, plan = fixture('controller')
new_state = base / 'job state'
controller.prepare(argparse.Namespace(source=str(source),destination=str(dest),state_dir=str(new_state),home=str(home)))
s, record = controller.load(new_state)
assert controller.plist_for(record, s)['WorkingDirectory'] == str(new_state)
assert controller.plist_for(record, s)['ProgramArguments'][1].startswith(str(new_state / 'runtime'))
assert not (new_state / 'progress.json').exists()
print('PASS external runtime, plan sealing and plist staging without launchd')
(new_state / 'runtime' / 'consolidate_checkout.py').write_text('# tampered')
try: controller.load(new_state)
except controller.JobError as error: assert 'hash' in str(error).lower()
else: raise AssertionError('Changed runtime accepted')
print('PASS runtime tampering rejected')
print('OFFLINE FIXTURE CHECKS PASSED')
