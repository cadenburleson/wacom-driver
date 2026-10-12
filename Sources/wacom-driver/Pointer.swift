// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit

/// Turns pen samples into the mouse and tablet events macOS apps expect from a pen tablet.
final class Pointer {
    /// Marks the keystrokes sent for ExpressKeys, so the settings window can tell them from typing.
    static let eventMarker: Int64 = 0x5741_4344

    private var config: Config
    private let source = CGEventSource(stateID: .hidSystemState)
    private var sideSwitches: [Int?] = []
    private var bindings: [KeyBinding?] = []

    private var inProximity = false
    private var tool = (eraser: false, id: 0x802, serial: 0)
    private var bounds = CGRect.zero
    private var position = CGPoint.zero
    /// Indexed like `buttons`: tip, right, middle.
    private var down = [false, false, false]
    private var keysDown: UInt8 = 0
    private var heldFlags: CGEventFlags = []
    private var lastClick = (time: 0.0, position: CGPoint.zero, count: 0)

    private static let buttons: [(down: CGEventType, up: CGEventType, drag: CGEventType, button: CGMouseButton)] = [
        (.leftMouseDown, .leftMouseUp, .leftMouseDragged, .left),
        (.rightMouseDown, .rightMouseUp, .rightMouseDragged, .right),
        (.otherMouseDown, .otherMouseUp, .otherMouseDragged, .center),
    ]
    private static let deviceID: Int64 = 1
    // NX_TABLET_CAPABILITY device ID, absolute X and Y, buttons and pressure.
    private static let capabilities: Int64 = 0x0447
    /// How far apart, in points, two taps may land and still count as a double-click.
    private static let doubleClickDistance = 6.0

    init(config: Config) {
        self.config = config
        apply(config)
    }

    /// Adopts new settings while running.
    func apply(_ config: Config) {
        self.config = config
        sideSwitches = config.penButtons.map { ["right": 1, "middle": 2][$0.lowercased()] }
        bindings = config.expressKeys.map(KeyBinding.init)
        // A modifier held by an ExpressKey must not outlive the binding that held it.
        heldFlags = []
        keysDown = 0
    }

    func handle(_ event: PenEvent) {
        switch event {
        case .enter(let eraser, let id, let serial):
            tool = (eraser, id, serial)
            proximity(true)
        case .leave:
            guard inProximity else { return }
            for i in down.indices where down[i] {
                release(i)
            }
            proximity(false)
        case .sample(let x, let y, let rawPressure, let lower, let upper):
            // The driver may start with the pen already over the tablet.
            if !inProximity { proximity(true) }
            let previous = position
            position = screenPoint(x, y)
            let pressure = pow(rawPressure, config.pressureGamma)

            var want = [rawPressure > config.tipThreshold * (down[0] ? 0.5 : 1), false, false]
            for (held, button) in zip([lower, upper], sideSwitches) where held {
                if let button { want[button] = true }
            }

            var changed = false
            for i in want.indices where want[i] != down[i] {
                changed = true
                if want[i] { press(i, pressure) } else { release(i) }
            }
            guard !changed else { return }
            let held = down.firstIndex(of: true)
            post(held.map { Pointer.buttons[$0].drag } ?? .mouseMoved,
                 button: held.map { Pointer.buttons[$0].button } ?? .left,
                 pressure: down[0] ? pressure : 0,
                 delta: CGPoint(x: position.x - previous.x, y: position.y - previous.y),
                 clicks: held == nil ? 0 : 1)
        }
    }

    func handleKeys(_ mask: UInt8) {
        for (i, binding) in bindings.enumerated() {
            let bit = UInt8(1) << i
            guard let binding, mask & bit != keysDown & bit else { continue }
            key(binding, down: mask & bit != 0)
        }
        keysDown = mask
    }

    private func press(_ i: Int, _ pressure: Double) {
        down[i] = true
        var clicks = 1
        if i == 0 {
            let now = ProcessInfo.processInfo.systemUptime
            let distance = hypot(position.x - lastClick.position.x, position.y - lastClick.position.y)
            let repeated = now - lastClick.time < NSEvent.doubleClickInterval && distance < Pointer.doubleClickDistance
            clicks = repeated ? lastClick.count + 1 : 1
            lastClick = (now, position, clicks)
        }
        post(Pointer.buttons[i].down, button: Pointer.buttons[i].button, pressure: i == 0 ? pressure : 0, clicks: clicks)
    }

