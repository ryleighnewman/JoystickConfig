/// LightHelper: standalone CLI tool for setting DualSense/DS4 light bar colors.
/// Runs as a separate process so GameController framework doesn't interfere.
/// Usage: LightHelper <red> <green> <blue> [brightness]
///   RGB: 0-255. Brightness: 0=off, 1=dim, 2=bright (default: 2).

import Foundation
import IOKit
import IOKit.hid

// MARK: - Parse arguments

guard CommandLine.arguments.count >= 4,
      let r = UInt8(CommandLine.arguments[1]),
      let g = UInt8(CommandLine.arguments[2]),
      let b = UInt8(CommandLine.arguments[3]) else {
    fputs("Usage: LightHelper <r> <g> <b> [brightness 0-2]\n", stderr)
    exit(1)
}

let brightness: UInt8 = CommandLine.arguments.count > 4 ? UInt8(CommandLine.arguments[4]) ?? 2 : 2

// The "shared" 6th arg (always passed by the app now) writes the LED report
// non-exclusively, alongside the live gamecontrollerd: last write wins. An
// earlier path killed gamecontrolleragentd and seized the device; that
// daemon-kill has been removed because the in-process writer plus shared mode
// cover every live use, and spawning killall on a system daemon from a
// sandboxed bundle is not acceptable for the App Store. The open below stays
// non-exclusive in shared mode.
let shared = CommandLine.arguments.count > 5 && CommandLine.arguments[5] == "shared"

let sonyVID: Int32 = 0x054C
let dualSensePIDs: Set<Int32> = [0x0CE6, 0x0DF2]
let ds4PIDs: Set<Int32> = [0x05C4, 0x09CC]

// MARK: - Find and write to the controller

let matching = IOServiceMatching(kIOHIDDeviceKey) as NSMutableDictionary
matching[kIOHIDVendorIDKey as String] = sonyVID

var iterator: io_iterator_t = 0
guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { exit(2) }
defer { IOObjectRelease(iterator) }

var sequenceTag: UInt8 = 0
var found = false
var entry = IOIteratorNext(iterator)
while entry != 0 {
    defer { IOObjectRelease(entry); entry = IOIteratorNext(iterator) }

    guard let pidRef = IORegistryEntryCreateCFProperty(entry, kIOHIDProductIDKey as CFString, kCFAllocatorDefault, 0) else { continue }
    guard let devPID = (pidRef.takeUnretainedValue() as? NSNumber)?.int32Value else { continue }
    guard dualSensePIDs.contains(devPID) || ds4PIDs.contains(devPID) else { continue }

    guard let dev = IOHIDDeviceCreate(kCFAllocatorDefault, entry) else { continue }
    // Shared mode opens non-exclusively so we coexist with the live
    // daemon; default mode seizes the freshly-released device.
    let openOptions = shared ? IOOptionBits(kIOHIDOptionsTypeNone)
                             : IOOptionBits(kIOHIDOptionsTypeSeizeDevice)
    guard IOHIDDeviceOpen(dev, openOptions) == kIOReturnSuccess else { continue }

    var isBT = false
    if let tRef = IORegistryEntryCreateCFProperty(entry, kIOHIDTransportKey as CFString, kCFAllocatorDefault, 0) {
        isBT = ((tRef.takeUnretainedValue() as? String) ?? "").lowercased().contains("bluetooth")
    }

    let isDS = dualSensePIDs.contains(devPID)
    let isDS4 = ds4PIDs.contains(devPID)

    if isDS && !isBT {
        // DualSense USB: report ID 0x02, 48 bytes total (report ID in buffer per HIDAPI)
        var data = [UInt8](repeating: 0, count: 48)
        data[0]  = 0x02  // report ID
        data[1]  = 0x00  // ucEnableBits1
        data[2]  = 0x04  // ucEnableBits2: LED enable
        data[39] = 0x06  // ucEnableBits3: LED setup + brightness enable
        data[42] = 0x02  // ucLedAnim: enable
        data[43] = brightness  // ucLedBrightness: 0=off, 1=dim, 2=bright
        data[45] = r; data[46] = g; data[47] = b
        IOHIDDeviceSetReport(dev, kIOHIDReportTypeOutput, 0x02, data, data.count)
    } else if isDS && isBT {
        // DualSense BT: 78-byte report - [0]=0x31, [1]=seq<<4, [2]=0x10 tag,
        // USB payload at [3], CRC over [0..73] at [74..77]. Verified live.
        var data = [UInt8](repeating: 0, count: 78)
        data[0]  = 0x31
        sequenceTag = (sequenceTag &+ 1) & 0x0F
        data[1]  = sequenceTag << 4
        data[2]  = 0x10
        data[4]  = 0x04
        data[41] = 0x02; data[44] = 0x02
        data[45] = brightness
        data[47] = r; data[48] = g; data[49] = b
        let crcIn: [UInt8] = [0xA2] + Array(data[0..<74])
        let crc = crc32(crcIn)
        data[74] = UInt8(crc & 0xFF); data[75] = UInt8((crc >> 8) & 0xFF)
        data[76] = UInt8((crc >> 16) & 0xFF); data[77] = UInt8((crc >> 24) & 0xFF)
        IOHIDDeviceSetReport(dev, kIOHIDReportTypeOutput, 0x31, data, data.count)
    } else if isDS4 && !isBT {
        // DS4 USB: report ID 0x05, 32 bytes
        var data = [UInt8](repeating: 0, count: 32)
        data[0] = 0x05; data[1] = 0x07
        data[6] = r; data[7] = g; data[8] = b
        IOHIDDeviceSetReport(dev, kIOHIDReportTypeOutput, 0x05, data, data.count)
    } else if isDS4 && isBT {
        // DS4 BT: 78-byte report per DS4Windows / hid-sony; RGB at [8..10],
        // CRC over [0..73] at [74..77].
        var data = [UInt8](repeating: 0, count: 78)
        data[0] = 0x11; data[1] = 0xC0; data[2] = 0xA0; data[3] = 0xF7; data[4] = 0x04
        data[8] = r; data[9] = g; data[10] = b
        let crcIn: [UInt8] = [0xA2] + Array(data[0..<74])
        let crc = crc32(crcIn)
        data[74] = UInt8(crc & 0xFF); data[75] = UInt8((crc >> 8) & 0xFF)
        data[76] = UInt8((crc >> 16) & 0xFF); data[77] = UInt8((crc >> 24) & 0xFF)
        IOHIDDeviceSetReport(dev, kIOHIDReportTypeOutput, 0x11, data, data.count)
    }

    IOHIDDeviceClose(dev, 0)
    found = true
}

exit(found ? 0 : 3)

// MARK: - CRC32

func crc32(_ data: [UInt8]) -> UInt32 {
    var crc: UInt32 = 0xFFFFFFFF
    for byte in data {
        crc ^= UInt32(byte)
        for _ in 0..<8 { crc = (crc & 1 != 0) ? (crc >> 1) ^ 0xEDB88320 : crc >> 1 }
    }
    return crc ^ 0xFFFFFFFF
}
