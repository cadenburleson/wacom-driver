#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Builds the driver from source, puts it in ~/Applications and starts it at login.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="$HOME/Applications/WacomDriver.app"

scripts/build-app.sh
mkdir -p "$HOME/Applications"
rm -rf "$APP"
cp -R .build/WacomDriver.app "$APP"
"$APP/Contents/MacOS/wacom-driver" --install
