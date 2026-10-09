# Public releases

Tivano is distributed outside the Mac App Store as an Apple-silicon DMG.
Local Release and Dev packages use the same Developer ID Application team.
A distributable release also needs Apple notarization; a signature alone is
not a notarization ticket.

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
- Publish only the reviewed local `main` revision. Dev and task worktrees are
  not release sources. Sync the approved main branch with origin only after
  explicit push authorization; an uploaded tag does not update the main branch.
- Choose the Release version and increment its build number before packaging.
  If promoting approved Dev features, use `scripts/set_version.py release
  catch-up-dev`. Do not advance Dev merely to publish Release.
- Add a dated `## [x.y.z]` changelog section with release notes and `### Thanks`.
  Run `python3 scripts/release_credits.py`; without a reachable prior `v*` tag,
  the credits script checks the repository's complete retained history.
- Review the local push policy: `publish_release.sh` pushes a version tag,
  while the pre-push hook permits main and explicitly reviewed release tags. At an explicitly authorized
  release, permit only the reviewed release tag and preserve the restrictions
  on Dev and pre-migration ancestry. Do not disable the hook or use `--no-verify`.
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
DMG, notarizes and staples the DMG, and assesses it with Gatekeeper. It then
installs the verified app in `/Applications/Tivano.app`. It never launches it;
a running Release must be explicitly authorized to quit before replacement.

After Apple setup and the repository changes above are verified, an explicitly
requested package can use:

```bash
scripts/release.sh
```

Packaging is separate from a GitHub publication and repository visibility change.
After the owner authorizes publication, `scripts/publish_release.sh` checks
notes and credits, verifies the stapled DMG, tags the agreed revision, and
uploads the DMG and release notes. An existing empty, stable draft for the same
tag is adopted: the DMG is uploaded first, then the draft is published with the
reviewed notes. Published releases, prereleases, and drafts with assets are
refused; assets are never overwritten. If upload succeeds but publication
fails, review the populated draft manually before retrying. API errors stop the
script rather than being treated as a missing release.

The checkout must be clean and match local main, and an existing version tag
must point to that exact revision. Review the exact code revision, version,
notes, and DMG before executing it. Do not treat a local development ZIP as
an official release artifact.
