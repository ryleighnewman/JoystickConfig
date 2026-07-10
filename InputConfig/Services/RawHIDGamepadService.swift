import Foundation
import IOKit
import IOKit.hid
import Combine

/// Enumerates HID gamepads via IOKit and reads their input reports
/// directly, bypassing Apple's GameController framework. This is how
/// InputConfig supports controllers that GameController can't see:
/// 8BitDo Ultimate 2C in XInput mode, generic Xbox 360 wired pads,
/// PowerA / Logitech F310-F710 / MadCatz Xbox-compatibles, etc.
///
/// Architecture overview:
///
///   1. `IOHIDManager` is configured with a match dictionary covering
///      Generic Desktop / Joystick + Generic Desktop / Gamepad usage
///      pages. Whenever a matching device appears the connect handler
///      fires.
///   2. For each device we look up a `ControllerProfile` from
///      `ControllerProfileDatabase`. If we find one we install an input
///      report callback and start parsing. If no profile matches we
///      record the device but skip input until we add a descriptor
///      parser (see `HIDDescriptorParser`).
///   3. The input report callback runs on IOKit's runloop thread
///      (the main runloop in our case). It calls a `nonisolated`
///      handler that decodes the report off-actor and writes the
///      resulting state into the lock-protected `RawHIDGamepad`. No
///      Task/main-actor hop on the hot path.
///   4. `GameControllerService` polls the published gamepad list each
///      half second to slot them in alongside the GCControllers + Steam
///      Controller, and queries `state(for:)` from its mapping
///      pipeline.
@MainActor
final class RawHIDGamepadService: ObservableObject {

    static let shared = RawHIDGamepadService()

    /// All gamepads we have seen and successfully started reading.
    /// Published so the controller list UI and `GameControllerService`
    /// can react to attach / detach.
    @Published private(set) var connectedGamepads: [RawHIDGamepad] = []

    /// HID devices we found but couldn't identify with a hand-coded
    /// profile. Kept for diagnostic display in Settings → Devices.
    @Published private(set) var unidentifiedDevices: [UnidentifiedDevice] = []

    struct UnidentifiedDevice: Identifiable, Equatable {
        let id: UInt64
        let vendorID: Int32
        let productID: Int32
        let productName: String
    }

    private var manager: IOHIDManager?
    private var openDevices: [UInt64: RawHIDGamepad] = [:]
    private var reportBuffers: [UInt64: UnsafeMutablePointer<UInt8>] = [:]
    private var reportBufferSizes: [UInt64: Int] = [:]
    /// Floor for per-device report buffer allocation. Devices that
    /// report a larger `kIOHIDMaxInputReportSizeKey` get a buffer
    /// matched to their declared maximum so fight-stick HID reports
    /// (up to ~128 bytes) aren't truncated mid-decode.
    private let minimumReportBufferSize = 64

    /// Maps the raw IOHIDDevice pointer identity to its location ID so
    /// the nonisolated callback can find the matching gamepad without
    /// taking a lock or rummaging through ObservableObject state.
    /// Access serialized via `deviceLookupLock`.
    nonisolated(unsafe) private var deviceToLocation: [ObjectIdentifier: UInt64] = [:]
    private let deviceLookupLock = NSLock()

    /// Same idea for the gamepad itself - the report callback needs to
    /// reach the RawHIDGamepad to write its updated state without
    /// hopping to the main actor each frame.
    nonisolated(unsafe) private var gamepadsByLocation: [UInt64: RawHIDGamepad] = [:]

    private init() { }

    // MARK: - Public lifecycle

    /// Build the IOHIDManager and start observing the bus. Idempotent;
    /// safe to call from app startup.
    func start() {
        guard manager == nil else { return }

        let mgr = IOHIDManagerCreate(kCFAllocatorDefault,
                                     IOOptionBits(kIOHIDOptionsTypeNone))
        manager = mgr

        // Match against the two Generic Desktop usage values that all
        // HID gamepads identify with. Joystick = 0x04, Gamepad = 0x05.
        let joystickMatch: [String: Any] = [
            kIOHIDDeviceUsagePageKey as String: 0x01,
            kIOHIDDeviceUsageKey as String: 0x04,
        ]
        let gamepadMatch: [String: Any] = [
            kIOHIDDeviceUsagePageKey as String: 0x01,
            kIOHIDDeviceUsageKey as String: 0x05,
        ]
        // Multi-axis Controller (0x08): some wheels, yokes, and HOTAS
        // devices identify with this usage instead of Joystick/Gamepad
        // and would otherwise never trigger the attach callback.
        let multiAxisMatch: [String: Any] = [
            kIOHIDDeviceUsagePageKey as String: 0x01,
            kIOHIDDeviceUsageKey as String: 0x08,
        ]
        let matches: [[String: Any]] = [joystickMatch, gamepadMatch, multiAxisMatch]
        IOHIDManagerSetDeviceMatchingMultiple(mgr, matches as CFArray)

        IOHIDManagerScheduleWithRunLoop(mgr,
                                        CFRunLoopGetMain(),
                                        CFRunLoopMode.commonModes.rawValue)

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        IOHIDManagerRegisterDeviceMatchingCallback(mgr, { context, _, _, device in
            guard let context = context else { return }
            let svc = Unmanaged<RawHIDGamepadService>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in svc.handleDeviceAttached(device) }
        }, selfPtr)

