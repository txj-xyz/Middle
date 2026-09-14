#!/bin/bash
# Builds Middle.app into ./build.
#
# macOS ties Accessibility and Input Monitoring grants to the app's code
# signature, so an ad-hoc signature (which changes on every build) means
# re-approving the app after each rebuild. If a real signing identity is
# available in the keychain we use it, which keeps the grants stable.
#
# Environment overrides, used by .github/workflows/release.yml:
#   UNIVERSAL=1          build arm64 + x86_64 rather than just this machine
#   VERSION=1.2.3        stamp the bundle version instead of keeping Info.plist's
#   CODESIGN_IDENTITY=…  sign with this identity instead of searching the keychain
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-release}"
APP="build/Middle.app"

BUILD=(swift build -c "$CONFIG")
if [ "${UNIVERSAL:-0}" = "1" ]; then
  BUILD+=(--arch arm64 --arch x86_64)
fi

"${BUILD[@]}"
BIN="$("${BUILD[@]}" --show-bin-path)/Middle"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp "$BIN" "$APP/Contents/MacOS/Middle"

if [ -n "${VERSION:-}" ]; then
  /usr/libexec/PlistBuddy \
    -c "Set :CFBundleShortVersionString $VERSION" \
    -c "Set :CFBundleVersion $VERSION" \
    "$APP/Contents/Info.plist"
fi

IDENTITY="${CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null \
  | awk '/Developer ID Application|Apple Development/ { print $2; exit }')}"

if [ -n "$IDENTITY" ]; then
  # --timestamp and the hardened runtime are both preconditions for notarising.
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
  echo "Signed with identity $IDENTITY"
else
  codesign --force --sign - "$APP"
  echo "Ad-hoc signed. macOS will ask for permissions again after each rebuild;"
  echo "remove the stale entries in System Settings > Privacy & Security if it"
  echo "silently stops working."
fi

echo "Built $APP"
