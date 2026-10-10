#!/bin/bash
# Builds, signs, notarizes and packages Tivano into a DMG. Never installs, quits or
# launches the app: Release is updated through its own updater (scripts/install_app.sh
# installs a build by hand when explicitly asked).
#
#   scripts/release.sh
#   scripts/release.sh --preflight  # checks setup without building or installing
#
# Needs Xcode, XcodeGen, a Developer ID Application certificate for the team below
# and a notarytool keychain profile (NOTARY_PROFILE, "Tivano-Notarize" by default).
set -euo pipefail

PREFLIGHT_ONLY=0
case "${1:-}" in
  "") ;;
  --preflight) PREFLIGHT_ONLY=1 ;;
  *) echo "Usage: scripts/release.sh [--preflight]" >&2; exit 2 ;;
esac
[ "$#" -le 1 ] || { echo "Usage: scripts/release.sh [--preflight]" >&2; exit 2; }

cd "$(dirname "$0")/.."
ROOT="$PWD"
TEAM_ID="5WF7HRPLRX"
NOTARY_PROFILE="${NOTARY_PROFILE:-Tivano-Notarize}"
APP_NAME="Tivano"
# ".noindex" keeps Spotlight and Launchpad from listing the build copies of the app.
BUILD="$ROOT/build.noindex/public-release"
ARCHIVE="$BUILD/Tivano.xcarchive"
EXPORT="$BUILD/export"
VERSION=$(scripts/version.sh release)
DMG="$ROOT/build.noindex/Tivano-$VERSION.dmg"

step() { printf '\n==> %s\n' "$1"; }

notarize() {
  local file="$1" result status id attempt receipt
  receipt="$BUILD/$(basename "$file").notary-submit.json"
  # submit and info are separate operations (notarytool --help and Apple's TN3147).
  result=$(xcrun notarytool submit "$file" --keychain-profile "$NOTARY_PROFILE" --output-format json)
  printf '%s\n' "$result" > "$receipt"
  id=$(printf '%s' "$result" | plutil -extract id raw - 2>/dev/null || true)
  [ -n "$id" ] || { echo "No submission ID returned; inspect $receipt before retrying." >&2; exit 1; }
  echo "Notarization submitted: $id; receipt saved at $receipt"
  for ((attempt=0; attempt<2880; attempt++)); do
    if result=$(xcrun notarytool info "$id" --keychain-profile "$NOTARY_PROFILE" --output-format json); then
      status=$(printf '%s' "$result" | plutil -extract status raw - 2>/dev/null || true)
      case "$status" in
        Accepted) echo "Notarization accepted for $(basename "$file")"; return ;;
        "In Progress") ;;
        Invalid)
          printf '%s\n' "$result"
          xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE" || true
          exit 1
          ;;
        *) echo "Unexpected status response for $id; retrying." >&2 ;;
      esac
    else
      echo "Status check failed for $id; retrying without resubmitting." >&2
    fi
    sleep 30
  done
  echo "Notarization still unresolved for $id. Receipt preserved at $receipt; do not resubmit blindly." >&2
  exit 1
}

# Validate saved credentials without submitting an app; fail before archiving.
# Apple: https://developer.apple.com/documentation/technotes/tn3147-migrating-to-the-latest-notarization-tool
step "Checking Developer ID and notarization setup"
[[ "$TEAM_ID" =~ ^[A-Z0-9]{10}$ ]] || { echo "Invalid release Team ID." >&2; exit 1; }
UPDATER_TEAM=$(python3 - <<'PYTEAM'
import re
from pathlib import Path
text = Path("Tivano/App/AppUpdater.swift").read_text()
match = re.search(r'static let teamID = "([A-Z0-9]{10})"', text)
print(match.group(1) if match else "")
PYTEAM
)
RELEASE_TEAM=$(sed -nE 's/^[[:space:]]*DEVELOPMENT_TEAM[[:space:]]*=[[:space:]]*([A-Z0-9]{10})[[:space:]]*$/\1/p' config/release.xcconfig)
[ "$UPDATER_TEAM" = "$TEAM_ID" ] && [ "$RELEASE_TEAM" = "$TEAM_ID" ] || {
  echo "Release build, updater and packaging script must use the same Team ID." >&2
  exit 1
}
IDENTITIES=$(security find-identity -v -p codesigning | sed -nE "s/^[[:space:]]*[0-9]+\) ([0-9A-F]{40}) \"Developer ID Application: .*\($TEAM_ID\)\".*/\1/p")
IDENTITY_COUNT=$(printf '%s\n' "$IDENTITIES" | awk 'NF { n++ } END { print n+0 }')
[ "$IDENTITY_COUNT" = 1 ] || {
  echo "Expected one usable Developer ID Application identity for team $TEAM_ID; found $IDENTITY_COUNT." >&2
  echo "Create/import the certificate and matching private key before packaging." >&2
  exit 1
}
IDENTITY="$IDENTITIES"
xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" --output-format json > /dev/null
if [ "$PREFLIGHT_ONLY" = 1 ]; then
  echo "Public release setup is usable; no app was built, submitted, installed or launched."
  exit 0
