#!/bin/bash
#
# Releases dev exactly as it stands, in one command:
#   1. Release takes Dev's version and CHANGELOG's ## [Unreleased] becomes that
#      version, in one "Prepare Tivano x.y.z" commit on local dev.
#   2. scripts/release.sh builds, notarizes and packages that commit.
#   3. A GitHub pull request turns main into dev's exact tree and is squash-merged.
#   4. Local main fast-forwards and scripts/publish_release.sh tags and publishes the DMG.
#
#   scripts/ship.sh
#
# The release cannot drift from dev: it stops unless Dev's version is newer than
# the last v* tag, and unless main's tree equals dev's after the merge. Each step
# skips when already done, so a failed run can be repeated. Never installs, quits
# or launches an app; Release is updated through its own updater.
set -euo pipefail

cd "$(dirname "$0")/.."
PROJECT="elijah7x/tivano"
step() { printf '\n==> %s\n' "$1"; }
fail() { echo "$1" >&2; exit 1; }

checkout_of() {
  git worktree list --porcelain | awk -v ref="refs/heads/$1" '
    /^worktree / { path = substr($0, 10) }
    $0 == "branch " ref { print path; exit }'
}
version_in() { git show "$1:config/$2.xcconfig" | sed -nE 's/^MARKETING_VERSION[[:space:]]*=[[:space:]]*([0-9.]+)[[:space:]]*$/\1/p'; }
newer() { [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" = "$1" ]; }

DEV_CHECKOUT=$(checkout_of dev)
MAIN_CHECKOUT=$(checkout_of main)
[ -n "$DEV_CHECKOUT" ] && [ -n "$MAIN_CHECKOUT" ] || fail "dev and main each need a local checkout."
[ -z "$(git -C "$DEV_CHECKOUT" status --porcelain)" ] || fail "The dev checkout has uncommitted changes."
[ -z "$(git -C "$MAIN_CHECKOUT" status --porcelain)" ] || fail "The main checkout has uncommitted changes."

step "Checking main and versions"
git fetch origin --prune --tags --quiet
[ "$(git rev-parse main)" = "$(git rev-parse origin/main)" ] || fail "Local main differs from origin/main. Resolve that first."
VERSION=$(version_in dev dev)
TAG="v$VERSION"
# Only tags in main's history count; tags inherited from upstream Droppy do not.
LAST=$(git tag --merged origin/main -l 'v[0-9]*' --sort=-v:refname | head -1)
if git rev-parse -q --verify "refs/tags/$TAG" > /dev/null; then
  [ "$(git rev-parse "$TAG^{tree}")" = "$(git rev-parse "dev^{tree}")" ] \
    || fail "$TAG already exists for other code. Merge into dev, which advances Dev's version, then ship."
elif ! newer "$VERSION" "${LAST#v}"; then
  fail "Dev is $VERSION, not newer than $LAST. Every merge into dev advances Dev's version; fix that, not Release."
fi

WORK="$DEV_CHECKOUT-worktrees/ship-$VERSION"
PREP_WORK="$WORK-prepare-$$"
PREP_OWNED=0
BUILD_OWNED=0
cleanup_preparation() {
  status=$?
  trap - EXIT
  if [ "$PREP_OWNED" = 1 ]; then
    echo "Preparation exited ($status); owned worktree: $PREP_WORK" >&2
    if git worktree list --porcelain | awk -v path="$PREP_WORK" '
      $0 == "worktree " path { found = 1 } END { exit !found }'; then
      git -C "$PREP_WORK" rev-parse HEAD >&2 || true
      git -C "$PREP_WORK" diff --stat >&2 || true
      git worktree remove --force "$PREP_WORK" \
        || echo "Cleanup failed; preparation worktree retained at $PREP_WORK." >&2
    elif [ -e "$PREP_WORK" ] || [ -L "$PREP_WORK" ]; then
      echo "Unregistered preparation path retained for inspection: $PREP_WORK" >&2
    fi
  fi
  exit "$status"
}
trap cleanup_preparation EXIT

if [ "$(version_in dev release)" = "$VERSION" ] && git show dev:CHANGELOG.md | grep -q "^## \[$VERSION\]"; then
  step "dev already prepared for $VERSION"
else
  step "Preparing $VERSION on dev"
  git show dev:CHANGELOG.md | python3 -c '
import re, sys
text = sys.stdin.read()
m = re.search(r"^## \[Unreleased\]\n(.*?)(?=^## \[)", text, re.S | re.M)
sys.exit(0 if m and re.search(r"^### ", m.group(1), re.M) else 1)' \
    || fail "CHANGELOG.md has nothing under ## [Unreleased]. Every merge into dev adds its entry there."
  [ ! -e "$PREP_WORK" ] && [ ! -L "$PREP_WORK" ] || fail "Preparation path already exists: $PREP_WORK"
  PREP_BASE=$(git rev-parse dev)
  PREP_OWNED=1
  git worktree add --detach --quiet "$PREP_WORK" "$PREP_BASE"
  (
    cd "$PREP_WORK"
    python3 scripts/set_version.py release catch-up-dev
    THANKS=$(python3 scripts/release_credits.py | python3 -c 'import sys; print(sys.stdin.read().strip())')
    [ -n "$THANKS" ] || THANKS="- No outside contributors."
    python3 - "$VERSION" "$(date +%F)" "$THANKS" <<'PY'
import re, sys
from pathlib import Path
version, day, thanks = sys.argv[1:]
path = Path("CHANGELOG.md")
text = path.read_text()
m = re.search(r"^## \[Unreleased\]\n(.*?)(?=^## \[)", text, re.S | re.M)
body = m.group(1).strip()
if "### Thanks" not in body:
    body += "\n\n" + (thanks if thanks.startswith("### Thanks\n") else "### Thanks\n\n" + thanks)
path.write_text(text[:m.start()] + f"## [Unreleased]\n\n## [{version}] - {day}\n\n{body}\n\n" + text[m.end():])
PY
    git add config/release.xcconfig CHANGELOG.md
    git commit --quiet -m "Prepare Tivano $VERSION" -m "Release takes Dev's version; the Unreleased changelog becomes $VERSION."
  )
  [ "$(git rev-parse dev)" = "$PREP_BASE" ] || fail "dev moved while preparing; rerun."
  git -C "$DEV_CHECKOUT" merge --ff-only --quiet "$(git -C "$PREP_WORK" rev-parse HEAD)" \
    || fail "dev moved while preparing; rerun."
  [ "$(git rev-parse dev)" = "$(git -C "$PREP_WORK" rev-parse HEAD)" ] \
    || fail "dev moved while preparing; rerun."
  git worktree remove --force "$PREP_WORK"
  PREP_OWNED=0
fi
DEV_COMMIT=$(git rev-parse dev)
DEV_TREE=$(git rev-parse "dev^{tree}")

DMG="$WORK/build.noindex/Tivano-$VERSION.dmg"
if [ -e "$WORK" ] || [ -L "$WORK" ]; then
  [ ! -L "$WORK" ] || fail "Refusing existing symlink at $WORK."
  git worktree list --porcelain | awk -v path="$WORK" '
    /^worktree / { matching = ($0 == "worktree " path) }
    matching && $0 == "detached" { found = 1 } END { exit !found }' \
    || fail "Unknown existing path at $WORK; inspect it before rerunning."
  [ "$(git -C "$WORK" rev-parse 'HEAD^{tree}')" = "$DEV_TREE" ] \
    || fail "Existing build worktree has another tree; retained at $WORK."
  [ -z "$(git -C "$WORK" status --porcelain --untracked-files=all)" ] \
    || fail "Existing build worktree has user changes; retained at $WORK."
fi
if [ -f "$DMG" ] && xcrun stapler validate "$DMG" > /dev/null 2>&1 \
  && [ "$(git -C "$WORK" rev-parse 'HEAD^{tree}')" = "$DEV_TREE" ]; then
  step "Notarized DMG for $VERSION already built"
else
  step "Building and notarizing $VERSION"
  if [ ! -d "$WORK" ]; then
    git worktree add --detach --quiet "$WORK" "$DEV_COMMIT"
    BUILD_OWNED=1
  fi
  (cd "$WORK" && scripts/release.sh)
fi

BRANCH="release/$TAG"
MAIN_COMMIT=$(git rev-parse origin/main)
# Matching refs returns an array even for absence; transport/auth failures still fail.
# https://docs.github.com/en/rest/git/refs#list-matching-references
REFS=$(gh api "repos/$PROJECT/git/matching-refs/heads/$BRANCH")
REF=$(jq -ce --arg ref "refs/heads/$BRANCH" '
  if type != "array" then error("Invalid refs response")
  elif any(.[]; (.ref | type) != "string" or (.object.sha | type) != "string")
  then error("Invalid ref record") else
    [.[] | select(.ref == $ref)] |
    if length > 1 then error("Duplicate release refs") else . end
  end' <<< "$REFS")
COMMIT=$(jq -r '.[0].object.sha // empty' <<< "$REF")
[ "$(jq 'length' <<< "$REF")" = 0 ] || \
  jq -e '.[0].object.type == "commit" and (.[0].object.sha | type == "string" and length > 0)' <<< "$REF" > /dev/null
# Do not filter by base: a release PR aimed at the wrong base must be rejected.
PRS=$(gh api -X GET "repos/$PROJECT/pulls" -f state=all -f head="${PROJECT%%/*}:$BRANCH" \
  -f per_page=100 --paginate --slurp | jq -ce '
    if type != "array" or length == 0 or any(.[]; type != "array")
    then error("Invalid PR pages") else add end')
[ "$(jq 'length' <<< "$PRS")" -le 1 ] || fail "Multiple PRs exist for $BRANCH; resolve them first."
PR=""
PR_STATE=""
PR_MERGED=false
if [ "$(jq 'length' <<< "$PRS")" = 1 ]; then
  PR_NUMBER=$(jq -er '.[0].number | select(type == "number")' <<< "$PRS")
  PR_DATA=$(gh api "repos/$PROJECT/pulls/$PR_NUMBER")
  jq -e --arg project "$PROJECT" --arg branch "$BRANCH" '
    .base.ref == "main" and .base.repo.full_name == $project and
    .head.ref == $branch and .head.repo.full_name == $project and
    (.state == "open" or .state == "closed") and (.merged | type == "boolean")
  ' <<< "$PR_DATA" > /dev/null || fail "Release PR #$PR_NUMBER has an unexpected base, head or state."
  PR_HEAD=$(jq -er '.head.sha | select(type == "string" and length > 0)' <<< "$PR_DATA")
  [ -z "$COMMIT" ] || [ "$COMMIT" = "$PR_HEAD" ] || fail "Release ref and PR head differ."
  PR_STATE=$(jq -r '.state' <<< "$PR_DATA")
  PR_MERGED=$(jq -r '.merged' <<< "$PR_DATA")
  [ "$PR_STATE" != closed ] || [ "$PR_MERGED" = true ] || fail "Release PR #$PR_NUMBER was closed without merging."
  [ -n "$COMMIT" ] || [ "$PR_MERGED" = true ] || fail "Open release PR has no release ref."
  COMMIT="$PR_HEAD"
  PR="https://github.com/$PROJECT/pull/$PR_NUMBER"
fi
if [ -n "$COMMIT" ]; then
  RELEASE_COMMIT=$(gh api "repos/$PROJECT/git/commits/$COMMIT")
  jq -e --arg tree "$DEV_TREE" '
    .tree.sha == $tree and (.parents | length) == 1 and
    (.parents[0].sha | type == "string" and length > 0)
  ' <<< "$RELEASE_COMMIT" > /dev/null || fail "Existing release ref/PR has another tree or unexpected parents."
  RELEASE_BASE=$(jq -r '.parents[0].sha' <<< "$RELEASE_COMMIT")
  git merge-base --is-ancestor "$RELEASE_BASE" origin/main \
    || fail "Existing release commit is not based on main's history."
  if [ "$PR_MERGED" = true ]; then
    MERGED_SHA=$(jq -er '.merge_commit_sha | select(type == "string" and length > 0)' <<< "$PR_DATA")
    MERGED_COMMIT=$(gh api "repos/$PROJECT/git/commits/$MERGED_SHA")
    jq -e --arg tree "$DEV_TREE" --arg base "$RELEASE_BASE" '
      .tree.sha == $tree and (.parents | length) == 1 and .parents[0].sha == $base
    ' <<< "$MERGED_COMMIT" > /dev/null || fail "Merged release PR does not satisfy the single-commit exact-tree contract."
    git merge-base --is-ancestor "$MERGED_SHA" origin/main || fail "Merged release PR is not in main."
    [ "$(git rev-parse 'origin/main^{tree}')" = "$DEV_TREE" ] || fail "Merged release PR exists but main no longer matches dev."
  elif [ "$(git rev-parse 'origin/main^{tree}')" != "$DEV_TREE" ] || [ "$PR_STATE" = open ]; then
    [ "$RELEASE_BASE" = "$MAIN_COMMIT" ] || fail "main moved since the release ref was created; refusing to rewrite it."
  fi
fi

if [ "$(git rev-parse 'origin/main^{tree}')" = "$DEV_TREE" ]; then
  [ "$PR_STATE" != open ] || fail "main matches dev but the release PR is still open; resolve that state first."
  step "main already matches dev"
else
  step "Opening a pull request that makes main equal dev"
  if [ -z "$COMMIT" ]; then
  ENTRIES=$(git diff --no-renames --name-status -z origin/main "$DEV_COMMIT" | python3 -c '
import json, subprocess, sys
fields = sys.stdin.buffer.read().split(b"\0")
out = []
for status, path in zip(fields[0::2], fields[1::2]):
    path = path.decode()
    if status == b"D":
        out.append({"path": path, "mode": "100644", "type": "blob", "sha": None})
        continue
    mode, kind, sha = subprocess.check_output(["git", "ls-tree", sys.argv[1], "--", path], text=True).split("\t")[0].split()
    if kind != "blob":
        sys.exit(f"Unsupported {kind} at {path}")
    out.append({"path": path, "mode": mode, "type": "blob", "sha": sha})
print(json.dumps(out))' "$DEV_COMMIT")
  for sha in $(jq -r '.[] | select(.sha != null) | .sha' <<< "$ENTRIES"); do
    remote=$(git cat-file blob "$sha" | base64 | tr -d '\n' | jq -Rs '{content: ., encoding: "base64"}' \
      | gh api "repos/$PROJECT/git/blobs" --input - --jq .sha)
    [ "$remote" = "$sha" ] || fail "Uploaded blob $remote does not match $sha."
  done
  TREE=$(jq -n --arg base "$(git rev-parse 'origin/main^{tree}')" --argjson tree "$ENTRIES" '{base_tree: $base, tree: $tree}' \
    | gh api "repos/$PROJECT/git/trees" --input - --jq .sha)
  [ "$TREE" = "$DEV_TREE" ] || fail "Remote tree $TREE does not match dev's $DEV_TREE."
  COMMIT=$(jq -n --arg m "Release Tivano $VERSION" --arg t "$TREE" --arg p "$(git rev-parse origin/main)" \
    '{message: $m, tree: $t, parents: [$p]}' | gh api "repos/$PROJECT/git/commits" --input - --jq .sha)
  gh api "repos/$PROJECT/git/refs" -f ref="refs/heads/$BRANCH" -f sha="$COMMIT" > /dev/null
  fi
  NOTES=$(git show "$DEV_COMMIT:CHANGELOG.md" | python3 -c '
import re, sys
m = re.search(r"^## \[" + re.escape(sys.argv[1]) + r"\][^\n]*\n(.*?)(?=^## \[)", sys.stdin.read(), re.S | re.M)
print(m.group(1).strip())' "$VERSION")
  if [ -z "$PR" ]; then
    PR=$(gh pr create -R "$PROJECT" --base main --head "$BRANCH" --title "Release Tivano $VERSION" \
      --body "Makes main equal local dev ($DEV_TREE) for $TAG."$'\n\n'"$NOTES")
  fi
  echo "$PR"
  gh pr merge "$PR" -R "$PROJECT" --squash --match-head-commit "$COMMIT" \
    --subject "Release Tivano $VERSION (#${PR##*/})" --body ""
  git fetch origin --prune --quiet
  [ "$(git rev-parse 'origin/main^{tree}')" = "$DEV_TREE" ] || fail "Merged main does not match dev's tree."
fi

step "Fast-forwarding local main"
git -C "$MAIN_CHECKOUT" merge --ff-only --quiet origin/main

step "Publishing $TAG"
"$MAIN_CHECKOUT/scripts/publish_release.sh" "$DMG"

step "Cleaning up"
if [ "$BUILD_OWNED" = 1 ]; then
  git worktree remove --force "$WORK"
else
  echo "Reused build worktree retained at $WORK."
fi
printf '\nShipped %s from dev %s. Update Release through its own updater.\n' "$TAG" "$DEV_COMMIT"
