#!/usr/bin/env python3
"""Offline, explicit public-history rewrite; see docs/repository-history.md."""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import subprocess
import sys

FORMAT = 'tivano-public-history-2026-10-12-v1'
MARKER = 'tivano-public-history-migration'
REMOTES = {
    'https://github.com/elijah7x/tivano',
    'https://github.com/elijah7x/tivano.git',
    'git@github.com:elijah7x/tivano.git',
    'ssh://git@github.com/elijah7x/tivano.git',
}
SHA = re.compile(r'[0-9a-f]{40}\Z')
ZERO = '0' * 40


def require(condition, message):
    if not condition:
        raise ValueError(message)


def load_json(path):
    def pairs(items):
        result = {}
        for key, value in items:
            require(key not in result, 'Duplicate JSON key')
            result[key] = value
        return result
    return json.loads(Path(path).read_text(), object_pairs_hook=pairs)


def exact(value, keys):
    require(isinstance(value, dict) and set(value) == set(keys), 'Invalid manifest fields')


def ref_name(ref):
    require(isinstance(ref, str) and ref.startswith(('refs/heads/', 'refs/tags/'))
            and ref != 'refs/heads/dev', 'Unsupported ref (dev is forbidden)')
    require(not any(c in ref for c in '~^:?*[\\') and '..' not in ref
            and '@{' not in ref and '//' not in ref
            and all(ord(c) > 32 and ord(c) != 127 for c in ref)
            and all(p and not p.startswith('.') and not p.endswith(('.', '.lock'))
                    for p in ref.split('/')), 'Invalid ref name')
    return ref


def sha(value):
    require(isinstance(value, str) and SHA.fullmatch(value) and value != ZERO,
            'Invalid or zero object SHA')
    return value


def path_name(value):
    require(isinstance(value, str) and value and '\\' not in value
            and '\x00' not in value and not value.startswith('/'), 'Invalid repository path')
    require(all(p not in ('', '.', '..') and p.lower() != '.git' for p in value.split('/'))
            and str(PurePosixPath(value)) == value, 'Path escapes repository')
    return value.encode('utf-8')


class Git:
    def __init__(self, repo=None):
        self.prefix = ['git'] + (['--git-dir=' + str(repo)] if repo else [])
        self.written = set()
        self.env = {k: v for k, v in os.environ.items() if not k.startswith('GIT_')}
        self.env.update(GIT_NO_REPLACE_OBJECTS='1', GIT_CONFIG_NOSYSTEM='1',
                        GIT_CONFIG_GLOBAL=os.devnull, GIT_TERMINAL_PROMPT='0')

    def run(self, *args, data=None):
        result = subprocess.run(self.prefix + list(args), input=data, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, env=self.env)
        require(result.returncode == 0, 'Git plumbing failed: ' + ' '.join(args[:2]))
        return result.stdout

    def kind(self, oid):
        return self.run('cat-file', '-t', oid).strip().decode()

    def object(self, kind, oid):
        return self.run('cat-file', kind, oid)

    def write(self, kind, data, apply):
        oid = hashlib.sha1(kind.encode() + b' ' + str(len(data)).encode() + b'\0' + data).hexdigest()
        if apply and oid not in self.written:
            actual = self.run('hash-object', '-t', kind, '--stdin', '-w', data=data).strip().decode()
            require(actual == oid, 'Git object hash mismatch')
            self.written.add(oid)
        return oid


def headers(raw):
    head, separator, message = raw.partition(b'\n\n')
    require(separator, 'Malformed commit/tag object')
    blocks = []
    for line in head.split(b'\n'):
        if line.startswith(b' '):
            require(blocks, 'Malformed header continuation')
            blocks[-1] += b'\n' + line
        else:
            require(b' ' in line, 'Malformed object header')
            blocks.append(line)
    return blocks, message


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(',', ':')).encode()).hexdigest()


def save(directory, name, value):
    destination = directory / name
    with destination.open('x', encoding='utf-8') as stream:
        json.dump(value, stream, indent=2, ensure_ascii=False)
        stream.write('\n')


