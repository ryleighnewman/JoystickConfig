import Foundation
import Combine
import CoreGraphics
import ApplicationServices
#if canImport(AppKit)
import AppKit
#endif

/// External-input monitoring service: lets the user bind their Mac's
/// mouse / trackpad (and, on an Accessibility-only basis, keyboard) as
/// **input sources** for a preset.
///
/// ## Permission model (App Store safe)
///
/// Earlier builds used an `IOHIDManager` matched on keyboard / mouse
/// usages plus a CGEventTap that consumed the raw keystroke stream. That
/// required the Input Monitoring permission, which App Store review
/// (guideline 2.4.5) rejects for a non-accessibility purpose, so it was
/// removed. This version rides only on the app's single approved
/// permission, **Accessibility**:
///   - Mouse / trackpad: a listen-only `CGEventTap` for mouse events
///     (buttons, scroll, movement). Mouse events do not require Input
///     Monitoring, so this needs only Accessibility.
///   - Keyboard: AppKit `NSEvent` global + local monitors (the
///     Accessibility API path), gated on `AXIsProcessTrusted()` and only
///     started for presets that actually use a `.extKey` binding. No
///     IOHID, no keystroke-stream CGEventTap, no Input Monitoring prompt.
///
/// Everything is gated so nothing runs until Accessibility is granted and
/// a running preset needs it:
///   - `events` fires mouse events while `startMouseMonitoring()` is
///     active and keyboard events while `startKeyboardMonitoring()` is.
///   - `devices` lists the synthetic Mouse / Keyboard entries while the
///     matching monitor is active.
///
/// Game controllers are unaffected - they come through the GameController
/// framework (`GameControllerService`) and raw HID *gamepads* through
/// `RawHIDGamepadService`, neither of which needs Input Monitoring.
/// Cursor-position based bindings (`.cursorRegion`) read
/// `NSEvent.mouseLocation` directly in `CursorRegionService`.
final class ExternalInputDeviceService: ObservableObject, @unchecked Sendable {
    static let shared = ExternalInputDeviceService()

    // MARK: - Public types (preserved for the binding model + views)

    enum Bus: String, Codable {
        case usb, bluetooth, builtIn, unknown
    }

    enum Kind: String, Codable {
        case keyboard, mouse, keypad
    }

    struct Device: Identifiable, Hashable {
        let id: String
        let kind: Kind
        let vendorID: Int
        let productID: Int
        let vendorName: String
        let productName: String
        let serialNumber: String?
        let bus: Bus
        let locationID: Int
    }

    enum Event: Hashable {
        case keyDown(deviceID: String, hidCode: Int)
        case keyUp(deviceID: String, hidCode: Int)
        case mouseButtonDown(deviceID: String, button: Int)
        case mouseButtonUp(deviceID: String, button: Int)
        case mouseMove(deviceID: String, dx: Int, dy: Int)
        case scroll(deviceID: String, dx: Int, dy: Int)
        /// Force Touch pressure update from the Mac trackpad. value is the
        /// 0-1 press force; stage is 0 (no click), 1 (click), 2 (force click).
        case pressureChanged(deviceID: String, value: Float, stage: Int)

        var deviceID: String {
            switch self {
            case .keyDown(let id, _), .keyUp(let id, _),
                 .mouseButtonDown(let id, _), .mouseButtonUp(let id, _),
                 .mouseMove(let id, _, _), .scroll(let id, _, _),
                 .pressureChanged(let id, _, _):
                return id
            }
        }
    }

    struct LoggedEvent: Identifiable, Hashable {
        let id = UUID()
        let timestamp: Date
        let label: String
    }

    // MARK: - Published state

    /// Synthetic device entries (a Mouse and / or Keyboard row) for whichever
    /// monitors are currently active. Empty until a running preset that uses an
    /// external-input binding starts monitoring and Accessibility is granted.
    @Published private(set) var devices: [Device] = []
    @Published private(set) var recentEvents: [String: [LoggedEvent]] = [:]
    @Published private(set) var receivedAnyKeyboardEvent = false

    /// Live Force Touch pressure metrics for UI gauges (0-1 force and the
    /// click stage). Published only on meaningful change so a slow press
    /// does not render-storm observers.
    @Published private(set) var trackpadPressure: Float = 0
    @Published private(set) var trackpadPressureStage: Int = 0
    @Published private(set) var rawActiveInputs: Set<String> = []

