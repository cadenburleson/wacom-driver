#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Undoes scripts/install.sh. The tablet goes back to its built-in mouse mode.
set -euo pipefail

APP="$HOME/Applications/WacomDriver.app"

if [ -x "$APP/Contents/MacOS/wacom-driver" ]; then
    "$APP/Contents/MacOS/wacom-driver" --uninstall
fi
rm -rf "$APP"
