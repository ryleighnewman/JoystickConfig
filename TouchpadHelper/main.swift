/// TouchpadHelper: long-running CLI that reads HID input reports from
/// connected Sony controllers (DualSense, DualSense Edge, DualShock 4) and
/// emits parsed touchpad finger positions to stdout, one line per report.
///
/// Designed to run alongside `gamecontrolleragentd` without seizing the
/// device, so the main app's GCController-based button/axis polling keeps
/// working while we get the touchpad bytes (which GCController does not
/// expose).
///
/// Line format on stdout (lines are terminated with \n, flushed each report):
///   T <reportSeq> <touchpadButton> \
///     <f0Active> <f0Id> <f0X> <f0Y> \
///     <f1Active> <f1Id> <f1X> <f1Y> \
///     <controller>
///
/// Additionally, whenever the PS/mute/extras button byte (buttons[2] of the
/// Sony report, which also carries the DualSense Edge paddle and FN bits in
/// its high nibble) CHANGES, a line:
///   B <buttons2decimal> <controller>
/// With `--buttons-only`, T lines are suppressed and only B lines are
/// emitted. The main app uses this mode on macOS 14+, where GameController
/// provides touch data but the Edge extras are only visible to an external
/// process reading the raw report (the app's own in-process HID open
/// receives no Bluetooth input reports while its GameController session is
/// active; this helper process does).
///
/// Where:
///   reportSeq        UInt64 monotonically increasing per device
///   touchpadButton   0/1 (touchpad pressed)
///   fNActive         0/1 (finger contact?)
///   fNId             0-127 cycling contact id, lets us spot lift/replace
///   fNX, fNY         Integer position in device-native coordinates
///                    DualSense: 0..1919 x 0..1079
///                    DualShock 4: 0..1919 x 0..942
///   controller       "dualsense" or "dualshock4"
///
/// Exits when stdin closes (parent process death) or on SIGTERM/SIGINT.

import Foundation
import IOKit
import IOKit.hid

// MARK: - Constants

let sonyVID: Int32 = 0x054C
let dualSensePIDs: Set<Int32> = [0x0CE6, 0x0DF2]   // DualSense + DualSense Edge
let ds4PIDs: Set<Int32>       = [0x05C4, 0x09CC]
let buttonsOnly = CommandLine.arguments.contains("--buttons-only")

// MARK: - Helpers

func emit(_ line: String) {
    // FileHandle.standardOutput.write avoids the line-buffering surprise of print()
    if let data = (line + "\n").data(using: .utf8) {
        FileHandle.standardOutput.write(data)
    }
}

func log(_ msg: String) {
    FileHandle.standardError.write((msg + "\n").data(using: .utf8) ?? Data())
}

// MARK: - Per-device state

final class DeviceCtx {
    let device: IOHIDDevice
    let pid: Int32
    let isBT: Bool
    let kind: String           // "dualsense" or "dualshock4"
    var seq: UInt64 = 0
    /// Bluetooth DualSense needs a feature-get on 0x05 to flip into 0x31
    /// extended-report mode (which contains the touchpad bytes).
    var didEnableBTReports = false
    /// Last buttons[2] value emitted on a B line, so we only emit on change.
    var lastButtons2: UInt8 = 0
    var emittedInitialButtons = false

    init(device: IOHIDDevice, pid: Int32, isBT: Bool, kind: String) {
        self.device = device
        self.pid = pid
        self.isBT = isBT
        self.kind = kind
    }
}

/// Touchpad block parsing. Returns (touchpadButton, f0Active, f0Id, f0X, f0Y,
/// f1Active, f1Id, f1X, f1Y) for a single input-report buffer. `report` points
/// at the first byte AFTER any HID report-ID prefix (some IOHID input
/// callbacks include the report ID, some don't).
func parseTouchpadBlock(_ buf: UnsafePointer<UInt8>, len: Int,
                       blockOffset: Int, buttonByte: Int, buttonMask: UInt8)
    -> (UInt8, UInt8, UInt8, Int, Int, UInt8, UInt8, Int, Int)? {
    guard len >= blockOffset + 9 else { return nil }
    let p = buf

    let tpBtn: UInt8 = (p[buttonByte] & buttonMask) != 0 ? 1 : 0

    // Each finger block = 4 bytes: [id+contactBit, x_lo, x_hi|y_lo, y_hi]
    let off = blockOffset
    let f0Header = p[off]
    let f0Active: UInt8 = (f0Header & 0x80) == 0 ? 1 : 0   // high bit clear = touching
    let f0Id: UInt8 = f0Header & 0x7F
    let f0X = Int(p[off + 1]) | ((Int(p[off + 2]) & 0x0F) << 8)
    let f0Y = (Int(p[off + 2]) >> 4) | (Int(p[off + 3]) << 4)

    let f1Header = p[off + 4]
    let f1Active: UInt8 = (f1Header & 0x80) == 0 ? 1 : 0
    let f1Id: UInt8 = f1Header & 0x7F
    let f1X = Int(p[off + 5]) | ((Int(p[off + 6]) & 0x0F) << 8)
    let f1Y = (Int(p[off + 6]) >> 4) | (Int(p[off + 7]) << 4)

    return (tpBtn, f0Active, f0Id, f0X, f0Y, f1Active, f1Id, f1X, f1Y)
}

