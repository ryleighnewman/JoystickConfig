#if os(macOS)
import Foundation
import CoreGraphics
import AppKit
import ApplicationServices
import Carbon.HIToolbox

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

    /// Cached event source for synthetic events. Created once on first
    /// access. Previously this was a computed property, which meant
    /// every key press / mouse motion / scroll wheel call paid the
    /// CGEventSource initialization cost. On a turbo-firing or
    /// joystick-as-mouse preset that was many hundreds of allocations
    /// per second.
    private lazy var eventSource: CGEventSource? = CGEventSource(stateID: .hidSystemState)

    /// Magic marker we stamp onto every `CGEvent` we post via this class.
    /// `ExternalInputDeviceService`'s `CGEventTap` reads back this field
    /// and ignores any event carrying this marker - that's how we
    /// guarantee a binding's keyboard OUTPUT can't loop back as keyboard
    /// INPUT and trigger itself. "INPUTC01" in ASCII.
    nonisolated(unsafe) static let ownEventMarker: Int64 = 0x49_4E_50_55_54_43_30_31

    /// Post a CGEvent we created, after stamping our marker so the
    /// CGEventTap consumer can recognize and skip it. All post call sites
    /// in this file go through here.
    ///
    /// IMPORTANT: posts to **`.cghidEventTap`**, not `.cgSessionEventTap`.
    /// `.cghidEventTap` is the lowest-level tap - events appear as if
    /// from real HID hardware, BEFORE the WindowServer's "is this app
    /// trusted to post events" filter runs. That filter is what gates
    /// `.cgSessionEventTap` posts on the Accessibility permission and
    /// silently drops events from apps that haven't been granted it.
    /// Posting at the HID layer is how Enjoyable, BetterMouse, Karabiner
    /// and similar input remappers ship without requiring users to add
    /// the app to System Settings → Privacy & Security → Accessibility.
    fileprivate func taggedPost(_ event: CGEvent) {
        event.setIntegerValueField(.eventSourceUserData, value: Self.ownEventMarker)
        event.post(tap: .cghidEventTap)
    }

    // MARK: - Keyboard Simulation

    func keyDown(_ hidCode: Int) {
        guard !pressedKeys.contains(hidCode) else { return }
        pressedKeys.insert(hidCode)

        if let virtualCode = KeyCodeMap.hidToVirtualKeyCode[hidCode] {
            if let event = CGEvent(keyboardEventSource: eventSource, virtualKey: CGKeyCode(virtualCode), keyDown: true) {
                // Apply EVERY currently-held modifier, not just the case where
                // this key is itself a modifier. Without this, a chord like
                // Cmd+C (Cmd held, then C pressed) fired C as a bare key because
                // the C event carried no modifier flags, so combo outputs like
                // Copy, the screenshot shortcuts, and Cmd+Shift+Z did nothing.
                let flags = currentModifierFlags()
                if !flags.isEmpty { event.flags = flags }
                taggedPost(event)
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
                // Carry the still-held modifiers so releasing the letter of a
                // chord (e.g. the C of Cmd+C) does not read as a bare key-up.
                let flags = currentModifierFlags()
                if !flags.isEmpty { event.flags = flags }
                taggedPost(event)
            }
        } else {
            postSpecialKey(hidCode, keyDown: false)
        }
    }

    /// Type a literal string by posting keyboard events whose characters are
    /// set with keyboardSetUnicodeString, in 20-UTF-16-unit chunks (the API's
    /// per-event limit). Goes through the same taggedPost path as every other
    /// output, so the string cannot loop back as input and no new permission
    /// surface is involved. Capitals, symbols, and non-Latin text all work
    /// because the characters bypass keycode translation entirely.
    func typeString(_ text: String) {
        guard !text.isEmpty else { return }
        // Chunk on grapheme (Character) boundaries so a surrogate pair (emoji,
        // astral chars) or a combining sequence is never split across the
        // 20-UTF-16-unit API limit, which would corrupt the character.
        var chunk: [UInt16] = []
        func flush() {
            guard !chunk.isEmpty else { return }
            if let down = CGEvent(keyboardEventSource: eventSource, virtualKey: 0, keyDown: true) {
                down.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                taggedPost(down)
            }
            if let up = CGEvent(keyboardEventSource: eventSource, virtualKey: 0, keyDown: false) {
                up.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                taggedPost(up)
            }
            chunk.removeAll(keepingCapacity: true)
        }
        for character in text {
            let u = Array(String(character).utf16)
            if !chunk.isEmpty && chunk.count + u.count > 20 { flush() }
            if u.count > 20 {
                // A single grapheme wider than the limit is pathological; post
                // it on its own rather than dropping or splitting it.
                flush()
                chunk = u
                flush()
                continue
            }
            chunk.append(contentsOf: u)
        }
        flush()
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

    /// Union of the modifier flags for every modifier key currently held in
    /// `pressedKeys`. Applied to every synthesized key event so chords such as
    /// Cmd+C, Cmd+Shift+3, and Option+[ register with their modifiers instead
    /// of firing as bare keys.
    private func currentModifierFlags() -> CGEventFlags {
        var flags: CGEventFlags = []
        for code in pressedKeys {
            if let f = modifierFlags(for: code) { flags.insert(f) }
        }
        return flags
    }

    /// HID code → NSEvent.subtype:systemDefined NX key code. Static so
    /// it's allocated once at type init, not per call. Was previously
    /// a local `let` inside `postSpecialKey`, allocating a fresh dict
    /// on every media-key press.
    private static let specialKeyMap: [Int: Int] = [
        71: 0x91,   // Brightness Down
        72: 0x90,   // Brightness Up
        307: 0x14,  // Rewind
        308: 0x10,  // Play/Pause
        309: 0x13,  // Fast Forward
        310: 0x07,  // Mute
        311: 0x00,  // Volume Up
        312: 0x01,  // Volume Down
    ]

    private func postSpecialKey(_ hidCode: Int, keyDown: Bool) {
        guard let nxKeyType = Self.specialKeyMap[hidCode] else { return }

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
        if let cg = event?.cgEvent { taggedPost(cg) }
    }

    // MARK: - Mouse Button Simulation

    func mouseButtonDown(_ button: Int) {
        guard !pressedMouseButtons.contains(button) else { return }
        // `NSScreen.main` can be nil during sleep/wake transitions and
        // fast-user-switching, and CGMouseButton(rawValue:) returns nil
        // for buttons outside 0...31. Either case used to force-unwrap
        // and crash the entire mapping engine mid-binding; now both
        // fall back gracefully.
        guard let screenHeight = NSScreen.main?.frame.height,
              let cgButton = cgMouseButton(for: button) else { return }
        pressedMouseButtons.insert(button)

        let location = NSEvent.mouseLocation
        let cgPoint = CGPoint(x: location.x, y: screenHeight - location.y)

        let eventType: CGEventType
        switch button {
        case 0: eventType = .leftMouseDown
        case 1: eventType = .rightMouseDown
        default: eventType = .otherMouseDown
        }

        if let event = CGEvent(mouseEventSource: eventSource, mouseType: eventType,
                               mouseCursorPosition: cgPoint, mouseButton: cgButton) {
            taggedPost(event)
        }
    }

    func mouseButtonUp(_ button: Int) {
        guard pressedMouseButtons.contains(button) else { return }
        guard let cgButton = cgMouseButton(for: button) else { return }
        // Always release. NSScreen.main can be nil during sleep/wake and fast
        // user switching; if we bailed on that the button would stay physically
        // down. Fall back to a zero-height screen so the up event still posts
        // and our pressed-state stays consistent.
        pressedMouseButtons.remove(button)

        let screenHeight = NSScreen.main?.frame.height ?? 0
        let location = NSEvent.mouseLocation
        let cgPoint = CGPoint(x: location.x, y: screenHeight - location.y)

        let eventType: CGEventType
        switch button {
        case 0: eventType = .leftMouseUp
        case 1: eventType = .rightMouseUp
        default: eventType = .otherMouseUp
        }

        if let event = CGEvent(mouseEventSource: eventSource, mouseType: eventType,
                               mouseCursorPosition: cgPoint, mouseButton: cgButton) {
            taggedPost(event)
        }
    }

    /// Map a InputConfig logical mouse-button index to CGMouseButton.
    /// Returns nil for indices that don't have a CGMouseButton equivalent
    /// instead of force-unwrapping; the caller drops the event.
    private func cgMouseButton(for index: Int) -> CGMouseButton? {
        switch index {
        case 0: return .left
        case 1: return .right
        default: return CGMouseButton(rawValue: UInt32(index))
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
            taggedPost(event)
        }
    }

    // MARK: - Mouse Wheel Simulation

    func scrollWheel(deltaX: Int32, deltaY: Int32) {
        if let event = CGEvent(scrollWheelEvent2Source: eventSource, units: .pixel,
                               wheelCount: 2, wheel1: deltaY, wheel2: deltaX, wheel3: 0) {
            taggedPost(event)
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
                    taggedPost(event)
                }
            } else {
                // Media / special keys live outside the virtual-key map; route
                // them through the systemDefined path so they release too and
                // don't stick down after stop() or pause.
                postSpecialKey(key, keyDown: false)
            }
        }
        pressedKeys.removeAll()

        for button in pressedMouseButtons {
            mouseButtonUp(button)
        }
        pressedMouseButtons.removeAll()
    }

    // MARK: - Diagnostic Test

    /// Test that event creation + posting works. Returns a description
    /// of what happened.
    ///
    /// Note: output is synthesized at the HID layer via `.cghidEventTap`
    /// (see `taggedPost`). Delivery to other apps requires the Accessibility
    /// permission, which `AccessibilityPermissionService.requestAccess()`
    /// asks for; this diagnostic only verifies that event creation and
    /// posting do not fail, so it intentionally runs without an
    /// `AXIsProcessTrusted` check.
    static func runDiagnostic() -> String {
        var results: [String] = []

        // 1. Check if we can create an event source
        let source = CGEventSource(stateID: .hidSystemState)
        results.append("Event Source: \(source != nil ? "OK" : "FAILED")")

        // 2. Check if we can create a keyboard event
        let keyEvent = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
        results.append("Key Event Create: \(keyEvent != nil ? "OK" : "FAILED")")

        // 3. Check if we can create a mouse move event
        let mouseEvent = CGEvent(mouseEventSource: source, mouseType: .mouseMoved,
                                  mouseCursorPosition: .zero, mouseButton: .left)
        results.append("Mouse Event Create: \(mouseEvent != nil ? "OK" : "FAILED")")

        // 4. Try posting a harmless mouse move with zero delta
        if let event = mouseEvent {
            event.setIntegerValueField(.mouseEventDeltaX, value: 0)
            event.setIntegerValueField(.mouseEventDeltaY, value: 0)
            // taggedPost is an instance method; use the singleton.
            InputSimulator.shared.taggedPost(event)
            results.append("Event Post: OK (no error)")
        } else {
            results.append("Event Post: SKIPPED (no event)")
        }

        // 5. App path
        results.append("App Path: \(Bundle.main.bundlePath)")

        return results.joined(separator: "\n")
    }
}

