#!/bin/sh
# Builds BatteryLimiter.app and packages it for a GitHub release.
#
# ditto rather than zip: it preserves the bundle's symlinks and extended
# attributes, and a plain `zip` can produce an .app that no longer passes
# `codesign --verify` on the other end.
set -e
cd "$(dirname "$0")/.."

./Scripts/build_app.sh

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" \
    BatteryLimiter.app/Contents/Info.plist)
ZIP="BatteryLimiter-$VERSION.zip"

rm -f "$ZIP"
ditto -c -k --keepParent BatteryLimiter.app "$ZIP"

# Verify the signature survived the round trip, since that's what breaks silently.
WORK=$(mktemp -d)
ditto -x -k "$ZIP" "$WORK"
codesign --verify --deep "$WORK/BatteryLimiter.app"
rm -rf "$WORK"

echo
echo "Built $ZIP"
echo "SHA-256: $(shasum -a 256 "$ZIP" | cut -d' ' -f1)"
echo
echo "Attach it to a release with:"
echo "  gh release create v$VERSION $ZIP --title \"v$VERSION\" --notes \"...\""
