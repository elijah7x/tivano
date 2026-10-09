# Local development signing

Debug and locally packaged Release use the same **Developer ID Application**
team. Their bundle IDs remain distinct and stable: `dev.tivano.Tivano.dev`
and `dev.tivano.Tivano`. See [packaging](packaging.md) for the package-and-install
contract and independently versioned editions.

## One-time setup

Install the team's Developer ID Application certificate and matching private
key in the build Mac's login Keychain. Both xcconfig files must specify the same
`DEVELOPMENT_TEAM`. The packaging script requires exactly one usable matching
identity and refuses local or ad-hoc fallback. Preserve the private key in a
secure backup; do not recreate signing identities between builds.

If macOS asks whether `codesign` may use the signing private key, authorize
that tool using Keychain's “Always Allow” option. Do not enable access for all
applications. A locked Keychain can still require its password.

`scripts/setup_local_signing.sh` is a legacy local-certificate utility; it is
not used by the current packaging workflow. Existing local certificates are
left in Keychain for older builds.

## Build without launching

```bash
xcodebuild -project Tivano.xcodeproj -scheme Tivano -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath build.noindex/dev \
  -skipPackagePluginValidation build
```

Both configurations use Developer ID, hardened runtime and secure timestamps.
Local signing does not automatically notarize the app. Public distribution
must use the [public release workflow](public-release.md); keep the updater's
production signature checks.

## Install and run (only when explicitly requested)

```bash
scripts/quick_run.sh
```

This quits Dev if it is running, packages and verifies the new app, then
installs/relaunches `/Applications/Tivano Dev.app`. It is only for an explicitly
requested run/relaunch. Packaging alone uses `scripts/package_local.sh` and
never launches or quits apps. Keep stable install paths and bundle IDs;
the editions use [independent production and test stores](shared-library.md).

Keychain recognizes updated code by its designated requirement rather than
its changing content hash. Switching from the old local identity to Developer
ID may require a one-time authorization for each edition and existing Keychain
item. Choose “Always Allow” for a trusted edition when prompted. The two bundle
IDs remain separate identities even though they share a signing team.
Accessibility, screen recording and automation grants follow their own macOS
policies. Permission persistence must be checked across explicitly authorized
installs/relaunches; signing alone does not prove it.

## Verification

```bash
codesign --verify --deep --strict --verbose=2 \
  'build.noindex/dev/Build/Products/Debug/Tivano Dev.app'
codesign -d -r- 'build.noindex/dev/Build/Products/Debug/Tivano Dev.app'
```

The designated requirement must retain the bundle ID and Apple Developer ID
team identity, with no build-dependent `cdhash`. The packaging script also
checks hardened runtime and a secure timestamp.

Sources: [Apple TN3127 — Code Signing Requirements](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements)
and [Xcode build settings](https://developer.apple.com/documentation/xcode/build-settings-reference).

## Contributor credits

Release credits identify maintainers by GitHub username. Private historical email
identities must be supplied outside source control, either with repeated local
`git config --local --add tivano.maintainerEmail <email>` entries or the
comma-separated `TIVANO_MAINTAINER_EMAILS` environment variable. Other contributors
using GitHub noreply addresses remain eligible for credit.

## Development product screenshots

Only with explicit launch authorization, run
`uv run --with Pillow scripts/product_captures.py` to build and launch an isolated
Debug capture instance. It uses mock conversations, independent storage/defaults
and a generated backdrop from existing theme colors. It does not read the desktop
wallpaper or Keychain. The `--website-captures` flag is disabled in Release builds.
Raw stills, framing sidecars and resized PNGs remain in
`build.noindex/product-captures/`; the tool does not add application assets.

## CLI discovery

Tivano reads the login shell environment with a 15-second budget. If shell startup
fails, it uses the standard fallback PATH without caching the failed probe as a
successful load. Subsequent CLI operations may retry after 30 seconds. The
Providers refresh button also requests a new probe immediately, including after a
CLI installation or a shell configuration change. If discovery still fails, check
shell startup files or set the provider's executable path explicitly. Tivano does
not guess which nvm/fnm Node version a project should use.
