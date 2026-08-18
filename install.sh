#!/bin/bash
# ==========================================
# MacKeySwitch — build and install from source
# ==========================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="MacKeySwitch"
EXECUTABLE_NAME="LayoutSwitcher"
BUNDLE_ID="com.okuzmin.mackeyswitch"
BUILT_APP="$SCRIPT_DIR/dist/$APP_NAME.app"
INSTALLED_APP="/Applications/$APP_NAME.app"

echo "=========================================="
echo "        MacKeySwitch Setup                "
echo "=========================================="
echo ""
echo "This script will:"
echo "  1. Build the app from source (universal: Apple silicon + Intel)"
echo "  2. Install it into /Applications"
echo "  3. Set it to start at login"
echo "  4. Walk you through the privacy permissions it needs"
echo ""

# ------------------------------------------------------------------
# 0. Prerequisites
# ------------------------------------------------------------------
if ! command -v swift >/dev/null 2>&1; then
    echo "Apple's Command Line Tools are required to build MacKeySwitch."
    echo "A system prompt should appear — follow it, then run this script again."
    xcode-select --install || true
    exit 1
fi

MACOS_MAJOR="$(sw_vers -productVersion | cut -d. -f1)"
if [ "$MACOS_MAJOR" -lt 13 ]; then
    echo "ERROR: MacKeySwitch needs macOS 13 (Ventura) or later."
    echo "       This machine reports $(sw_vers -productVersion)."
    exit 1
fi

if [ ! -x "$SCRIPT_DIR/installer/build_app.sh" ]; then
    echo "ERROR: installer/build_app.sh not found or not executable."
    echo "       Run this script from the root of the MacKeySwitch repository."
    exit 1
fi

# ------------------------------------------------------------------
# 1. Build
# ------------------------------------------------------------------
echo "Step 1: Building $APP_NAME..."
echo ""
"$SCRIPT_DIR/installer/build_app.sh"

if [ ! -d "$BUILT_APP" ]; then
    echo "ERROR: the build did not produce $BUILT_APP"
    exit 1
fi

# ------------------------------------------------------------------
# 2. Install into /Applications
# ------------------------------------------------------------------
echo ""
echo "Step 2: Installing into /Applications..."

if pgrep -x "$EXECUTABLE_NAME" >/dev/null 2>&1; then
    echo "   Stopping the running copy..."
    pkill -x "$EXECUTABLE_NAME" 2>/dev/null || true
    sleep 1
fi

if [ -d "$INSTALLED_APP" ]; then
    echo "   Removing the previous version..."
    rm -rf "$INSTALLED_APP"
fi

# `cp -R` rather than `ditto`/`mv` so a build left in dist/ stays usable afterwards.
cp -R "$BUILT_APP" /Applications/

# Only relevant if the repository itself arrived as a download; harmless otherwise, and
# targeted at the quarantine flag rather than clearing every extended attribute.
xattr -dr com.apple.quarantine "$INSTALLED_APP" 2>/dev/null || true

echo "   Installed: $INSTALLED_APP"

# ------------------------------------------------------------------
# 3. Start at login
# ------------------------------------------------------------------
echo ""
echo "Step 3: Setting up 'Start at Login'..."

# Delegated to the app itself, which registers through SMAppService — the same path as the
# toggle in its Settings window. Registering here by another route (an AppleScript "login
# item", say) would leave that toggle reading "off" while the app really did launch at
# login, and the two would drift apart from then on.
if "$INSTALLED_APP/Contents/MacOS/$EXECUTABLE_NAME" --enable-login-item; then
    echo "   MacKeySwitch will start automatically at login."
    echo "   (Turn this off in Settings → General, or in System Settings → General → Login Items.)"
else
    echo "   WARNING: could not register the login item."
    echo "            You can turn it on later in MacKeySwitch's Settings → General."
fi

# ------------------------------------------------------------------
# 4. Permissions
# ------------------------------------------------------------------
echo ""
echo "Step 4: macOS privacy permissions..."
echo ""
echo "MacKeySwitch watches what you type in order to spot a wrong-layout word,"
echo "and types the corrected version back. macOS requires you to allow both"
echo "explicitly — no app can grant this to itself."
echo ""
read -r -p "Press [Enter] to begin the permission setup..."

"$SCRIPT_DIR/installer/regrant-permissions.sh" "$INSTALLED_APP" "$BUNDLE_ID"

echo ""
echo "=========================================="
echo " Setup complete."
echo "=========================================="
echo ""
echo "Rebuilding later? Without a stable signing identity every rebuild looks like"
echo "a brand-new app to macOS, and the Accessibility grant is forgotten. Either:"
echo ""
echo "  export MACKEYSWITCH_CODESIGN_IDENTITY=\"Apple Development: you@example.com\""
echo ""
echo "before building, or re-run installer/regrant-permissions.sh afterwards."
