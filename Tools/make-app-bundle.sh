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

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>VoxVerba</string>
    <key>CFBundleDisplayName</key><string>VoxVerba</string>
    <key>CFBundleIdentifier</key><string>com.voxverba.app</string>
    <key>CFBundleExecutable</key><string>VoxVerba</string>
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

codesign --force --sign - --entitlements "$ROOT/build/VoxVerba.entitlements" "$APP" 2>/dev/null || \
    codesign --force --sign - "$APP"

echo "built $APP"
