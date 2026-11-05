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
VERSION=$(scripts/version.sh release full)
PREVIEW=false
TITLE="Tivano $VERSION"
CREATE_FLAGS=()
FINAL_FLAGS=(--prerelease=false)
if [[ "$VERSION" =~ ^([0-9]+\.[0-9]+\.[0-9]+)-preview\.([1-9][0-9]*)$ ]]; then
  PREVIEW=true
  TITLE="Tivano ${BASH_REMATCH[1]} Preview ${BASH_REMATCH[2]}"
  CREATE_FLAGS=(--prerelease --latest=false)
  FINAL_FLAGS=(--prerelease=true --latest=false)
fi
TAG="v$VERSION"
DMG_NAME="Tivano-$VERSION.dmg"
DMG="${1:-build.noindex/$DMG_NAME}"
ASSET_LABEL="$DMG_NAME (Apple silicon, notarized)"
[ "$(basename "$DMG")" = "$DMG_NAME" ] || {
  echo "Publish only $DMG_NAME; App ZIP files stay local." >&2
  exit 1
}
NOTES="$(mktemp -t tivano-notes)"
MIRROR_FEED="$(mktemp -t tivano-mirror-feed)"
trap 'rm -f "$NOTES" "$MIRROR_FEED"' EXIT
python3 scripts/build_changelog.py --section "$VERSION" > "$NOTES" || { echo "No ## [$VERSION] section in CHANGELOG.md. Add one before publishing."; exit 1; }

step() { printf '\n==> %s\n' "$1"; }

[ -f "$DMG" ] || { echo "No disk image at $DMG. Run scripts/release.sh first."; exit 1; }
[ -s "$NOTES" ] || { echo "No release notes at $NOTES."; exit 1; }
if ! grep -qE '^## (New features|Bug fixes|Refinements)' "$NOTES"; then
  echo "$NOTES needs at least one of the three headings: ## New features, ## Bug fixes, ## Refinements."
  exit 1
fi

if [ "$PREVIEW" = false ]; then
step "Checking every contributor is thanked"
if ! python3 scripts/release_credits.py --check "$NOTES"; then
  echo "Add a ### Thanks section to the ## [$VERSION] entry in CHANGELOG.md naming them (python3 scripts/release_credits.py prints it), then publish again."
  exit 1
fi

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
codesign --verify --strict -R='anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13] and certificate leaf[subject.OU] = "5WF7HRPLRX"' "$DMG"
spctl --assess --type open --context context:primary-signature --ignore-cache --no-cache "$DMG"
DMG_SIZE=$(stat -f %z "$DMG")
DMG_DIGEST="sha256:$(shasum -a 256 "$DMG" | awk '{print $1}')"

if [ "$PREVIEW" = true ]; then
  step "Checking the public preview commit"
  REMOTE_MAIN=$(git ls-remote --exit-code origin refs/heads/main | awk '{print $1}')
  REMOTE_PREVIEW_TAG=$(git ls-remote --exit-code origin "refs/tags/$TAG" "refs/tags/$TAG^{}")
  REVISION=$(awk '/\^\{\}$/ {print $1; found=1} END {if (!found) exit 1}' <<< "$REMOTE_PREVIEW_TAG") ||
    REVISION=$(awk 'NR == 1 {print $1}' <<< "$REMOTE_PREVIEW_TAG")
  [ -n "$REVISION" ] || { echo "Preview tag must already exist remotely." >&2; exit 1; }
  PUBLIC_COMMIT=$(gh api "repos/$PROJECT/git/commits/$REVISION")
  jq -e --arg main "$REMOTE_MAIN" --arg tree "$(git rev-parse 'refs/heads/preview^{tree}')" '
    (.parents | length) == 1 and .parents[0].sha == $main and .tree.sha == $tree
  ' <<< "$PUBLIC_COMMIT" > /dev/null || { echo "Preview commit violates the public tree/parent contract." >&2; exit 1; }
