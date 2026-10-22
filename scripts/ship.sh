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
  git -c core.quotePath=false worktree list --porcelain | awk -v ref="refs/heads/$1" '
    /^worktree / { path = substr($0, 10) }
    $0 == "branch " ref { print path; exit }'
}
version_in() { git show "$1:config/$2.xcconfig" | sed -nE 's/^MARKETING_VERSION[[:space:]]*=[[:space:]]*([0-9.]+)[[:space:]]*$/\1/p'; }
newer() { [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" = "$1" ]; }

COMMON_DIR=$(cd "$(git rev-parse --git-common-dir)" && pwd -P)
TEMP_ROOT="$COMMON_DIR/tivano-worktrees.noindex"
[ ! -L "$TEMP_ROOT" ] || fail "Temporary root is a symlink: $TEMP_ROOT"
if [ -e "$TEMP_ROOT" ]; then
  [ -d "$TEMP_ROOT" ] || fail "Temporary root is not a directory: $TEMP_ROOT"
else
  mkdir "$TEMP_ROOT"
fi
root_identity() {
  python3 - "${1:-$TEMP_ROOT}" <<'PY'
import os, sys
path = sys.argv[1]
if os.path.realpath(path) != path or not os.path.isdir(path):
    sys.exit("Unsafe temporary root: " + path)
stat = os.stat(path)
print(f"{stat.st_dev}:{stat.st_ino}")
PY
}
ROOT_ID=$(root_identity) || fail "Invalid temporary root."
assert_temp_root() {
  [ "$(root_identity)" = "$ROOT_ID" ] || fail "Temporary root identity changed."
}

# Serialize releases sharing the common-dir; never reclaim an interrupted lock blindly.
SHIP_LOCK="$TEMP_ROOT/ship.lock"
mkdir "$SHIP_LOCK" 2>/dev/null || fail "Another release or an interrupted lock exists at $SHIP_LOCK. Inspect it before retrying."
LOCK_ID=$(root_identity "$SHIP_LOCK") || fail "Invalid release lock."
release_lock() {
  python3 - "$SHIP_LOCK" "$LOCK_ID" <<'PY'
import os, sys
path, identity = sys.argv[1:]
try:
    stat = os.lstat(path)
    if not os.path.islink(path) and f"{stat.st_dev}:{stat.st_ino}" == identity:
        os.rmdir(path)
except OSError as error:
    print(f"Release lock retained at {path}: {error}", file=sys.stderr)
PY
}
trap 'status=$?; trap - EXIT; release_lock; exit "$status"' EXIT

# Check both Git's registration and the on-disk identity, including replacement paths.
worktree_identity() {
  assert_temp_root
  python3 - "$1" "$2" "$COMMON_DIR" <<'PY'
import os, subprocess, sys
path, branch, common = sys.argv[1:]
def git(*args):
    return subprocess.check_output(["git", "-C", path, *args], text=True).strip()
try:
    if os.path.realpath(path) != path or os.path.islink(os.path.join(path, ".git")):
        raise ValueError("symlink or nonphysical path")
    records = subprocess.check_output(["git", "worktree", "list", "--porcelain", "-z"]).split(b"\0\0")
    matches = [r.split(b"\0") for r in records if r.split(b"\0")[0] == os.fsencode("worktree " + path)]
    expected = os.fsencode("branch refs/heads/" + branch) if branch != "detached" else b"detached"
    if len(matches) != 1 or expected not in matches[0] or any(
        f.startswith((b"locked", b"prunable")) for f in matches[0]
    ):
        raise ValueError("unexpected worktree registration")
    if git("rev-parse", "--show-toplevel") != path:
        raise ValueError("unexpected worktree root")
    actual = git("rev-parse", "--git-common-dir")
    if os.path.realpath(os.path.join(path, actual)) != common:
        raise ValueError("different common directory")
    if branch == "detached":
        if subprocess.run(["git", "-C", path, "symbolic-ref", "-q", "HEAD"], stdout=subprocess.DEVNULL).returncode != 1:
            raise ValueError("HEAD is not detached")
    elif git("symbolic-ref", "HEAD") != "refs/heads/" + branch:
        raise ValueError("unexpected branch")
    admin = os.path.realpath(os.path.join(path, git("rev-parse", "--git-dir")))
    print(":".join(str(n) for p in (path, os.path.join(path, ".git"), admin)
                   for n in (os.lstat(p).st_dev, os.lstat(p).st_ino)))
except (OSError, ValueError, subprocess.CalledProcessError) as error:
    sys.exit(f"Unsafe worktree {path}: {error}")
PY
}
assert_clean() {
  local changes
  changes=$(git -C "$1" status --porcelain --untracked-files=all) \
    || fail "Could not inspect worktree changes: $1"
  [ -z "$changes" ] || fail "Worktree has user changes: $1"
}
assert_unused_path() {
  assert_temp_root
  [ ! -e "$1" ] && [ ! -L "$1" ] || fail "Unknown existing path: $1"
  if git -c core.quotePath=false worktree list --porcelain | grep -Fx "worktree $1" > /dev/null; then
    fail "Missing but registered worktree: $1"
  fi
}
DEV_CHECKOUT=$(checkout_of dev)
MAIN_CHECKOUT=$(checkout_of main)
[ -n "$DEV_CHECKOUT" ] || fail "dev needs a local checkout."
DEV_ID=$(worktree_identity "$DEV_CHECKOUT" dev) || fail "Invalid dev checkout."
assert_clean "$DEV_CHECKOUT"
DEV_START=$(git rev-parse dev)
MAIN_START=$(git rev-parse main)
MAIN_ID=""
if [ -n "$MAIN_CHECKOUT" ]; then
  MAIN_ID=$(worktree_identity "$MAIN_CHECKOUT" main) || fail "Invalid main checkout."
  assert_clean "$MAIN_CHECKOUT"
fi

step "Checking main and versions"
git fetch origin --prune --tags --quiet
[ "$(git rev-parse main)" = "$MAIN_START" ] \
  && [ "$MAIN_START" = "$(git rev-parse origin/main)" ] || fail "Local main differs from origin/main or moved. Resolve that first."
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

WORK="$TEMP_ROOT/ship-$VERSION"
MAIN_WORK="$TEMP_ROOT/ship-$VERSION-main"
PREP_WORK="$WORK-prepare-$$"
PREP_OWNED=0
BUILD_OWNED=0
MAIN_OWNED=0
PREP_ID=""
BUILD_ID=""
PREP_COMMIT=""
BUILD_OUTPUTS=""
release_outputs() {
  python3 - "$WORK" "$VERSION" "$1" "${2:-}" <<'PY'
import hashlib, json, os, subprocess, sys
root, version, action, expected = sys.argv[1:]
allowed = {f"build.noindex/Tivano-{version}.dmg"}
allowed.update("build.noindex/public-release/" + name for name in (
    "archive.log", "export.log", "ExportOptions.plist",
    "Tivano.zip.notary-submit.json", f"Tivano-{version}.dmg.notary-submit.json"))
try:
    paths = subprocess.check_output(["git", "-C", root, "ls-files", "--others",
                                    "--ignored", "--exclude-standard", "-z"]).split(b"\0")
    snapshot = {}
    for raw in filter(None, paths):
        name = os.fsdecode(raw)
        path = os.path.join(root, name)
        if name not in allowed or os.path.realpath(path) != path or not os.path.isfile(path):
            sys.exit("Unknown ignored content retained: " + path)
        stat = os.stat(path)
        with open(path, "rb") as stream:
            digest = hashlib.sha256()
            for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                digest.update(chunk)
            digest = digest.hexdigest()
        snapshot[name] = [stat.st_dev, stat.st_ino, stat.st_size, stat.st_mtime_ns, digest]
    encoded = json.dumps(snapshot, sort_keys=True)
    if action == "capture":
        print(encoded)
    elif encoded != expected:
        sys.exit("Release outputs changed; retained: " + root)
    else:
        for name in snapshot:
            os.unlink(os.path.join(root, name))
        for name in ("build.noindex/public-release", "build.noindex"):
            try:
                os.rmdir(os.path.join(root, name))
            except OSError:
                pass
except (OSError, subprocess.CalledProcessError) as error:
    sys.exit(str(error))
PY
}
report_retained() {
  status=$?
  trap - EXIT
  for kind in PREP BUILD MAIN; do
    case "$kind" in
      PREP) owned=$PREP_OWNED; path=$PREP_WORK ;;
      BUILD) owned=$BUILD_OWNED; path=$WORK ;;
      MAIN) owned=$MAIN_OWNED; path=$MAIN_WORK ;;
    esac
    if [ "$owned" = 1 ]; then
      echo "Release exited ($status); retained $kind worktree: $path" >&2
      git -C "$path" rev-parse HEAD >&2 || true
    fi
  done
  release_lock
  exit "$status"
}
trap report_retained EXIT

