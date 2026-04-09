import Foundation
import IOKit
import IOKit.hid

/// Direct IOKit HID control for DualSense / DualShock 4 light bars.
///
/// Three strategies are attempted:
/// 1. GCController.light API (called from GameControllerService)
/// 2. IOKit HID output report (USB protocol)
/// 3. IOKit HID feature report (used by macOS System Settings)
///
/// The class is NOT MainActor-isolated so IOKit calls run freely.
class HIDLightController {
    nonisolated(unsafe) static let shared = HIDLightController()

    private var manager: IOHIDManager?
    private let queue = DispatchQueue(label: "com.joystickconfig.hidlight")
    private var sequenceTag: UInt8 = 0

    private let sonyVID = 0x054C
    private let dualSensePIDs: Set<Int> = [0x0CE6, 0x0DF2]
    private let ds4PIDs: Set<Int> = [0x05C4, 0x09CC]

    private init() {
        queue.async { [weak self] in
            self?.setupManager()
        }
    }

    private func setupManager() {
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        guard let manager = manager else { return }

        let matching: [String: Any] = [kIOHIDVendorIDKey as String: sonyVID]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)

        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        debugPrint("[HIDLight] Manager open: \(result == kIOReturnSuccess ? "OK" : "err 0x\(String(result, radix: 16))")")
    }

    /// Set light bar color. Thread-safe — dispatches to internal queue.
    func setLightColor(red: UInt8, green: UInt8, blue: UInt8, controllerIndex: Int? = nil) {
        queue.async { [weak self] in
            self?.setLightColorSync(red: red, green: green, blue: blue, controllerIndex: controllerIndex)
        }
    }

    private func setLightColorSync(red: UInt8, green: UInt8, blue: UInt8, controllerIndex: Int?) {
        guard let manager = manager else { return }
        guard let deviceSet = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else {
            debugPrint("[HIDLight] No devices")
            return
        }

        let devices = deviceSet.sorted { d1, d2 in
            (prop(d1, kIOHIDLocationIDKey) ?? 0) < (prop(d2, kIOHIDLocationIDKey) ?? 0)
        }

        var idx = 0
        for device in devices {
            guard let vid = prop(device, kIOHIDVendorIDKey), vid == sonyVID else { continue }
            guard let pid = prop(device, kIOHIDProductIDKey) else { continue }

            let isDS = dualSensePIDs.contains(pid)
            let isDS4 = ds4PIDs.contains(pid)
            guard isDS || isDS4 else { continue }

            if let target = controllerIndex, idx != target { idx += 1; continue }

            let name = propStr(device, kIOHIDProductKey) ?? "?"
            debugPrint("[HIDLight] Setting \(name) (PID 0x\(String(pid, radix:16))) to RGB(\(red),\(green),\(blue))")

            if isDS {
                // Try all methods
                let usb = sendDualSenseUSB(device, red, green, blue)
                if !usb {
                    let bt = sendDualSenseBT(device, red, green, blue)
                    if !bt {
                        sendDualSenseFeature(device, red, green, blue)
                    }
                }
            } else {
                let usb = sendDS4USB(device, red, green, blue)
                if !usb { sendDS4BT(device, red, green, blue) }
            }

            idx += 1
        }
    }

    // MARK: - DualSense USB (Report ID 0x02)

    private func sendDualSenseUSB(_ dev: IOHIDDevice, _ r: UInt8, _ g: UInt8, _ b: UInt8) -> Bool {
        // Try without seize first
        if sendDualSenseUSBReport(dev, r, g, b) { return true }

        // Try with device seize (needed when GCController framework holds the device)
        let openRes = IOHIDDeviceOpen(dev, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
        if openRes == kIOReturnSuccess {
            let ok = sendDualSenseUSBReport(dev, r, g, b)
            IOHIDDeviceClose(dev, IOOptionBits(kIOHIDOptionsTypeNone))
            if ok { return true }
        }

        // Try with report ID embedded in buffer (some macOS IOKit stacks want this)
        var rptWithId = [UInt8](repeating: 0, count: 64)
        rptWithId[0] = 0x02 // report ID
        rptWithId[1] = 0x00 // valid_flag0
        rptWithId[2] = 0x04 // valid_flag1: lightbar control enable
        rptWithId[39] = 0x02 // valid_flag2
        rptWithId[42] = 0x02 // lightbar_setup
        rptWithId[45] = r
        rptWithId[46] = g
        rptWithId[47] = b
        let r3 = IOHIDDeviceSetReport(dev, kIOHIDReportTypeOutput, 0x02, rptWithId, rptWithId.count)
        debugPrint("[HIDLight] DS USB embedded-id: \(r3 == kIOReturnSuccess ? "OK" : "0x\(String(r3, radix:16))")")
        return r3 == kIOReturnSuccess
    }

    private func sendDualSenseUSBReport(_ dev: IOHIDDevice, _ r: UInt8, _ g: UInt8, _ b: UInt8) -> Bool {
        var rpt = [UInt8](repeating: 0, count: 63)
        rpt[0] = 0x00  // valid_flag0: no haptic changes
        rpt[1] = 0x04  // valid_flag1: lightbar control enable
        rpt[38] = 0x02 // valid_flag2: lightbar setup control enable
        rpt[41] = 0x02 // lightbar_setup: light on
        rpt[44] = r    // lightbar_red
        rpt[45] = g    // lightbar_green
        rpt[46] = b    // lightbar_blue

        let res = IOHIDDeviceSetReport(dev, kIOHIDReportTypeOutput, 0x02, rpt, rpt.count)
        debugPrint("[HIDLight] DS USB output: \(res == kIOReturnSuccess ? "OK" : "0x\(String(res, radix:16))")")
        return res == kIOReturnSuccess
    }

    // MARK: - DualSense BT (Report ID 0x31)

    @discardableResult
    private func sendDualSenseBT(_ dev: IOHIDDevice, _ r: UInt8, _ g: UInt8, _ b: UInt8) -> Bool {
        // Try normal first, then with seize
        if sendDualSenseBTReport(dev, r, g, b) { return true }

        let openRes = IOHIDDeviceOpen(dev, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
        if openRes == kIOReturnSuccess {
            let ok = sendDualSenseBTReport(dev, r, g, b)
            IOHIDDeviceClose(dev, IOOptionBits(kIOHIDOptionsTypeNone))
            return ok
        }
        return false
    }

    private func sendDualSenseBTReport(_ dev: IOHIDDevice, _ r: UInt8, _ g: UInt8, _ b: UInt8) -> Bool {
        var rpt = [UInt8](repeating: 0, count: 78)
        sequenceTag = (sequenceTag &+ 1) & 0x0F
        rpt[0] = (sequenceTag << 4) | 0x02
        rpt[1] = 0x00  // valid_flag0: no haptic changes
        rpt[2] = 0x04  // valid_flag1: lightbar control enable
        rpt[39] = 0x02 // valid_flag2: lightbar setup control enable
        rpt[42] = 0x02 // lightbar_setup: light on
        rpt[45] = r    // lightbar_red
        rpt[46] = g    // lightbar_green
        rpt[47] = b    // lightbar_blue

        // CRC32
        var crc_in = [UInt8]()
        crc_in.append(0xA2)
        crc_in.append(0x31)
        crc_in.append(contentsOf: rpt[0..<74])
        let crc = crc32(crc_in)
        rpt[74] = UInt8(crc & 0xFF)
        rpt[75] = UInt8((crc >> 8) & 0xFF)
        rpt[76] = UInt8((crc >> 16) & 0xFF)
        rpt[77] = UInt8((crc >> 24) & 0xFF)

        let res = IOHIDDeviceSetReport(dev, kIOHIDReportTypeOutput, 0x31, rpt, rpt.count)
        debugPrint("[HIDLight] DS BT output: \(res == kIOReturnSuccess ? "OK" : "0x\(String(res, radix:16))")")
        return res == kIOReturnSuccess
    }

    // MARK: - DualSense Feature Report (Report ID 0x05)
    // macOS System Settings may use feature reports to set the color

    @discardableResult
    private func sendDualSenseFeature(_ dev: IOHIDDevice, _ r: UInt8, _ g: UInt8, _ b: UInt8) -> Bool {
        // Try several feature report approaches
        // Approach 1: Feature report 0x05
        var rpt1 = [UInt8](repeating: 0, count: 64)
        rpt1[0] = 0x05
        rpt1[1] = 0x04 // lightbar
        rpt1[41] = 0x02 // lightbar_setup
        rpt1[44] = r; rpt1[45] = g; rpt1[46] = b
        let r1 = IOHIDDeviceSetReport(dev, kIOHIDReportTypeFeature, 0x05, rpt1, rpt1.count)
        debugPrint("[HIDLight] DS feature 0x05: \(r1 == kIOReturnSuccess ? "OK" : "0x\(String(r1, radix:16))")")

        // Approach 2: Output report 0x02 with seize (open exclusive, write, close)
        let r2 = IOHIDDeviceOpen(dev, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
        if r2 == kIOReturnSuccess {
            var rpt2 = [UInt8](repeating: 0, count: 63)
            rpt2[0] = 0x02; rpt2[1] = 0x04; rpt2[38] = 0x02
            rpt2[41] = 0x02 // lightbar_setup
            rpt2[44] = r; rpt2[45] = g; rpt2[46] = b
            let w = IOHIDDeviceSetReport(dev, kIOHIDReportTypeOutput, 0x02, rpt2, rpt2.count)
            debugPrint("[HIDLight] DS seized output: \(w == kIOReturnSuccess ? "OK" : "0x\(String(w, radix:16))")")
            IOHIDDeviceClose(dev, IOOptionBits(kIOHIDOptionsTypeNone))
            return w == kIOReturnSuccess
        }

        return r1 == kIOReturnSuccess
    }

    // MARK: - DualShock 4 USB (Report ID 0x05)

    private func sendDS4USB(_ dev: IOHIDDevice, _ r: UInt8, _ g: UInt8, _ b: UInt8) -> Bool {
        var rpt = [UInt8](repeating: 0, count: 31)
        rpt[0] = 0x07
        rpt[5] = r; rpt[6] = g; rpt[7] = b
        let res = IOHIDDeviceSetReport(dev, kIOHIDReportTypeOutput, 0x05, rpt, rpt.count)
        debugPrint("[HIDLight] DS4 USB: \(res == kIOReturnSuccess ? "OK" : "0x\(String(res, radix:16))")")
        return res == kIOReturnSuccess
    }

    // MARK: - DualShock 4 BT (Report ID 0x11)

    @discardableResult
    private func sendDS4BT(_ dev: IOHIDDevice, _ r: UInt8, _ g: UInt8, _ b: UInt8) -> Bool {
        var rpt = [UInt8](repeating: 0, count: 78)
        rpt[0] = 0xC0; rpt[1] = 0x20; rpt[2] = 0xF3; rpt[3] = 0x04
        rpt[6] = r; rpt[7] = g; rpt[8] = b

        var crc_in = [UInt8]()
        crc_in.append(0xA2); crc_in.append(0x11)
        crc_in.append(contentsOf: rpt[0..<74])
        let crc = crc32(crc_in)
        rpt[74] = UInt8(crc & 0xFF)
        rpt[75] = UInt8((crc >> 8) & 0xFF)
        rpt[76] = UInt8((crc >> 16) & 0xFF)
        rpt[77] = UInt8((crc >> 24) & 0xFF)

        let res = IOHIDDeviceSetReport(dev, kIOHIDReportTypeOutput, 0x11, rpt, rpt.count)
        debugPrint("[HIDLight] DS4 BT: \(res == kIOReturnSuccess ? "OK" : "0x\(String(res, radix:16))")")
        return res == kIOReturnSuccess
    }

    // MARK: - Helpers

    private func debugPrint(_ message: @autoclosure () -> String) {
        #if DEBUG
        print(message())
        #endif
    }

    private func prop(_ d: IOHIDDevice, _ k: String) -> Int? {
        (IOHIDDeviceGetProperty(d, k as CFString) as? NSNumber)?.intValue
    }
    private func propStr(_ d: IOHIDDevice, _ k: String) -> String? {
        IOHIDDeviceGetProperty(d, k as CFString) as? String
    }

    private func crc32(_ data: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc & 1 != 0) ? (crc >> 1) ^ 0xEDB88320 : crc >> 1
            }
        }
        return crc ^ 0xFFFFFFFF
    }
}