else
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

fi

step "Checking the existing release"
# A failed API call is not treated as a missing release. Read all pages so a
# draft can never be overlooked because newer releases filled the first page.
RELEASES=$(gh api --paginate --slurp "repos/$PROJECT/releases")
EXISTING=$(jq -ce --arg tag "$TAG" '
  if type != "array" or length == 0 or any(.[]; type != "array")
  then error("Invalid release pages") else add end |
  [.[] | select(.tag_name == $tag)] |
  if length > 1 then error("Multiple releases use this tag") else . end
' <<< "$RELEASES")
RELEASE_STATE=missing
if [ "$(jq 'length' <<< "$EXISTING")" = 1 ]; then
  RELEASE_STATE=$(jq -er --arg revision "$REVISION" --arg name "$DMG_NAME" \
    --argjson preview "$PREVIEW" --argjson size "$DMG_SIZE" --arg digest "$DMG_DIGEST" '
    .[0] |
    if (.draft | type) != "boolean" or .prerelease != $preview or
       (.assets | type) != "array" or .target_commitish != $revision
    then error("Release target or draft/prerelease state does not match")
    elif .draft and (.assets | length) == 0 then "empty-draft"
    elif (.assets | length) == 1 and .assets[0].name == $name and
         .assets[0].size == $size and .assets[0].digest == $digest and
         .assets[0].state == "uploaded"
    then (if .draft then "uploaded-draft" else "published" end)
    else error("Release must contain exactly the matching DMG name, size and SHA-256 digest") end
  ' <<< "$EXISTING") || {
    echo "Release $TAG differs from the reviewed revision or notarized DMG; nothing was overwritten." >&2
    exit 1
  }
fi

# The remote tag, rather than target_commitish alone, establishes the release commit.
REMOTE_TAG=$(gh api "repos/$PROJECT/git/matching-refs/tags/$TAG" | jq -ce --arg ref "refs/tags/$TAG" '
  if type != "array" then error("Invalid tag refs") else
    [.[] | select(.ref == $ref)] |
    if length > 1 then error("Duplicate tag refs") else . end end')
if [ "$(jq 'length' <<< "$REMOTE_TAG")" = 1 ]; then
  TAG_KIND=$(jq -er '.[0].object.type' <<< "$REMOTE_TAG")
  TAG_SHA=$(jq -er '.[0].object.sha' <<< "$REMOTE_TAG")
  while [ "$TAG_KIND" = tag ]; do
    TAG_OBJECT=$(gh api "repos/$PROJECT/git/tags/$TAG_SHA")
    TAG_KIND=$(jq -er '.object.type' <<< "$TAG_OBJECT")
    TAG_SHA=$(jq -er '.object.sha' <<< "$TAG_OBJECT")
  done
  [ "$TAG_KIND" = commit ] && [ "$TAG_SHA" = "$REVISION" ] || {
    echo "Remote $TAG does not resolve to reviewed main $REVISION; nothing was changed." >&2
    exit 1
  }
elif [ "$RELEASE_STATE" != missing ] && [ "$RELEASE_STATE" != empty-draft ]; then
  echo "Existing release $TAG has no remote tag; refusing recovery." >&2
  exit 1
fi
REMOTE_MAIN=$(git ls-remote --exit-code origin refs/heads/main | awk '{print $1}')
if [ "$PREVIEW" = true ]; then
  [ "$(jq 'length' <<< "$REMOTE_TAG")" = 1 ] &&
  jq -e --arg main "$REMOTE_MAIN" '.parents[0].sha == $main' <<< "$PUBLIC_COMMIT" > /dev/null || {
    echo "Remote preview tag is missing or main moved; refusing publication." >&2; exit 1;
  }
fi
[ "$PREVIEW" = true ] || [ "$REMOTE_MAIN" = "$REVISION" ] || {
  echo "Remote main no longer equals reviewed main $REVISION; refusing publication." >&2
  exit 1
}

if [ "$PREVIEW" = false ]; then
step "Tagging $TAG"
if ! git rev-parse -q --verify "refs/tags/$TAG" > /dev/null; then
  git tag -a "$TAG" "$REVISION" -m "Tivano $VERSION"
fi
if [ "$(jq 'length' <<< "$REMOTE_TAG")" = 0 ]; then
  git push origin "refs/tags/$TAG"
fi

fi

case "$RELEASE_STATE" in
  empty-draft)
    step "Uploading to the empty draft"
    gh release upload "$TAG" "$DMG#$ASSET_LABEL" -R "$PROJECT"
    ;;
  missing)
    step "Creating the draft"
    gh release create "$TAG" "$DMG#$ASSET_LABEL" --draft \
      -R "$PROJECT" --verify-tag --target "$REVISION" \
      --title "$TITLE" --notes-file "$NOTES" ${CREATE_FLAGS[@]+"${CREATE_FLAGS[@]}"}
    ;;