assert_dev_at() {
  [ "$(worktree_identity "$DEV_CHECKOUT" dev)" = "$DEV_ID" ] \
    && [ "$(checkout_of dev)" = "$DEV_CHECKOUT" ] \
    && [ "$(git rev-parse dev)" = "$1" ] || fail "dev moved during release; refusing to continue."
  assert_clean "$DEV_CHECKOUT"
}
remove_owned_worktree() {
  local path="$1" branch="$2" identity="$3" commit="$4" ignored changes
  changes=$(git -C "$path" status --porcelain --untracked-files=all) || {
    echo "Could not inspect changes; worktree retained: $path" >&2
    return 1
  }
  if [ "$(worktree_identity "$path" "$branch")" != "$identity" ] \
    || [ "$(git -C "$path" rev-parse HEAD)" != "$commit" ] \
    || [ -n "$changes" ]; then
    echo "Changed worktree retained: $path" >&2
    return 1
  fi
  ignored=$(git -C "$path" ls-files --others --ignored --exclude-standard) || {
    echo "Could not inspect ignored contents; worktree retained: $path" >&2
    return 1
  }
  if [ -n "$ignored" ]; then
    # Only outputs observed after our fresh build are eligible, never a reused directory.
    if [ "$path" != "$WORK" ] || [ "$BUILD_OWNED" != 1 ] || [ -z "$BUILD_OUTPUTS" ]; then
      echo "Ignored contents require inspection; worktree retained: $path" >&2
      return 1
    fi
    release_outputs remove "$BUILD_OUTPUTS" || return 1
  fi
  git worktree remove "$path" || {
    echo "Worktree could not be safely removed; retained: $path" >&2
    return 1
  }
}
assert_dev_at "$DEV_START"
if [ -e "$MAIN_WORK" ] || [ -L "$MAIN_WORK" ]; then
  [ "$MAIN_CHECKOUT" = "$MAIN_WORK" ] || fail "Unknown existing main path: $MAIN_WORK"
  [ "$(worktree_identity "$MAIN_WORK" main)" = "$MAIN_ID" ] \
    && [ "$(git -C "$MAIN_WORK" rev-parse HEAD)" = "$MAIN_START" ] || fail "Temporary main identity changed."
