import Foundation

/// Static description of how to decode a HID report for a specific
/// (vendor, product) pair. Lets `RawHIDGamepadService` pull buttons,
/// axes, triggers, and hat directions out of the raw byte stream
/// without needing to parse the device's HID descriptor at runtime.
///
/// Profiles are matched in order: vendor + product, then vendor + PID
/// range, then `ReportLayout.generic` falls back to descriptor parsing
/// at runtime (see `HIDDescriptorParser`).
struct ControllerProfile: Equatable {

    let identifier: String
    let displayName: String
    let vendorID: Int32
    let productMatches: [ProductMatch]
    let layout: ReportLayout
    let physicalButtonNames: [String]

    /// When set, the profile only matches devices whose IOKit transport
    /// string contains this value (case-insensitive), e.g. "USB". Used to
    /// keep wired-only layouts (8BitDo XInput) from claiming the same
    /// VID/PID block when it shows up over Bluetooth with a different,
    /// shorter report format that the wired decoder would silently drop.
    var requiredTransport: String? = nil

    /// How to match a device's product ID against this profile.
    enum ProductMatch: Equatable {
        case exact(Int32)
        case range(ClosedRange<Int32>)

        func matches(_ pid: Int32) -> Bool {
            switch self {
            case .exact(let value): return pid == value
            case .range(let r): return r.contains(pid)
            }
        }
    }

    /// Pre-baked decoder layouts. Each case knows the byte offsets and
    /// bit positions for its specific report format.
    enum ReportLayout: Equatable {
        /// Standard Xbox 360 / XInput 20-byte report. Covers 8BitDo
        /// Ultimate 2C (XInput mode), generic Xbox 360 wired pads,
        /// Logitech F310/F710 in XInput mode, and most "PC Game
        /// Controller" wired pads that ship with XInput as default.
        case xinput

        /// Sony DualShock 3 HID layout (49-byte report). Buttons in
        /// bytes 2-4, sticks in 6-9, pressure-sensitive buttons in
        /// 14-25. Connected via USB only (Bluetooth requires pairing
        /// tools outside the app's scope).
        case dualShock3

        /// Layout synthesized at runtime by walking the HID descriptor.
        /// Used for unknown (vendor, product) pairs so the controller
        /// still works without a hand-coded entry.
        case generic(GenericLayout)
    }

    /// Output of `HIDDescriptorParser`. Encodes where buttons and axes
    /// live in the report for an arbitrary HID gamepad.
    struct GenericLayout: Equatable {
        var buttonBitOffsets: [Int]      // Bit index of each button, relative to the payload (after any report ID byte)
        var axisByteOffsets: [Int]       // Byte offset of each axis, payload-relative
        var axisByteWidths: [Int]        // Per-axis: 1 (8-bit) or 2 (16-bit); parallel to axisByteOffsets
        var axisIsSignedFlags: [Bool]    // Per-axis: signed-centred-at-0 vs unsigned-centred-at-midpoint
        var axisUsages: [Int] = []       // Per-axis HID usage (0x30 X, 0x31 Y, 0x32 Z, 0x33 Rx, 0x34 Ry, 0x35 Rz); parallel to axisByteOffsets. Empty = unknown, decoder falls back to positional Y-flip.
        var hatByteOffset: Int?          // Byte that holds the 4-bit hat direction (kept for display/tests; hatBitOffset is authoritative)
        var triggerByteOffsets: [Int]    // Byte offsets of analogue triggers (0-255), payload-relative
        var reportSize: Int              // Expected payload bytes (excluding the leading report ID byte if present)
        var hasReportID: Bool            // True if first byte of each report is a report ID we should skip
        var hatBitOffset: Int? = nil     // Absolute payload-relative bit offset of the 4-bit hat (handles high-nibble hats)
        var hatLogicalMin: Int = 0       // Hat's declared logical minimum (0 or 1); values map north = logicalMin
        var reportID: Int? = nil         // Which input report ID this layout decodes, for multi-report devices
    }
}

extension ControllerProfile {

    /// Returns true if this profile claims the given (vid, pid).
    func matches(vendorID vid: Int32, productID pid: Int32) -> Bool {
        guard vid == vendorID else { return false }
        return productMatches.contains { $0.matches(pid) }
    }
}
