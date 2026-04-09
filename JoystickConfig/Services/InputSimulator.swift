#if os(macOS)
import Foundation
import CoreGraphics
import AppKit

/// Simulates keyboard and mouse input on macOS using CGEvent.
///
/// IMPORTANT: Accessibility permission is tracked per code signature.
/// During development with ad-hoc signing (CODE_SIGN_IDENTITY = "-"),
/// you must re-grant permission in System Settings after each rebuild.
/// Remove old entries and re-add the newly built app.
final class InputSimulator: @unchecked Sendable {
    nonisolated(unsafe) static let shared = InputSimulator()

    private var pressedKeys: Set<Int> = []
    private var pressedMouseButtons: Set<Int> = []

    /// Create an event source for synthetic events (nil if accessibility not granted)
    private var eventSource: CGEventSource? {
        CGEventSource(stateID: .hidSystemState)
    }

    // MARK: - Keyboard Simulation

    func keyDown(_ hidCode: Int) {
        guard !pressedKeys.contains(hidCode) else { return }
        pressedKeys.insert(hidCode)

        if let virtualCode = KeyCodeMap.hidToVirtualKeyCode[hidCode] {
            let flags = modifierFlags(for: hidCode)
            if let event = CGEvent(keyboardEventSource: eventSource, virtualKey: CGKeyCode(virtualCode), keyDown: true) {
                if let flags = flags {
                    event.flags = flags
                }
                event.post(tap: .cgSessionEventTap)
            }
        } else {
            postSpecialKey(hidCode, keyDown: true)
        }
    }

    func keyUp(_ hidCode: Int) {
        guard pressedKeys.contains(hidCode) else { return }
        pressedKeys.remove(hidCode)

        if let virtualCode = KeyCodeMap.hidToVirtualKeyCode[hidCode] {
            if let event = CGEvent(keyboardEventSource: eventSource, virtualKey: CGKeyCode(virtualCode), keyDown: false) {
                event.post(tap: .cgSessionEventTap)
            }
        } else {
            postSpecialKey(hidCode, keyDown: false)
        }
    }

    private func modifierFlags(for hidCode: Int) -> CGEventFlags? {
        switch hidCode {
        case 224, 228: return .maskControl
        case 225, 229: return .maskShift
        case 226, 230: return .maskAlternate
        case 227, 231: return .maskCommand
        default: return nil
        }
    }

