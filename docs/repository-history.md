# Repository history

Tivano is based on Droppy Code. The source, license notices, and attribution
remain in this repository; removing upstream Git commits does not change
the ownership or licensing of that source.

On 2026-10-08, the maintainer explicitly authorized a history migration
before making the repository public. The repository retains the maintainer’s
Tivano development and publication commits, with inherited commit ancestry
removed. Author and committer metadata use the GitHub identity `elijah7x`
and its GitHub noreply address.

Historical snapshots were sanitized: private icon delivery directories and
stale internal audit documents were removed, hardcoded maintainer emails
were replaced with the config/env-based credits implementation, and old
onboarding images were replaced with the current generated captures.
These historical snapshots are edited records and are not build-tested
representations of the original revisions. The final application source
matches the audited Dev 0.1.5 source; this migration does not change either
edition’s version or installed application.

The original history and the old-to-new commit map are kept in a private
archive outside the repository. Old task worktrees must not be merged or
pushed into this rewritten history; recreate future tasks from the new
main or dev branch.

## Privacy migration (2026-10-12)

On 2026-10-12 the maintainer explicitly authorized merging, releasing and
replacing the old public history. This authorization covers public account
usage details, real host aliases and private paths in historical AGENTS,
T08 acceptance records, fixtures and operations scripts. Current copies have
been sanitized. It does not authorize deleting old application versions,
licenses, attribution or release downloads, or unrelated historical content.
The lead executed the migration with a private full backup and exact per-ref
leases: 15 public branch/tag refs were updated atomically. The reviewed mapping
covers 129 commits, including private local dev history. Application source,
version files, licenses, authors, dates and DAG topology were preserved; only
the selected sensitive documents/scripts and one private commit message changed.
Release downloads remain available. The mapped local integration tree is unchanged.
Server-managed PR refs and direct old-SHA caches are outside this ref rewrite;
this is not a claim that GitHub has erased every old object.

Before rewriting, the lead must retain a complete private repository backup
and freeze the exact public refs and their original object SHAs. Include all
public branches and tags that can retain sensitive ancestry, and explicitly
resolve any refs outside the selected set. The tool never chooses remote refs
to delete and does not remove old objects, backups or downloads.

`scripts/sanitize_public_history.py` uses Python's standard library and Git
plumbing. It accepts only an explicitly named, standalone SHA-1 bare repository,
without worktrees, alternates, shallow history, grafts or replace refs. The lead
must create a file named `tivano-public-history-migration` in that private bare
repository containing exactly `tivano-public-history-2026-10-12-v1`. Do not mark
an existing working repository as a migration repository. The tool never edits
the owner checkout, local dev or another worktree. Keep replacement inputs,
frozen refs, rules and output outside the public repository.

