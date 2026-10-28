#!/bin/bash
# Builds a release and packs it for download: dist/SiliconMeter-<version>.zip and .dmg.
# Ad-hoc signed, not notarized (no Apple Developer ID); see README "설치" for the first-launch
# steps a downloaded copy needs.
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/build_app.sh >/dev/null
APP="build/SiliconMeter.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
NAME="SiliconMeter-$VERSION"

rm -rf dist && mkdir -p dist
codesign --verify --deep --strict "$APP"

# Zip: ditto keeps the bundle's extended attributes and symlinks intact.
ditto -c -k --sequesterRsrc --keepParent "$APP" "dist/$NAME.zip"

# Disk image with an Applications shortcut for drag-to-install.
STAGE=$(mktemp -d)
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "SiliconMeter" -srcfolder "$STAGE" -ov -format UDZO "dist/$NAME.dmg"
rm -rf "$STAGE"

( cd dist && shasum -a 256 "$NAME.zip" "$NAME.dmg" > "$NAME.sha256" )
echo "Packed:"
ls -lh dist