fi

step "Generating the Xcode project"
xcodegen generate --quiet

step "Archiving $APP_NAME $VERSION"
rm -rf "$BUILD"
mkdir -p "$BUILD"
if ! xcodebuild archive \
  -project Tivano.xcodeproj \
  -scheme Tivano \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "$ARCHIVE" \
  -derivedDataPath "$BUILD/DerivedData" \
  -skipPackagePluginValidation \
  -skipMacroValidation \
  ARCHS=arm64 \
  EXCLUDED_ARCHS=x86_64 \
  ONLY_ACTIVE_ARCH=NO \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$IDENTITY" > "$BUILD/archive.log" 2>&1; then
  grep -E "error:" "$BUILD/archive.log" | head -40 || tail -40 "$BUILD/archive.log"
  exit 1
fi

step "Exporting with Developer ID"
cat > "$BUILD/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key>
  <string>developer-id</string>
  <key>teamID</key>
  <string>$TEAM_ID</string>
  <key>signingStyle</key>
  <string>manual</string>
  <key>signingCertificate</key>
  <string>Developer ID Application</string>
</dict>
</plist>
PLIST
if ! xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportPath "$EXPORT" \
  -exportOptionsPlist "$BUILD/ExportOptions.plist" > "$BUILD/export.log" 2>&1; then
  tail -40 "$BUILD/export.log"
  exit 1
fi
APP="$EXPORT/$APP_NAME.app"

step "Verifying the signature"
codesign --verify --deep --strict --verbose=2 \
  -R="anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13] and certificate leaf[subject.OU] = \"$TEAM_ID\" and identifier \"dev.tivano.Tivano\"" "$APP"
details=$(codesign -dv --verbose=4 "$APP" 2>&1)
grep -q "Authority=Developer ID Application" <<< "$details"
grep -qx "TeamIdentifier=$TEAM_ID" <<< "$details"
grep -q "flags=.*runtime" <<< "$details"
grep -q "Timestamp=" <<< "$details"
archs=$(lipo -archs "$APP/Contents/MacOS/$APP_NAME")
if [ "$archs" != "arm64" ]; then
  echo "Expected an Apple silicon binary, got: $archs"
  exit 1
fi

step "Notarizing the app"
ditto -c -k --keepParent "$APP" "$BUILD/Tivano.zip"
notarize "$BUILD/Tivano.zip"
xcrun stapler staple "$APP"

step "Building the disk image"
# The styled window (background, baked .DS_Store, volume icon) lives in release/dmg, see release/dmg/README.md.
"$ROOT/scripts/package_dmg.sh" --app "$APP" --output "$DMG"
codesign --sign "$IDENTITY" --timestamp "$DMG"

step "Notarizing the disk image"
notarize "$DMG"
xcrun stapler staple "$DMG"

step "Checking Gatekeeper"
spctl --assess --type execute --ignore-cache --no-cache --verbose "$APP"
spctl --assess --type open --context context:primary-signature --ignore-cache --no-cache --verbose "$DMG"
xcrun stapler validate "$DMG"

step "Cleaning up"
# Only the disk image stays, so Spotlight and Launchpad never list a second copy of the app.
rm -rf "$ARCHIVE" "$EXPORT" "$BUILD/Tivano.zip" "$BUILD/DerivedData"

printf '\nReady: %s\nscripts/ship.sh publishes it; by hand, scripts/publish_release.sh once CHANGELOG.md has a ## [%s] section.\n' "$DMG" "$VERSION"
