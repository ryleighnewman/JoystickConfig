import Foundation

/// Stateless decoder that turns a raw HID input report into a
/// `ControllerState` according to a profile's `ReportLayout`.
///
/// The mapping from button index to logical control follows the same
/// numbering InputConfig uses elsewhere:
///   0 = A,  1 = B,  2 = X,  3 = Y
///   4 = LB, 5 = RB, 6 = LT, 7 = RT
///   8 = Back/Select, 9 = Start, 10 = Home/Guide
///   11 = L3 (left stick click), 12 = R3 (right stick click)
///   13 = D-Pad Up, 14 = D-Pad Down, 15 = D-Pad Left, 16 = D-Pad Right
///
/// Axes:
///   0 = LX, 1 = LY (inverted: up is negative in HID, positive in our model)
///   2 = RX, 3 = RY (inverted)
///   4 = LT analog, 5 = RT analog
enum HIDReportDecoder {

    static func decode(report: Data, profile: ControllerProfile) -> ControllerState {
        var state = ControllerState()
        switch profile.layout {
        case .xinput:
            decodeXInput(report: report, into: &state)
        case .dualShock3:
            decodeDualShock3(report: report, into: &state)
        case .generic(let layout):
            decodeGeneric(report: report, layout: layout, into: &state)
        }
        return state
    }

    // MARK: - XInput layout

    /// Standard 20-byte Xbox 360 / XInput-over-HID report. The first
    /// byte is usually a report ID (0x00) or "message type" header;
    /// the next byte is sometimes the packet length (0x14). We support
    /// both forms by sniffing the layout at run time.
    ///
    /// Canonical Xbox 360 wired controller layout (post-header):
    ///   byte 0-1: 16-bit button bitfield (little endian)
    ///   byte 2:   left trigger (0-255)
    ///   byte 3:   right trigger (0-255)
    ///   byte 4-5: LX signed 16-bit LE
    ///   byte 6-7: LY signed 16-bit LE (positive = up)
    ///   byte 8-9: RX
    ///   byte 10-11: RY
    static func decodeXInput(report: Data, into state: inout ControllerState) {
        // Determine where the payload starts. Xbox 360 wired controllers
        // prefix reports with a 2-byte header (message type 0x00 +
        // length 0x14). 8BitDo "XInput mode" controllers usually skip
        // the header and start directly with the button bitfield.
        // Detect by sniffing for the header bytes rather than guessing
        // by length - some firmware emits 15-19 byte compact reports
        // that the old length-only check routed wrong.
        let allBytes = Array(report)
        guard allBytes.count >= 14 else { return }
        let hasHeader = allBytes.count >= 20
            && allBytes[0] == 0x00
            && allBytes[1] == 0x14
        let bytes = hasHeader ? Array(allBytes.dropFirst(2)) : allBytes
        guard bytes.count >= 12 else { return }

        // Buttons (16-bit bitfield, little endian)
        let buttons = UInt16(bytes[0]) | (UInt16(bytes[1]) << 8)

        // D-pad bits go into the hat (matches MFi convention - the
        // visualizer's DPadWidget reads state.hats[0] and bindings to
        // .hat events fire from here too).
        //
        // Simultaneous opposite presses (e.g. flaky d-pad reporting
        // Up+Down) used to produce y=0 which is indistinguishable from
        // "neutral". Detect that and report a small sentinel deflection
        // so the user can SEE the contradiction in the visualizer.
        let dpadUp = bit(buttons, 0)
        let dpadDown = bit(buttons, 1)
        let dpadLeft = bit(buttons, 2)
        let dpadRight = bit(buttons, 3)
        let hatX: Float = (dpadLeft > 0.5 && dpadRight > 0.5) ? 0 : (dpadRight - dpadLeft)
        // Up-positive, matching the GC-framework / Steam / engine convention
        // (this was inverted, so d-pad Up on XInput pads read as Down).
        let hatY: Float = (dpadUp > 0.5 && dpadDown > 0.5) ? 0 : (dpadUp - dpadDown)
        state.hats[0] = (x: hatX, y: hatY)

        // XInput button bit positions (canonical Xbox 360 mapping)
        state.buttons[9]  = bit(buttons, 4)   // Start
        state.buttons[8]  = bit(buttons, 5)   // Back
        state.buttons[11] = bit(buttons, 6)   // L3
        state.buttons[12] = bit(buttons, 7)   // R3
        state.buttons[4]  = bit(buttons, 8)   // LB
        state.buttons[5]  = bit(buttons, 9)   // RB
        state.buttons[10] = bit(buttons, 10)  // Guide / Home
        state.buttons[0]  = bit(buttons, 12)  // A
        state.buttons[1]  = bit(buttons, 13)  // B
        state.buttons[2]  = bit(buttons, 14)  // X
        state.buttons[3]  = bit(buttons, 15)  // Y

        // Triggers (analogue 0-255). Also report as digital "button
        // pressed" when > 30/255 so digital trigger bindings still
        // fire on controllers without dedicated trigger buttons.
        let lt = Float(bytes[2]) / 255.0
        let rt = Float(bytes[3]) / 255.0
        state.axes[4] = lt
        state.axes[5] = rt
        state.buttons[6] = lt > 0.12 ? 1.0 : 0.0
        state.buttons[7] = rt > 0.12 ? 1.0 : 0.0

        // Sticks. XInput's Y is positive = up. InputConfig uses
        // positive = down (matches GameController framework), so flip Y.
        state.axes[0] = signedInt16(bytes[4], bytes[5])
        state.axes[1] = -signedInt16(bytes[6], bytes[7])
        state.axes[2] = signedInt16(bytes[8], bytes[9])
        state.axes[3] = -signedInt16(bytes[10], bytes[11])
    }