        IOHIDManagerRegisterDeviceRemovalCallback(mgr, { context, _, _, device in
            guard let context = context else { return }
            let svc = Unmanaged<RawHIDGamepadService>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in svc.handleDeviceDetached(device) }
        }, selfPtr)

        IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    /// Tear everything down. Mostly for tests; the singleton stays
    /// alive for the app's lifetime in production.
    ///
    /// Order matters: clear the lookup tables BEFORE closing devices
    /// so any callback already in flight on the HID thread can't
    /// resolve a gamepad and reach a soon-to-be-deallocated object.
    /// Closing the device while the callback holds a stale pointer is
    /// the classic use-after-free this dance avoids.
    func stop() {
        deviceLookupLock.lock()
        deviceToLocation.removeAll()
        gamepadsByLocation.removeAll()
        deviceLookupLock.unlock()

        for (_, gamepad) in openDevices {
            IOHIDDeviceUnscheduleFromRunLoop(gamepad.device,
                                             CFRunLoopGetMain(),
                                             CFRunLoopMode.commonModes.rawValue)
            IOHIDDeviceClose(gamepad.device, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        for (_, buf) in reportBuffers { buf.deallocate() }
        reportBuffers.removeAll()
        reportBufferSizes.removeAll()
        openDevices.removeAll()
        connectedGamepads = []
        unidentifiedDevices = []

        if let mgr = manager {
            IOHIDManagerClose(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
            IOHIDManagerUnscheduleFromRunLoop(mgr,
                                              CFRunLoopGetMain(),
                                              CFRunLoopMode.commonModes.rawValue)
            manager = nil
        }
    }

    /// Read the latest decoded state for a gamepad.
    func state(for gamepad: RawHIDGamepad) -> ControllerState {
        return gamepad.state
    }

    // MARK: - Device lifecycle

    private func handleDeviceAttached(_ device: IOHIDDevice) {
        if isClaimedByGameControllerFramework(device) { return }

        guard let info = readDeviceInfo(device) else { return }
        if openDevices[info.locationID] != nil { return }

        // First pass: hand-coded profile lookup. Covers the common
        // controllers we care about (8BitDo, Xbox 360 wired, Logitech,
        // PowerA, MadCatz, DualShock 3).
        var profile = ControllerProfileDatabase.profile(
            forVendor: info.vendorID,
            product: info.productID,
            transport: info.transport
        )

        // Second pass: if no hand-coded entry matched, ask the HID
        // descriptor parser to synthesize a generic layout. This lets
        // unknown gamepads work without code changes - covers older
        // retro pads, racing wheels, and the long tail of obscure
        // controllers users report.
        if profile == nil {
            if let descriptor = IOHIDDeviceGetProperty(device, kIOHIDReportDescriptorKey as CFString) as? Data,
               let layout = HIDDescriptorParser.parse(descriptor) {
                profile = ControllerProfile(
                    identifier: "generic-hid-\(info.vendorID)-\(info.productID)",
                    displayName: info.productName,
                    vendorID: info.vendorID,
                    productMatches: [.exact(info.productID)],
                    layout: .generic(layout),
                    physicalButtonNames: genericButtonNames(count: layout.buttonBitOffsets.count)
                )
            }
        }

        if profile == nil {
            let undef = UnidentifiedDevice(
                id: info.locationID,
                vendorID: info.vendorID,
                productID: info.productID,
                productName: info.productName
            )
            // Cache the object->location mapping for unidentified devices too,
            // so detach can resolve the location and remove the published slot.
            // Without this, unplugged unidentified devices lingered forever.
            deviceLookupLock.lock()
            deviceToLocation[ObjectIdentifier(device)] = info.locationID
            deviceLookupLock.unlock()
            if !unidentifiedDevices.contains(undef) {
                unidentifiedDevices.append(undef)
            }
            return
        }

        // Open the device. Pass kIOHIDOptionsTypeNone so other consumers
        // (including macOS background services) can keep reading the
        // same device. Empirically this is what we need for 8BitDo
        // controllers to work alongside system controller agents.
        let openResult = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard openResult == kIOReturnSuccess else { return }

        // A DualShock 3 on USB stays silent until the host sends the
        // Sixaxis "operational mode" feature report (ID 0xF4). Without
        // it the pad enumerates, opens, and never emits a single input
        // report, so the profile is dead on arrival.
        if let p = profile, case .dualShock3 = p.layout {
            var enable: [UInt8] = [0x42, 0x0C, 0x00, 0x00]
            IOHIDDeviceSetReport(device,
                                 kIOHIDReportTypeFeature,
                                 0xF4,
                                 &enable,
                                 enable.count)
        }

        let gamepad = RawHIDGamepad(
            device: device,
            id: info.locationID,
            vendorID: info.vendorID,
            productID: info.productID,
            productName: info.productName,
            manufacturer: info.manufacturer,
            transport: info.transport,
            profile: profile
        )
        openDevices[info.locationID] = gamepad

        // Build a callback lookup table so the report handler can
        // resolve `sender → gamepad` in O(1) without touching @Published
        // state or hopping to the main actor.
        deviceLookupLock.lock()
        deviceToLocation[ObjectIdentifier(device)] = info.locationID
        gamepadsByLocation[info.locationID] = gamepad
        deviceLookupLock.unlock()

        // Query the device's declared max input report size. Fight
        // sticks and racing wheels can declare 128+ byte reports; a
        // fixed 64-byte buffer truncates them mid-decode and produces
        // wrong state. Fall back to our floor for devices that don't
        // declare the key.
        let declaredMax = (IOHIDDeviceGetProperty(device, kIOHIDMaxInputReportSizeKey as CFString) as? NSNumber)?.intValue ?? 0
        let bufferSize = max(minimumReportBufferSize, declaredMax)
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        buffer.initialize(repeating: 0, count: bufferSize)
        reportBuffers[info.locationID] = buffer
        reportBufferSizes[info.locationID] = bufferSize

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(
            device,
            buffer,
            bufferSize,
            rawHIDInputReportCallback,
            selfPtr
        )
        IOHIDDeviceScheduleWithRunLoop(device,
                                       CFRunLoopGetMain(),
                                       CFRunLoopMode.commonModes.rawValue)

        connectedGamepads.append(gamepad)
    }

    private func handleDeviceDetached(_ device: IOHIDDevice) {
        // Resolve the location from the cached table rather than re-reading it
        // from the dying device. IOKit frequently fails this property read for
        // an already-departed USB device, and the old early-return on that
        // failure leaked the report buffer, device handle, lookup entries, and
        // the published slot. Clear lookup tables FIRST so an in-flight HID
        // callback can't resolve a gamepad and dereference a soon-to-be-
        // released IOHIDDevice.
        deviceLookupLock.lock()
        let cachedLocation = deviceToLocation.removeValue(forKey: ObjectIdentifier(device))
        let location = cachedLocation
            ?? (IOHIDDeviceGetProperty(device, kIOHIDLocationIDKey as CFString) as? NSNumber)?.uint64Value
        if let location = location {
            gamepadsByLocation.removeValue(forKey: location)
        }
        deviceLookupLock.unlock()

        guard let location = location else { return }

        if let gamepad = openDevices.removeValue(forKey: location) {
            IOHIDDeviceUnscheduleFromRunLoop(gamepad.device,
                                             CFRunLoopGetMain(),
                                             CFRunLoopMode.commonModes.rawValue)
            IOHIDDeviceClose(gamepad.device, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        if let buf = reportBuffers.removeValue(forKey: location) {
            buf.deallocate()
        }
        reportBufferSizes.removeValue(forKey: location)
        connectedGamepads.removeAll { $0.id == location }
        unidentifiedDevices.removeAll { $0.id == location }
    }

    // MARK: - Report dispatch (non-isolated)

    /// Decode a raw HID input report and write the result into the
    /// matching `RawHIDGamepad`. Called from `rawHIDInputReportCallback`
    /// on IOKit's runloop thread; deliberately non-isolated so we
    /// don't pay a Task creation cost for every report.
    nonisolated func dispatchReport(deviceRef: IOHIDDevice,
                                    reportPointer: UnsafeMutablePointer<UInt8>,
                                    length: CFIndex) {
        deviceLookupLock.lock()
        let location = deviceToLocation[ObjectIdentifier(deviceRef)]
        let gamepad = location.flatMap { gamepadsByLocation[$0] }
        deviceLookupLock.unlock()

        guard let gamepad, let profile = gamepad.profile else { return }
        let data = Data(bytes: reportPointer, count: length)
        let newState = HIDReportDecoder.decode(report: data, profile: profile)
        gamepad.updateState(newState)
    }

    // MARK: - Helpers

    private struct DeviceInfo {
        let locationID: UInt64
        let vendorID: Int32
        let productID: Int32
        let productName: String
        let manufacturer: String?
        let transport: String
    }

    private func readDeviceInfo(_ device: IOHIDDevice) -> DeviceInfo? {
        guard let vidRef = IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString) as? NSNumber,
              let pidRef = IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? NSNumber,
              let locRef = IOHIDDeviceGetProperty(device, kIOHIDLocationIDKey as CFString) as? NSNumber else {
            return nil
        }
        let name = (IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String)
            ?? "HID Gamepad"
        let mfr = IOHIDDeviceGetProperty(device, kIOHIDManufacturerKey as CFString) as? String
        let transport = (IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString) as? String)
            ?? "Unknown"

        return DeviceInfo(
            locationID: locRef.uint64Value,
            vendorID: vidRef.int32Value,
            productID: pidRef.int32Value,
            productName: name,
            manufacturer: mfr,
            transport: transport
        )
    }

    /// Friendly placeholder names for descriptor-synthesized profiles
    /// where we don't know which physical button is which. The
    /// binding editor displays these in the input scanner.
    private func genericButtonNames(count: Int) -> [String] {
        return (0..<max(count, 1)).map { "Button \($0)" }
    }

    /// Some controllers are already handled by Apple's GameController
    /// framework (DualSense, Xbox Series, Switch Pro, MFi 8BitDo,
    /// etc.). For those we let the system framework keep ownership
    /// rather than fighting over the device.
    private func isClaimedByGameControllerFramework(_ device: IOHIDDevice) -> Bool {
        guard let vidRef = IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString) as? NSNumber else {
            return false
        }
        let vid = vidRef.int32Value

        // Microsoft - all Xbox One / Series controllers handled by
        // GameController; Xbox 360 wired (PID 0x028E, 0x028F, 0x02A1)
        // is NOT, so we claim those.
        if vid == 0x045E {
            if let pidRef = IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? NSNumber {
                let pid = pidRef.int32Value
                let xbox360Wired: Set<Int32> = [0x028E, 0x028F, 0x02A1]
                if xbox360Wired.contains(pid) { return false }
            }
            return true
        }

        // Sony DualSense / DualShock 4 handled by GameController;
        // DualShock 3 (PID 0x0268) is NOT, so we claim that.
        if vid == 0x054C {
            if let pidRef = IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? NSNumber,
               pidRef.int32Value == 0x0268 {
                return false
            }
            return true
        }

        // Nintendo Switch Pro / Joy-Con handled by GameController on
        // Ventura+.
        if vid == 0x057E { return true }

        // Google Stadia and Amazon Luna are GameController-supported on
        // modern macOS. Without suppressing them here the same pad was
        // enumerated by BOTH drivers (an MFi slot and a raw-HID slot with
        // different index schemes), so scans could record indices the
        // user's preset slot never matched.
        if vid == 0x18D1 { return true }   // Google (Stadia)
        if vid == 0x1949 { return true }   // Amazon (Luna)

        return false
    }
}

// MARK: - C callback bridge

/// Free function called by IOKit on the runloop thread when a HID
/// input report arrives. Hands off to the service's nonisolated
/// `dispatchReport` so decoding happens immediately without a
/// main-actor hop.
private func rawHIDInputReportCallback(context: UnsafeMutableRawPointer?,
                                       result: IOReturn,
                                       sender: UnsafeMutableRawPointer?,
                                       type: IOHIDReportType,
                                       reportID: UInt32,
                                       report: UnsafeMutablePointer<UInt8>,
                                       reportLength: CFIndex) {
    guard result == kIOReturnSuccess else { return }
    guard let context = context, let sender = sender else { return }
    let svc = Unmanaged<RawHIDGamepadService>.fromOpaque(context).takeUnretainedValue()
    let device = Unmanaged<IOHIDDevice>.fromOpaque(sender).takeUnretainedValue()
    svc.dispatchReport(deviceRef: device,
                       reportPointer: report,
                       length: reportLength)
}
