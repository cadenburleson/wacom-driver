// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import IOKit.hid

let wacomVendorID = 0x056A

struct Model {
    let name: String
    let maxX: Double
    let maxY: Double
    let maxPressure: Double
}

/// The 2015 Intuos family ("INTUOSHT2" in the Linux wacom driver), which all share one
/// protocol. Only 0x033B has been tested.
let models: [Int: Model] = [
    0x033B: Model(name: "Intuos Draw S (CTL-490)", maxX: 15200, maxY: 9500, maxPressure: 2047),
    0x033C: Model(name: "Intuos Art S (CTH-490)", maxX: 15200, maxY: 9500, maxPressure: 2047),
    0x033D: Model(name: "Intuos Draw M (CTL-690)", maxX: 21600, maxY: 13500, maxPressure: 2047),
    0x033E: Model(name: "Intuos Art M (CTH-690)", maxX: 21600, maxY: 13500, maxPressure: 2047),
]

/// Width over height of the active area; the same for every model above.
let tabletAspect = 1.6

enum PenEvent {
    case enter(eraser: Bool, toolID: Int, serial: Int)
    case leave
    /// x, y and pressure are normalised to 0–1; x and y originate at the top-left corner.
    case sample(x: Double, y: Double, pressure: Double, lower: Bool, upper: Bool)
}

/// Finds the tablet, switches it out of mouse emulation and decodes its reports.
final class Tablet {
    var onPen: (PenEvent) -> Void = { _ in }
    /// Bitmask of the ExpressKeys currently held.
    var onKeys: (UInt8) -> Void = { _ in }
    /// The model's name when a tablet connects, nil when it is unplugged.
    var onConnection: (String?) -> Void = { _ in }
    var dump = false

    static let expressKeyCount = 4

    private let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    private var model: Model?
    /// The pen interface, kept to notice when the tablet is unplugged.
    private var pen: IOHIDDevice?

    // Interface 0 carries the pen, interface 1 the ExpressKeys (and touch on CTH models).
    private static let penUsagePage = 0xFF0D
    private static let padUsagePage = 0xFF00
    // Feature report 2 selects the mode: 2 sends pen reports instead of emulating a mouse.
    // Reading the report back does not return the mode, so there is nothing to restore on
    // exit; the tablet goes back to mouse emulation when it is replugged.
    private static let penMode: [UInt8] = [2, 2]

    func start() {
        let matching = [Tablet.penUsagePage, Tablet.padUsagePage].map {
            [kIOHIDVendorIDKey: wacomVendorID, kIOHIDPrimaryUsagePageKey: $0]
        }
        IOHIDManagerSetDeviceMatchingMultiple(manager, matching as CFArray)

        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, device in
            Unmanaged<Tablet>.fromOpaque(context!).takeUnretainedValue().attached(device)
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
            Unmanaged<Tablet>.fromOpaque(context!).takeUnretainedValue().removed(device)
        }, context)
        IOHIDManagerRegisterInputReportCallback(manager, { context, _, _, _, _, report, length in
            Unmanaged<Tablet>.fromOpaque(context!).takeUnretainedValue()
                .received(UnsafeBufferPointer(start: report, count: length))
        }, context)

        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        if result != kIOReturnSuccess {
            print("Could not open the tablet (\(hex(result))). Is another tablet driver holding it?")
        }
    }

    private func attached(_ device: IOHIDDevice) {
        let productID = IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int ?? 0
        guard let model = models[productID] else {
            print("Unsupported Wacom device \(hex(productID)), ignoring it.")
            return
        }
        self.model = model
        let usagePage = IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsagePageKey as CFString) as? Int
        guard usagePage == Tablet.penUsagePage else { return }

        pen = device
        let mode = Tablet.penMode
        let result = IOHIDDeviceSetReport(device, kIOHIDReportTypeFeature, CFIndex(mode[0]), mode, mode.count)
        if result == kIOReturnSuccess {
            print("\(model.name) connected.")
            onConnection(model.name)
        } else {
            print("Could not switch the tablet to pen mode (\(hex(result))).")
        }
    }

    private func removed(_ device: IOHIDDevice) {
        guard device == pen else { return }
        pen = nil
        onPen(.leave)
        onKeys(0)
        onConnection(nil)
        print("Tablet disconnected.")
    }

    private func received(_ report: UnsafeBufferPointer<UInt8>) {
        if dump {
            print(report.map { String(format: "%02x", $0) }.joined(separator: " "))
        }
        guard let model, let id = report.first else { return }
        switch (id, report.count) {
        case (0x10, 10...): penReport(report, model)
        case (0x02, 64...): padReport(report)
        default: break
        }
    }

    // Same layout as wacom_intuos_inout / wacom_intuos_general in the Linux driver.
    private func penReport(_ d: UnsafeBufferPointer<UInt8>, _ model: Model) {
        let status = d[1]
        if status & 0xFC == 0xC0 {
            let toolID = Int(d[2]) << 4 | Int(d[3]) >> 4 | Int(d[7] & 0x0F) << 16 | Int(d[8] & 0xF0) << 8
            let serial = Int(d[3] & 0x0F) << 28 | Int(d[4]) << 20 | Int(d[5]) << 12 | Int(d[6]) << 4 | Int(d[7]) >> 4
            // Every Wacom eraser ID has this bit set and no pen tip does.
            onPen(.enter(eraser: toolID & 0x008 != 0, toolID: toolID, serial: serial))
        } else if status & 0xFE == 0x80 {
            onPen(.leave)
        } else if status & 0xFE == 0x20 {
            // In range but too far away to report a position.
        } else if (status >> 1) & 0x0F <= 3 {
            let x = (Int(d[2]) << 8 | Int(d[3])) << 1 | Int(d[9] >> 1) & 1
            let y = (Int(d[4]) << 8 | Int(d[5])) << 1 | Int(d[9]) & 1
            let pressure = Int(d[6]) << 3 | Int(d[7] & 0xC0) >> 5 | Int(status & 1)
            onPen(.sample(
                x: min(Double(x) / model.maxX, 1),
                y: min(Double(y) / model.maxY, 1),
                pressure: min(Double(pressure) / model.maxPressure, 1),
                lower: status & 0x02 != 0,
                upper: status & 0x04 != 0))
        }
    }

    // Up to seven 8-byte messages; message 128 carries the ExpressKey state.
    private func padReport(_ d: UnsafeBufferPointer<UInt8>) {
        for i in 0..<Int(d[1] & 0x07) where d[2 + i * 8] == 128 {
            onKeys(d[3 + i * 8] & 0x0F)
        }
    }
}

func hex<T: BinaryInteger>(_ value: T) -> String {
    "0x" + String(UInt32(truncatingIfNeeded: value), radix: 16)
}