/// Tracks and helps the user grant the macOS Accessibility permission,
/// which InputConfig needs to deliver the keyboard and mouse actions a
/// user maps to their controller. This is the app's one approved use of
/// Accessibility (App Store guideline 2.4.5): it is used solely to perform
/// the user's own mappings, never to read or monitor input.
///
/// macOS posts no notification when this permission changes, so we re-check
/// on app activation and via a short poll after we prompt.
@MainActor
final class AccessibilityPermissionService: ObservableObject {
    static let shared = AccessibilityPermissionService()

    /// True when the app is trusted for Accessibility (allowed to deliver
    /// synthetic keyboard/mouse events to other apps).
    @Published private(set) var isTrusted: Bool = AXIsProcessTrusted()

    private var pollTimer: Timer?
    private var pollTicks = 0

    private init() {
        // The user usually grants the permission in System Settings and then
        // switches back to us, so re-check whenever we become the active app.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    /// Re-read the current trust state, publishing only on change.
    func refresh() {
        let now = AXIsProcessTrusted()
        if now != isTrusted { isTrusted = now }
    }

    /// Show the standard macOS "allow Accessibility" prompt, open the
    /// Accessibility pane, and poll so our UI flips to granted the moment
    /// the user enables InputConfig.
    func requestAccess() {
        // Use the literal key string rather than the global
        // `kAXTrustedCheckOptionPrompt`, which Swift 6 strict concurrency
        // rejects as a non-Sendable mutable global. The value is stable.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        openSystemSettings()
    }

    /// Open System Settings directly to Privacy & Security -> Accessibility,
    /// and start polling for the user to toggle us on.
    func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        startPolling()
    }

