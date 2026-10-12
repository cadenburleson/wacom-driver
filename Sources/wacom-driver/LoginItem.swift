// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

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

    /// Whether launchd is already running the driver from this copy of the app.
    static var isCurrent: Bool {
        guard let agent = NSDictionary(contentsOf: agentURL),
              let arguments = agent["ProgramArguments"] as? [String] else { return false }
        return arguments.first == Bundle.main.executablePath && launchctl("print", "\(domain)/\(label)") == 0
    }

    /// Whether the app has Accessibility. Asked of a fresh process, because a running one
    /// never sees a grant that arrived after it started.
    static var isTrusted: Bool {
        guard let executable = Bundle.main.executablePath else { return false }
        return run(executable, ["--trusted"]) == 0
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

    /// Stops the driver. The tablet stays in pen mode, and so does nothing, until it is replugged.
    static func uninstall() {
        launchctl("bootout", "\(domain)/\(label)")
        try? FileManager.default.removeItem(at: agentURL)
        run("/usr/bin/tccutil", ["reset", "Accessibility", label])
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
