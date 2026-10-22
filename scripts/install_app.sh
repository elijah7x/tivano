#!/bin/bash
# Install a previously verified edition without quitting or launching anything.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
APP=${1:?Usage: install_app.sh <built.app> <dev|release>}
EDITION=${2:?Usage: install_app.sh <built.app> <dev|release>}
case "$EDITION" in
  dev) NAME='Tivano Dev'; IDENTIFIER='dev.tivano.Tivano.dev' ;;
  release) NAME='Tivano'; IDENTIFIER='dev.tivano.Tivano' ;;
  *) echo 'Invalid edition' >&2; exit 1 ;;
esac
COMMON_DIR=$(git -C "$ROOT" rev-parse --path-format=absolute --git-common-dir)
COMMON_DIR=$(cd "$COMMON_DIR" && pwd -P)
SOURCE_ROOT=$(dirname "$COMMON_DIR")
ARTIFACTS_ROOT=${TIVANO_ARTIFACTS_ROOT-$(dirname "$SOURCE_ROOT")}
case "$ARTIFACTS_ROOT" in
  /*) ;;
  *) echo 'TIVANO_ARTIFACTS_ROOT must be an absolute directory path.' >&2; exit 1 ;;
esac
physical_directory() {
  if [ -d "$1" ]; then
    (cd "$1" && pwd -P)
  elif [ -e "$1" ] || [ -L "$1" ]; then
    echo "Not a usable directory: $1" >&2
    return 1
  else
    local parent leaf
    parent=$(physical_directory "$(dirname "$1")") || return 1
    leaf=$(basename "$1")
    case "$leaf" in
      .) printf '%s\n' "$parent" ;;
      ..) dirname "$parent" ;;
      *) printf '%s/%s\n' "${parent%/}" "$leaf" ;;
    esac
  fi
}
external_directory() {
  local directory
  directory=$(physical_directory "$1") || return 1
  case "$directory" in
    "$ROOT"|"$ROOT"/*|"$SOURCE_ROOT"|"$SOURCE_ROOT"/*)
      echo 'Artifact paths must be outside the current and long-lived source checkouts.' >&2
      return 1 ;;
  esac
  printf '%s\n' "$directory"
}
ARTIFACTS_ROOT=$(external_directory "$ARTIFACTS_ROOT")
BACKUP_ROOT=$(external_directory "$ARTIFACTS_ROOT/private-artifacts/install-backups")
TARGET="/Applications/$NAME.app"
if ps -axo command= | grep -F "$TARGET/Contents/MacOS/" | grep -v grep >/dev/null; then
  echo "$NAME is running. Quit it explicitly; it was not replaced." >&2
  exit 1
fi
codesign --verify --deep --strict -R="identifier \"$IDENTIFIER\"" "$APP"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
[[ "$VERSION" = "$("$ROOT/scripts/version.sh" "$EDITION")" ]] || { echo 'Source app does not match the requested edition version' >&2; exit 1; }
STAGE=$(mktemp -d '/Applications/.tivano-install.XXXXXX')
trap 'if [ -e "$STAGE/previous.app" ]; then
  echo "Original app preserved at $STAGE/previous.app; rollback did not finish." >&2
else
  rm -rf "$STAGE"
fi' EXIT
ditto "$APP" "$STAGE/$NAME.app"
codesign --verify --deep --strict "$STAGE/$NAME.app"
# Check again after copying in case the owner launched the target in the meantime.
if ps -axo command= | grep -F "$TARGET/Contents/MacOS/" | grep -v grep >/dev/null; then
  echo "$NAME was launched during staging; it was not replaced." >&2
  exit 1
fi
BACKUP="$BACKUP_ROOT/$(date '+%Y%m%d-%H%M%S')-$$/$NAME.app"
if [ -e "$TARGET" ]; then
  mkdir -p "$(dirname "$BACKUP")"
  # The backup may be on another volume; keep the original for same-volume rollback.
  ditto "$TARGET" "$BACKUP"
  codesign --verify --deep --strict "$BACKUP"
  if ps -axo command= | grep -F "$TARGET/Contents/MacOS/" | grep -v grep >/dev/null; then
    echo "$NAME was launched during backup; it was not replaced." >&2
    exit 1
  fi
  mv "$TARGET" "$STAGE/previous.app"
fi
if ! mv "$STAGE/$NAME.app" "$TARGET"; then
  [ ! -e "$STAGE/previous.app" ] || mv "$STAGE/previous.app" "$TARGET"
  exit 1
fi
if ! codesign --verify --deep --strict "$TARGET"; then
  mv "$TARGET" "$STAGE/$NAME.app"
  [ ! -e "$STAGE/previous.app" ] || mv "$STAGE/previous.app" "$TARGET"
  exit 1
fi
rm -rf "$STAGE/previous.app"
echo "Installed $TARGET ($("$ROOT/scripts/version.sh" "$EDITION" display)); not launched."