    /// Poll the trust state for up to ~2 minutes (TCC changes aren't
    /// observable), stopping early once granted.
    func startPolling() {
        pollTimer?.invalidate()
        pollTicks = 0
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                self.refresh()
                self.pollTicks += 1
                if self.isTrusted || self.pollTicks >= 120 {
                    self.pollTimer?.invalidate()
                    self.pollTimer = nil
                }
            }
        }
        pollTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
}

/// Registers one system-wide keyboard shortcut (Control + Option + Command +
/// P) that toggles the most recently used preset on or off, even while another
/// app is in front. Uses Carbon's `RegisterEventHotKey`, which is allowed
/// inside the App Sandbox and needs no extra entitlement or permission. When
/// the chord is pressed it posts `toggleNotification`; ContentView listens and
/// performs the toggle on the main actor. Off by default; the user opts in
/// from Settings.
final class GlobalHotKeyService: @unchecked Sendable {
    static let shared = GlobalHotKeyService()
    static let toggleNotification = Notification.Name("InputConfig.ToggleRecentPreset")
    /// UserDefaults key shared by Settings (the toggle) and AppState (boot).
    static let enabledDefaultsKey = "InputConfig.globalHotkeyEnabled"

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private(set) var isEnabled = false

    /// Human-readable chord, shown in Settings.
    let shortcutDescription = "Control + Option + Command + P"