    // MARK: - DualShock 3 layout

    /// Sony DualShock 3 HID input report (USB). 49 bytes after the
    /// report ID. Buttons live in bytes 2-3, hat in byte 2 lower nibble,
    /// pressure-sensitive buttons in bytes 14-25, sticks in bytes 6-9.
    static func decodeDualShock3(report: Data, into state: inout ControllerState) {
        let bytes = Array(report)
        guard bytes.count >= 26 else { return }

        // The canonical DS3 offsets (buttons in bytes 2-3, PS at 4,
        // sticks 6-9, trigger pressures 18-19) already count the leading
        // 0x01 report ID as byte 0, and IOKit includes that ID byte in
        // the delivered buffer. base = 0 when the ID is present; if a
        // transport strips it, every offset shifts down one. The old
        // base = 1 double-counted the ID and read every control from
        // the wrong byte.
        let base = bytes[0] == 0x01 ? 0 : -1
        guard bytes.count >= base + 26 else { return }

        let b2 = bytes[base + 2]
        let b3 = bytes[base + 3]

        // Byte 2 bits: Select(0), L3(1), R3(2), Start(3), D-Pad U(4), D-Pad R(5), D-Pad D(6), D-Pad L(7)
        state.buttons[8]  = bit(UInt16(b2), 0)  // Select
        state.buttons[11] = bit(UInt16(b2), 1)  // L3
        state.buttons[12] = bit(UInt16(b2), 2)  // R3
        state.buttons[9]  = bit(UInt16(b2), 3)  // Start
        // D-pad to hat[0] (matches MFi convention)
        let ds3Up = bit(UInt16(b2), 4)
        let ds3Right = bit(UInt16(b2), 5)
        let ds3Down = bit(UInt16(b2), 6)
        let ds3Left = bit(UInt16(b2), 7)
        state.hats[0] = (
            x: ds3Right - ds3Left,
            // Up-positive (was inverted; see XInput note above).
            y: ds3Up - ds3Down
        )

        // Byte 3 bits: L2(0), R2(1), L1(2), R1(3), Triangle(4), Circle(5), Cross(6), Square(7)
        state.buttons[6]  = bit(UInt16(b3), 0)  // L2 (digital)
        state.buttons[7]  = bit(UInt16(b3), 1)  // R2 (digital)
        state.buttons[4]  = bit(UInt16(b3), 2)  // L1
        state.buttons[5]  = bit(UInt16(b3), 3)  // R1
        state.buttons[3]  = bit(UInt16(b3), 4)  // Triangle
        state.buttons[1]  = bit(UInt16(b3), 5)  // Circle
        state.buttons[0]  = bit(UInt16(b3), 6)  // Cross
        state.buttons[2]  = bit(UInt16(b3), 7)  // Square

        // PS button at byte 4 bit 0
        let b4 = bytes[base + 4]
        state.buttons[10] = bit(UInt16(b4), 0)

        // Sticks: bytes 6-9, unsigned 8-bit centred at 0x80
        state.axes[0] = unsignedToSigned(bytes[base + 6])
        state.axes[1] = unsignedToSigned(bytes[base + 7])
        state.axes[2] = unsignedToSigned(bytes[base + 8])
        state.axes[3] = unsignedToSigned(bytes[base + 9])

        // Analogue trigger pressures (DS3 pressure-sensitive buttons)
        let l2Analog = Float(bytes[base + 18]) / 255.0
        let r2Analog = Float(bytes[base + 19]) / 255.0
        state.axes[4] = l2Analog
        state.axes[5] = r2Analog
    }

