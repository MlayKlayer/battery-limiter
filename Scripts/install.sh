#!/bin/sh
# Builds BatteryLimiter.app and installs it to /Applications, then launches it.
# No sudo: /Applications is group-writable by admin, and a root-owned bundle
# would break the user-level SMAppService login-item registration.
set -e
cd "$(dirname "$0")/.."

./Scripts/build_app.sh

DEST="/Applications/BatteryLimiter.app"

# Quit any running copy first -- copying over a live bundle corrupts it.
osascript -e 'quit app "BatteryLimiter"' 2>/dev/null || true
pkill -x BatteryLimiter 2>/dev/null || true

rm -rf "$DEST"
ditto BatteryLimiter.app "$DEST"

# The signature must survive the copy or SMAppService.mainApp.register() fails.
codesign --verify "$DEST"

open "$DEST"
echo "Installed $DEST and launched it -- look for the battery % in your menu bar."