    private func release(_ i: Int) {
        down[i] = false
        post(Pointer.buttons[i].up, button: Pointer.buttons[i].button, pressure: 0, clicks: i == 0 ? lastClick.count : 1)
    }

    private func screenPoint(_ x: Double, _ y: Double) -> CGPoint {
        var (u, v) = config.leftHanded ? (1 - x, 1 - y) : (x, y)
        if config.keepAspect, bounds.height > 0 {
            // Centre the largest area of the tablet that has the display's shape.
            let ratio = (bounds.width / bounds.height) / tabletAspect
            if ratio > 1 {
                v = (v - 0.5) * ratio + 0.5
            } else {
                u = (u - 0.5) / ratio + 0.5
            }
        }
        // Stay just inside the display so the cursor cannot slip onto a neighbouring one.
        return CGPoint(x: bounds.minX + min(max(u, 0), 1) * (bounds.width - 1),
                       y: bounds.minY + min(max(v, 0), 1) * (bounds.height - 1))
    }

    private func targetBounds() -> CGRect {
        var displays = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        CGGetActiveDisplayList(UInt32(displays.count), &displays, &count)
        return CGDisplayBounds(config.display < Int(count) ? displays[config.display] : CGMainDisplayID())
    }

    private func post(_ type: CGEventType, button: CGMouseButton, pressure: Double, delta: CGPoint = .zero, clicks: Int) {
        guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: position, mouseButton: button) else { return }
        event.flags.formUnion(heldFlags)
        event.setIntegerValueField(.mouseEventClickState, value: Int64(clicks))
        event.setIntegerValueField(.mouseEventDeltaX, value: Int64(delta.x.rounded()))
        event.setIntegerValueField(.mouseEventDeltaY, value: Int64(delta.y.rounded()))
        event.setDoubleValueField(.mouseEventPressure, value: pressure)
        event.setIntegerValueField(.mouseEventSubtype, value: Int64(CGEventMouseSubtype.tabletPoint.rawValue))
        event.setIntegerValueField(.tabletEventDeviceID, value: Pointer.deviceID)
        event.setDoubleValueField(.tabletEventPointPressure, value: pressure)
        event.setIntegerValueField(.tabletEventPointButtons, value: Int64((0..<3).reduce(0) { $0 | (down[$1] ? 1 << $1 : 0) }))
        event.post(tap: .cghidEventTap)
    }

    /// Tells apps which tool is over the tablet, so they can tell the eraser from the tip.
    private func proximity(_ entering: Bool) {
        inProximity = entering
        if entering { bounds = targetBounds() }
        guard let event = CGEvent(source: source) else { return }
        event.type = .tabletProximity
        event.setIntegerValueField(.tabletProximityEventVendorID, value: Int64(wacomVendorID))
        event.setIntegerValueField(.tabletProximityEventDeviceID, value: Pointer.deviceID)
        event.setIntegerValueField(.tabletProximityEventPointerID, value: tool.eraser ? 2 : 1)
        event.setIntegerValueField(.tabletProximityEventVendorPointerType, value: Int64(tool.id))
        event.setIntegerValueField(.tabletProximityEventVendorPointerSerialNumber, value: Int64(tool.serial))
        event.setIntegerValueField(.tabletProximityEventVendorUniqueID, value: Int64(tool.serial))
        event.setIntegerValueField(.tabletProximityEventCapabilityMask, value: Pointer.capabilities)
        event.setIntegerValueField(.tabletProximityEventPointerType,
                                   value: Int64((tool.eraser ? NSEvent.PointingDeviceType.eraser : .pen).rawValue))
        event.setIntegerValueField(.tabletProximityEventEnterProximity, value: entering ? 1 : 0)
        event.post(tap: .cghidEventTap)
    }

    private func key(_ binding: KeyBinding, down: Bool) {
        let event: CGEvent?
        if let code = binding.key {
            event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)
            event?.flags.formUnion(binding.flags)
        } else {
            // Bare modifiers are held, and applied to the pen's own events as well.
            if down { heldFlags.formUnion(binding.flags) } else { heldFlags.subtract(binding.flags) }
            event = CGEvent(keyboardEventSource: source, virtualKey: binding.modifierKey, keyDown: down)
            event?.type = .flagsChanged
            event?.flags = heldFlags
        }
        event?.setIntegerValueField(.eventSourceUserData, value: Pointer.eventMarker)
        event?.post(tap: .cghidEventTap)
    }
}
