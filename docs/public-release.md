# Public releases

Tivano is distributed outside the Mac App Store as an Apple-silicon DMG.
Local Release and Dev packages use the same Developer ID Application team.
A distributable release also needs Apple notarization; a signature alone is
not a notarization ticket.

## Release downloads

Upload exactly one app installer per GitHub Release: the notarized
`Tivano-<version>.dmg`. Its label includes the `.dmg` extension, Apple silicon,
and notarization status. Release notes start with a direct DMG download link.
Do not upload App ZIP files, including from ad-hoc completion scripts; local
package ZIPs and the temporary ZIP submitted to Apple remain local.

GitHub automatically adds **Source code (zip)** and **Source code (tar.gz)**
for the release tag. They are not uploaded assets and cannot be deleted or
hidden through the release-asset API. Keep the tag and leave these archives
alone; the notes explain that they are source snapshots, not app installers.
See [GitHub's release documentation](https://docs.github.com/en/repositories/releasing-projects-on-github/about-releases).

## Static update feeds and the 1.0.2 transition

Update metadata is separate from the brand website. Ordinary users do not need a
GitHub account or token. The current updater requests the configured public mirror,
[GitHub Pages feed](https://elijah7x.github.io/tivano/updates.json), and
[raw feed](https://raw.githubusercontent.com/elijah7x/tivano/gh-pages/updates.json)
concurrently with a bounded response window. It selects the highest successfully
observed version; a source outside the window remains unknown. Pages and raw
content share GitHub infrastructure. See [mirror operations](operations/aliyun-update-mirror.md)
for the trusted installer origins, deadline and retry contract.

When static sources fail or are older than a known cached version, the existing
GitHub Releases API is the fallback. It may reuse the edition's Keychain token or
local GitHub CLI login, including login-shell environment credentials; it respects
the CLI opt-out and never sends tokens to static feeds or installer hosts.

The versioned JSON schema is `{ "schema_version": 1, "releases": [...] }`.
Release fields match the Releases API, with a `sha256` field on the DMG asset.
The client rejects malformed/unknown feeds, missing digests, unexpected installer
URLs, drafts/prereleases and future releases, then tries the next source. It
checks SHA-256 before mounting, then retains the Developer ID team, bundle-ID,
version and Gatekeeper checks. A stale static feed does not replace a newer
locally cached release. The checksum is not an independent signature: the signed
app/Gatekeeper checks remain the authenticity boundary.

`gh-pages` contains published metadata only, independently of app source. The
publisher uses GitHub's Git Database API, refuses version rollback/concurrent
writes, never force-updates refs, and does not alter main/dev or disable the
local pre-push hook. GitHub Pages must remain on `gh-pages` at `/`, without a
custom domain; a different existing configuration stops publication for review.

After uploading and publishing the notarized DMG, `publish_release.sh` runs:

```bash
python3 scripts/publish_update_feed.py --tag vX.Y.Z --dmg path/to/Tivano-X.Y.Z.dmg
```

It checks the published stable release, asset name/size and GitHub's SHA-256
digest against the local DMG before advancing the feed. Pages deploys
asynchronously. If feed publication fails after the release goes live, rerun
this command alone: do not re-upload the DMG or recreate its release/tag.
Verify both public JSON URLs after the Pages build completes. Initial Pages
setup uses `--enable-pages`; `--output path/to/updates.json` generates a local
manifest without publishing or enabling Pages.

**1.0.2 and earlier have hard-coded API checks.** A new static feed cannot
remotely change their executable. Keep the repository public, the Releases API,
`v*` tags and `Tivano-<version>.dmg` assets available. They can install the first
version containing the new updater through their original path; all subsequent
checks use the static feeds. An old client already returning API 403 must wait
for its IP quota to reset, use another network, or manually install that
transition version from the public Releases page. Signing into GitHub does not
change old updater code. The static-feed bootstrap describes the existing 1.0.2
installer; it does not itself ship the new updater. Shipping requires the normal
explicitly authorized release process.

## Apple account and local setup

Wait for Apple Developer Program membership to become active. A purchase
acknowledgement alone does not establish active membership. Check enrollment
in the [Apple Developer account](https://developer.apple.com/account/).

Once active:

1. Find the membership's ten-character Team ID.
2. Create a **Developer ID Application** certificate in Xcode or the developer
   account and install it with its matching private key on the build Mac.
   A DMG containing an app does not need a Developer ID Installer certificate.
3. Save notarization credentials in this Mac's Keychain. The Apple ID method
   uses an app-specific password, entered at the command's secure prompt:

   ```bash
   xcrun notarytool store-credentials "Tivano-Notarize" \
     --apple-id "YOUR_APPLE_ID" --team-id "YOUR_TEAM_ID"
   ```

   Do not add `--password` to shell history or commit credentials. An App Store
   Connect API key is another supported authentication option.
4. Confirm the local identity and profile:

   ```bash
   security find-identity -v -p codesigning
   xcrun notarytool history --keychain-profile "Tivano-Notarize"
   ```

Apple references: [Developer ID certificates](https://developer.apple.com/help/account/certificates/create-developer-id-certificates/)
and [notarytool credentials](https://developer.apple.com/documentation/technotes/tn3147-migrating-to-the-latest-notarization-tool).

Before archiving, run `scripts/release.sh --preflight`. It checks the signing
team against the updater, requires exactly one matching Developer ID identity,
and validates the saved notarization profile. It does not build or install.

The release build also requires Xcode and XcodeGen.

## Repository changes required before the first release

- Keep the maintainer's Team ID consistent in `config/release.xcconfig`,
  `scripts/release.sh`, and `AppUpdater`'s signature requirement. Keep the Developer ID,
  hardened-runtime, timestamp, bundle-ID, Team-ID, and Gatekeeper checks.
- The approved complete local `dev` is the code source; do not select task
  commits for a release. Build from its fixed prepared commit. After a squash
  PR produces an exact-tree `main`, run `publish_release.sh` from the reviewed
  main checkout. Sync main with origin only with explicit push authorization
  or as part of an explicit release request; a tag does not update main.
- Release takes Dev's version (`scripts/set_version.py release catch-up-dev`,
  done by `scripts/ship.sh`). Dev's version advances with every merge into dev,
  so it is already newer than the last release. Do not advance Dev merely to
  publish Release, and never bump Release alone.
- Add a dated `## [x.y.z]` changelog section with release notes and `### Thanks`.
  Run `python3 scripts/release_credits.py`. On dev, it maps the previous public
  tag to an exact-tree Prepare ancestor; a missing or ambiguous boundary stops
  publication instead of scanning all retained history.
- Review the local push policy: `publish_release.sh` pushes a version tag,
  and the pre-push hook permits main and `v*` tags that point at
  `origin/main`, preserving the restrictions on Dev and pre-migration ancestry.
  Do not disable the hook or use `--no-verify`.
- Review the DMG appearance and run a first-install and update smoke check on
  a machine that has not trusted the local development certificate. Confirm
  launch, provider login, permissions, and localization. Changes
  from local to Developer ID signing can require new privacy grants.

## Public repository presentation

Before changing visibility, update the GitHub description to describe Tivano
rather than a private working copy. Set a homepage only after verifying the
public product site. Repository metadata changes require explicit authorization.
Keep upstream attribution and trademark contacts intact. Issue and pull-request
templates in `.github/` help collect reproducible reports without credentials
or private conversation content.

## Build, notarize, and publish

`scripts/release.sh` archives Release, exports Developer ID signing, verifies
its signature, notarizes the app, staples its ticket, creates and signs the
DMG, notarizes and staples the DMG, and assesses it with Gatekeeper. It does
not install, quit or launch anything; the owner updates Release through the
in-app updater. `scripts/install_app.sh` installs a build only on request.

An explicit release request runs the whole sequence from the dev checkout:

```bash
scripts/ship.sh
```

It prepares the version and changelog on dev, fixes that dev commit as the
build source and runs `scripts/release.sh` on it. It opens and squash-merges a
GitHub pull request whose tree exactly matches that commit, fast-forwards local
main and runs `scripts/publish_release.sh` from the reviewed main checkout. It
stops when Dev's version is not newer than the last release in main's history,
when `[Unreleased]` is empty, or when merged main's tree differs from the fixed
dev tree. A failed run can be retried subject to the artifact and publication
checks below; this does not promise recovery of an interrupted notarization.

A permanent main checkout is not required. `ship.sh` may reuse an existing clean
main checkout, but does not take ownership of it or automatically clean it up;
otherwise it creates a temporary one. The release worktree root is
`$COMMON_DIR/tivano-worktrees.noindex`, derived from the physical Git common-dir.
It is not Git's `$COMMON_DIR/worktrees` registration directory. Ordinary Hydra
worktrees remain managed by the app's existing mechanism; this is not an
app-wide path migration. On success, only safe worktrees created by this run
are removed. On failure, remaining worktrees and artifacts are preserved;
reused worktrees are never automatically removed. Releases sharing a common-dir
are serialized with a temporary lock. A hard interruption may leave that lock;
confirm no release process remains before removing it, rather than reclaiming it
automatically. Git inspection failures stop the release or retain the affected
worktree instead of being treated as a clean state.

Local Dev packaging uses the same source checkout; no separate source directory
is needed. Packaging, installation, launching, GitHub publication and repository
visibility changes retain their separate authorization requirements. A merge
does not authorize packaging or installation. An explicit local package request
authorizes installing the requested edition, not launching it; a Dev package
request also authorizes quitting Dev first. Release must not be overwritten
while running without explicit quit authorization. Public release does not
install or launch the app, or authorize a visibility change.
After the owner authorizes publication, `scripts/publish_release.sh` checks
notes and credits, verifies the stapled DMG, tags the agreed revision, and
uploads the DMG and release notes. An existing empty, stable draft for the same
tag is adopted: the DMG is uploaded first, then the draft is published with the
reviewed notes. A populated draft or published release is reused only when its reviewed commit,
state and single DMG name, size and SHA-256 match exactly. Matching retries
resume publication, feed and mirror steps without overwriting assets; mismatches
and prereleases are refused. API errors stop the script rather than being
treated as a missing release.

The checkout must be clean and match local main, and an existing version tag
must point to that exact revision. Review the exact code revision, version,
notes, and DMG before executing it. Do not treat a local development ZIP as
an official release artifact.

The optional release-head cleanup retains the installed pre-push hook. The tracked
guard supports deletion only with the exact reviewed release ref and SHA; an
older installed guard may refuse it, leaving the branch for explicit cleanup.
`scripts/install_git_hooks.sh --install` installs the tracked guard on a fresh
clone and refuses to overwrite a different existing hook.
