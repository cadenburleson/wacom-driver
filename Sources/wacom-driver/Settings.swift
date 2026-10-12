// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import SwiftUI
import notify

/// What opening the app does: makes sure the driver is running, then shows a window for
/// choosing what the tablet's buttons do.
enum SettingsApp {
    private static let delegate = AppDelegate()

    static func run() -> Never {
        let app = NSApplication.shared
        // The background driver has no Dock icon; the settings window gets one while it is open.
        app.setActivationPolicy(.regular)
        app.activate(ignoringOtherApps: true)

        // A freshly downloaded app runs from a random read-only path until it is moved.
        if Bundle.main.bundlePath.contains("/AppTranslocation/") {
            alert("Move WacomDriver to Applications first",
                  "macOS is running this copy from a temporary location. Drag WacomDriver into your Applications folder, then open it from there.")
            exit(0)
        }
        if LoginItem.isCurrent {
            // A driver still running from before an update takes this as its cue to restart.
            notify_post(Config.changedNotification)
        } else {
            do {
                try LoginItem.install()
            } catch {
                alert("WacomDriver could not start", error.localizedDescription)
                exit(1)
            }
        }

        app.delegate = delegate
        app.mainMenu = mainMenu()
        app.run()
        exit(0)
    }

    static func alert(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.runModal()
    }

    private static func mainMenu() -> NSMenu {
        let menu = NSMenu()
        let appMenu = NSMenu()
        // Not "Quit": the driver itself keeps running.
        appMenu.addItem(withTitle: "Close Settings", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        for submenu in [appMenu, windowMenu] {
            let item = NSMenuItem()
            item.submenu = submenu
            menu.addItem(item)
        }
        return menu
    }
}

private final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = NSHostingController(rootView: SettingsView(model: SettingsModel()))
        // The window grows while the Accessibility notice is showing.
        controller.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentViewController: controller)
        window.title = "WacomDriver"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

final class SettingsModel: ObservableObject {
    @Published private(set) var config = Config.load()
    /// Bitmask of the tablet buttons held right now.
    @Published private(set) var pressed: UInt8 = 0
    /// The tablet button whose shortcut is being recorded.
    @Published private(set) var recording: Int?
    @Published private(set) var tabletName: String?
    @Published private(set) var trusted = LoginItem.isTrusted

    // Our own connection to the tablet, used only to show which button is being pressed.
    private let tablet = Tablet()
    private var monitor: Any?

    init() {
        tablet.onKeys = { [weak self] in self?.pressed = $0 }
        tablet.onConnection = { [weak self] in self?.tabletName = $0 }
        tablet.start()
        if !trusted {
            Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
                guard LoginItem.isTrusted else { return }
                self?.trusted = true
                timer.invalidate()
            }
        }
    }

    func expressKey(_ index: Int) -> String {
        index < config.expressKeys.count ? config.expressKeys[index] : ""
    }

    func setExpressKey(_ index: Int, _ spec: String) {
        var keys = config.expressKeys
        keys += Array(repeating: "", count: max(0, index + 1 - keys.count))
        keys[index] = spec
        config.expressKeys = keys
        save()
    }

    func penButton(_ index: Int) -> Binding<String> {
        Binding(
            get: { index < self.config.penButtons.count ? self.config.penButtons[index].lowercased() : "none" },
            set: { action in
                var buttons = self.config.penButtons
                buttons += Array(repeating: "none", count: max(0, index + 1 - buttons.count))
                buttons[index] = action
                self.config.penButtons = buttons
                self.save()
            })
    }

    /// Starts or cancels recording a shortcut for a tablet button.
    func toggleRecording(_ index: Int) {
        let wasRecording = recording == index
        stopRecording()
        guard !wasRecording else { return }
        recording = index

        // A modifier pressed and released on its own becomes a binding that holds it.
        var modifiers: CGEventFlags = []
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            // Pressing a tablet button mid-recording must not record that button's own shortcut.
            if event.cgEvent?.getIntegerValueField(.eventSourceUserData) == Pointer.eventMarker { return nil }
            let flags = CGEventFlags(event.modifierFlags)
            var spec: String?
            if event.type == .keyDown {
                spec = KeyBinding.spec(flags: flags, key: event.keyCode)
                if spec == nil { NSSound.beep() }
            } else if flags.isEmpty {
                spec = KeyBinding.spec(flags: modifiers, key: nil)
            } else {
                modifiers.formUnion(flags)
            }
            if let spec {
                self?.setExpressKey(index, spec)
                self?.stopRecording()
            }
            return nil
        }
    }

    func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    func uninstall() {
        let confirm = NSAlert()
        confirm.messageText = "Uninstall WacomDriver?"
        confirm.informativeText = "The driver stops and no longer starts when you log in. Your settings are kept."
        confirm.addButton(withTitle: "Uninstall")
        confirm.addButton(withTitle: "Cancel")
        guard confirm.runModal() == .alertFirstButtonReturn else { return }
        LoginItem.uninstall()
        SettingsApp.alert("WacomDriver is uninstalled",
                          "You can now move it to the Trash. Unplug the tablet and plug it back in to use it as a basic mouse.")
        NSApp.terminate(nil)
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = nil
    }

    private func save() {
        do {
            try config.save()
        } catch {
            SettingsApp.alert("The settings could not be saved", error.localizedDescription)
        }
    }
}

private struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Label(model.tabletName.map { "\($0) connected" } ?? "No supported tablet connected",
                          systemImage: model.tabletName == nil ? "exclamationmark.triangle" : "checkmark.circle.fill")
                    if !model.trusted {
                        LabeledContent {
                            Button("Open Settings…", action: model.openAccessibilitySettings)
                        } label: {
                            Label("The pen cannot move the cursor until WacomDriver is turned on under Accessibility.",
                                  systemImage: "hand.raised.fill")
                        }
                    }
                }
                Section {
                    ForEach(0..<Tablet.expressKeyCount, id: \.self) { index in
                        LabeledContent {
                            ShortcutField(model: model, index: index)
                        } label: {
                            Label {
                                Text("Button \(index + 1)")
                            } icon: {
                                // Lights up while that button is held on the tablet.
                                Image(systemName: "circle.fill")
                                    .imageScale(.small)
                                    .foregroundStyle(model.pressed & (1 << UInt8(index)) != 0
                                        ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary))
                            }
                        }
                    }
                } header: {
                    Text("Tablet buttons")
                } footer: {
                    Text("Press a button on the tablet to see which row it is. To change one, click its shortcut and type the keys, or press and release a modifier key on its own to have the button hold it.")
                }
                Section("Pen buttons") {
                    ForEach(0..<2, id: \.self) { index in
                        Picker(index == 0 ? "Lower button" : "Upper button", selection: model.penButton(index)) {
                            Text("Right click").tag("right")
                            Text("Middle click").tag("middle")
                            Text("Nothing").tag("none")
                        }
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Button("Uninstall…", action: model.uninstall)
                Spacer()
                Text("The driver keeps running after you close this window.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 480, height: model.trusted ? 540 : 610)
    }
}

private struct ShortcutField: View {
    @ObservedObject var model: SettingsModel
    let index: Int

    var body: some View {
        let binding = KeyBinding(model.expressKey(index))
        let recording = model.recording == index
        HStack(spacing: 6) {
            if binding != nil, !recording {
                Button {
                    model.setExpressKey(index, "")
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .help("Make this button do nothing")
            }
            Button(recording ? "Type a shortcut…" : binding?.label ?? "Nothing") {
                model.toggleRecording(index)
            }
        }
    }
}

private extension CGEventFlags {
    init(_ flags: NSEvent.ModifierFlags) {
        self = []
        if flags.contains(.control) { insert(.maskControl) }
        if flags.contains(.option) { insert(.maskAlternate) }
        if flags.contains(.shift) { insert(.maskShift) }
        if flags.contains(.command) { insert(.maskCommand) }
    }
}
