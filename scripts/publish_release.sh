#!/bin/bash
#
# Publishes a release on GitHub: tags the version, uploads the notarized disk
# image and posts the notes from CHANGELOG.md, then updates the static feed.
# Keep the Releases API intact for 1.0.2 and older updaters.
#
#   scripts/publish_release.sh [path/to/Tivano-1.2.3.dmg]
#
# The version is config/release.xcconfig's MARKETING_VERSION; the disk image defaults to
# the one scripts/release.sh leaves in build.noindex. The notes are the ## [<version>] section of CHANGELOG.md, written as "### New features", "### Bug fixes" and "### Refinements" headings with a bullet per change; scripts/build_changelog.py --section extracts it with the headings promoted to "## ", which is what the app reads into its cards. A `### Thanks` heading under the version names every outside contributor whose merge request shipped in it, and publishing stops until `scripts/release_credits.py --check` finds them all named. The tag goes on HEAD, or on RELEASE_REF when
# the version bump has landed on main from elsewhere. Needs gh signed in with
# write access to the repository.
set -euo pipefail

cd "$(dirname "$0")/.."
PROJECT="elijah7x/tivano"
VERSION=$(scripts/version.sh release)
TAG="v$VERSION"
DMG_NAME="Tivano-$VERSION.dmg"
DMG="${1:-build.noindex/$DMG_NAME}"
ASSET_LABEL="$DMG_NAME (Apple silicon, notarized)"
[ "$(basename "$DMG")" = "$DMG_NAME" ] || {
  echo "Publish only $DMG_NAME; App ZIP files stay local." >&2
  exit 1
}
NOTES="$(mktemp -t tivano-notes)"
trap 'rm -f "$NOTES"' EXIT
python3 scripts/build_changelog.py --section "$VERSION" > "$NOTES" || { echo "No ## [$VERSION] section in CHANGELOG.md. Add one before publishing."; exit 1; }

step() { printf '\n==> %s\n' "$1"; }

[ -f "$DMG" ] || { echo "No disk image at $DMG. Run scripts/release.sh first."; exit 1; }
[ -f "$NOTES" ] || { echo "No release notes at $NOTES."; exit 1; }
if ! grep -qE '^## (New features|Bug fixes|Refinements)' "$NOTES"; then
  echo "$NOTES needs at least one of the three headings: ## New features, ## Bug fixes, ## Refinements."
  exit 1
fi

step "Checking every contributor is thanked"
if ! python3 scripts/release_credits.py --check "$NOTES"; then
  echo "Add a ### Thanks section to the ## [$VERSION] entry in CHANGELOG.md naming them (python3 scripts/release_credits.py prints it), then publish again."
  exit 1
fi

python3 - "$NOTES" "$PROJECT" "$TAG" "$DMG_NAME" <<'PYNOTES'
import sys
from pathlib import Path
notes, project, tag, filename = sys.argv[1:]
path = Path(notes)
body = path.read_text()
url = f"https://github.com/{project}/releases/download/{tag}/{filename}"
path.write_text(
    f"[Download Tivano (.dmg, Apple silicon)]({url})\n\n"
    "Open the DMG and drag Tivano to Applications. "
    "The Source code archives below are for developers, not app installers.\n\n"
    "If Tivano 1.0.2 or earlier reports HTTP 403 while checking updates, "
    "install this DMG manually once. Later checks use public static feeds "
    "and do not require a GitHub login.\n\n"
    + body
)
PYNOTES

step "Checking the disk image is notarized"
xcrun stapler validate "$DMG" > /dev/null

step "Checking the reviewed main revision"
REVISION=$(git rev-parse "${RELEASE_REF:-HEAD}^{commit}")
MAIN_REVISION=$(git rev-parse "refs/heads/main^{commit}")
[ "$REVISION" = "$MAIN_REVISION" ] && [ "$(git rev-parse HEAD)" = "$REVISION" ] || {
  echo "Publish from the reviewed local main revision, not Dev or a task revision." >&2
  exit 1
}
[ -z "$(git status --porcelain)" ] || { echo "Commit or remove pending changes before publishing." >&2; exit 1; }
if git rev-parse -q --verify "refs/tags/$TAG" > /dev/null; then
  [ "$(git rev-parse "refs/tags/$TAG^{commit}")" = "$REVISION" ] || {
    echo "$TAG does not point to the reviewed main revision. No tag was changed." >&2
    exit 1
  }
fi

step "Checking the existing release"
# A failed API call is not treated as a missing release. Read all pages so a
# draft can never be overlooked because newer releases filled the first page.
EXISTING=$(gh api --paginate "repos/$PROJECT/releases" \
  --jq ".[] | select(.tag_name == \"$TAG\") | [.draft, .prerelease, (.assets | length)] | @tsv")
if [ -n "$EXISTING" ] && [ "$EXISTING" != "$(printf 'true\tfalse\t0')" ]; then
  echo "Release $TAG is already published, is a prerelease, or has assets. Review it manually; nothing was overwritten." >&2
  exit 1
fi

step "Tagging $TAG"
if ! git rev-parse -q --verify "refs/tags/$TAG" > /dev/null; then
  git tag -a "$TAG" "$REVISION" -m "Tivano $VERSION"
fi
git push origin "$TAG"

if [ -n "$EXISTING" ]; then
  step "Uploading to the empty draft"
  gh release upload "$TAG" "$DMG#$ASSET_LABEL" -R "$PROJECT"
  # Only publish after upload succeeds. Never delete a draft or clobber an asset.
  gh release edit "$TAG" -R "$PROJECT" --draft=false --prerelease=false \
    --verify-tag --title "Tivano $VERSION" --notes-file "$NOTES"
else
  step "Creating the release"
  gh release create "$TAG" "$DMG#$ASSET_LABEL" \
    -R "$PROJECT" --verify-tag --target "$REVISION" \
    --title "Tivano $VERSION" --notes-file "$NOTES"
fi

printf '\nPublished: https://github.com/%s/releases/tag/%s\n' "$PROJECT" "$TAG"
step "Publishing the static update feed"
python3 scripts/publish_update_feed.py --tag "$TAG" --dmg "$DMG"
