// SPDX-License-Identifier: GPL-2.0-or-later
import CoreGraphics
import Foundation
import notify

/// User settings, read from ~/.config/wacom-driver/config.json. Every key is optional.
struct Config: Codable {
    /// Index into the active display list; 0 is the main display.
    var display = 0
    /// Rotate the tablet 180° (cable on the right).
    var leftHanded = false
    /// Use only the part of the tablet that matches the display's aspect ratio.
    var keepAspect = true
    /// Pressure curve exponent: below 1 is softer, above 1 is firmer.
    var pressureGamma = 1.0
    /// Pressure (0–1) at which the tip counts as pressed.
    var tipThreshold = 0.02
    /// Lower and upper pen side switch: "right", "middle" or "none".
    var penButtons = ["right", "middle"]
    /// The four ExpressKeys, in the order the tablet reports them (see --dump).
    var expressKeys = ["cmd+z", "cmd+shift+z", "[", "]"]

    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/wacom-driver/config.json")
    /// Darwin notification that tells the running driver to read the file again.
    static let changedNotification = "com.cadenburleson.wacom-driver.config-changed"

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        display = try c.decodeIfPresent(Int.self, forKey: .display) ?? display
        leftHanded = try c.decodeIfPresent(Bool.self, forKey: .leftHanded) ?? leftHanded
        keepAspect = try c.decodeIfPresent(Bool.self, forKey: .keepAspect) ?? keepAspect
        pressureGamma = try c.decodeIfPresent(Double.self, forKey: .pressureGamma) ?? pressureGamma
        tipThreshold = try c.decodeIfPresent(Double.self, forKey: .tipThreshold) ?? tipThreshold
        penButtons = try c.decodeIfPresent([String].self, forKey: .penButtons) ?? penButtons
        expressKeys = try c.decodeIfPresent([String].self, forKey: .expressKeys) ?? expressKeys
    }

    enum CodingKeys: String, CodingKey {
        case display, leftHanded, keepAspect, pressureGamma, tipThreshold, penButtons, expressKeys
    }

    static func load() -> Config {
        guard let data = try? Data(contentsOf: url) else { return Config() }
        do {
            return try JSONDecoder().decode(Config.self, from: data)
        } catch {
            print("Ignoring \(url.path): \(error)")
            return Config()
        }
    }

    /// Writes the file and has the running driver pick it up.
    func save() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try FileManager.default.createDirectory(at: Config.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(self).write(to: Config.url, options: .atomic)
        notify_post(Config.changedNotification)
    }
}

/// A key combination such as "cmd+shift+z", or bare modifiers such as "shift" that are held
/// for as long as the ExpressKey is down.
struct KeyBinding {
    var flags: CGEventFlags = []
    var key: CGKeyCode?
    /// Key code reported in the flagsChanged event of a modifier-only binding.
    var modifierKey: CGKeyCode = 0

    init?(_ spec: String) {
        for part in spec.lowercased().split(separator: "+") {
            switch part {
            case "cmd", "command": flags.insert(.maskCommand); modifierKey = 55
            case "shift": flags.insert(.maskShift); modifierKey = 56
            case "opt", "option", "alt": flags.insert(.maskAlternate); modifierKey = 58
            case "ctrl", "control": flags.insert(.maskControl); modifierKey = 59
            default:
                guard let code = KeyBinding.keyCodes[String(part)] else { return nil }
                key = code
            }
        }
        if key == nil && flags.isEmpty { return nil }
    }

    /// The text `init` parses for a combination, or nil when the key has no name here.
    static func spec(flags: CGEventFlags, key: CGKeyCode?) -> String? {
        var parts = modifiers.filter { flags.contains($0.flag) }.map(\.name)
        if let key {
            guard let name = keyNames[key] else { return nil }
            parts.append(name)
        }
        return parts.isEmpty ? nil : parts.joined(separator: "+")
    }

    /// How the binding reads in the settings window, such as "⇧⌘Z" or "Hold ⇧".
    var label: String {
        let symbols = KeyBinding.modifiers.filter { flags.contains($0.flag) }.map(\.symbol).joined()
        guard let key, let name = KeyBinding.keyNames[key] else { return "Hold " + symbols }
        let isShort = name.count == 1 || (name.hasPrefix("f") && Int(name.dropFirst()) != nil)
        return symbols + (KeyBinding.keyLabels[name] ?? (isShort ? name.uppercased() : name.capitalized))
    }

    // In the order macOS draws them.
    private static let modifiers: [(flag: CGEventFlags, name: String, symbol: String)] = [
        (.maskControl, "ctrl", "⌃"), (.maskAlternate, "opt", "⌥"), (.maskShift, "shift", "⇧"), (.maskCommand, "cmd", "⌘"),
    ]

    // ANSI virtual key codes.
    static let keyCodes: [String: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11,
        "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21,
        "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31,
        "u": 32, "[": 33, "i": 34, "p": 35, "return": 36, "l": 37, "j": 38, "'": 39, "k": 40,
        ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "tab": 48, "space": 49,
        "`": 50, "delete": 51, "escape": 53, "left": 123, "right": 124, "down": 125, "up": 126,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100,
        "f9": 101, "f10": 109, "f11": 103, "f12": 111, "home": 115, "end": 119, "pageup": 116,
        "pagedown": 121, "forwarddelete": 117,
    ]
    private static let keyNames = Dictionary(uniqueKeysWithValues: keyCodes.map { ($1, $0) })
    private static let keyLabels = [
        "left": "←", "right": "→", "up": "↑", "down": "↓", "escape": "Esc",
        "pageup": "Page Up", "pagedown": "Page Down", "forwarddelete": "Forward Delete",
    ]
}