else
  assert_unused_path "$MAIN_WORK"
fi

assert_main_at() {
  [ "$(checkout_of main)" = "$MAIN_CHECKOUT" ] \
    && [ "$(worktree_identity "$MAIN_CHECKOUT" main)" = "$MAIN_ID" ] \
    && [ "$(git rev-parse main)" = "$1" ] \
    && [ "$(git -C "$MAIN_CHECKOUT" rev-parse HEAD)" = "$1" ] || fail "main moved or its checkout identity changed."
  assert_clean "$MAIN_CHECKOUT"
}
ensure_main_checkout() {
  [ "$(git rev-parse main)" = "$MAIN_START" ] || fail "Local main moved during release."
  if [ -z "$MAIN_CHECKOUT" ]; then
    [ -z "$(checkout_of main)" ] || fail "main acquired another checkout during release."
    assert_unused_path "$MAIN_WORK"
    git worktree add --quiet "$MAIN_WORK" main
    MAIN_OWNED=1
    MAIN_CHECKOUT="$MAIN_WORK"
    MAIN_ID=$(worktree_identity "$MAIN_CHECKOUT" main) || fail "Invalid temporary main checkout."
  fi
  assert_main_at "$MAIN_START"
}

if [ "$(version_in dev release)" = "$VERSION" ] && git show dev:CHANGELOG.md | grep "^## \[$VERSION\]" > /dev/null; then
  step "dev already prepared for $VERSION"