    private init() {}

    /// Returns false when registration fails (typically because another app
    /// owns the chord) so callers can keep their on/off UI truthful.
    @discardableResult
    func enable() -> Bool {
        guard !isEnabled else { return true }

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        // Capture-free C callback: it only bounces a notification onto the
        // main queue, touching no instance state, so there is no data race.
        let callback: EventHandlerUPP = { _, _, _ -> OSStatus in
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: GlobalHotKeyService.toggleNotification, object: nil)
            }
            return noErr
        }
        let installStatus = InstallEventHandler(GetApplicationEventTarget(), callback, 1, &spec, nil, &handlerRef)
        guard installStatus == noErr else {
            NSLog("GlobalHotKeyService: InstallEventHandler failed (status \(installStatus)); hotkey not enabled")
            return false
        }

        let hotKeyID = EventHotKeyID(signature: OSType(0x4A4B4350), id: 1) // 'JKCP'
        let mods = UInt32(controlKey | optionKey | cmdKey)
        let registerStatus = RegisterEventHotKey(UInt32(kVK_ANSI_P), mods, hotKeyID,
                            GetApplicationEventTarget(), 0, &hotKeyRef)
        guard registerStatus == noErr else {
            // The chord is likely already claimed by another app. Don't report
            // ourselves as enabled when the registration didn't take, and clean
            // up the handler we just installed.
            NSLog("GlobalHotKeyService: RegisterEventHotKey failed (status \(registerStatus)); the chord may be taken by another app")
            if let h = handlerRef { RemoveEventHandler(h); handlerRef = nil }
            return false
        }
        isEnabled = true
        return true
    }

    func disable() {
        if let h = hotKeyRef { UnregisterEventHotKey(h); hotKeyRef = nil }
        if let e = handlerRef { RemoveEventHandler(e); handlerRef = nil }
        isEnabled = false
    }

    /// Apply a desired on/off state and persist it.
    func setEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Self.enabledDefaultsKey)
        if on { enable() } else { disable() }
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

    static func runDiagnostic() -> String { "iOS: Not supported" }
}

@MainActor
final class AccessibilityPermissionService: ObservableObject {
    static let shared = AccessibilityPermissionService()
    @Published private(set) var isTrusted: Bool = true
    func refresh() {}
    func requestAccess() {}
    func openSystemSettings() {}
    func startPolling() {}
}

#endif