let inputCallback: IOHIDReportCallback = { context, _, _, reportType, reportID, report, reportLength in
    guard let context = context else { return }
    let ctx = Unmanaged<DeviceCtx>.fromOpaque(context).takeUnretainedValue()
    guard reportType == kIOHIDReportTypeInput else { return }

    ctx.seq &+= 1

    // Pick offsets based on (PID, transport, report ID). All offsets are
    // relative to the start of the IOHID input buffer (no report-ID prefix).
    var blockOffset = 0
    var buttonByte = 0
    let buttonMask: UInt8 = 0x02     // touchpad-click bit for DS5; same bit for DS4 in correct byte

    if dualSensePIDs.contains(ctx.pid) {
        // The IOHID buffer includes the report ID at [0]. The Sony payload
        // (x,y,rx,ry,z,rz, seq, buttons[4], ...) follows the prefix:
        //   USB 0x01: 1-byte prefix (ID)            -> buttons[2] = 10, touch = 33
        //   BT  0x31: 2-byte prefix (ID + seq tag)  -> buttons[2] = 11, touch = 34
        // Both verified live: PS flips [10] bit 0 on USB; an Edge FN press
        // flips [11] bit 4 on BT while the d-pad hat idles as 0x08 at [9].
        // (The previous USB buttonByte of 9 was buttons[1] - the shoulder
        // byte - so the emitted touchpad-click flag was actually R1; and the
        // previous BT touch offset of 35 produced X readings past the
        // touchpad's 1919 maximum.)
        if !ctx.isBT {
            guard reportID == 0x01, reportLength >= 41 else { return }
            blockOffset = 33
            buttonByte = 10
        } else {
            guard reportID == 0x31, reportLength >= 43 else { return }
            blockOffset = 34
            buttonByte = 11
        }
        // Emit the extras byte on change. buttons[2]: PS bit 0, touchpad
        // click bit 1, mute bit 2; DualSense Edge FN-L/FN-R/paddle-L/
        // paddle-R at bits 4/5/6/7.
        if reportLength > buttonByte {
            let b2 = report[buttonByte]
            if !ctx.emittedInitialButtons || b2 != ctx.lastButtons2 {
                ctx.emittedInitialButtons = true
                ctx.lastButtons2 = b2
                emit("B \(b2) \(ctx.kind)")
            }
        }
        if buttonsOnly { return }
    } else if ds4PIDs.contains(ctx.pid) {
        if !ctx.isBT {
            // DualShock 4 USB, report 0x01: per Linux hid-sony.c,
            // DS4_INPUT_REPORT_USABLE_TOUCHPAD_DATA_OFFSET = 33.
            guard reportID == 0x01, reportLength >= 41 else { return }
            blockOffset = 33
            buttonByte = 7
        } else {
            // DS4 BT, report 0x11: 2-byte BT header shifts everything by 2.
            guard reportID == 0x11, reportLength >= 43 else { return }
            blockOffset = 35
            buttonByte = 9
        }
    } else {
        return
    }

    guard let parsed = parseTouchpadBlock(report, len: reportLength,
                                          blockOffset: blockOffset,
                                          buttonByte: buttonByte,
                                          buttonMask: buttonMask) else { return }

    var (tpBtn, f0Active, f0Id, f0X, f0Y, f1Active, f1Id, f1X, f1Y) = parsed

    // Sanity check: DualSense touchpad maxes are X=1919, Y=1079; DS4 has
    // slightly smaller Y. Anything well outside that range means we parsed
    // garbage; drop the finger so a bogus position doesn't pollute calibration.
    let maxX = 1919, maxY = 1079
    if f0Active != 0, !(f0X >= 0 && f0X <= maxX && f0Y >= 0 && f0Y <= maxY) {
        f0Active = 0
    }
    if f1Active != 0, !(f1X >= 0 && f1X <= maxX && f1Y >= 0 && f1Y <= maxY) {
        f1Active = 0
    }

    emit("T \(ctx.seq) \(tpBtn) \(f0Active) \(f0Id) \(f0X) \(f0Y) \(f1Active) \(f1Id) \(f1X) \(f1Y) \(ctx.kind)")
}

