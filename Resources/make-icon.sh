#!/bin/bash
# Regenerates Resources/AppIcon.icns from the vector glyph in MiddleIcon.swift.
#
# The .icns is committed, so this only needs running when the artwork changes.
set -euo pipefail
cd "$(dirname "$0")/.."

ICONSET="build/Middle.iconset"
rm -rf "$ICONSET"
swift run -c release Middle --export-icon "$ICONSET" >/dev/null
iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
rm -rf "$ICONSET"

echo "Wrote Resources/AppIcon.icns"