else
  step "Preparing $VERSION on dev"
  git show dev:CHANGELOG.md | python3 -c '
import re, sys
text = sys.stdin.read()
m = re.search(r"^## \[Unreleased\]\n(.*?)(?=^## \[)", text, re.S | re.M)
sys.exit(0 if m and re.search(r"^### ", m.group(1), re.M) else 1)' \
    || fail "CHANGELOG.md has nothing under ## [Unreleased]. Every merge into dev adds its entry there."
  assert_unused_path "$PREP_WORK"
  assert_dev_at "$DEV_START"
  PREP_BASE=$DEV_START
  git worktree add --detach --quiet "$PREP_WORK" "$PREP_BASE"
  PREP_OWNED=1
  PREP_ID=$(worktree_identity "$PREP_WORK" detached) || fail "Invalid preparation worktree."
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
  assert_dev_at "$PREP_BASE"
  [ "$(worktree_identity "$PREP_WORK" detached)" = "$PREP_ID" ] || fail "Preparation identity changed."
  assert_clean "$PREP_WORK"
  PREP_COMMIT=$(git -C "$PREP_WORK" rev-parse HEAD)
  git -C "$DEV_CHECKOUT" merge --ff-only --quiet "$PREP_COMMIT" \
    || fail "dev moved while preparing; rerun."
  assert_dev_at "$PREP_COMMIT"
  if remove_owned_worktree "$PREP_WORK" detached "$PREP_ID" "$PREP_COMMIT"; then
    PREP_OWNED=0
  fi
fi
DEV_COMMIT=${PREP_COMMIT:-$DEV_START}
assert_dev_at "$DEV_COMMIT"
DEV_TREE=$(git rev-parse "$DEV_COMMIT^{tree}")
# Resolve the public tag to a trusted dev Prepare boundary before any GitHub write.
CREDIT_BASE=$(cd "$DEV_CHECKOUT" && python3 scripts/release_credits.py --range-base)
assert_dev_unchanged() {
  assert_dev_at "$DEV_COMMIT"
}

DMG="$WORK/build.noindex/Tivano-$VERSION.dmg"
if [ -e "$WORK" ] || [ -L "$WORK" ]; then
  BUILD_ID=$(worktree_identity "$WORK" detached) || fail "Invalid existing build worktree."
  [ "$(git -C "$WORK" rev-parse HEAD)" = "$DEV_COMMIT" ] \
    && [ "$(git -C "$WORK" rev-parse 'HEAD^{tree}')" = "$DEV_TREE" ] \
    || fail "Existing build worktree has another commit; retained at $WORK."
  assert_clean "$WORK"
else
  assert_unused_path "$WORK"
fi
if [ -f "$DMG" ] && xcrun stapler validate "$DMG" > /dev/null 2>&1 \
  && [ "$(git -C "$WORK" rev-parse 'HEAD^{tree}')" = "$DEV_TREE" ]; then
  step "Notarized DMG for $VERSION already built"
