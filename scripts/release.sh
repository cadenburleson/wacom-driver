#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Maintainer script: publishes a GitHub release with a notarized WacomDriver.dmg for people
# to download and the same app as WacomDriver.zip for scripts.
#
#   scripts/release.sh 1.2.0
#
# Needs a Developer ID certificate, the asc CLI (for notarization) and gh. Run it from a
# clean checkout that has been pushed; the release is tagged at the current commit.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=${1:?usage: scripts/release.sh <version>}
APP=.build/WacomDriver.app
ZIP=.build/WacomDriver.zip
DMG=.build/WacomDriver.dmg

if [ -n "$(git status --porcelain)" ]; then
    echo "Commit or stash your changes first." >&2
    exit 1
fi

scripts/build-app.sh "$VERSION"
ditto -c -k --keepParent "$APP" "$ZIP"
asc notarization submit --file "$ZIP" --wait
# Staple the ticket so the app opens without a network connection, then zip that copy.
xcrun stapler staple "$APP"
ditto -c -k --keepParent "$APP" "$ZIP"

# The disk image shows the app next to a shortcut to Applications, to drag one onto the other.
# Signing the image itself keeps macOS from running the app from a temporary copy.
STAGE=$(mktemp -d)
ditto "$APP" "$STAGE/WacomDriver.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname WacomDriver -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG"
rm -rf "$STAGE"
IDENTITY=$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/ {print $2; exit}')
codesign --sign "$IDENTITY" --timestamp "$DMG"
asc notarization submit --file "$DMG" --wait
xcrun stapler staple "$DMG"

gh release create "v$VERSION" "$DMG" "$ZIP" --target "$(git rev-parse HEAD)" --title "v$VERSION" --generate-notes
