import Foundation
import IOKit
import IOKit.hid
import Combine

/// Information about an 8BitDo controller detected at the HID level.
struct EightBitDoDevice: Identifiable, Hashable {
    let id: UInt64       // location ID (unique per physical device)
    let productID: Int32
    let productName: String
    let transport: String  // "USB", "Bluetooth", etc.
    let mode: EightBitDoMode
}

/// The connection mode an 8BitDo controller appears to be running in,
/// determined by inspecting its USB product ID and vendor name string.
/// 8BitDo controllers expose different product IDs depending on the mode
/// switch position. The mode determines which other systems will accept the
/// controller.
///
/// On macOS:
///   - apple/MFi mode is fully supported through the GameController framework
///   - switch mode is partially supported (as a Nintendo Switch controller)
///   - xinput and dinput modes are recognized as HID devices but the
///     GameController framework will not see them
///   - macMode is the only one that exposes adaptive triggers, haptics, and
///     the full extended gamepad profile
enum EightBitDoMode: String {
    case apple = "Apple/MFi"       // Mode switch A
    case nintendoSwitch = "Switch" // Mode switch S
    case xinput = "XInput"         // Mode switch X
    case dinput = "DInput"         // Mode switch D
    case android = "Android"       // Android mode
    case unknown = "Unknown"

    var supportedByMacOS: Bool {
        switch self {
        case .apple, .nintendoSwitch: return true
        default: return false
        }
    }
}

/// Watches IOKit for 8BitDo controllers and reports their mode.
/// This complements `GameControllerService` (which uses Apple's
/// GameController framework). If an 8BitDo controller is connected
/// but does not appear in `GameControllerService.connectedControllers`,
/// it is almost certainly in a mode the framework does not support.
@MainActor
final class EightBitDoDetector: ObservableObject {
    @Published private(set) var detectedDevices: [EightBitDoDevice] = []

    /// 8BitDo's official USB vendor ID.
    static let vendorID: Int32 = 0x2DC8

    private var manager: IOHIDManager?
    private let queue = DispatchQueue(label: "com.inputconfig.8bitdo")
    private var rescanTimer: Timer?

    init() {
        setupManager()
        startPolling()
    }

    // MARK: - Setup

    private func setupManager() {
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        guard let manager = manager else { return }

        let match: [String: Any] = [kIOHIDVendorIDKey as String: Self.vendorID]
        IOHIDManagerSetDeviceMatching(manager, match as CFDictionary)

        // Event-driven detection: rescan the instant an 8BitDo device appears
        // or disappears, instead of waking every 2 s forever to poll. The
        // callback captures nothing (it reads its context arg), so it is a
        // valid C function pointer. A slow safety poll below still covers the
        // rare missed-event-during-mode-switch case the old comment worried
        // about, so behavior is preserved while idle wakes drop ~7x.
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        let cb: IOHIDDeviceCallback = { context, _, _, _ in
            guard let context = context else { return }
            let me = Unmanaged<EightBitDoDetector>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in me.rescan() }
        }
        IOHIDManagerRegisterDeviceMatchingCallback(manager, cb, ctx)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, cb, ctx)

        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    /// Detection is event-driven (match/removal callbacks in setupManager); this
    /// slow 15 s poll is only a safety net for events IOHIDManager can miss
    /// during 8BitDo mode switches. rescan() is idempotent and change-gated, so
    /// the poll costs nothing between actual connect/disconnect changes.
    private func startPolling() {
        rescanTimer?.invalidate()
        rescan()
        rescanTimer = Timer.scheduledTimer(withTimeInterval: 15.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.rescan() }
        }
        if let timer = rescanTimer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    func rescan() {
        guard let manager = manager else { return }
        guard let deviceSet = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else {
            if !detectedDevices.isEmpty { detectedDevices = [] }
            return
        }

        var seen = Set<UInt64>()
        var newDevices: [EightBitDoDevice] = []

        for device in deviceSet {
            guard let pidRef = IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? NSNumber,
                  let locRef = IOHIDDeviceGetProperty(device, kIOHIDLocationIDKey as CFString) as? NSNumber else { continue }

            let pid = pidRef.int32Value
            let location = locRef.uint64Value
            if seen.contains(location) { continue }
            seen.insert(location)

            let name = (IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String) ?? "8BitDo Controller"
            let transport = (IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString) as? String) ?? "Unknown"
            let mode = Self.detectMode(productID: pid, productName: name)

            newDevices.append(EightBitDoDevice(
                id: location,
                productID: pid,
                productName: name,
                transport: transport,
                mode: mode
            ))
        }

        // Order by location for stable display
        newDevices.sort { $0.id < $1.id }

        // Only publish if something changed
        if newDevices != detectedDevices {
            detectedDevices = newDevices
        }
    }

    // MARK: - Mode Detection

    /// 8BitDo encodes the connection mode in the USB product ID. The exact
    /// PIDs vary across models, so we use both the PID range and the product
    /// name string to make a best guess. Models known to support Apple/MFi
    /// mode include the Pro 2, Ultimate, SN30 Pro+, Pro, SN30 Pro, and Lite SE.
    static func detectMode(productID: Int32, productName: String) -> EightBitDoMode {
        let lower = productName.lowercased()

        // Apple/MFi mode reports the controller as an MFi gamepad, so the
        // GameController framework will see it. PIDs in the 0x6000-0x6FFF
        // range are typically Apple/MFi mode, but the most reliable indicator
        // is that the name contains "MFi" or the controller appears in
        // GCController.controllers().
        if lower.contains("mfi") || lower.contains("apple") {
            return .apple
        }

        // Common PID hints from 8BitDo's documentation and SDL2 mappings.
        switch productID {
        case 0x6000...0x6FFF:
            return .apple
        case 0x9000...0x9FFF, 0x2000...0x2FFF:
            return .nintendoSwitch
        case 0x3100...0x31FF, 0x3000...0x30FF:
            // 0x3106 is the Ultimate XInput PID. Range used as a fallback.
            return .xinput
        case 0xAB00...0xABFF, 0x5000...0x5FFF:
            // Older retro-style controllers in DInput mode.
            return .dinput
        case 0x1000...0x1FFF, 0x4000...0x4FFF:
            return .android
        default:
            // If the name explicitly mentions a mode, use that.
            if lower.contains("xinput") || lower.contains("xbox") { return .xinput }
            if lower.contains("switch") || lower.contains("ns ") { return .nintendoSwitch }
            if lower.contains("android") { return .android }
            return .unknown
        }
    }
}
