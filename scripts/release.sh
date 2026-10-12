#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Maintainer script: publishes a notarized WacomDriver.zip as a GitHub release.
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

gh release create "v$VERSION" "$ZIP" --target "$(git rev-parse HEAD)" --title "v$VERSION" --generate-notes
