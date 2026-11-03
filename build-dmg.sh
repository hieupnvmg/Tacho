#!/bin/bash
# Build the app and package it as a drag-to-Applications disk image.
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="Tacho"
APP_DIR="$(pwd)/dist/${APP_NAME}.app"
DMG_PATH="$(pwd)/dist/${APP_NAME}.dmg"

./build-app.sh

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP_DIR/Contents/Info.plist")

echo "==> Staging disk image contents…"
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
cp -R "$APP_DIR" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

echo "==> Creating $DMG_PATH…"
rm -f "$DMG_PATH"
hdiutil create \
    -volname "${APP_NAME} ${VERSION}" \
    -srcfolder "$STAGING" \
    -fs HFS+ \
    -format UDZO \
    -imagekey zlib-level=9 \
    -ov \
    "$DMG_PATH" >/dev/null

echo "==> Done: $DMG_PATH"
echo "    Kéo \"${APP_NAME}\" vào Applications để cài."