    private func postSpecialKey(_ hidCode: Int, keyDown: Bool) {
        let specialKeyMap: [Int: Int] = [
            71: 0x91,   // Brightness Down
            72: 0x90,   // Brightness Up
            307: 0x14,  // Rewind
            308: 0x10,  // Play/Pause
            309: 0x13,  // Fast Forward
            310: 0x07,  // Mute
            311: 0x00,  // Volume Up
            312: 0x01,  // Volume Down
        ]

        guard let nxKeyType = specialKeyMap[hidCode] else { return }

        let flags: Int = keyDown ? 0xa00 : 0xb00
        let data1 = (nxKeyType << 16) | flags
        let event = NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(flags)),
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            subtype: 8,
            data1: data1,
            data2: -1
        )
        event?.cgEvent?.post(tap: .cgSessionEventTap)
    }

    // MARK: - Mouse Button Simulation

    func mouseButtonDown(_ button: Int) {
        guard !pressedMouseButtons.contains(button) else { return }
        pressedMouseButtons.insert(button)

        let location = NSEvent.mouseLocation
        let cgPoint = CGPoint(x: location.x, y: NSScreen.main!.frame.height - location.y)

        let eventType: CGEventType
        let mouseButton: CGMouseButton
        switch button {
        case 0:
            eventType = .leftMouseDown
            mouseButton = .left
        case 1:
            eventType = .rightMouseDown
            mouseButton = .right
        default:
            eventType = .otherMouseDown
            mouseButton = CGMouseButton(rawValue: UInt32(button))!
        }

        if let event = CGEvent(mouseEventSource: eventSource, mouseType: eventType,
                               mouseCursorPosition: cgPoint, mouseButton: mouseButton) {
            event.post(tap: .cgSessionEventTap)
        }
    }

    func mouseButtonUp(_ button: Int) {
        guard pressedMouseButtons.contains(button) else { return }
        pressedMouseButtons.remove(button)

        let location = NSEvent.mouseLocation
        let cgPoint = CGPoint(x: location.x, y: NSScreen.main!.frame.height - location.y)

        let eventType: CGEventType
        let mouseButton: CGMouseButton
        switch button {
        case 0:
            eventType = .leftMouseUp
            mouseButton = .left
        case 1:
            eventType = .rightMouseUp
            mouseButton = .right
        default:
            eventType = .otherMouseUp
            mouseButton = CGMouseButton(rawValue: UInt32(button))!
        }

        if let event = CGEvent(mouseEventSource: eventSource, mouseType: eventType,
                               mouseCursorPosition: cgPoint, mouseButton: mouseButton) {
            event.post(tap: .cgSessionEventTap)
        }
    }

    // MARK: - Mouse Motion Simulation

    func moveMouse(deltaX: Int, deltaY: Int) {
        let location = NSEvent.mouseLocation
        let screenHeight = NSScreen.main?.frame.height ?? 1080
        let currentPoint = CGPoint(x: location.x, y: screenHeight - location.y)
        let newPoint = CGPoint(x: currentPoint.x + CGFloat(deltaX), y: currentPoint.y + CGFloat(deltaY))

        if let event = CGEvent(mouseEventSource: eventSource, mouseType: .mouseMoved,
                               mouseCursorPosition: newPoint, mouseButton: .left) {
            event.setIntegerValueField(.mouseEventDeltaX, value: Int64(deltaX))
            event.setIntegerValueField(.mouseEventDeltaY, value: Int64(deltaY))
            event.post(tap: .cgSessionEventTap)
        }
    }

    // MARK: - Mouse Wheel Simulation

    func scrollWheel(deltaX: Int32, deltaY: Int32) {
        if let event = CGEvent(scrollWheelEvent2Source: eventSource, units: .pixel,
                               wheelCount: 2, wheel1: deltaY, wheel2: deltaX, wheel3: 0) {
            event.post(tap: .cgSessionEventTap)
        }
    }

    func scrollWheelStep(axis: MouseAxis, direction: MouseDirection) {
        let delta: Int32 = direction == .positive ? 5 : -5
        switch axis {
        case .vertical:
            scrollWheel(deltaX: 0, deltaY: delta)
        case .horizontal:
            scrollWheel(deltaX: delta, deltaY: 0)
        }
    }

    // MARK: - Release All

    func releaseAll() {
        for key in pressedKeys {
            if let virtualCode = KeyCodeMap.hidToVirtualKeyCode[key] {
                if let event = CGEvent(keyboardEventSource: eventSource, virtualKey: CGKeyCode(virtualCode), keyDown: false) {
                    event.post(tap: .cgSessionEventTap)
                }
            }
        }
        pressedKeys.removeAll()

        for button in pressedMouseButtons {
            mouseButtonUp(button)
        }
        pressedMouseButtons.removeAll()
    }

    // MARK: - Accessibility Check

    /// Check if accessibility permission is granted WITHOUT prompting
    static var hasAccessibilityPermission: Bool {
        let options = ["AXTrustedCheckOptionPrompt": false] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Request accessibility permission (shows system dialog)
    static func requestAccessibilityPermission() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    // MARK: - Diagnostic Test

    /// Test if event posting actually works. Returns a description of what happened.
    static func runDiagnostic() -> String {
        var results: [String] = []

        // 1. Check AX trusted
        let trusted = hasAccessibilityPermission
        results.append("AX Trusted: \(trusted)")

        // 2. Check if we can create an event source
        let source = CGEventSource(stateID: .hidSystemState)
        results.append("Event Source: \(source != nil ? "OK" : "FAILED")")

        // 3. Check if we can create a keyboard event
        let keyEvent = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
        results.append("Key Event Create: \(keyEvent != nil ? "OK" : "FAILED")")

        // 4. Check if we can create a mouse move event
        let mouseEvent = CGEvent(mouseEventSource: source, mouseType: .mouseMoved,
                                  mouseCursorPosition: .zero, mouseButton: .left)
        results.append("Mouse Event Create: \(mouseEvent != nil ? "OK" : "FAILED")")

        // 5. Try posting a harmless mouse move with zero delta
        if let event = mouseEvent {
            event.setIntegerValueField(.mouseEventDeltaX, value: 0)
            event.setIntegerValueField(.mouseEventDeltaY, value: 0)
            event.post(tap: .cgSessionEventTap)
            results.append("Event Post: OK (no error)")
        } else {
            results.append("Event Post: SKIPPED (no event)")
        }

        // 6. App path
        results.append("App Path: \(Bundle.main.bundlePath)")

        return results.joined(separator: "\n")
    }
}

#else

// iOS stub - input simulation not available
final class InputSimulator: @unchecked Sendable {
    nonisolated(unsafe) static let shared = InputSimulator()

    func keyDown(_ hidCode: Int) {}
    func keyUp(_ hidCode: Int) {}
    func mouseButtonDown(_ button: Int) {}
    func mouseButtonUp(_ button: Int) {}
    func moveMouse(deltaX: Int, deltaY: Int) {}
    func scrollWheel(deltaX: Int32, deltaY: Int32) {}
    func scrollWheelStep(axis: MouseAxis, direction: MouseDirection) {}
    func releaseAll() {}

    static var hasAccessibilityPermission: Bool { false }
    static func requestAccessibilityPermission() {}
    static func runDiagnostic() -> String { "iOS: Not supported" }
}

#endif