// MARK: - Device matching / open

var managedContexts: [DeviceCtx] = []   // retain so callback ptrs stay valid

func openSonyController(_ device: IOHIDDevice) {
    guard let vid = (IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString) as? Int32),
          vid == sonyVID,
          let pid = (IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int32) else {
        return
    }
    let kind: String
    if dualSensePIDs.contains(pid) { kind = "dualsense" }
    else if ds4PIDs.contains(pid) { kind = "dualshock4" }
    else { return }

    // Open without seize so gamecontrolleragentd can keep using buttons/axes.
    guard IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
        log("[TouchpadHelper] could not open device pid=\(String(format: "%04x", pid))")
        return
    }

    let isBT: Bool
    if let t = IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString) as? String {
        isBT = t.lowercased().contains("bluetooth")
    } else {
        isBT = false
    }

    let ctx = DeviceCtx(device: device, pid: pid, isBT: isBT, kind: kind)
    managedContexts.append(ctx)

    // Allocate a small input-report buffer. 78 bytes covers the largest layout.
    let bufSize = 96
    let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)

    let ptr = Unmanaged.passUnretained(ctx).toOpaque()
    IOHIDDeviceRegisterInputReportCallback(device, buf, bufSize, inputCallback, ptr)
    IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)

    if dualSensePIDs.contains(pid) && isBT {
        // Send the feature get-report on report ID 0x05 to enable extended
        // (touchpad-containing) 0x31 input reports over Bluetooth.
        var fbuf = [UInt8](repeating: 0, count: 41)
        var len: CFIndex = CFIndex(fbuf.count)
        _ = IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, 0x05, &fbuf, &len)
        ctx.didEnableBTReports = true
    }

    // Log device usage so we can confirm we're on the gamepad interface
    // and not a secondary HID interface that just happens to be the same VID.
    var usagePage: Int = -1
    var usage: Int = -1
    if let n = IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsagePageKey as CFString) as? Int { usagePage = n }
    if let n = IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsageKey as CFString) as? Int { usage = n }
    log("[TouchpadHelper] opened \(kind) pid=\(String(format: "%04x", pid)) transport=\(isBT ? "BT" : "USB") usage=\(usagePage)/\(usage)")
}

let matchingCallback: IOHIDDeviceCallback = { _, _, _, device in
    openSonyController(device)
}

let removalCallback: IOHIDDeviceCallback = { _, _, _, device in
    managedContexts.removeAll { $0.device == device }
    log("[TouchpadHelper] device disconnected")
}

// MARK: - Manager setup

let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
// Match only the actual gamepad interface, NOT the Edge's secondary
// function/settings interfaces (which share the same VID/PID but have a
// completely different report layout). Without this filter, the helper was
// opening every Sony HID interface and parsing nonsense bytes from the
// non-gamepad one as if they were touchpad coordinates.
let matching: [[CFString: Any]] = [
    [
        kIOHIDVendorIDKey as CFString: sonyVID,
        kIOHIDDeviceUsagePageKey as CFString: kHIDPage_GenericDesktop,
        kIOHIDDeviceUsageKey as CFString: kHIDUsage_GD_GamePad,
    ],
    [
        // Some DS4 variants enumerate as Joystick instead of GamePad.
        kIOHIDVendorIDKey as CFString: sonyVID,
        kIOHIDDeviceUsagePageKey as CFString: kHIDPage_GenericDesktop,
        kIOHIDDeviceUsageKey as CFString: kHIDUsage_GD_Joystick,
    ],
]
IOHIDManagerSetDeviceMatchingMultiple(manager, matching as CFArray)
IOHIDManagerRegisterDeviceMatchingCallback(manager, matchingCallback, nil)
IOHIDManagerRegisterDeviceRemovalCallback(manager, removalCallback, nil)
IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)

guard IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
    log("[TouchpadHelper] IOHIDManagerOpen failed")
    exit(2)
}

// MARK: - Lifecycle

// Exit cleanly when parent closes our stdin (the typical way subprocesses get
// notified of parent death on macOS when not using SIGTERM handling).
let stdinSource = DispatchSource.makeReadSource(fileDescriptor: 0, queue: .global())
stdinSource.setEventHandler {
    var buf = [UInt8](repeating: 0, count: 64)
    let n = read(0, &buf, buf.count)
    if n <= 0 { exit(0) }
}
stdinSource.resume()

signal(SIGTERM) { _ in exit(0) }
signal(SIGINT)  { _ in exit(0) }

emit("R ready")
CFRunLoopRun()