def rules_from(path):
    source = Path(path).resolve()
    rules = load_json(source)
    exact(rules, ['version', 'paths', 'messages'])
    require(type(rules['version']) is int and rules['version'] == 1, 'Unknown rules version')
    require(isinstance(rules['paths'], list) and isinstance(rules['messages'], list), 'Invalid rules')
    seen, actions = set(), []
    for rule in rules['paths']:
        require(isinstance(rule, dict), 'Invalid path rule')
        action = rule.get('action')
        keys = {'delete': ['path', 'action'], 'rename': ['path', 'action', 'to'],
                'replace': ['path', 'action', 'file'],
                'substitute': ['path', 'action', 'replacements']}
        require(action in keys, 'Unknown path action')
        extra = ['to'] if action in ('replace', 'substitute') and 'to' in rule else []
        exact(rule, keys[action] + extra)
        name = path_name(rule['path'])
        require(name not in seen, 'Duplicate source path')
        seen.add(name)
        item = dict(rule, name=name)
        if 'to' in rule:
            item['target'] = path_name(rule['to'])
            require(item['target'] != name, 'Rename has identical target')
        if action == 'replace':
            require(isinstance(rule['file'], str), 'Invalid replacement file')
            file = Path(rule['file'])
            if not file.is_absolute():
                file = source.parent / file
            item['content'] = file.read_bytes()
        elif action == 'substitute':
            item['pairs'] = replacement_pairs(rule['replacements'])
        actions.append(item)
    targets = [r['target'] for r in actions if 'target' in r]
    require(len(set(targets)) == len(targets) and not set(targets).intersection(seen),
            'Rename targets must be unique and disjoint from rule sources')
    messages = {}
    for rule in rules['messages']:
        exact(rule, ['commit', 'replacements'])
        oid = sha(rule['commit'])
        require(oid not in messages, 'Duplicate message rule')
        messages[oid] = replacement_pairs(rule['replacements'])
    return rules, actions, messages


def replacement_pairs(value):
    require(isinstance(value, list) and value, 'Empty or invalid replacements')
    result = []
    for entry in value:
        exact(entry, ['old', 'new'])
        require(isinstance(entry['old'], str) and entry['old']
                and isinstance(entry['new'], str), 'Invalid literal replacement')
        result.append((entry['old'].encode(), entry['new'].encode()))
    return result


def substitute(content, pairs):
    for old, new in pairs:
        content = content.replace(old, new)
    return content