else
  step "Building and notarizing $VERSION"
  assert_dev_unchanged
  if [ ! -d "$WORK" ]; then
    assert_unused_path "$WORK"
    git worktree add --detach --quiet "$WORK" "$DEV_COMMIT"
    BUILD_OWNED=1
    BUILD_ID=$(worktree_identity "$WORK" detached) || fail "Invalid build worktree."
  fi
  [ "$(worktree_identity "$WORK" detached)" = "$BUILD_ID" ] \
    && [ "$(git -C "$WORK" rev-parse HEAD)" = "$DEV_COMMIT" ] || fail "Build worktree moved."
  assert_clean "$WORK"
  if [ "$BUILD_OWNED" = 1 ]; then
    [ ! -e "$WORK/build.noindex" ] && [ ! -L "$WORK/build.noindex" ] \
      || fail "Unexpected build output path in fresh worktree."
  fi
  (cd "$WORK" && scripts/release.sh)
  if [ "$BUILD_OWNED" = 1 ]; then
    BUILD_OUTPUTS=$(release_outputs capture) || {
      BUILD_OUTPUTS=""
      echo "Build outputs include unknown contents; cleanup will retain $WORK." >&2
    }
  fi
fi

assert_dev_unchanged
[ "$(worktree_identity "$WORK" detached)" = "$BUILD_ID" ] \
  && [ "$(git -C "$WORK" rev-parse HEAD)" = "$DEV_COMMIT" ] || fail "Build worktree identity changed."
