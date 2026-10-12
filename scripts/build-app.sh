#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Builds .build/WacomDriver.app.
#
#   scripts/build-app.sh            build for this Mac
#   scripts/build-app.sh 1.2.0      release build: universal, hardened, stamped with a version
#
# Signs with a Developer ID when the keychain has one. Otherwise the signature is ad hoc and
# macOS asks for Accessibility again after every rebuild.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=${1:-}
APP=.build/WacomDriver.app
BUILD=(swift build -c release)
SIGN=(codesign --force)
if [ -n "$VERSION" ]; then
    BUILD+=(--arch arm64 --arch x86_64)
    SIGN+=(--options runtime --timestamp)
fi

"${BUILD[@]}"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$("${BUILD[@]}" --show-bin-path)/wacom-driver" "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
if [ -n "$VERSION" ]; then
    plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
fi

IDENTITY=$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/ {print $2; exit}')
"${SIGN[@]}" --sign "${IDENTITY:--}" "$APP"