def rewrite(args):
    require(args.repo and args.refs and args.rules and args.output,
            'Explicit --repo, --refs, --rules and --output are required')
    repo = Path(args.repo).resolve(strict=True)
    require(repo != Path(__file__).resolve().parents[1], 'Refusing source checkout')
    git = Git(repo)
    require(git.run('rev-parse', '--is-bare-repository').strip() == b'true', 'Dedicated bare repo required')
    require((repo / MARKER).is_file() and (repo / MARKER).read_text().strip() == FORMAT,
            'Dedicated migration marker missing or invalid')
    require(not any((repo / p).exists() for p in ('worktrees', 'shallow', 'info/grafts', 'objects/info/alternates')),
            'Worktrees, shallow history, grafts and alternates are forbidden')
    require(not git.run('for-each-ref', '--format=%(refname)', 'refs/replace').strip(), 'Replace refs forbidden')
    require(git.run('rev-parse', '--show-object-format').strip() == b'sha1', 'Only SHA-1 repositories supported')
    frozen = load_json(args.refs)
    require(isinstance(frozen, dict) and frozen, 'Frozen refs must be a nonempty ref-to-SHA object')
    for ref, oid in frozen.items():
        ref_name(ref); sha(oid)
        require(git.run('show-ref', '--verify', '--hash', ref).strip().decode() == oid,
                'Frozen ref missing or moved: ' + ref)
        require(git.kind(oid) in ('commit', 'tag'), 'Ref must resolve to commit or annotated tag')
        git.run('rev-parse', '--verify', oid + '^{commit}')
    local_refs = set(args.local_only_ref)
    require(local_refs.issubset(frozen) and all(ref.startswith('refs/heads/local-history-') for ref in local_refs),
            'Local-only refs must be explicit frozen local-history branches')
    rules, actions, messages = rules_from(args.rules)
    commits = git.run('rev-list', '--topo-order', '--reverse', *frozen.values(), '--').decode().splitlines()
    require(set(messages).issubset(commits), 'Message rule references unreachable commit')
    output = Path(args.output).resolve()
    require(not output.is_relative_to(repo) and not output.is_relative_to(Path(__file__).resolve().parents[1]),
            'Output must be private and outside repositories')
    output.mkdir(mode=0o700, parents=True, exist_ok=False)
    os.chmod(output, 0o700)
    mapping, changes, signatures, tagmap = {}, {}, [], {}
    verified_blobs = set()

    def tree_oid(files):
        root = {}
        for name, entry in files.items():
            node = root
            parts = name.split(b'/')
            for part in parts[:-1]:
                require(part not in node or isinstance(node[part], dict), 'File/directory collision')
                node = node.setdefault(part, {})
            require(parts[-1] not in node, 'Tree path collision')
            node[parts[-1]] = entry

        def emit(node):
            entries = []
            for name, value in node.items():
                if isinstance(value, dict):
                    mode, oid = b'40000', emit(value)
                    key = name + b'/'
                else:
                    mode, oid = value
                    key = name
                entries.append((key, mode + b' ' + name + b'\0' + bytes.fromhex(oid)))
            return git.write('tree', b''.join(raw for _, raw in sorted(entries)), args.apply)
        return emit(root)

    for old in commits:
        blocks, message = headers(git.object('commit', old))
        trees = [b[5:].decode() for b in blocks if b.startswith(b'tree ')]
        require(len(trees) == 1, 'Commit must have one tree')
        files = {}
        unverified = set()
        for entry in git.run('ls-tree', '-r', '-z', trees[0]).split(b'\0'):
            if not entry:
                continue
            metadata, name = entry.split(b'\t', 1)
            mode, kind, oid = metadata.split(b' ')
            require(kind in (b'blob', b'commit'), 'Unexpected tree entry')
            if kind == b'blob' and oid not in verified_blobs:
                unverified.add(oid)
            files[name] = (mode, oid.decode())
        if unverified:
            result = git.run('cat-file', '--batch-check', data=b'\n'.join(sorted(unverified)) + b'\n')
            found = set()
            for line in result.splitlines():
                fields = line.split()
                require(len(fields) == 3 and fields[1] == b'blob' and fields[2].isdigit(), 'Missing or invalid blob')
                found.add(fields[0])
            require(found == unverified, 'Blob validation mismatch')
            verified_blobs.update(found)
        changed = set()
        for rule in actions:
            name = rule['name']
            if name not in files:
                continue
            mode, oid = files[name]
            action = rule['action']
            if action == 'delete':
                del files[name]; changed.add(name)
            elif action == 'rename':
                target = rule['target']
                require(target not in files, 'Rename target already exists')
                files[target] = files.pop(name); changed.update((name, target))
            else:
                require(mode in (b'100644', b'100755'), 'Replacement requires regular blob')
                content = git.object('blob', oid)
                new = rule['content'] if action == 'replace' else substitute(content, rule['pairs'])
                if content != new:
                    files[name] = (mode, git.write('blob', new, args.apply)); changed.add(name)
                if 'target' in rule:
                    target = rule['target']
                    require(target not in files, 'Rename target already exists')
                    files[target] = files.pop(name); changed.update((name, target))
        tree = tree_oid(files) if changed else trees[0]
        newblocks = []
        parents_changed = False
        for block in blocks:
            if block.startswith(b'tree '):
                block = b'tree ' + tree.encode()
            elif block.startswith(b'parent '):
                parent = block[7:].decode()
                require(parent in mapping, 'Missing parent mapping')
                parents_changed |= mapping[parent] != parent
                block = b'parent ' + mapping[parent].encode()
            newblocks.append(block)
        newmessage = substitute(message, messages.get(old, []))
        modified = bool(changed) or parents_changed or newmessage != message
        if modified:
            removed = [b.split(b' ', 1)[0].decode() for b in newblocks
                       if b.startswith((b'gpgsig ', b'gpgsig-sha256 ', b'mergetag '))]
            if removed:
                signatures.append({'object': old, 'removed_headers': removed})
            newblocks = [b for b in newblocks if not b.startswith((b'gpgsig ', b'gpgsig-sha256 ', b'mergetag '))]
        mapping[old] = git.write('commit', b'\n'.join(newblocks) + b'\n\n' + newmessage, args.apply)
        changes[old] = sorted(p.decode('utf-8', 'surrogateescape') for p in changed)

    def remap(oid):
        if oid in mapping:
            return mapping[oid]
        if oid in tagmap:
            return tagmap[oid]
        require(git.kind(oid) == 'tag', 'Tag target has no commit mapping')
        blocks, message = headers(git.object('tag', oid))
        targets = [b[7:].decode() for b in blocks if b.startswith(b'object ')]
        require(len(targets) == 1, 'Tag must have one target')
        target = remap(targets[0])
        if target == targets[0]:
            tagmap[oid] = oid
            return oid
        blocks = [b'object ' + target.encode() if b.startswith(b'object ') else b for b in blocks]
        markers = (b'-----BEGIN PGP SIGNATURE-----', b'-----BEGIN SSH SIGNATURE-----',
                   b'-----BEGIN SIGNED MESSAGE-----')
        offsets = [message.find(marker) for marker in markers if marker in message]
        if offsets:
            message = message[:min(offsets)]
            signatures.append({'object': oid, 'removed_tag_signature': True})
        tagmap[oid] = git.write('tag', b'\n'.join(blocks) + b'\n\n' + message, args.apply)
        return tagmap[oid]

    refs = {ref: {'old': oid, 'new': remap(oid)} for ref, oid in frozen.items()}
    summaries = {}
    for ref, oid in frozen.items():
        reachable = git.run('rev-list', oid, '--').decode().splitlines()
        summaries[ref] = sorted({p for commit in reachable for p in changes[commit]})
    manifest = {'format': FORMAT, 'applied': args.apply, 'repo': str(repo),
                'rules_sha256': digest(rules), 'refs': refs,
                'local_only_refs': sorted(local_refs),
                'push': {ref: pair for ref, pair in refs.items() if pair['old'] != pair['new'] and ref not in local_refs}}
    manifest['sha256'] = digest(manifest)
    save(output, 'commit-map.json', mapping)
    save(output, 'tag-map.json', tagmap)
    save(output, 'ref-paths.json', summaries)
    save(output, 'removed-signatures.json', signatures)
    save(output, 'migration-manifest.json', manifest)
    if args.apply:
        transaction = 'start\n' + ''.join('update {} {} {}\n'.format(ref, pair['new'], pair['old'])
                                        for ref, pair in refs.items()) + 'prepare\ncommit\n'
        git.run('update-ref', '--stdin', data=transaction.encode())
    print('Applied refs' if args.apply else 'Dry-run: no objects or refs written')
    print('Private reports: ' + str(output))