assert_clean "$WORK"
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
  assert_dev_unchanged
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
    assert_dev_unchanged
    remote=$(git cat-file blob "$sha" | base64 | tr -d '\n' | jq -Rs '{content: ., encoding: "base64"}' \
      | gh api "repos/$PROJECT/git/blobs" --input - --jq .sha)
    [ "$remote" = "$sha" ] || fail "Uploaded blob $remote does not match $sha."
  done
  assert_dev_unchanged
  TREE=$(jq -n --arg base "$(git rev-parse 'origin/main^{tree}')" --argjson tree "$ENTRIES" '{base_tree: $base, tree: $tree}' \
    | gh api "repos/$PROJECT/git/trees" --input - --jq .sha)
  [ "$TREE" = "$DEV_TREE" ] || fail "Remote tree $TREE does not match dev's $DEV_TREE."
  assert_dev_unchanged
  COMMIT=$(jq -n --arg m "Release Tivano $VERSION" --arg t "$TREE" --arg p "$(git rev-parse origin/main)" \
    '{message: $m, tree: $t, parents: [$p]}' | gh api "repos/$PROJECT/git/commits" --input - --jq .sha)
  assert_dev_unchanged
  gh api "repos/$PROJECT/git/refs" -f ref="refs/heads/$BRANCH" -f sha="$COMMIT" > /dev/null
  fi
  NOTES=$(git show "$DEV_COMMIT:CHANGELOG.md" | python3 -c '
import re, sys
m = re.search(r"^## \[" + re.escape(sys.argv[1]) + r"\][^\n]*\n(.*?)(?=^## \[)", sys.stdin.read(), re.S | re.M)
print(m.group(1).strip())' "$VERSION")
  if [ -z "$PR" ]; then
    assert_dev_unchanged
    PR=$(gh pr create -R "$PROJECT" --base main --head "$BRANCH" --title "Release Tivano $VERSION" \
      --body "Makes main equal local dev ($DEV_TREE) for $TAG."$'\n\n'"$NOTES")
  fi
  echo "$PR"
  # The squash commit is main's only record of who wrote the release, so carry every
  # outside author and co-author on dev since the previous release as a trailer.
  COAUTHORS=$(git log --no-merges --format='%an <%ae>%n%(trailers:key=Co-authored-by,valueonly)' \
    "$CREDIT_BASE..$DEV_COMMIT" | awk -v me="<$(git log -1 --format=%ae "$DEV_COMMIT")>" '
      { gsub(/^[ \t]+|[ \t]+$/, ""); l = tolower($0) }
      l == "" || index(l, tolower(me)) || l ~ /@(anthropic\.com|localhost)>$/ || seen[l]++ { next }
      { print "Co-authored-by: " $0 }')
  assert_dev_unchanged
  gh pr merge "$PR" -R "$PROJECT" --squash --match-head-commit "$COMMIT" \
    --subject "Release Tivano $VERSION (#${PR##*/})" --body "$COAUTHORS"
  git fetch origin --prune --quiet
  [ "$(git rev-parse 'origin/main^{tree}')" = "$DEV_TREE" ] || fail "Merged main does not match dev's tree."
fi

assert_dev_unchanged
ensure_main_checkout
step "Fast-forwarding local main"
PUBLISH_COMMIT=$(git rev-parse origin/main)
[ "$(git rev-parse "$PUBLISH_COMMIT^{tree}")" = "$DEV_TREE" ] || fail "main no longer matches dev."
assert_main_at "$MAIN_START"
git -C "$MAIN_CHECKOUT" merge --ff-only --quiet "$PUBLISH_COMMIT"

assert_dev_unchanged
assert_main_at "$PUBLISH_COMMIT"
[ "$(worktree_identity "$WORK" detached)" = "$BUILD_ID" ] \
  && [ "$(git -C "$WORK" rev-parse HEAD)" = "$DEV_COMMIT" ] || fail "Build worktree identity changed."
assert_clean "$WORK"
step "Publishing $TAG"
"$MAIN_CHECKOUT/scripts/publish_release.sh" "$DMG"

step "Cleaning up"
if [ -n "$COMMIT" ]; then
  cleanup_release_head() (
    # Read-only API failures cannot mean absence. A missing exact ref is idempotent.
    CURRENT=$(gh api "repos/$PROJECT/git/matching-refs/heads/$BRANCH" | \
      jq -ce --arg ref "refs/heads/$BRANCH" '
        if type != "array" then error("Invalid cleanup refs") else
          [.[] | select(.ref == $ref)] |
          if length > 1 then error("Duplicate cleanup refs") else . end end') || return 1
    [ "$(jq 'length' <<< "$CURRENT")" != 0 ] || return 0
    [ "$(jq -r '.[0].object.type' <<< "$CURRENT")" = commit ] &&
    [ "$(jq -r '.[0].object.sha' <<< "$CURRENT")" = "$COMMIT" ] || {
      echo "Release head refs/heads/$BRANCH moved; retained without deletion." >&2
      return 1
    }
    # Keep the installed hook; older guards may refuse this optional cleanup.
    TIVANO_CLEANUP_REF="refs/heads/$BRANCH" TIVANO_CLEANUP_SHA="$COMMIT" \
      git push origin ":refs/heads/$BRANCH"
  )
  if ! cleanup_release_head; then
    echo "Release $TAG is fully published; cleanup remains for refs/heads/$BRANCH (expected $COMMIT). No moved ref was intentionally deleted." >&2
  fi
fi
if [ "$BUILD_OWNED" = 1 ]; then
  if remove_owned_worktree "$WORK" detached "$BUILD_ID" "$DEV_COMMIT"; then
    BUILD_OWNED=0
  fi
else
  echo "Reused build worktree retained at $WORK."
fi
if [ "$MAIN_OWNED" = 1 ]; then
  if remove_owned_worktree "$MAIN_WORK" main "$MAIN_ID" "$PUBLISH_COMMIT"; then
    MAIN_OWNED=0
  fi
else
  echo "Existing main checkout retained at $MAIN_CHECKOUT."
fi
printf '\nShipped %s from dev %s. Update Release through its own updater.\n' "$TAG" "$DEV_COMMIT"
