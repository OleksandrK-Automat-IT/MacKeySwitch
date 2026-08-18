#!/bin/bash
# Walk the user through granting MacKeySwitch the permissions it needs.
#
# Worth knowing why this is a script and not a checkbox: an ad-hoc signature is different
# on every rebuild, so macOS files each build as a different app. The old entry in System
# Settings keeps pointing at a signature that no longer exists, and re-ticking its checkbox
# grants nothing — the entry has to be removed and the app added again. Setting
# MACKEYSWITCH_CODESIGN_IDENTITY to a stable identity avoids the whole dance.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
APP_BUNDLE="${1:-$PROJECT_DIR/dist/MacKeySwitch.app}"
BUNDLE_ID="${2:-com.okuzmin.mackeyswitch}"
EXECUTABLE_NAME="LayoutSwitcher"

if [ ! -d "$APP_BUNDLE" ]; then
    echo "ERROR: no app bundle at $APP_BUNDLE"
    exit 1
fi

echo "Stopping running MacKeySwitch..."
pkill -x "$EXECUTABLE_NAME" 2>/dev/null || true
sleep 1

echo "Resetting stale privacy entries for $BUNDLE_ID..."
# Accessibility: needed to post the corrected keystrokes.
tccutil reset Accessibility "$BUNDLE_ID" >/dev/null 2>&1 || true
# ListenEvent = "Input Monitoring": needed by the event tap that watches for typing.
tccutil reset ListenEvent "$BUNDLE_ID" >/dev/null 2>&1 || true

echo "Opening Privacy settings (Accessibility)..."
open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility" >/dev/null 2>&1 || true

echo "Opening Finder with MacKeySwitch selected (for drag and drop)..."
open -R "$APP_BUNDLE"

cat <<EOF

==================================================
 Step 1 of 2 — Accessibility
==================================================
MacKeySwitch types the corrected word for you, and macOS only lets an app
send keystrokes with Accessibility access.

  1. If a 'MacKeySwitch' entry is already listed, select it and click '-'.
     (Re-ticking the old entry does not work after a rebuild — see above.)
  2. Drag MacKeySwitch.app from the Finder window into the list.
  3. Make sure its toggle is on.

EOF

read -r -p "Press [Enter] when Accessibility is done... "

echo "Opening Privacy settings (Input Monitoring)..."
open "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent" >/dev/null 2>&1 || true

cat <<EOF

==================================================
 Step 2 of 2 — Input Monitoring
==================================================
This is what lets MacKeySwitch see the word you are typing. Depending on your
macOS version, Accessibility alone may already cover it — if MacKeySwitch does
not appear in this list at all, that is fine, just skip it.

  1. Remove any stale 'MacKeySwitch' entry with '-'.
  2. Drag MacKeySwitch.app into the list.
  3. Make sure its toggle is on.

EOF

read -r -p "Press [Enter] when you are done, to launch MacKeySwitch... "

echo "Launching $APP_BUNDLE"
open "$APP_BUNDLE"

cat <<EOF

MacKeySwitch runs in the menu bar — look for the flag icon near the clock.
If the icon shows '?? ⚠' it is still waiting for Accessibility; it will start
on its own within a couple of seconds of the permission being granted.
EOF
