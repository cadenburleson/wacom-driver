// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit

setvbuf(stdout, nil, _IOLBF, 0)

let usage = """
usage: wacom-driver <command>

  --run         run the driver in the foreground
  --dump        print the tablet's raw reports instead of moving the cursor
  --install     start the driver now and at every login
  --uninstall   stop the driver and remove it from login

Opening WacomDriver.app does the same as --install.
Settings are read from \(Config.url.path).
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
case nil where Bundle.main.bundleURL.pathExtension == "app":
    LoginItem.showManager()
    exit(0)
default:
    print(usage)
    exit(arguments.first == "--help" ? 0 : 64)
}

let tablet = Tablet()
tablet.dump = arguments.first == "--dump"

if !tablet.dump {
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
}

tablet.start()

let signals = [SIGINT, SIGTERM].map { number in
    signal(number, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
    source.setEventHandler {
        tablet.stop()
        exit(0)
    }
    source.resume()
    return source
}

CFRunLoopRun()
