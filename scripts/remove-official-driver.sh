#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Removes Wacom's own drivers (Wacom Tablet 6.x and the legacy Pen Tablet 5.x), which would
# otherwise compete with this one for the tablet. Run with sudo.
set -uo pipefail

if [ "$EUID" -ne 0 ]; then
    echo "Run with sudo." >&2
    exit 1
fi

USER_ID=$(stat -f %u /dev/console)
for agent in DataStoreMgr IOManager wacomtablet pentablet; do
    launchctl bootout "gui/$USER_ID" "/Library/LaunchAgents/com.wacom.$agent.plist" 2>/dev/null
done
launchctl bootout system /Library/LaunchDaemons/com.wacom.UpdateHelper.plist 2>/dev/null
pkill -f '/Wacom Tablet\.localized/|/PrivilegedHelperTools/(com\.wacom\.|Wacom_)|/PenTabletDriver\.app/'

PATHS=(
    "/Applications/Wacom Tablet.localized"
    "/Applications/Pen Tablet.localized"
    "/Library/Application Support/Tablet"
    "/Library/DCV Extensions/WacomADCV.json"
    "/Library/Extensions/Pen Tablet.kext"
    "/Library/Extensions/SiLabsUSBDriver64.kext"
    "/Library/Frameworks/WacomMultiTouch.framework"
    "/Library/Internet Plug-Ins/WacomTabletPlugin.plugin"
    "/Library/LaunchAgents/com.wacom.DataStoreMgr.plist"
    "/Library/LaunchAgents/com.wacom.IOManager.plist"
    "/Library/LaunchAgents/com.wacom.wacomtablet.plist"
    "/Library/LaunchAgents/com.wacom.pentablet.plist"
    "/Library/LaunchDaemons/com.wacom.UpdateHelper.plist"
    "/Library/PreferencePanes/WacomCenter.prefpane"
    "/Library/PreferencePanes/WacomTablet.prefpane"
    "/Library/Preferences/Tablet"
    "/Library/PrivilegedHelperTools/Wacom_IOManager.app"
    "/Library/PrivilegedHelperTools/com.wacom.DataStoreMgr.app"
    "/Library/PrivilegedHelperTools/com.wacom.TabletHelper.app"
    "/Library/PrivilegedHelperTools/com.wacom.UpdateHelper.app"
)

left=0
for path in "${PATHS[@]}"; do
    rm -rf "$path"
    if [ -e "$path" ]; then
        echo "Could not remove $path"
        left=1
    fi
done
rmdir "/Library/DCV Extensions" 2>/dev/null

pkgutil --forget com.wacom.TabletInstaller >/dev/null 2>&1
pkgutil --forget com.wacom.PenTabletInstaller >/dev/null 2>&1

[ "$left" -eq 0 ] && echo "Wacom's drivers are removed."
exit "$left"
