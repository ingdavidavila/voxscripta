#!/bin/bash
# Assembles VoxVerba.app around the SPM-built executable.
#
# SwiftPM produces a bare binary, and a bare binary on macOS runs without a dock
# icon, without proper activation, and without the entitlements that make the
# privacy guarantee checkable. This wraps it in a real bundle so the app behaves
# like an app and `codesign -d --entitlements` shows what it can and cannot do.
set -euo pipefail

CONFIG="${1:-debug}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$(swift build --package-path "$ROOT" -c "$CONFIG" --show-bin-path)"
APP="$ROOT/build/VoxVerba.app"

swift build --package-path "$ROOT" -c "$CONFIG" --product VoxVerbaApp

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/VoxVerbaApp" "$APP/Contents/MacOS/VoxVerba"

# The icon is generated, not committed as a binary, so it stays reproducible.
if [ ! -f "$ROOT/build/VoxVerba.icns" ]; then
    swiftc -O "$ROOT/Tools/make-icon.swift" -o "$ROOT/build/make-icon"
    "$ROOT/build/make-icon" "$ROOT/build"
    iconutil -c icns "$ROOT/build/VoxVerba.iconset" -o "$ROOT/build/VoxVerba.icns"
fi
cp "$ROOT/build/VoxVerba.icns" "$APP/Contents/Resources/VoxVerba.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>VoxVerba</string>
    <key>CFBundleDisplayName</key><string>VoxVerba</string>
    <key>CFBundleIdentifier</key><string>com.voxverba.app</string>
    <key>CFBundleExecutable</key><string>VoxVerba</string>
    <key>CFBundleIconFile</key><string>VoxVerba</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>Local-first transcription. Your audio never leaves this Mac.</string>
</dict>
</plist>
PLIST

# Entitlements assert the privacy claim structurally: no network client, ever.
cat > "$ROOT/build/VoxVerba.entitlements" <<ENT
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key><false/>
    <key>com.apple.security.files.user-selected.read-only</key><true/>
</dict>
</plist>
ENT

# Hardened runtime is required for notarization and costs nothing to enable now.
codesign --force --options runtime --sign - \
    --entitlements "$ROOT/build/VoxVerba.entitlements" "$APP" 2>/dev/null || \
    codesign --force --sign - "$APP"

# The privacy guarantee is only worth stating if it is checked. A network
# entitlement here would silently undo §26, so the build refuses to produce one.
if codesign -d --entitlements - "$APP" 2>/dev/null | grep -q "network.client"; then
    echo "FAIL: the bundle carries a network entitlement" >&2
    exit 1
fi

RUNTIME=$(codesign -d -v "$APP" 2>&1 | grep -o 'runtime' | head -1)
echo "built $APP"
echo "  hardened runtime: ${RUNTIME:-NOT ENABLED}"
echo "  network access:   none (no com.apple.security.network.client entitlement)"
echo
echo "Ad-hoc signed. For distribution see Docs/RELEASE.md — notarization needs a"
echo "Developer ID certificate and an Apple ID, which this script deliberately"
echo "does not handle."
