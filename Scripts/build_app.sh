#!/bin/sh
# Builds the Swift package and assembles BatteryLimiter.app.
# No Xcode project is used -- SPM + a bundle wrapper is enough for a
# menu bar app, and it's a much shorter path without a paid Developer ID.
set -e
cd "$(dirname "$0")/.."

swift build -c release

APP="BatteryLimiter.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

cp .build/release/BatteryLimiter "$APP/Contents/MacOS/BatteryLimiter"
cp .build/release/BatteryLimiterHelper "$APP/Contents/MacOS/battery-limiter-helper"
cp Sources/BatteryLimiter/Info.plist "$APP/Contents/Info.plist"

# Ad-hoc sign: no Developer ID, but SMAppService.mainApp.register() and
# launchd both require *some* signature to be present.
codesign --force --deep --sign - "$APP"

echo "Built $APP"