    /// Fires mouse events while `startMouseMonitoring()` is active and keyboard
    /// events while `startKeyboardMonitoring()` is active. Idle until a running
    /// preset actually uses an external-input binding.
    let events = PassthroughSubject<Event, Never>()

    /// True while the listen-only mouse `CGEventTap` is installed.
    @Published private(set) var cgEventTapInstalled = false
    @Published private(set) var cgEventTapReceivedAnyEvent = false

    /// Synthetic device IDs kept only so binding strings saved by older
    /// builds ("ekb 4 builtin.keyboard") still parse without crashing.
    static let builtInKeyboardID = "builtin.keyboard"
    static let builtInMouseID = "builtin.mouse"

    private static let excludeBuiltInKey = "InputConfig.externalInput.excludeBuiltIn"

    /// Retained as a stored preference only so Settings' existing toggle
    /// and the backup key list keep working. It no longer gates any
    /// monitoring because there is no monitoring.
    @Published var excludeBuiltInDevices: Bool {
        didSet {
            UserDefaults.standard.set(excludeBuiltInDevices, forKey: Self.excludeBuiltInKey)
        }
    }

    private init() {
        excludeBuiltInDevices = UserDefaults.standard.bool(forKey: Self.excludeBuiltInKey)
    }

    // MARK: - Public lookup (return empty / nil)

    func deviceName(for id: String) -> String? {
        devices.first(where: { $0.id == id })?.productName
    }

    func recentEventsFor(_ id: String) -> [LoggedEvent] { recentEvents[id] ?? [] }

    // MARK: - Mouse input monitoring (Accessibility-gated)

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    /// Begin listening for system mouse events (buttons, scroll, movement)
    /// so the user can bind their mouse as an input source. Uses a
    /// listen-only CGEventTap, which needs only the Accessibility permission
    /// - mouse events, unlike keyboard events, do not require Input
    /// Monitoring, so this rides on the app's one approved permission. We
    /// never tap keyboard events. No-op until Accessibility is granted; call
    /// again after the user grants it.
    func startMouseMonitoring() {
        if eventTap != nil { return }
        guard AXIsProcessTrusted() else { return }

        let mask: CGEventMask =
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.leftMouseUp.rawValue) |
            (1 << CGEventType.rightMouseDown.rawValue) |
            (1 << CGEventType.rightMouseUp.rawValue) |
            (1 << CGEventType.otherMouseDown.rawValue) |
            (1 << CGEventType.otherMouseUp.rawValue) |
            (1 << CGEventType.mouseMoved.rawValue) |
            (1 << CGEventType.leftMouseDragged.rawValue) |
            (1 << CGEventType.rightMouseDragged.rawValue) |
            (1 << CGEventType.otherMouseDragged.rawValue) |
            (1 << CGEventType.scrollWheel.rawValue)

        // Capture-free C callback; `userInfo` carries the service instance.
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            if let userInfo = userInfo {
                Unmanaged<ExternalInputDeviceService>.fromOpaque(userInfo)
                    .takeUnretainedValue()
                    .handleMouseEvent(type: type, event: event)
            }
            return Unmanaged.passUnretained(event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            // Tap couldn't be created (Accessibility not effective yet, or
            // the sandbox refused it). Leave installed=false; the UI's
            // Accessibility banner guides the user.
            return
        }

        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        eventTap = tap
        runLoopSource = src
        cgEventTapInstalled = true
        devices = [Device(id: Self.builtInMouseID, kind: .mouse,
                          vendorID: 0, productID: 0,
                          vendorName: "System", productName: "Mouse",
                          serialNumber: nil, bus: .unknown, locationID: 0)]

