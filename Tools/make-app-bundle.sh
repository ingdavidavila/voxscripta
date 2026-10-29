#!/bin/bash
# Assembles VoxScripta.app around the SPM-built executable.
#
# SwiftPM produces a bare binary, and a bare binary on macOS runs without a dock
# icon, without proper activation, and without the entitlements that make the
# privacy guarantee checkable. This wraps it in a real bundle so the app behaves
# like an app and `codesign -d --entitlements` shows what it can and cannot do.
set -euo pipefail

CONFIG="${1:-debug}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# The version comes from the source rather than being repeated here. Two copies
# of a version number drift, and this one is stamped into every transcript's
# provenance, where being wrong misattributes the work.
VERSION="$(sed -n 's/.*static let version = "\(.*\)".*/\1/p' \
    "$ROOT/Sources/VoxScriptaCore/VoxScripta.swift")"
[ -n "$VERSION" ] || { echo "could not read the version from VoxScripta.swift" >&2; exit 1; }
# Monotonic build number: how many commits exist.
BUILD="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)"
# Checked before the build rather than during it. Since Swift 6.4 made the
# Xcode build system the default, SwiftPM compiles mlx-swift's .metal sources
# itself, so a missing toolchain fails several minutes in with a wall of
# compiler invocations instead of the one line that says what to do. The
# toolchain is also dropped by every Xcode update, so this is not a rare case —
# it has happened twice in this project.
if ! xcrun -sdk macosx metal --version >/dev/null 2>&1; then
    echo "The Metal toolchain is missing, which an Xcode update will do." >&2
    echo "Reinstall it and run this again:" >&2
    echo "    xcodebuild -downloadComponent MetalToolchain" >&2
    exit 1
fi

BIN="$(swift build --package-path "$ROOT" -c "$CONFIG" --show-bin-path)"
APP="$ROOT/build/VoxScripta.app"

swift build --package-path "$ROOT" -c "$CONFIG" --product VoxScriptaApp

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/VoxScriptaApp" "$APP/Contents/MacOS/VoxScripta"

# The icon is generated, not committed as a binary, so it stays reproducible.
if [ ! -f "$ROOT/build/VoxScripta.icns" ]; then
    swiftc -O "$ROOT/Tools/make-icon.swift" -o "$ROOT/build/make-icon"
    "$ROOT/build/make-icon" "$ROOT/build"
    iconutil -c icns "$ROOT/build/VoxScripta.iconset" -o "$ROOT/build/VoxScripta.icns"
fi
cp "$ROOT/build/VoxScripta.icns" "$APP/Contents/Resources/VoxScripta.icns"

# MLX's Metal shaders. SwiftPM cannot build these — see Tools/build-metallib.sh
# — and without the library the app links fine and then fails at the first GPU
# call, so it is built here and placed beside the executable where MLX looks for
# it first.
if [ ! -f "$ROOT/build/mlx.metallib" ]; then
    "$ROOT/Tools/build-metallib.sh"
fi
cp "$ROOT/build/mlx.metallib" "$APP/Contents/MacOS/mlx.metallib"

# Translations. Checked first: an untranslated string falls back to English and
# looks deliberate, so the only way to catch one is to compare the table against
# the catalogues before shipping.
"$ROOT/Tools/check-localization.sh"
for lproj in "$ROOT"/Resources/Localization/*.lproj; do
    [ -d "$lproj" ] || continue
    cp -R "$lproj" "$APP/Contents/Resources/"
done

# Resource bundles from dependencies (tokenizer data, and so on).
for bundle in "$BIN"/*.bundle; do
    [ -e "$bundle" ] || continue
    cp -R "$bundle" "$APP/Contents/Resources/"
done

# The bundled language model, if one has been fetched. Its absence is not an
# error: the app falls back to Apple's system model, and says so when it cannot.
if [ -d "$ROOT/build/Model" ] && [ -f "$ROOT/build/Model/config.json" ]; then
    cp -R "$ROOT/build/Model" "$APP/Contents/Resources/Model"
    MODEL_SIZE=$(du -sh "$APP/Contents/Resources/Model" | cut -f1)
else
    MODEL_SIZE="none — run Tools/fetch-model.sh for a self-contained build"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>VoxScripta</string>
    <key>CFBundleDisplayName</key><string>Vox Scripta</string>
    <key>CFBundleIdentifier</key><string>com.voxscripta.app</string>
    <key>CFBundleExecutable</key><string>VoxScripta</string>
    <key>CFBundleIconFile</key><string>VoxScripta</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleLocalizations</key>
    <array><string>en</string><string>es</string></array>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSMicrophoneUsageDescription</key><string>Vox Scripta records audio so it can transcribe it. Recordings are saved on this device and are never uploaded.</string>
    <key>NSHumanReadableCopyright</key><string>Local-first transcription. Your audio never leaves this Mac.</string>
</dict>
</plist>
PLIST

# Entitlements assert the privacy claim structurally: no network client, ever.
cat > "$ROOT/build/VoxScripta.entitlements" <<ENT
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key><false/>
    <key>com.apple.security.files.user-selected.read-only</key><true/>
    <!-- Recording in the app needs the microphone, and the hardened runtime
         denies it without this. It grants input only: there is still no
         network, no camera, and no address book. -->
    <key>com.apple.security.device.audio-input</key><true/>
</dict>
</plist>
ENT

# The metallib lives beside the executable because that is the first place MLX
# looks. codesign treats anything in Contents/MacOS as nested code and refuses to
# seal an unsigned one, which silently dropped the app to a signature with no
# entitlements — so it is signed first, on its own.
if [ -f "$APP/Contents/MacOS/mlx.metallib" ]; then
    codesign --force --sign - "$APP/Contents/MacOS/mlx.metallib"
fi

# Hardened runtime is required for notarization and costs nothing to enable now.
codesign --force --options runtime --sign - \
    --entitlements "$ROOT/build/VoxScripta.entitlements" "$APP"

# The privacy guarantee is only worth stating if it is checked. A network
# entitlement here would silently undo §26, so the build refuses to produce one.
if codesign -d --entitlements - "$APP" 2>/dev/null | grep -q "network.client"; then
    echo "FAIL: the bundle carries a network entitlement" >&2
    exit 1
fi

# A signature that lost its entitlements is worse than a failed build, because
# the privacy guarantee is asserted by what the entitlements do *not* contain.
if ! codesign -d --entitlements - "$APP" 2>/dev/null | grep -q "user-selected"; then
    echo "FAIL: the bundle lost its entitlements during signing" >&2
    exit 1
fi

RUNTIME=$(codesign -d -v "$APP" 2>&1 | grep -o 'runtime' | head -1)
echo "built $APP"
echo "  hardened runtime: ${RUNTIME:-NOT ENABLED}"
echo "  network access:   none (no com.apple.security.network.client entitlement)"
echo "  bundled model:    $MODEL_SIZE"
echo
echo "Ad-hoc signed. For distribution see Docs/RELEASE.md — notarization needs a"
echo "Developer ID certificate and an Apple ID, which this script deliberately"
echo "does not handle."
