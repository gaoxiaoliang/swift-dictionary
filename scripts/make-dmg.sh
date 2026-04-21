#!/usr/bin/env bash
# Build a DMG containing the .app and a symlink to /Applications.
# Usage: ./scripts/make-dmg.sh <path-to-app> <output-dmg> <volume-name>

set -euo pipefail

APP_PATH="${1:?usage: make-dmg.sh <app> <dmg> <volname>}"
DMG_PATH="${2:?usage: make-dmg.sh <app> <dmg> <volname>}"
VOL_NAME="${3:?usage: make-dmg.sh <app> <dmg> <volname>}"

if [[ ! -d "$APP_PATH" ]]; then
    echo "error: app bundle not found at $APP_PATH" >&2
    exit 1
fi

# Stage directory that becomes the DMG root
STAGE_DIR="$(mktemp -d /tmp/swift-dict-dmg.XXXXXX)"
trap 'rm -rf "$STAGE_DIR"' EXIT

echo "==> Staging DMG contents in $STAGE_DIR"
cp -R "$APP_PATH" "$STAGE_DIR/"
ln -s /Applications "$STAGE_DIR/Applications"

# Remove any stale DMG
rm -f "$DMG_PATH"

echo "==> Creating DMG: $DMG_PATH"
hdiutil create \
    -volname "$VOL_NAME" \
    -srcfolder "$STAGE_DIR" \
    -ov \
    -format UDZO \
    -fs HFS+ \
    "$DMG_PATH"

echo "==> Done: $DMG_PATH"
