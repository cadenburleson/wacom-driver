# wacom-driver

An open-source macOS driver for Wacom's 2015 Intuos pen tablets, written after Wacom's own
driver kept crashing on macOS 27.

It reads the tablet's raw USB reports and posts the pen as real tablet events, so apps get
absolute positioning, pressure and eraser detection. It runs entirely in user space: no
kernel or system extension, no network access, and nothing is written to the tablet.

This is an unofficial project and is not affiliated with or endorsed by Wacom. "Wacom" and
"Intuos" are trademarks of Wacom Co., Ltd.

## Supported tablets

| USB ID | Tablet | Status |
| --- | --- | --- |
| `056a:033b` | Intuos Draw S (CTL-490) | tested |
| `056a:033c` | Intuos Art S (CTH-490) | untested, pen only |
| `056a:033d` | Intuos Draw M (CTL-690) | untested |
| `056a:033e` | Intuos Art M (CTH-690) | untested, pen only |

To find your tablet's ID, hold Option and choose Apple menu → System Information → USB, or
run `system_profiler SPUSBDataType`. Other Wacom tablets use different report formats and
will be ignored; see [Other tablets](#other-tablets).

Requires macOS 13 or later. Tested on Apple silicon with macOS 27; the Intel build is
untested.

## Install

1. Uninstall Wacom's own driver if you have it (Wacom Tablet Utility → Uninstall), or the two
   will fight over the tablet.
2. Download `WacomDriver.zip` from the
   [latest release](https://github.com/cadenburleson/wacom-driver/releases/latest) and unzip it.
3. Move **WacomDriver** to your Applications folder and open it.
4. When macOS asks, turn on **WacomDriver** in System Settings → Privacy & Security →
   Accessibility. The driver needs this to move the cursor.

The driver then runs in the background and starts whenever you log in. To update, replace the
app with the new version and open it once. To uninstall, open the app and choose
**Uninstall**, then move it to the Trash.

## Settings

Optional, in `~/.config/wacom-driver/config.json`. Defaults:

```json
{
  "display": 0,
  "leftHanded": false,
  "keepAspect": true,
  "pressureGamma": 1.0,
  "tipThreshold": 0.02,
  "penButtons": ["right", "middle"],
  "expressKeys": ["cmd+z", "cmd+shift+z", "[", "]"]
}
```

- `display`: which screen the tablet maps to; 0 is the main display.
- `leftHanded`: rotate the tablet 180°.
- `keepAspect`: use only the part of the tablet that matches the screen's shape, so circles
  stay round.
- `pressureGamma`: below 1 makes the pen softer, above 1 firmer.
- `tipThreshold`: how hard the tip must press, from 0 to 1, before it counts as a click.
- `penButtons`: lower and upper side switch; `"right"`, `"middle"` or `"none"`.
- `expressKeys`: the tablet's four buttons. Each is a key combination (`"cmd+shift+z"`,
  `"space"`) or bare modifiers (`"shift"`) that are held while the button is down.

Open WacomDriver again to apply changes.

## Build from source

Needs Xcode or its command line tools.

```sh
git clone https://github.com/cadenburleson/wacom-driver.git
cd wacom-driver
scripts/install.sh
```

This builds `WacomDriver.app`, copies it to `~/Applications` and starts it;
`scripts/uninstall.sh` reverses that. Without a Developer ID certificate the app is signed
ad hoc, and macOS asks for Accessibility again after every rebuild.

`sudo scripts/remove-official-driver.sh` removes Wacom's driver if its own uninstaller is
missing or broken.

## Troubleshooting

- **The pen does nothing:** check that WacomDriver is turned on under Accessibility, then
  open the app again to restart the driver.
- **The pen works as a slow, relative mouse:** the driver is not running, and the tablet has
  fallen back to its built-in mouse mode. Open the app.
- **Logs:** `~/Library/Logs/wacom-driver.log`.
- **Raw reports:** from a source checkout, `swift run wacom-driver --dump` prints what a
  supported tablet sends.

## Other tablets

Each Wacom family has its own report format, so a new tablet needs its own decoder. If you
have one and want it supported, open an issue with the tablet's model and USB ID. The 2013
Intuos and Bamboo tablets are the closest relatives and the likeliest to be added.

## Credits and license

The report layout was worked out from the Linux kernel's Wacom driver
(`drivers/hid/wacom_wac.c`).

Licensed under the GNU General Public License, version 2 or (at your option) any later
version. See [LICENSE](LICENSE).
