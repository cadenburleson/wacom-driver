// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit

/// Keeps the driver running in the background through a per-user LaunchAgent that points
/// back at this executable.
enum LoginItem {
    static let label = "com.cadenburleson.wacom-driver"

    private static let library = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library")
    private static let agentURL = library.appendingPathComponent("LaunchAgents/\(label).plist")
    private static let logURL = library.appendingPathComponent("Logs/wacom-driver.log")
    private static var domain: String { "gui/\(getuid())" }

    struct Failure: LocalizedError {
        let errorDescription: String?
    }

    /// Starts the driver now and at every login, replacing any copy already running.
    static func install() throws {
        guard let executable = Bundle.main.executablePath else {
            throw Failure(errorDescription: "Could not find the driver's own executable.")
        }
        let agent: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executable, "--run"],
            "RunAtLoad": true,
            "KeepAlive": true,
            "ProcessType": "Interactive",
            "LimitLoadToSessionType": "Aqua",
            "StandardOutPath": logURL.path,
            "StandardErrorPath": logURL.path,
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: agent, format: .xml, options: 0)
        try FileManager.default.createDirectory(at: agentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: agentURL)

        launchctl("bootout", "\(domain)/\(label)")
        // launchd refuses to load the agent until the old instance has finished shutting down.
        for _ in 0..<20 {
            if launchctl("bootstrap", domain, agentURL.path) == 0 { return }
            usleep(250_000)
        }
        throw Failure(errorDescription: "launchd would not start the driver.")
    }

    /// Stops the driver, which puts the tablet back in its built-in mouse mode.
    static func uninstall() {
        launchctl("bootout", "\(domain)/\(label)")
        try? FileManager.default.removeItem(at: agentURL)
        run("/usr/bin/tccutil", ["reset", "Accessibility", label])
    }

    /// What opening the app does: start the driver, then say what happens next.
    static func showManager() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.activate(ignoringOtherApps: true)

        // A freshly downloaded app runs from a random read-only path until it is moved.
        if Bundle.main.bundlePath.contains("/AppTranslocation/") {
            alert("Move WacomDriver to Applications first",
                  "macOS is running this copy from a temporary location. Drag WacomDriver into your Applications folder, then open it from there.")
            return
        }
        do {
            try install()
        } catch {
            alert("WacomDriver could not start", error.localizedDescription)
            return
        }

        let choice = alert(
            "WacomDriver is running",
            """
            It works in the background and starts when you log in.

            The first time, macOS asks for Accessibility permission, which the driver needs to move the cursor: turn on WacomDriver in System Settings → Privacy & Security → Accessibility.
            """,
            buttons: ["OK", "Open Accessibility Settings", "Uninstall"])
        switch choice {
        case .alertSecondButtonReturn:
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        case .alertThirdButtonReturn:
            uninstall()
            alert("WacomDriver is uninstalled", "You can now move it to the Trash.")
        default:
            break
        }
    }

    @discardableResult
    private static func alert(_ title: String, _ text: String, buttons: [String] = ["OK"]) -> NSApplication.ModalResponse {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        buttons.forEach { alert.addButton(withTitle: $0) }
        return alert.runModal()
    }

    @discardableResult
    private static func launchctl(_ arguments: String...) -> Int32 {
        run("/bin/launchctl", arguments)
    }

    @discardableResult
    private static func run(_ tool: String, _ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return -1
        }
        process.waitUntilExit()
        return process.terminationStatus
    }
}
