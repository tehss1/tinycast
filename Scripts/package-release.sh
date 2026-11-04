#!/bin/bash
# Package a self-signed release. Usage: package-release.sh <app> <dmg> <zip>
set -euo pipefail
APP="${1:?}" DMG="${2:?}" ZIP="${3:?}"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/${APP##*/}"
ln -s /Applications "$STAGE/Applications"
mkdir -p "$(dirname "$DMG")" "$(dirname "$ZIP")"
hdiutil create -volname "$(basename "$APP" .app)" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
ditto -c -k --keepParent --sequesterRsrc "$APP" "$ZIP"