esac
if [ "$RELEASE_STATE" != published ]; then
  # Re-read after upload: a timeout may have succeeded, and no second asset is allowed.
  READY=$(gh api "repos/$PROJECT/releases" --paginate --slurp | jq -ce --arg tag "$TAG" '
    add | [.[] | select(.tag_name == $tag)] |
    if length == 1 then .[0] else error("Expected exactly one release") end')
  jq -e --arg revision "$REVISION" --arg name "$DMG_NAME" --argjson size "$DMG_SIZE" \
    --argjson preview "$PREVIEW" --arg digest "$DMG_DIGEST" '
    .target_commitish == $revision and .draft == true and .prerelease == $preview and
    (.assets | length) == 1 and .assets[0].name == $name and
    .assets[0].size == $size and .assets[0].digest == $digest and .assets[0].state == "uploaded"
  ' <<< "$READY" > /dev/null || {
    echo "Uploaded draft does not match the reviewed revision and DMG; retained without publishing." >&2
    exit 1
  }
  step "Publishing the matching draft"
  gh release edit "$TAG" -R "$PROJECT" --draft=false "${FINAL_FLAGS[@]}" \
    --verify-tag --title "$TITLE" --notes-file "$NOTES"
else
  step "Matching release already published; resuming feed and mirror"
fi

printf '\nPublished: https://github.com/%s/releases/tag/%s\n' "$PROJECT" "$TAG"
if [ "$PREVIEW" = true ]; then
  echo "Previews are GitHub-only; no update feed or mirror is published."
  exit 0
fi
step "Publishing the static update feed"
if ! python3 scripts/publish_update_feed.py --tag "$TAG" --dmg "$DMG"; then
  echo "GitHub release $TAG is published; static feed failed. Rerun publish_release.sh with this same DMG to resume." >&2
  exit 1
fi

step "Syncing the domestic update mirror"
# Generate from this exact release, not a possibly stale asynchronous Pages deployment.
if ! python3 scripts/publish_update_feed.py --tag "$TAG" --dmg "$DMG" --output "$MIRROR_FEED"; then
  echo "GitHub release $TAG is published; mirror feed generation failed. Rerun publish_release.sh with this same DMG to resume." >&2
  exit 1
fi
MIRROR_HOST="${TIVANO_MIRROR_HOST:-tivano-mirror}"
MIRROR_ARGS=(--host "$MIRROR_HOST" --dmg "$DMG" --feed "$MIRROR_FEED")
MIRROR_VIA="${TIVANO_MIRROR_VIA:-}"
if [ -n "$MIRROR_VIA" ]; then MIRROR_ARGS+=(--via "$MIRROR_VIA"); fi
if ! python3 scripts/publish_update_mirror.py "${MIRROR_ARGS[@]}"; then
  echo "GitHub release is already published, but the mirror sync failed. Retry publish_update_mirror.py, or rerun publish_release.sh with this same DMG to resume; do not delete the release." >&2
  exit 1
fi
