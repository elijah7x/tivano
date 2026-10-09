# Independent edition libraries

Release owns production data. Dev is a separate test environment, not a viewer or
mirror of production. Droppy Code is independent of both editions.

| Storage | Release | Dev |
| --- | --- | --- |
| Application Support | `~/Library/Application Support/Tivano` | `~/Library/Application Support/Tivano Dev` |
| Worktrees and patches | `~/.tivano` | `~/.tivano-dev` |
| Keychain service | `Tivano` | `Tivano Dev` |
| Bundle ID / preferences | `dev.tivano.Tivano` | `dev.tivano.Tivano.dev` |

Neither edition imports upstream or other-edition preferences or credentials.
Deleting a credential affects only its own service. Existing Release keys remain
in `Tivano`; configure Dev keys explicitly. Older credential services are not
silently imported or deleted. Existing Dev-only Keychain items are not erased by
separation; review them manually if they were previously used for production.

Provider CLI logins/configuration (such as Claude/Codex), external MCP integration
files and user project checkouts remain user/provider-owned. This separation does
not create separate OS accounts or provider sandboxes. Use separate test projects
and provider accounts when testing destructive behavior.

## Separating an existing shared installation

Do not run older shared-library builds after separation. Update both editions to
this code before running them concurrently; a new edition's bootstrap lock can
exclude an already-running old build but cannot stop an old shared build launched
later. Bundle IDs, Release updater configuration and production verification stay
unchanged. Public publishing remains a separate, explicitly authorized operation.

1. Quit **all** Tivano, Tivano Dev, Droppy Code and Cody instances. Never move a
   live library. Packaging does not authorize quitting Release.
2. Preview: `python3 scripts/separate_data.py`.
3. Apply: `python3 scripts/separate_data.py --apply`.
4. Install updated editions through the requested packaging/release workflow.
   Do not relaunch automatically. Verify production history/attachments/worktrees
   in Release and an empty library in Dev when launching is authorized.

The tool takes the existing lock files exclusively, creates a private backup and
manifest in `~/Library/Application Support/Tivano Backups/separation-<id>/`, stages
and validates JSON before changing the live library, and leaves production data
at `Tivano`. It archives the former Dev library/state/preferences and resets them.
It removes the old Droppy library alias and restores a separate Droppy snapshot,
rewriting structured absolute attachment paths to each app's own library.

The former `~/.tivano -> ~/.droppy-code` alias is removed; the state directory
moves to `~/.tivano`, and Git worktree registrations are repaired. Stored production
state paths are updated. Droppy starts with an empty state directory: those active
worktrees now belong to Tivano, not to both apps. Their original files are backed
up, but a filesystem copy is not an independently registered Git worktree.

The tool does not launch apps, export credentials, delete production conversations,
or overwrite another independent upstream library. An unexpected alias or invalid
JSON stops it. A completed marker makes repeat runs no-ops. An interrupted apply
leaves `.tivano-separation-in-progress.json` pointing to the backup and refuses
blind retries: recover using the manifest, repair Git registrations if needed, and
only remove the pending marker after inspecting the recovered state. Backups
contain private data; do not commit or publish them.

Fresh installs simply create their edition's empty directories. There is no
implicit Droppy import. Capture runs remain isolated. Each edition holds an exclusive
lifetime lease on its own library, so it is the only writer and saves directly; the
first launch after an update removes the lock files and per-launch MCP folders the
shared-library builds left behind. Automatic Hydra merges still take a lock beside
both libraries, because the editions can work on the same repository.
