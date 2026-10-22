# Local package contract

An owner-requested build/package produces a package **and updates the corresponding
installed app**, unless explicitly requested as build-only. Agent-initiated
verification builds remain build-only. An explicit Dev package request also
authorizes quitting Dev before replacing its bundle; verify it has exited first.
Release packaging requires separate authorization to quit a running Release app.
Packaging never authorizes launching or publishing.

```bash
scripts/package_local.sh --both     # current request: install both editions
scripts/package_local.sh --dev      # only the requested Dev build
scripts/package_local.sh --release  # only the requested Release build
```

The script verifies all requested builds before installing any; keeps prior apps
under `<artifact-root>/private-artifacts/install-backups/<timestamp>-<pid>/<App name>.app`;
stages each verified bundle under `/Applications` before a swap;
and refuses to replace a running target. It never copies or deletes live session
data. Both local editions use the same Developer ID Application team, with
separate stable bundle IDs and install paths:

| Edition | Installed app | Bundle ID | Initial display version |
| --- | --- | --- | --- |
| Release | `/Applications/Tivano.app` | `dev.tivano.Tivano` | `0.0.1` |
| Dev | `/Applications/Tivano Dev.app` | `dev.tivano.Tivano.dev` | `dev-0.0.1` |

Local ZIPs are in `<artifact-root>/local-packages/<edition>/`, where `<edition>`
is `dev` or `release`; filenames and ZIP contents are unchanged. DerivedData and
build logs remain in the project's `build.noindex/<edition>/`. Long-lived local
packages and rollback bundles stay outside the source checkouts; old backups are
not automatically removed.

Set `TIVANO_ARTIFACTS_ROOT` to override the external parent containing
`local-packages/` and `private-artifacts/`. It must be an absolute directory path
outside both the current worktree and the long-lived source checkout. The scripts
resolve existing directory symlinks and validate the final package/backup directory
as well as the root, rejecting paths into either checkout before building or replacing
an installed app. Unusable paths fail without replacing it.
Without an override, the scripts obtain the absolute Git common-dir with
`git rev-parse --path-format=absolute --git-common-dir` and resolve its physical
path. Its parent is the long-lived source checkout; that checkout's parent
(the wrapper directory) is the artifact root, shared by all its worktrees.

Backups are copied and verified before the original app is moved into staging,
so rollback stays on the `/Applications` volume even if the artifact root is on
another volume. If rollback fails, the original staged app is preserved for recovery.

Both editions retain hardened runtime and secure timestamps. Local packaging does not submit to Apple
notarization or upload publicly; public distribution uses the release pipeline.
The public `release.sh` pipeline builds and notarizes Release without installing,
quitting or launching it, and keeps its temporary outputs separate from local app backups.

## Independent versions

The authoritative version/build files are `config/release.xcconfig` and
`config/dev.xcconfig`, attached to the corresponding target configurations in both
the Xcode project and XcodeGen spec. Apple's `CFBundleShortVersionString` stays
numeric; Dev's UI and package filenames add `dev-`.

```bash
scripts/set_version.py dev 0.0.2
scripts/package_local.sh --dev
# Release remains unchanged.
```

Packaging alone does not invent a new version or synchronize editions. Version
changes are explicit; the setter increments that edition's internal build number.

When the owner approves Dev and asks Release to catch up:

```bash
scripts/set_version.py release catch-up-dev
scripts/package_local.sh --release
```

Before building, use the approved Dev code revision; copying a version number
alone does not promote code. The release display name and unbadged icon remain
Release's even when the numeric version catches up.

## Edition data

See [independent edition libraries](shared-library.md). Release and Dev each own
their library and never read the other's, so Dev experiments cannot modify
production conversations. Project folders and provider CLI configuration remain
shared; keep backups before risky experiments on them.

Source: [Apple CFBundleShortVersionString](https://developer.apple.com/documentation/bundleresources/information-property-list/cfbundleshortversionstring)
requires three period-separated integers, so `dev-` is intentionally not stored
in that system field.
