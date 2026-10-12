// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import notify

setvbuf(stdout, nil, _IOLBF, 0)

let usage = """
usage: wacom-driver <command>

  --run         run the driver in the foreground
  --dump        print the tablet's raw reports and what they decode to
  --install     start the driver now and at every login
  --uninstall   stop the driver and remove it from login

Opening WacomDriver.app installs the driver and shows its settings.
The settings are stored in \(Config.url.path).
"""

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case "--run", "--dump":
    break
case "--install":
    do {
        try LoginItem.install()
        print("WacomDriver is running and will start at login.")
        exit(0)
    } catch {
        print(error.localizedDescription)
        exit(1)
    }
case "--uninstall":
    LoginItem.uninstall()
    print("WacomDriver is uninstalled.")
    exit(0)
case "--trusted":
    // Internal: lets the settings window ask a fresh process whether Accessibility is granted.
    exit(AXIsProcessTrusted() ? 0 : 1)
case nil where Bundle.main.bundleURL.pathExtension == "app":
    SettingsApp.run()
default:
    print(usage)
    exit(arguments.first == "--help" ? 0 : 64)
}

/// Changes when the app on disk is replaced by an update.
func executableStamp() -> String {
    let attributes = try? FileManager.default.attributesOfItem(atPath: Bundle.main.executablePath ?? "")
    return "\(attributes?[.systemFileNumber] ?? 0) \(attributes?[.modificationDate] ?? 0)"
}

let tablet = Tablet()
tablet.dump = arguments.first == "--dump"

if tablet.dump {
    // Show what each report decodes to, so a decoder can be checked without Accessibility.
    tablet.onPen = { print("  \($0)") }
    tablet.onKeys = { print("  keys \($0)") }
} else {
    // Posting events needs Accessibility. A running process never sees the grant arrive, so
    // re-exec until a fresh check passes, prompting only the first time round.
    let waiting = arguments.contains("--waiting")
    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: !waiting] as CFDictionary
    if !AXIsProcessTrustedWithOptions(options) {
        if !waiting {
            print("Waiting for permission: System Settings → Privacy & Security → Accessibility.")
        }
        sleep(2)
        let path = Bundle.main.executablePath ?? CommandLine.arguments[0]
        execv(path, [strdup(path), strdup("--run"), strdup("--waiting"), nil])
        exit(1)
    }
    if waiting { print("Permission granted.") }
    let pointer = Pointer(config: Config.load())
    tablet.onPen = pointer.handle
    tablet.onKeys = pointer.handleKeys

    // Sent by the settings window whenever it opens or saves a change.
    let stamp = executableStamp()
    var token: Int32 = 0
    notify_register_dispatch(Config.changedNotification, &token, .main) { _ in
        // Make way for an updated app; launchd starts the new copy straight away.
        if executableStamp() != stamp { exit(0) }
        pointer.apply(Config.load())
        print("Settings reloaded.")
    }
}

tablet.start()
CFRunLoopRun()
