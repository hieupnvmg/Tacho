#!/bin/bash
# Build Tacho and wrap the binary in a double-clickable .app bundle.
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="Tacho"
BUNDLE_ID="io.github.hieupnvmg.tacho"
# The single source of the version; release.sh bumps it. The updater compares
# it against the newest GitHub release tag.
VERSION="$(tr -d '[:space:]' < VERSION)"
BUILD_DIR="$(pwd)/.build/release"
APP_DIR="$(pwd)/dist/${APP_NAME}.app"

echo "==> Building (release)…"
swift build -c release

echo "==> Assembling bundle…"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BUILD_DIR/Tacho" "$APP_DIR/Contents/MacOS/$APP_NAME"
# Drawn by scripts/make-icon.swift.
cp Assets/AppIcon.icns "$APP_DIR/Contents/Resources/AppIcon.icns"

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key><string>${APP_NAME}</string>
    <key>CFBundleExecutable</key><string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSSupportsAutomaticTermination</key><false/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

# Ad-hoc signature so macOS is happy launching an unsigned local build.
codesign --force --deep --sign - "$APP_DIR" >/dev/null 2>&1 || true

echo "==> Done: $APP_DIR"
echo "    open \"$APP_DIR\""
