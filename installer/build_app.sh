#!/bin/bash
# Builds dist/MacKeySwitch.app — a universal, signed, icon-bearing app bundle.
#
# This is the part both install.sh (local install) and build_installer.sh (pkg + dmg for
# distribution) need, which is why it lives on its own rather than inside the packaging
# script.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
APP_NAME="MacKeySwitch"
BUNDLE_ID="com.okuzmin.mackeyswitch"
VERSION="2.0"
DEPLOYMENT_TARGET="13.0"
OUTPUT_DIR="$PROJECT_DIR/dist"
APP_BUNDLE="$OUTPUT_DIR/$APP_NAME.app"
APP_DIR="$APP_BUNDLE/Contents"

# Step 1: Build a universal release binary.
#
# `swift build -c release` alone produces a thin binary for the build machine's
# architecture. The shipped 2.0 build was arm64-only while its Info.plist advertised
# macOS 13, so it simply refused to launch on every Intel Mac.
#
# Built one slice at a time and lipo'd together, rather than with `--arch arm64 --arch
# x86_64`: that flag routes through xcbuild, which only exists in a full Xcode install, so
# it fails outright when the Command Line Tools are the selected developer directory.
echo "[1/4] Building universal release binary (arm64 + x86_64)..."
cd "$PROJECT_DIR"

SLICES=()
for arch in arm64 x86_64; do
    echo "   --- $arch ---"
    swift build -c release --triple "${arch}-apple-macosx${DEPLOYMENT_TARGET}" 2>&1
    slice="$PROJECT_DIR/.build/${arch}-apple-macosx/release/LayoutSwitcher"
    if [ ! -f "$slice" ]; then
        echo "ERROR: $arch build produced no binary at $slice"
        exit 1
    fi
    SLICES+=("$slice")
done

BUILD_TMP="$PROJECT_DIR/.build/universal"
mkdir -p "$BUILD_TMP"
BINARY="$BUILD_TMP/LayoutSwitcher"
lipo -create -output "$BINARY" "${SLICES[@]}"

# Either slice carries the same resources.
BUNDLE_DIR="$PROJECT_DIR/.build/arm64-apple-macosx/release/LayoutSwitcher_LayoutSwitcher.bundle"

echo "   Architectures: $(lipo -archs "$BINARY")"
for arch in arm64 x86_64; do
    if ! lipo -archs "$BINARY" | grep -qw "$arch"; then
        echo "ERROR: binary is missing the $arch slice"
        exit 1
    fi
done

# Step 2: Assemble the .app bundle
echo "[2/4] Creating .app bundle..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_DIR/MacOS" "$APP_DIR/Resources"

cp "$BINARY" "$APP_DIR/MacOS/LayoutSwitcher"

# Copy dictionary resources
if [ -d "$BUNDLE_DIR" ]; then
    cp "$BUNDLE_DIR/en_words.txt" "$APP_DIR/Resources/"
    cp "$BUNDLE_DIR/ua_words.txt" "$APP_DIR/Resources/"
else
    echo "   WARNING: Resource bundle not found, copying from Sources"
    cp "$PROJECT_DIR/Sources/LayoutSwitcher/Resources/en_words.txt" "$APP_DIR/Resources/"
    cp "$PROJECT_DIR/Sources/LayoutSwitcher/Resources/ua_words.txt" "$APP_DIR/Resources/"
fi

# Copy the interface translations to Contents/Resources/<code>.lproj — the standard place
# for them in a macOS app, and the first location Localization looks in.
for lproj in en uk; do
    src="$PROJECT_DIR/Sources/LayoutSwitcher/Resources/${lproj}.lproj"
    if [ ! -f "$src/Localizable.strings" ]; then
        echo "ERROR: missing $src/Localizable.strings"
        exit 1
    fi
    cp -R "$src" "$APP_DIR/Resources/"
done
echo "   Localizations: en, uk"

# Ship the licence alongside the app: GPL-3.0 requires the text to travel with the binary.
cp "$PROJECT_DIR/LICENSE" "$APP_DIR/Resources/LICENSE"

# Step 3: Render the app icon.
#
# Drawn by the app itself, from the same code as the About tab, so Finder shows the same
# icon the app does and no binary asset has to be kept in the repository.
echo "[3/4] Rendering app icon..."
ICONSET="$OUTPUT_DIR/$APP_NAME.iconset"
if "$APP_DIR/MacOS/LayoutSwitcher" --export-iconset "$ICONSET" >/dev/null 2>&1 \
   && iconutil -c icns "$ICONSET" -o "$APP_DIR/Resources/$APP_NAME.icns" 2>/dev/null; then
    ICON_PLIST_ENTRY="    <key>CFBundleIconFile</key>
    <string>$APP_NAME</string>"
    echo "   Icon: $APP_DIR/Resources/$APP_NAME.icns"
else
    echo "   WARNING: icon generation failed, shipping without a custom icon"
    ICON_PLIST_ENTRY=""
fi
rm -rf "$ICONSET"

cat > "$APP_DIR/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>LayoutSwitcher</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>$APP_NAME</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleLocalizations</key>
    <array>
        <string>en</string>
        <string>uk</string>
    </array>
$ICON_PLIST_ENTRY
    <key>LSUIElement</key>
    <true/>
    <key>LSMinimumSystemVersion</key>
    <string>$DEPLOYMENT_TARGET</string>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright 2026 Oleksandr Kuzmin. Licensed under GPL-3.0.</string>
</dict>
</plist>
PLIST

# Step 4: Code sign.
#
# No `--deep`: Apple deprecated it, and it signs nested code with the *outer* bundle's
# options, which is wrong whenever the two differ. There is no nested code here anyway.
#
# Set MACKEYSWITCH_CODESIGN_IDENTITY to a stable identity to keep the code signature — and
# therefore the granted Accessibility permission — the same across rebuilds.
echo "[4/4] Code signing..."
IDENTITY="${MACKEYSWITCH_CODESIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ] && security find-identity -v -p codesigning 2>/dev/null | grep -q "Developer ID Application"; then
    IDENTITY=$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 | awk -F'"' '{print $2}')
fi

if [ -n "$IDENTITY" ]; then
    echo "   Signing with: $IDENTITY"
    codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP_BUNDLE"
else
    echo "   No signing identity found, using ad-hoc signing"
    echo "   NOTE: an ad-hoc signature is different on every rebuild, so macOS treats each"
    echo "         build as a new app and forgets the Accessibility grant. Re-run"
    echo "         installer/regrant-permissions.sh after rebuilding, or set"
    echo "         MACKEYSWITCH_CODESIGN_IDENTITY to a stable identity."
    codesign --force --options runtime --sign - "$APP_BUNDLE"
fi
codesign --verify --strict --verbose=1 "$APP_BUNDLE"

echo ""
echo "App bundle ready: $APP_BUNDLE"
du -sh "$APP_BUNDLE"
