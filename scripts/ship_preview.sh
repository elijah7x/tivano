#!/bin/bash
# Publishes a GitHub-only prerelease that no update channel offers to stable users.
# Run scripts/ship_preview.sh from a clean local preview branch. Never installs.
set -euo pipefail

cd "$(dirname "$0")/.."
PROJECT="elijah7x/tivano"
step() { printf '\n==> %s\n' "$1"; }
fail() { echo "$1" >&2; exit 1; }
[ "$#" = 0 ] || fail "Usage: scripts/ship_preview.sh"
[ "$(git branch --show-current)" = preview ] || fail "Run from local branch preview."
[ -z "$(git status --porcelain)" ] || fail "Commit pending changes before shipping."
VERSION=$(scripts/version.sh release full)
[[ "$VERSION" =~ ^([0-9]+\.[0-9]+\.[0-9]+)-preview\.([1-9][0-9]*)$ ]] || fail "Release version must be X.Y.Z-preview.N."
TITLE="Tivano ${BASH_REMATCH[1]} Preview ${BASH_REMATCH[2]}"
TAG="v$VERSION"
PREVIEW_HEAD=$(git rev-parse HEAD)
TREE=$(git rev-parse 'HEAD^{tree}')
assert_preview() {
  [ "$(git branch --show-current)" = preview ] &&
  [ "$(git rev-parse HEAD)" = "$PREVIEW_HEAD" ] &&
  [ -z "$(git status --porcelain)" ] || fail "Preview checkout changed; artifacts retained."
}
require_new_tag() {
  if git show-ref --verify --quiet "refs/tags/$TAG"; then fail "$TAG already exists locally."; fi
  local refs
  refs=$(git ls-remote origin "refs/tags/$TAG") || fail "Could not read remote tags."
  [ -z "$refs" ] || fail "$TAG already exists remotely."
}
require_new_tag
NOTES=$(mktemp -t tivano-preview-notes)
trap 'rm -f "$NOTES"' EXIT
python3 - "$VERSION" > "$NOTES" <<'PY'
import re, sys
from pathlib import Path
text = Path('CHANGELOG.md').read_text()
m = re.search(r'^## \[' + re.escape(sys.argv[1]) + r'\] - [0-9]{4}-[0-9]{2}-[0-9]{2}\s*\n(.*?)(?=^## |\Z)', text, re.M | re.S)
if not m or not m[1].strip():
    sys.exit('Missing dated preview changelog section or empty release notes.')
print(m[1].strip())
PY
step "Fetching origin"
git fetch origin --prune --quiet
step "Building $TITLE"
scripts/release.sh
assert_preview
require_new_tag
step "Creating the public preview commit"
REMOTE_MAIN=$(git ls-remote --exit-code origin refs/heads/main | awk '{print $1}')
[ -n "$REMOTE_MAIN" ] || fail "Remote main is missing."
# Fetch its object if main advanced while the notarized build was running.
git fetch --quiet origin "$REMOTE_MAIN"
assert_preview
PUBLIC_COMMIT=$(printf '%s\n' "$TITLE" | git commit-tree "$TREE" -p "$REMOTE_MAIN")
git tag -a "$TAG" "$PUBLIC_COMMIT" -m "$TITLE"
step "Pushing $TAG to $PROJECT"
git push origin "refs/tags/$TAG"
step "Publishing $TITLE"
scripts/publish_release.sh "build.noindex/Tivano-$VERSION.dmg"
printf '\nShipped %s from preview %s. GitHub-only prerelease.\n' "$TAG" "$PREVIEW_HEAD"
