# Guide for AI coding agents

This file is for an AI assistant (Claude Code, Codex, Cursor and the like) that has been
asked to set this driver up on someone's Mac, or to extend it to a tablet it does not support
yet. It assumes you can run shell commands on that Mac and that its owner is there to help.

## What you cannot do yourself

Three steps need the person, so plan around them and say exactly what you need:

- **Granting Accessibility.** Only they can turn on WacomDriver in System Settings → Privacy &
  Security → Accessibility. You cannot script this.
- **Moving the pen.** You cannot see or touch the tablet. To check anything, start a capture,
  ask for one specific action ("hover for two seconds, then press hard once"), and read the
  output.
- **Admin rights.** Removing Wacom's driver needs root. Never ask for a password in chat. Either
  have them run the `sudo` command, or run it through the macOS password dialog:
  `osascript -e 'do shell script "/bin/bash /absolute/path/to/script.sh" with administrator privileges'`

Ask before removing Wacom's driver; it deletes their software.

## Setting it up

1. **Identify the tablet.** Wacom's USB vendor ID is `056a`.

   ```sh
   hidutil list | grep -i 0x56a
   ```

   The second column is the product ID. If it is in the `models` table in
   `Sources/wacom-driver/Tablet.swift`, the tablet is supported: carry on. If not, go to
   [Adding a tablet](#adding-a-tablet). If nothing is listed, the tablet is not connected.

2. **Check for Wacom's own driver.** Two drivers on one tablet both move the cursor.

   ```sh
   launchctl list | grep -i wacom
   ls /Applications | grep -i -E 'wacom|pen tablet'
   ```

   If it is there, ask, then remove it with Wacom Tablet Utility → Uninstall or
   `sudo scripts/remove-official-driver.sh`. Read that script first: it lists every path it
   deletes.

3. **Install.** From a clone, when `xcode-select -p` shows developer tools are installed:

   ```sh
   scripts/install.sh
   ```

   Otherwise use the notarized release, which needs no tools:

   ```sh
   curl -L -o /tmp/WacomDriver.zip https://github.com/cadenburleson/wacom-driver/releases/latest/download/WacomDriver.zip
   mkdir -p ~/Applications && ditto -x -k /tmp/WacomDriver.zip ~/Applications
   ~/Applications/WacomDriver.app/Contents/MacOS/wacom-driver --install
   ```

4. **Ask for Accessibility.** macOS shows a prompt on first run. The driver waits for the
   grant and carries on by itself once it has it.

5. **Verify.** `~/Library/Logs/wacom-driver.log` should end with a line like
   `Intuos Draw S (CTL-490) connected.` A last line of `Waiting for permission` means step 4
   is not done. Then ask the person to draw something and confirm pressure works.

Settings live in `~/.config/wacom-driver/config.json`; the README documents every key. After
changing them, run `wacom-driver --install` again to restart the driver.

## How the code is laid out

One Swift package, no dependencies, about 600 lines.

| File | Job |
| --- | --- |
| `Tablet.swift` | Finds the tablet with IOHIDManager, switches it out of mouse emulation, decodes raw reports into `PenEvent`s and an ExpressKey bitmask. All tablet-specific knowledge is here. |
| `Pointer.swift` | Turns `PenEvent`s into `CGEvent` mouse and tablet events: screen mapping, pressure curve, clicks, proximity. Knows nothing about USB. |
| `Config.swift` | The settings file and key-combination parsing. |
| `LoginItem.swift` | Installs and removes the LaunchAgent, and the dialog shown when the app is opened. |
| `main.swift` | Command-line dispatch and the Accessibility wait. |

Data flows one way: HID report → `Tablet.received` → `PenEvent` → `Pointer.handle` → `CGEvent`.
A new tablet should only need changes in `Tablet.swift`.

## Adding a tablet

The reference for every Wacom protocol is the Linux kernel driver. Fetch
`drivers/hid/wacom_wac.c`, `wacom_wac.h` and `wacom_sys.c` from
<https://github.com/torvalds/linux/tree/master/drivers/hid> and read them alongside this.

1. **Look the tablet up.** In `wacom_wac.c`, find `wacom_features_0x<PRODUCT ID>`. It gives the
   name, maximum X and Y, maximum pressure, and a *type* such as `INTUOSHT2` or `BAMBOO_PEN`.
   The type decides everything else. For example:

   ```c
   static const struct wacom_features wacom_features_0x33B =
       { "Wacom Intuos S 2", 15200, 9500, 2047, 63, INTUOSHT2, ... };
   ```

2. **Find its decoder.** `wacom_wac_irq` switches on the type and calls the function that
   parses its reports. The types this driver handles go through `wacom_intuos_inout` and
   `wacom_intuos_general`; `penReport` in `Tablet.swift` is a port of those two. The older
   Bamboo and 2013 Intuos tablets (`BAMBOO_PEN`, `BAMBOO_PT`, `INTUOSHT`) use `wacom_bpt_pen`
   instead, which is short and a good first addition. ExpressKeys for all of these arrive
   through `wacom_bpt3_touch` and `wacom_bpt3_button_msg`, ported here as `padReport`.

3. **Find its mode switch.** Out of the box these tablets pretend to be a mouse.
   `_wacom_query_tablet_data` in `wacom_sys.c` picks a feature report and value per type that
   turns on real pen reports; for the supported family it is report 2, value 2 (`penMode`).
   Tablets with type `HID_GENERIC` describe themselves through standard HID digitizer usages
   and are a bigger job: they need descriptor parsing, not a fixed layout.

4. **Read the tablet's HID interfaces** to see which usage pages and report sizes to expect:

   ```sh
   ioreg -r -c IOHIDDevice -l -w 0 > /tmp/hid.txt
   ```

   Search the output for the tablet's product name. Each interface lists `PrimaryUsagePage`,
   `MaxInputReportSize`, `MaxFeatureReportSize` and the raw `ReportDescriptor`. IDs here are
   decimal: `1386` is `0x056a`. `Tablet.start` only matches usage pages `0xFF0D` (pen) and
   `0xFF00` (pad), so add the tablet's pages if they differ.

5. **Add the model, then capture.** Put the product ID in `models` with the dimensions from
   step 1. Unknown IDs are ignored and never get the mode switch, so nothing arrives before
   this. Then:

   ```sh
   swift run wacom-driver --dump
   ```

   It prints every raw report in hex and, indented beneath it, whatever the decoder made of
   it. It needs no permissions and can run next to the installed driver. Ask the person for
   one action at a time and compare: hover in the top-left corner (x and y near 0), then the
   bottom-right (near 1), press lightly then hard (pressure rising towards 1), each side
   switch, each ExpressKey, pen away from the tablet (`leave`).

6. **Write the decoder.** Dispatch on report ID and length in `Tablet.received`, add a parse
   function beside `penReport`, and emit the same `PenEvent`s. Normalize x, y and pressure to
   0–1 with the top-left as the origin. Keep going until the dump matches what the person did.

7. **Try it for real.** `scripts/install.sh`, then have them draw. Posting events only works
   from the installed app (see the next section), which is why the dump comes first.

8. **Record it.** Add a row to the table in `README.md` marked tested, with the product ID.
   A pull request with the new model is welcome.

## macOS behaviour worth knowing

Each of these cost time to find out.

- **Reading needs no permission; posting does.** Opening a tablet's vendor-defined HID
  interfaces works from any process. Posting `CGEvent`s needs Accessibility, which macOS
  checks against the app responsible for the process. For a binary started from a shell that
  is the terminal, so `swift run wacom-driver --run` usually waits for a permission the
  terminal does not have. Test event posting through the installed app.
- **Ad-hoc signatures lose the grant.** Without a Developer ID, every rebuild is a new app as
  far as macOS is concerned, and the old Accessibility entry stops working while still looking
  enabled. Run `tccutil reset Accessibility com.cadenburleson.wacom-driver`, install again and
  ask for the grant again. Do as much as you can with `--dump` first.
- **A running process never sees the grant arrive.** `AXIsProcessTrusted()` keeps returning
  false until the process restarts, which is why `main.swift` re-execs itself while waiting.
- **Check synthesized events without posting them.** `NSEvent(cgEvent:)` on an event you built
  shows whether AppKit will read it as a tablet event (`subtype == .tabletPoint`, `pressure`,
  `pointingDeviceType`). Apps only see pressure when the mouse event carries the tablet-point
  subtype, and only tell pen from eraser through the proximity event.
- **The mode switch outlives the process.** The tablet stays in pen mode until it is replugged,
  so with no driver running the pen does nothing at all. The driver cannot put the old mode
  back on exit: reading feature report 2 does not return the mode (this family always answers
  `0x10`), so there is no known value to restore.
- **launchd needs a moment.** `launchctl bootstrap` straight after `bootout` fails while the old
  instance is shutting down, so `LoginItem.install` retries.
- **Logs.** The installed driver writes to `~/Library/Logs/wacom-driver.log`.

## Conventions

- Swift only, no third-party packages, no kernel or system extensions.
- Start every source file with `// SPDX-License-Identifier: GPL-2.0-or-later`. The decoders are
  derived from the GPL Linux driver, so the project has to stay GPL.
- Comments say why, not what. Match the style of the file you are in.
- `scripts/release.sh` is for the maintainer; it needs their signing certificate.