def check_push(args):
    require(args.manifest and args.remote_url in REMOTES, 'Explicit manifest and canonical remote required')
    require(not args.apply and not any((args.repo, args.refs, args.rules, args.output, args.local_only_ref)),
            'Check-push cannot be combined with rewrite arguments')
    manifest = load_json(args.manifest)
    exact(manifest, ['format', 'applied', 'repo', 'rules_sha256', 'refs', 'push', 'local_only_refs', 'sha256'])
    checksum = manifest.pop('sha256')
    require(checksum == digest(manifest) and manifest['format'] == FORMAT
            and manifest['applied'] is True, 'Invalid or dry-run migration manifest')
    require(isinstance(manifest['rules_sha256'], str) and re.fullmatch(r'[0-9a-f]{64}', manifest['rules_sha256']),
            'Invalid rules digest')
    require(isinstance(manifest['refs'], dict) and isinstance(manifest['push'], dict)
            and manifest['push'], 'Empty migration push')
    for ref, pair in manifest['refs'].items():
        ref_name(ref); exact(pair, ['old', 'new']); sha(pair['old']); sha(pair['new'])
    local_refs = manifest['local_only_refs']
    require(isinstance(local_refs, list) and len(set(local_refs)) == len(local_refs)
            and set(local_refs).issubset(manifest['refs'])
            and all(isinstance(ref, str) and ref.startswith('refs/heads/local-history-') for ref in local_refs),
            'Invalid local-only refs')
    require(manifest['push'] == {ref: pair for ref, pair in manifest['refs'].items()
                                if pair['old'] != pair['new'] and ref not in local_refs}, 'Push map differs from ref map')
    git = Git()
    expected_repo = Path(manifest['repo']).resolve(strict=True)
    actual_repo = Path(os.fsdecode(git.run('rev-parse', '--absolute-git-dir')).strip()).resolve()
    require(actual_repo == expected_repo and git.run('rev-parse', '--is-bare-repository').strip() == b'true',
            'Push must originate from the dedicated rewritten bare repo')
    require((actual_repo / MARKER).read_text().strip() == FORMAT, 'Migration marker missing')
    batch = {}
    for line in sys.stdin:
        fields = line.split()
        require(len(fields) == 4, 'Malformed pre-push stdin')
        local_ref, new, ref, old = fields
        require(local_ref == ref and local_ref != 'refs/heads/dev', 'Migration requires matching source ref')
        ref_name(ref); sha(old); sha(new)
        require(ref not in batch and ref in manifest['push'], 'Duplicate or unknown push ref')
        require(git.run('show-ref', '--verify', '--hash', ref).strip().decode() == new,
                'Local rewritten ref changed')
        git.run('cat-file', '-e', new)
        batch[ref] = {'old': old, 'new': new}
    require(batch == manifest['push'], 'Entire push batch must exactly match manifest')
    online = {}
    for line in git.run('ls-remote', '--refs', args.remote_url, *batch).decode().splitlines():
        oid, ref = line.split()
        require(ref in batch and ref not in online, 'Unexpected remote ref response')
        online[ref] = oid
    require(online == {ref: pair['old'] for ref, pair in batch.items()}, 'Remote frozen SHA changed')
    print('Exact migration batch accepted', file=sys.stderr)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('repo', 'refs', 'rules', 'output', 'manifest', 'remote-url'):
        parser.add_argument('--' + name)
    parser.add_argument('--apply', action='store_true')
    parser.add_argument('--check-push', action='store_true')
    parser.add_argument('--local-only-ref', action='append', default=[])
    args = parser.parse_args()
    try:
        if args.check_push:
            check_push(args)
        else:
            require(not args.manifest and not args.remote_url, 'Push arguments require --check-push')
            rewrite(args)
        return 0
    except (ValueError, OSError, KeyError, TypeError, RecursionError) as error:
        print('Refused: ' + str(error), file=sys.stderr)
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
