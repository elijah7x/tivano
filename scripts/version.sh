#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
EDITION=${1:-release}
case "$EDITION" in dev|release) ;; *) echo 'Usage: version.sh [dev|release] [display|full]' >&2; exit 1 ;; esac
VERSION=$(awk -F= '/^MARKETING_VERSION[[:space:]]*=/ {gsub(/[[:space:]]/, "", $2); print $2}' "$ROOT/config/$EDITION.xcconfig")
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'Invalid numeric version' >&2; exit 1; }
FULL=$(awk -F= '/^TIVANO_RELEASE_VERSION[[:space:]]*=/ {gsub(/[[:space:]]/, "", $2); print $2}' "$ROOT/config/$EDITION.xcconfig")
if [ -n "$FULL" ] && [ "$FULL" != '$(MARKETING_VERSION)' ]; then
  [[ "$FULL" =~ ^([0-9]+\.[0-9]+\.[0-9]+)-preview\.[1-9][0-9]*$ ]] && [ "${BASH_REMATCH[1]}" = "$VERSION" ] || {
    echo 'Invalid full release version or mismatched numeric core' >&2; exit 1;
  }
else
  FULL="$VERSION"
fi
if [ "${2:-}" = full ]; then printf '%s\n' "$FULL"; exit 0; fi
if [ "${2:-}" = display ] && [ "$EDITION" = dev ]; then printf 'dev-%s\n' "$VERSION"; else printf '%s\n' "$VERSION"; fi