    // MARK: - Generic layout

    static func decodeGeneric(report: Data,
                              layout: ControllerProfile.GenericLayout,
                              into state: inout ControllerState) {
        let bytes = Array(report)
        var offset = 0
        if layout.hasReportID {
            guard !bytes.isEmpty else { return }
            // Decode only the input report this layout was built from.
            // Multi-report devices interleave battery / sensor / vendor
            // reports on other IDs; decoding those with the gamepad
            // layout produced phantom input.
            if let expected = layout.reportID, Int(bytes[0]) != expected { return }
            offset = 1
        }
        guard bytes.count >= offset + layout.reportSize else { return }

        // Zero-copy: index into `bytes` at `offset` instead of allocating a
        // fresh sub-array on every report. p(i) is exactly the old p(i)
        // (payload was bytes[offset...] copied) and payloadCount == payloadCount.
        let payloadCount = bytes.count - offset
        @inline(__always) func p(_ i: Int) -> UInt8 { bytes[offset + i] }

        // Buttons
        for (logicalIndex, bitPos) in layout.buttonBitOffsets.enumerated() {
            let byteIndex = bitPos / 8
            let bitInByte = bitPos % 8
            guard byteIndex < payloadCount else { continue }
            let pressed = (p(byteIndex) >> bitInByte) & 0x01
            state.buttons[logicalIndex] = pressed == 1 ? 1.0 : 0.0
        }

        // Axes. Per-axis width + signedness, so a controller that
        // mixes 8-bit and 16-bit axes (or signed sticks with unsigned
        // sliders) decodes each one correctly. Earlier versions used
        // a single width/signed for ALL axes - the last axis's
        // metadata won and scrambled the others.
        for (logicalIndex, byteOffset) in layout.axisByteOffsets.enumerated() {
            let width = logicalIndex < layout.axisByteWidths.count
                ? layout.axisByteWidths[logicalIndex] : 1
            let isSigned = logicalIndex < layout.axisIsSignedFlags.count
                ? layout.axisIsSignedFlags[logicalIndex] : false
            guard byteOffset + width <= payloadCount else { continue }
            let value: Float
            if width == 2 {
                if isSigned {
                    value = signedInt16(p(byteOffset), p(byteOffset + 1))
                } else {
                    let raw = UInt16(p(byteOffset)) | (UInt16(p(byteOffset + 1)) << 8)
                    value = max(-1.0, min(1.0, (Float(raw) - 32768.0) / 32767.0))
                }
            } else {
                if isSigned {
                    let raw = Int8(bitPattern: p(byteOffset))
                    value = max(-1.0, min(1.0, Float(raw) / 127.0))
                } else {
                    value = unsignedToSigned(p(byteOffset))
                }
            }
            // Y axes read inverted vs our up-positive convention, so flip them.
            // Prefer the axis's declared HID usage (0x31 Y, 0x34 Ry) when the
            // parser preserved it: a report that isn't ordered X,Y,Rx,Ry (e.g.
            // a racing wheel laying out X, Z-throttle, Rz-brake) would otherwise
            // negate whatever sits at position 1/3 and mangle non-Y axes. When
            // usage is unknown, fall back to the positional heuristic, which is
            // correct for conventional stick pads whose Y axes sit at 1 and 3.
            let flip: Bool
            if logicalIndex < layout.axisUsages.count {
                let usage = layout.axisUsages[logicalIndex]
                flip = (usage == 0x31 || usage == 0x34)
            } else {
                flip = (logicalIndex == 1 || logicalIndex == 3)
            }
            state.axes[logicalIndex] = flip ? -value : value
        }

        // Triggers
        for (i, byteOffset) in layout.triggerByteOffsets.enumerated() {
            guard byteOffset < payloadCount else { continue }
            let value = Float(p(byteOffset)) / 255.0
            state.axes[4 + i] = value
            state.buttons[6 + i] = value > 0.12 ? 1.0 : 0.0
        }

        // Hat switch (4-bit direction). Use the exact bit offset when the
        // parser recorded one (hats often sit in the high nibble after 12
        // buttons), and honor the declared logical minimum: pads that use
        // 1..8 with 0 as null would otherwise read rotated 45 degrees with
        // the resting value decoding as a held North.
        let hatBitOffset = layout.hatBitOffset ?? layout.hatByteOffset.map { $0 * 8 }
        if let hatBit = hatBitOffset {
            let hatByte = hatBit / 8
            if hatByte < payloadCount {
                // Read a 16-bit window so a 4-bit hat that straddles a byte
                // boundary keeps its high bits (a single-byte shift would drop
                // them and read a phantom held direction at rest).
                let lo = UInt16(p(hatByte))
                let hi = hatByte + 1 < payloadCount ? UInt16(p(hatByte + 1)) : 0
                let raw = Int(((lo | (hi << 8)) >> (hatBit % 8)) & 0x0F)
                let direction = raw - layout.hatLogicalMin
                // Standard 8-direction encoding after normalization
                // (0=N, 1=NE, ..., 7=NW; anything else = center).
                // Up-positive convention (N = +1), matching GC framework,
                // Steam, and the engine's hat matching. Was inverted.
                switch direction {
                case 0: setHat(&state, x: 0, y: 1)               // N
                case 1: setHat(&state, x: 0.707, y: 0.707)       // NE
                case 2: setHat(&state, x: 1, y: 0)               // E
                case 3: setHat(&state, x: 0.707, y: -0.707)      // SE
                case 4: setHat(&state, x: 0, y: -1)              // S
                case 5: setHat(&state, x: -0.707, y: -0.707)     // SW
                case 6: setHat(&state, x: -1, y: 0)              // W
                case 7: setHat(&state, x: -0.707, y: 0.707)      // NW
                default: setHat(&state, x: 0, y: 0)
                }
            }
        }
    }

    // MARK: - Helpers

    @inline(__always)
    private static func bit(_ value: UInt16, _ pos: Int) -> Float {
        return ((value >> pos) & 0x01) == 1 ? 1.0 : 0.0
    }

    @inline(__always)
    private static func signedInt16(_ low: UInt8, _ high: UInt8) -> Float {
        let raw = Int16(bitPattern: UInt16(low) | (UInt16(high) << 8))
        // Map -32768...32767 to -1.0...1.0, with a small deadzone clamp.
        return max(-1.0, min(1.0, Float(raw) / 32767.0))
    }

    @inline(__always)
    private static func unsignedToSigned(_ value: UInt8) -> Float {
        // 0...255 with 128 = centre → -1.0 ... 1.0.
        // Divide by 127 (not 128) so the maximum positive raw value
        // (255) maps to exactly +1.0; with 128 it would max at
        // +0.992 and the visualizer's "at limit" detection never
        // fires. Negative max (0) maps to -1.008, which we clamp.
        return max(-1.0, min(1.0, (Float(value) - 128.0) / 127.0))
    }

    @inline(__always)
    private static func setHat(_ state: inout ControllerState, x: Float, y: Float) {
        state.hats[0] = (x: x, y: y)
    }
}