The frozen refs JSON is a nonempty object mapping full ref names to original
40-character object SHAs (annotated tags use the tag object's SHA). Local bare
refs must still match it. Only heads and tags are accepted; dev is forbidden. A private staging branch named
`refs/heads/local-history-<name>` may be included with an explicit repeated
`--local-only-ref` argument. Its history is mapped for local dev reconciliation
but is excluded from the remote push manifest.
The rules JSON has exactly `version`, `paths` and `messages`, with version `1`.
For example, using neutral placeholders:

```json
{
  "version": 1,
  "paths": [
    {"path": "docs/T08-acceptance.md", "action": "replace", "file": "sanitized/T08-acceptance.md"},
    {"path": "historical-private-notes.md", "action": "delete"},
    {"path": "scripts/old-host-helper.py", "action": "rename", "to": "scripts/build-host-helper.py"},
    {"path": "scripts/example.py", "action": "substitute", "replacements": [{"old": "private literal", "new": "neutral literal"}]}
  ],
  "messages": [
    {"commit": "<original-full-commit-SHA>", "replacements": [{"old": "private literal", "new": "neutral literal"}]}
  ]
}
```

This is a schema illustration, not a migration input: the lead must select
actual historical paths and literal replacements, and provide fully sanitized
replacement files. A replace or substitute action may additionally specify
`to` to sanitize content and move the historical file in the same operation.
Replacement files resolve relative to the rules JSON or
use an explicit absolute location. Path actions apply only in commits where
the source path exists; replacement does not invent a document in earlier
commits. Rename targets must be unique, unused in that snapshot and disjoint
from rule sources. No wildcard, regex or unscoped blob/message substitution
is performed. Unknown fields, invalid paths, missing objects and unreachable
message targets fail closed. Submodule gitlink SHAs are retained as external
references; the tool does not fetch submodule repositories.

```sh
python3 scripts/sanitize_public_history.py --repo "<dedicated-bare-repo>" \
  --refs "<frozen-refs.json>" --rules "<rules.json>" --output "<new-private-plan-dir>"
# After reviewing the plan, repeat with a different new output directory:
python3 scripts/sanitize_public_history.py --repo "<dedicated-bare-repo>" \
  --refs "<frozen-refs.json>" --rules "<rules.json>" --output "<new-private-apply-dir>" --apply
```

Default dry-run computes object IDs and writes private reports without writing
Git objects or refs. Apply writes reconstructed objects and updates only the
frozen local bare refs in one compare-and-swap transaction. A failed apply may
leave unreachable objects and reports; it must not be treated as a completed
migration. No network command runs in rewrite mode. Unselected refs stay intact.
Original DAG topology, author, committer, dates, version source and commit
messages survive except explicit message replacements. Invalid commit
signatures/mergetags and signatures on rewritten annotated tags are removed
and recorded in `removed-signatures.json`; tag descriptions, tagger and dates
are preserved. Lightweight tags remain lightweight.

Review `commit-map.json`, `tag-map.json`, `ref-paths.json`, and the exact
old/new object pairs in `migration-manifest.json`. Review historical content
and application-source equality independently; the tool is not a sensitive
content scanner or a build validator. A manifest's checksum detects accidental
changes, not malicious forgery: it is an explicitly reviewed private input.
The lead must verify that apply completed and all bare refs match its map.

Install the updated pre-push guard and its adjacent validator for the dedicated
bare repository before pushing. The hook locates the validator at
`../scripts/sanitize_public_history.py` relative to its own directory; a copied
hook alone is insufficient. Use the normal configured hook location, never
`--no-verify`, a temporary hooksPath override or a generic force bypass.
Set `TIVANO_HISTORY_MANIFEST` explicitly to the applied private manifest.
The validator's independent `--check-push --manifest <file> --remote-url <url>`
mode consumes the four-field pre-push stdin batch, performs no mutation, and
requires every changed ref exactly once, identical local/remote ref names,
exact old/new SHAs, the matching dedicated bare repository, and live canonical
GitHub `ls-remote` SHAs equal to the frozen old SHAs. Unknown refs, dev, missing
entries, extra entries and all deletions are rejected. The manifest contains
only changed refs in its push batch; unchanged frozen refs are not pushed.
Ordinary pushes retain all existing restrictions.

The lead must push the entire manifest batch with an explicit
`--force-with-lease=<ref>:<oldSHA>` for each ref (and preferably `--atomic`),
using exact refspecs. The hook's online check cannot eliminate a race by itself;
server-side leases are mandatory. No push or GitHub write is performed by the
tool. A partial push requires a newly frozen, reviewed plan rather than reuse
of the original batch.

Afterward the owner must reconcile local main/dev and release ancestry with
the reviewed mappings; old task worktrees must not reintroduce the old DAG.
The ordinary guard's historical root allowlist and pinned version-tag SHAs
must be updated separately from the verified mappings before ordinary pushes
resume; this migration-only entry does not relax them. Preserve version source,
release downloads, licenses and contributor credit throughout. GitHub caches,
PR refs, forks, clones and direct old-SHA access may still expose old objects;
platform cleanup may be needed, and rewriting advertised refs alone is not
proof that those copies disappeared.
