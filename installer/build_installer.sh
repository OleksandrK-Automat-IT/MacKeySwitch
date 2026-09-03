#!/bin/bash
# MacKeySwitch Installer Builder
# Builds .pkg installer and .dmg disk image for distribution.
#
# The .app itself is built by build_app.sh — this script only packages it, so a local
# install (install.sh) does not have to produce a disk image it will never use.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
APP_NAME="MacKeySwitch"
BUNDLE_ID="com.okuzmin.mackeyswitch"
VERSION="2.1"
OUTPUT_DIR="$PROJECT_DIR/dist"

echo "=== Building $APP_NAME v$VERSION ==="

"$SCRIPT_DIR/build_app.sh"

# Step 5: Build .pkg installer
echo "[5/6] Building .pkg installer..."
PKG_ROOT="$OUTPUT_DIR/pkg_root"
rm -rf "$PKG_ROOT"
mkdir -p "$PKG_ROOT/Applications"
cp -R "$OUTPUT_DIR/$APP_NAME.app" "$PKG_ROOT/Applications/"

# The postinstall script runs as root, from the installer's own context. A dialog put up
# from here (the previous `osascript -e 'display dialog ...'`) belongs to root's session,
# not the user's, so it may never appear — and it blocked the installer while waiting for
# an answer nobody could give. The app already prompts for Accessibility on first launch,
# which is where the request belongs.
SCRIPTS_DIR="$OUTPUT_DIR/scripts"
rm -rf "$SCRIPTS_DIR"
mkdir -p "$SCRIPTS_DIR"
cat > "$SCRIPTS_DIR/postinstall" << 'POSTINSTALL'
#!/bin/bash
# MacKeySwitch asks for Accessibility itself on first launch; nothing to do here.
exit 0
POSTINSTALL
chmod +x "$SCRIPTS_DIR/postinstall"

pkgbuild \
    --root "$PKG_ROOT" \
    --identifier "$BUNDLE_ID" \
    --version "$VERSION" \
    --install-location "/" \
    --scripts "$SCRIPTS_DIR" \
    "$OUTPUT_DIR/${APP_NAME}_${VERSION}-unsigned.pkg"

# A .pkg has to be signed with an *Installer* identity — the Application identity used for
# the app is not accepted. Without one the package stays unsigned and macOS will refuse to
# open it on another machine.
if security find-identity -v 2>/dev/null | grep -q "Developer ID Installer"; then
    INSTALLER_IDENTITY=$(security find-identity -v | grep "Developer ID Installer" | head -1 | awk -F'"' '{print $2}')
    echo "   Signing package with: $INSTALLER_IDENTITY"
    productsign --sign "$INSTALLER_IDENTITY" \
        "$OUTPUT_DIR/${APP_NAME}_${VERSION}-unsigned.pkg" \
        "$OUTPUT_DIR/${APP_NAME}_${VERSION}.pkg"
    rm -f "$OUTPUT_DIR/${APP_NAME}_${VERSION}-unsigned.pkg"
else
    echo "   WARNING: no Developer ID Installer identity — package will be UNSIGNED."
    mv "$OUTPUT_DIR/${APP_NAME}_${VERSION}-unsigned.pkg" "$OUTPUT_DIR/${APP_NAME}_${VERSION}.pkg"
fi

echo "   Package: $OUTPUT_DIR/${APP_NAME}_${VERSION}.pkg"

# Step 6: Build .dmg
echo "[6/6] Building .dmg disk image..."
DMG_DIR="$OUTPUT_DIR/dmg_staging"
rm -rf "$DMG_DIR"
mkdir -p "$DMG_DIR"
cp -R "$OUTPUT_DIR/$APP_NAME.app" "$DMG_DIR/"
cp "$PROJECT_DIR/LICENSE" "$DMG_DIR/LICENSE.txt"

# Create symlink to Applications
ln -s /Applications "$DMG_DIR/Applications"

# Create a simple README
cat > "$DMG_DIR/README.txt" << 'README'
MacKeySwitch v2.1
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
  - Apple silicon or Intel
  - Accessibility permission

Created by Oleksandr Kuzmin, 2026
Licensed under GPL-3.0 — see LICENSE.txt
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
