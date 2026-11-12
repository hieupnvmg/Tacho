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
# Menu bar runner frames from RunCat Neo, with their licence and notice.
cp -R Assets/Runners "$APP_DIR/Contents/Resources/Runners"

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

# Signed with the self-signed "Tacho Signing" certificate when this Mac has
# it. macOS then keys permissions such as Accessibility to the certificate,
# so they survive rebuilds and updates; an ad-hoc signature changes with
# every build and loses them. Without the certificate, sign ad-hoc.
# TACHO_SIGN_IDENTITY=- forces ad-hoc, as build-dmg.sh does for releases.
IDENTITY="${TACHO_SIGN_IDENTITY:-Tacho Signing}"
if [ "$IDENTITY" != "-" ] && security find-identity -p codesigning | grep -q "\"$IDENTITY\""; then
    codesign --force --deep --sign "$IDENTITY" "$APP_DIR"
else
    [ "$IDENTITY" = "-" ] || echo "    (no \"$IDENTITY\" certificate; signing ad-hoc)"
    codesign --force --deep --sign - "$APP_DIR" >/dev/null 2>&1 || true
fi

echo "==> Done: $APP_DIR"
echo "    open \"$APP_DIR\""
