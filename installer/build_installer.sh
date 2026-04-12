#!/bin/bash
# MacKeySwitch Installer Builder
# Builds .pkg installer and .dmg disk image for distribution
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
APP_NAME="MacKeySwitch"
BUNDLE_ID="com.okuzmin.mackeyswitch"
VERSION="2.0"
OUTPUT_DIR="$PROJECT_DIR/dist"

echo "=== Building $APP_NAME v$VERSION ==="

# Step 1: Build release binary
echo "[1/5] Building release binary..."
cd "$PROJECT_DIR"
swift build -c release 2>&1

BINARY="$PROJECT_DIR/.build/release/LayoutSwitcher"
if [ ! -f "$BINARY" ]; then
    echo "ERROR: Release binary not found at $BINARY"
    exit 1
fi

# Step 2: Create .app bundle
echo "[2/5] Creating .app bundle..."
rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"

APP_DIR="$OUTPUT_DIR/$APP_NAME.app/Contents"
mkdir -p "$APP_DIR/MacOS" "$APP_DIR/Resources"

cp "$BINARY" "$APP_DIR/MacOS/LayoutSwitcher"

# Copy dictionary resources
BUNDLE_DIR="$PROJECT_DIR/.build/release/LayoutSwitcher_LayoutSwitcher.bundle"
if [ -d "$BUNDLE_DIR" ]; then
    cp "$BUNDLE_DIR/en_words.txt" "$APP_DIR/Resources/"
    cp "$BUNDLE_DIR/ua_words.txt" "$APP_DIR/Resources/"
else
    echo "WARNING: Resource bundle not found, copying from Sources"
    cp "$PROJECT_DIR/Sources/LayoutSwitcher/Resources/en_words.txt" "$APP_DIR/Resources/"
    cp "$PROJECT_DIR/Sources/LayoutSwitcher/Resources/ua_words.txt" "$APP_DIR/Resources/"
fi

cat > "$APP_DIR/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>LayoutSwitcher</string>
    <key>CFBundleIdentifier</key>
    <string>com.okuzmin.mackeyswitch</string>
    <key>CFBundleName</key>
    <string>MacKeySwitch</string>
    <key>CFBundleDisplayName</key>
    <string>MacKeySwitch</string>
    <key>CFBundleVersion</key>
    <string>2.0</string>
    <key>CFBundleShortVersionString</key>
    <string>2.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright 2026 Oleksandr Kuzmin. Licensed under GPL-3.0.</string>
</dict>
</plist>
PLIST

echo "   App bundle: $OUTPUT_DIR/$APP_NAME.app"

# Step 3: Code sign (ad-hoc if no Developer ID)
echo "[3/5] Code signing..."
if security find-identity -v -p codesigning 2>/dev/null | grep -q "Developer ID Application"; then
    IDENTITY=$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 | awk -F'"' '{print $2}')
    echo "   Signing with: $IDENTITY"
    codesign --force --deep --options runtime --sign "$IDENTITY" "$OUTPUT_DIR/$APP_NAME.app"
else
    echo "   No Developer ID found, using ad-hoc signing"
    codesign --force --deep --sign - "$OUTPUT_DIR/$APP_NAME.app"
fi

# Step 4: Build .pkg installer
echo "[4/5] Building .pkg installer..."
PKG_ROOT="$OUTPUT_DIR/pkg_root"
mkdir -p "$PKG_ROOT/Applications"
cp -R "$OUTPUT_DIR/$APP_NAME.app" "$PKG_ROOT/Applications/"

# Create postinstall script to remind about Accessibility
SCRIPTS_DIR="$OUTPUT_DIR/scripts"
mkdir -p "$SCRIPTS_DIR"
cat > "$SCRIPTS_DIR/postinstall" << 'POSTINSTALL'
#!/bin/bash
# Open Accessibility settings so user can grant permission
osascript -e 'display dialog "MacKeySwitch needs Accessibility access to monitor keyboard input.\n\nPlease add MacKeySwitch.app in:\nSystem Settings → Privacy & Security → Accessibility" buttons {"Open Settings", "Later"} default button "Open Settings"' 2>/dev/null && \
open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility" 2>/dev/null || true
exit 0
POSTINSTALL
chmod +x "$SCRIPTS_DIR/postinstall"

pkgbuild \
    --root "$PKG_ROOT" \
    --identifier "$BUNDLE_ID" \
    --version "$VERSION" \
    --install-location "/" \
    --scripts "$SCRIPTS_DIR" \
    "$OUTPUT_DIR/${APP_NAME}_${VERSION}.pkg"

echo "   Package: $OUTPUT_DIR/${APP_NAME}_${VERSION}.pkg"

# Step 5: Build .dmg
echo "[5/5] Building .dmg disk image..."
DMG_DIR="$OUTPUT_DIR/dmg_staging"
mkdir -p "$DMG_DIR"
cp -R "$OUTPUT_DIR/$APP_NAME.app" "$DMG_DIR/"

# Create symlink to Applications
ln -s /Applications "$DMG_DIR/Applications"

# Create a simple README
cat > "$DMG_DIR/README.txt" << 'README'
MacKeySwitch v2.0
Automatic Mac Keyboard Switcher
================================

Installation:
  Drag MacKeySwitch.app to the Applications folder.

First Launch:
  1. Open MacKeySwitch from Applications
  2. Grant Accessibility access when prompted:
     System Settings → Privacy & Security → Accessibility
  3. The app appears in the menu bar (flag icon)

Requirements:
  - macOS 13 (Ventura) or later
  - Accessibility permission

Created by Oleksandr Kuzmin, 2026
Licensed under GPL-3.0
README

hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$DMG_DIR" \
    -ov \
    -format UDZO \
    "$OUTPUT_DIR/${APP_NAME}_${VERSION}.dmg"

echo "   DMG: $OUTPUT_DIR/${APP_NAME}_${VERSION}.dmg"

# Cleanup staging dirs
rm -rf "$PKG_ROOT" "$DMG_DIR" "$SCRIPTS_DIR"

echo ""
echo "=== Build complete ==="
echo "  App:  $OUTPUT_DIR/$APP_NAME.app"
echo "  PKG:  $OUTPUT_DIR/${APP_NAME}_${VERSION}.pkg"
echo "  DMG:  $OUTPUT_DIR/${APP_NAME}_${VERSION}.dmg"
echo ""
echo "For notarized distribution, run:"
echo "  xcrun notarytool submit $OUTPUT_DIR/${APP_NAME}_${VERSION}.dmg \\"
echo "    --apple-id YOUR_APPLE_ID \\"
echo "    --team-id YOUR_TEAM_ID \\"
echo "    --password YOUR_APP_SPECIFIC_PASSWORD \\"
echo "    --wait"
echo "  xcrun stapler staple $OUTPUT_DIR/${APP_NAME}_${VERSION}.dmg"