        // Force Touch pressure is delivered only to the LOCAL monitor: macOS
        // routes NSEventTypePressure through the frontmost app's responder
        // chain, so a global monitor never receives it (there is no public API
        // that reports another app's trackpad force). Force Touch bindings
        // therefore fire only while InputConfig's own window is frontmost; a
        // global-monitor registration here would be silently dead, so we don't
        // install one and don't imply the feature works over other apps.
        ensurePressureMetricsMonitor()
    }

    /// Install the LOCAL pressure monitor on demand. Separate from the
    /// engine-driven monitoring so UI gauges (the Cursor Regions map) can
    /// show live Force Touch metrics while the user presses over our own
    /// window, with no Accessibility requirement and no engine running.
    func ensurePressureMetricsMonitor() {
        #if canImport(AppKit)
        guard pressureLocalMonitor == nil else { return }
        pressureLocalMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.pressure]
        ) { [weak self] ev in
            self?.handlePressureNSEvent(ev)
            return ev
        }
        #endif
    }

    #if canImport(AppKit)
    private func handlePressureNSEvent(_ ev: NSEvent) {
        let value = max(0, min(1, Float(ev.pressure)))
        let stage = ev.stage
        events.send(.pressureChanged(deviceID: Self.builtInMouseID,
                                     value: value, stage: stage))
        // Publish for UI gauges only on meaningful change.
        let stageFlipped = (stage >= 2) != (trackpadPressureStage >= 2)
        if abs(value - trackpadPressure) > 0.02 || stageFlipped || (value == 0 && trackpadPressure != 0) {
            trackpadPressure = value
            trackpadPressureStage = stage
        }
    }
    #endif

    /// Stop listening and release the tap + keyboard monitors.
    func stopMonitoring() {
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let src = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        cgEventTapInstalled = false
        #if canImport(AppKit)
        if let m = keyboardGlobalMonitor { NSEvent.removeMonitor(m); keyboardGlobalMonitor = nil }
        if let m = keyboardLocalMonitor { NSEvent.removeMonitor(m); keyboardLocalMonitor = nil }
        // The local pressure monitor stays installed so in-window UI gauges
        // keep working; there is no global pressure monitor to tear down.
        #endif
        devices = []
    }

    /// Tap callback body (runs on the main run loop). Translates a CGEvent
    /// into our device-agnostic `Event` and publishes it. Skips events we
    /// synthesized ourselves so a mouse OUTPUT can't loop back as INPUT.
    fileprivate func handleMouseEvent(type: CGEventType, event: CGEvent) {
        // The system can disable a tap if it ever blocks; re-enable it.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        if event.getIntegerValueField(.eventSourceUserData) == InputSimulator.ownEventMarker {
            return
        }
        let dev = Self.builtInMouseID
        let out: Event?
        switch type {
        case .leftMouseDown:  out = .mouseButtonDown(deviceID: dev, button: 0)
        case .leftMouseUp:    out = .mouseButtonUp(deviceID: dev, button: 0)
        case .rightMouseDown: out = .mouseButtonDown(deviceID: dev, button: 1)
        case .rightMouseUp:   out = .mouseButtonUp(deviceID: dev, button: 1)
        case .otherMouseDown:
            out = .mouseButtonDown(deviceID: dev, button: Int(event.getIntegerValueField(.mouseEventButtonNumber)))
        case .otherMouseUp:
            out = .mouseButtonUp(deviceID: dev, button: Int(event.getIntegerValueField(.mouseEventButtonNumber)))
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            out = .mouseMove(deviceID: dev,
                             dx: Int(event.getIntegerValueField(.mouseEventDeltaX)),
                             dy: Int(event.getIntegerValueField(.mouseEventDeltaY)))
        case .scrollWheel:
            out = .scroll(deviceID: dev,
                          dx: Int(event.getIntegerValueField(.scrollWheelEventDeltaAxis2)),
                          dy: Int(event.getIntegerValueField(.scrollWheelEventDeltaAxis1)))
        default:
            out = nil
        }
        guard let e = out else { return }
        if !cgEventTapReceivedAnyEvent { cgEventTapReceivedAnyEvent = true }
        events.send(e)
    }

    // MARK: - Keyboard input monitoring (Accessibility-gated, NSEvent)

    private var keyboardGlobalMonitor: Any?
    private var keyboardLocalMonitor: Any?
    private var pressureLocalMonitor: Any?

    /// Begin listening for Mac keyboard key presses so a `.extKey` binding
    /// can fire. Uses AppKit `NSEvent` monitors (the Accessibility API path),
    /// NOT a CGEventTap or IOHID keystroke stream, so it rides on the app's
    /// already-approved Accessibility permission and requests no new one. The
    /// global monitor delivers keys while another app (a game) is frontmost;
    /// the local monitor covers our own window. No-op until Accessibility is
    /// granted; call again after the user grants it.
    func startKeyboardMonitoring() {
        #if canImport(AppKit)
        guard AXIsProcessTrusted() else { return }
        if keyboardGlobalMonitor == nil {
            keyboardGlobalMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.keyDown, .keyUp]
            ) { [weak self] ev in
                self?.handleKeyboardNSEvent(ev)
            }
        }
        if keyboardLocalMonitor == nil {
            keyboardLocalMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.keyDown, .keyUp]
            ) { [weak self] ev in
                self?.handleKeyboardNSEvent(ev)
                return ev
            }
        }
        if !devices.contains(where: { $0.id == Self.builtInKeyboardID }) {
            devices.append(Device(id: Self.builtInKeyboardID, kind: .keyboard,
                                  vendorID: 0, productID: 0,
                                  vendorName: "System", productName: "Keyboard",
                                  serialNumber: nil, bus: .unknown, locationID: 0))
        }
        #endif
    }

    #if canImport(AppKit)
    private func handleKeyboardNSEvent(_ ev: NSEvent) {
        // Skip keys we synthesized ourselves so a key OUTPUT can't loop back
        // in as INPUT (mirror of the mouse tap's own-event guard).
        if let cg = ev.cgEvent,
           cg.getIntegerValueField(.eventSourceUserData) == InputSimulator.ownEventMarker {
            return
        }
        guard let hid = Self.hidUsage(forVirtualKeyCode: Int(ev.keyCode)) else { return }
        let dev = Self.builtInKeyboardID
        switch ev.type {
        case .keyDown:
            if ev.isARepeat { return }
            if !receivedAnyKeyboardEvent { receivedAnyKeyboardEvent = true }
            events.send(.keyDown(deviceID: dev, hidCode: hid))
        case .keyUp:
            events.send(.keyUp(deviceID: dev, hidCode: hid))
        default:
            break
        }
    }
    #endif

    /// Translate an AppKit / Carbon virtual key code (`NSEvent.keyCode`) into
    /// the USB HID Keyboard/Keypad usage code the rest of the app stores for
    /// keys (so a scanned key matches the same codes used by key OUTPUTS).
    /// Returns nil for keys with no standard HID usage. Table covers the full
    /// ANSI block, modifiers, function keys, arrows, and the keypad.
    static func hidUsage(forVirtualKeyCode vk: Int) -> Int? {
        Self.hidUsageByVirtualKey[vk]
    }

    /// Virtual-key to HID usage table, stored once. Building this dictionary
    /// inside the lookup function allocated a ~100-entry dict on every key
    /// event during typing.
    private static let hidUsageByVirtualKey: [Int: Int] = [
        // Letters and number row.
            0: 4, 1: 22, 2: 7, 3: 9, 4: 11, 5: 10, 6: 29, 7: 27, 8: 6, 9: 25,
            11: 5, 12: 20, 13: 26, 14: 8, 15: 21, 16: 28, 17: 23,
            18: 30, 19: 31, 20: 32, 21: 33, 22: 35, 23: 34, 24: 46, 25: 38,
            26: 36, 27: 45, 28: 37, 29: 39, 30: 48, 31: 18, 32: 24, 33: 47,
            34: 12, 35: 19, 36: 40, 37: 15, 38: 13, 39: 52, 40: 14, 41: 51,
            42: 49, 43: 54, 44: 56, 45: 17, 46: 16, 47: 55, 48: 43, 49: 44,
            50: 53, 51: 42, 53: 41,
            // Modifiers.
            55: 227, 56: 225, 57: 57, 58: 226, 59: 224,
            60: 229, 61: 230, 62: 228,
            // Keypad.
            65: 99, 67: 85, 69: 87, 71: 83, 75: 84, 76: 88, 78: 86, 81: 103,
            82: 98, 83: 89, 84: 90, 85: 91, 86: 92, 87: 93, 88: 94, 89: 95,
            91: 96, 92: 97,
            // Function keys.
            96: 62, 97: 63, 98: 64, 99: 60, 100: 65, 101: 66, 103: 68,
            105: 104, 107: 105, 109: 67, 111: 69, 113: 106,
            // Navigation cluster.
            114: 73, 115: 74, 116: 75, 117: 76, 118: 61, 119: 77, 120: 59,
            121: 78, 122: 58, 123: 80, 124: 79, 125: 81, 126: 82
    ]

    /// Stop the tap on app termination.
    func teardownForTermination() { stopMonitoring() }
}
