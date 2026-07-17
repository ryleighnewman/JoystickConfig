import Foundation

/// Parses a HID report descriptor at runtime and synthesizes a
/// `ControllerProfile.GenericLayout` describing where each button,
/// axis, hat, and trigger lives in the input report. Lets
/// `RawHIDGamepadService` support gamepads we have never seen
/// without a hand-coded entry in `ControllerProfileDatabase`.
///
/// The HID 1.11 spec (section 6.2.2) defines a descriptor as a
/// sequence of "items". Each short item is one prefix byte followed
/// by 0/1/2/4 bytes of data. The prefix encodes the item's type
/// (Main / Global / Local), tag (e.g. INPUT, USAGE_PAGE), and data
/// size. We walk the byte stream maintaining a small parser state
/// (current usage page, logical min/max, report size, report count,
/// pending usages list). When an INPUT item fires we record one or
/// more fields with their bit offset, size, and usage, then advance
/// a global bit cursor by `report_size * report_count`.
///
/// What we recognize:
///   - Button usage page (0x09) - one bit per button
///   - Generic Desktop axes (X/Y/Z/Rx/Ry/Rz) - 8 or 16 bit signed/unsigned
///   - Generic Desktop Hat switch (0x39) - 4 bit direction
///   - Generic Desktop Slider (0x36) - treated as trigger
///   - Constant fields - skipped (just advances the bit cursor)
///
/// What we skip on purpose:
///   - Long items (rare, different format)
///   - Multi-report-ID devices - we record the first report only
///   - Vendor-specific usage pages (we can't map them generically)
enum HIDDescriptorParser {

    /// Returns nil when the descriptor doesn't yield a useful layout
    /// (no buttons or no axes), in which case the caller should fall
    /// back to logging the device as unidentified.
    ///
    /// Multi-report-ID devices are supported: fields and bit cursors are
    /// tracked per input report ID, and the layout is built from the
    /// input report with the richest control set (most modern licensed
    /// pads declare extra IDs for battery, sensors, LEDs, and rumble;
    /// bailing on those gutted the "unknown gamepads work" promise).
    /// All recorded offsets are PAYLOAD-relative: for devices with
    /// report IDs they count from the byte after the leading ID byte,
    /// matching how `decodeGeneric` strips it before indexing.
    static func parse(_ descriptor: Data) -> ControllerProfile.GenericLayout? {
        var state = ParseState()
        // Key nil = device without REPORT_ID items.
        var fieldsByReport: [Int?: [Field]] = [:]
        var cursorByReport: [Int?: Int] = [:]
        var currentReportID: Int? = nil

        let bytes = Array(descriptor)
        var i = 0
        while i < bytes.count {
            let prefix = bytes[i]
            i += 1

            // Long item prefix (1111 1110). Skip; format is different
            // and almost never used in gamepads. Clamp the advance to
            // bytes.count so a truncated descriptor with a malicious
            // longSize byte can't overshoot the buffer.
            if prefix == 0xFE {
                if i + 1 < bytes.count {
                    let longSize = Int(bytes[i])
                    i = min(bytes.count, i + 2 + longSize)
                } else {
                    break
                }
                continue
            }

            let dataSizeCode = prefix & 0x03
            let dataSize = dataSizeCode == 3 ? 4 : Int(dataSizeCode)
            let itemType = (prefix >> 2) & 0x03
            let itemTag = (prefix >> 4) & 0x0F

            // Read data payload (little endian)
            var rawData: UInt32 = 0
            if dataSize > 0 {
                guard i + dataSize <= bytes.count else { break }
                for b in 0..<dataSize {
                    rawData |= UInt32(bytes[i + b]) << (8 * b)
                }
                i += dataSize
            }

            // Some items (LOGICAL_MIN/MAX) carry signed values - sign
            // extend if the high bit is set. Guard `bits < 32` because
            // `UInt32.max << 32` is undefined behaviour - for a full
            // 4-byte value the rawData is already 32 bits wide and the
            // bitPattern conversion handles the sign correctly without
            // extension.
            let signedData: Int = {
                guard dataSize > 0 else { return Int(rawData) }
                let bits = dataSize * 8
                if bits >= 32 {
                    return Int(Int32(bitPattern: rawData))
                }
                let signBit = UInt32(1) << (bits - 1)
                if rawData & signBit != 0 {
                    let extended = rawData | (UInt32.max << bits)
                    return Int(Int32(bitPattern: extended))
                }
                return Int(rawData)
            }()

            switch itemType {

            case 0: // Main
                switch itemTag {
                case 0x8: // INPUT
                    let dataFlag = rawData
                    let isConstant = (dataFlag & 0x01) != 0
                    let isVariable = (dataFlag & 0x02) != 0
                    let bitsPerEntry = state.reportSize

                    // Skip malformed descriptors that emit INPUT before
                    // REPORT_SIZE/REPORT_COUNT - they would overlay the
                    // previous entry at the same bit offset and produce
                    // garbage layouts. Better to bail than mis-decode.
                    // Also cap absurd values so a hostile descriptor
                    // (reportSize=0xFFFFFFFF, reportCount=0xFFFFFFFF)
                    // can't trap on integer overflow in the multiply.
                    guard state.reportSize > 0 && state.reportCount > 0,
                          state.reportSize <= 256,
                          state.reportCount <= 1024 else {
                        state.clearLocals()
                        break
                    }
                    let (mulResult, mulOverflow) = bitsPerEntry.multipliedReportingOverflow(by: state.reportCount)
                    if mulOverflow {
                        state.clearLocals()
                        break
                    }
                    let totalBits = mulResult

                    if !isConstant && isVariable {
                        // Distribute usages across the report count.
                        // If we have explicit usages they map 1:1; if
                        // we have a usage range (min/max), each entry
                        // gets a usage from the range.
                        let base = cursorByReport[currentReportID, default: 0]
                        for n in 0..<state.reportCount {
                            let usage = state.usage(forIndex: n)
                            fieldsByReport[currentReportID, default: []].append(Field(
                                bitOffset: base + n * bitsPerEntry,
                                bitSize: bitsPerEntry,
                                usagePage: state.usagePage,
                                usage: usage,
                                logicalMin: state.logicalMin,
                                logicalMax: state.logicalMax
                            ))
                        }
                    }

                    cursorByReport[currentReportID, default: 0] += totalBits
                    state.clearLocals()

                case 0x9, 0xB: // OUTPUT / FEATURE
                    // Output and feature reports occupy their own bit
                    // spaces. Advancing the INPUT cursor here shifted
                    // every later input field on devices with rumble or
                    // LED output items and inflated reportSize, so the
                    // decoder's size guard rejected every real report.
                    // (The old advance also multiplied unguarded, which
                    // a hostile descriptor could overflow.)
                    state.clearLocals()

                case 0xA: // COLLECTION
                    state.clearLocals()

                case 0xC: // END COLLECTION
                    state.clearLocals()

                default: break
                }

            case 1: // Global
                switch itemTag {
                case 0x0: state.usagePage = Int(rawData)
                case 0x1: state.logicalMin = signedData
                case 0x2: state.logicalMax = signedData
                case 0x7: state.reportSize = Int(rawData)
                case 0x8:
                    // REPORT_ID - the first byte of every report is the
                    // ID. Switch the active per-report bookkeeping; each
                    // report ID gets its own payload-relative cursor.
                    let id = Int(rawData)
                    // Fields recorded before the first REPORT_ID item
                    // (malformed but seen in the wild) belong to that
                    // first report; migrate them. Their offsets are
                    // already payload-relative so no shift is needed.
                    if currentReportID == nil {
                        if let orphans = fieldsByReport[Int?.none], !orphans.isEmpty {
                            fieldsByReport[id, default: []].append(contentsOf: orphans)
                            fieldsByReport[Int?.none] = nil
                        }
                        if let orphanCursor = cursorByReport[Int?.none] {
                            cursorByReport[id, default: 0] += orphanCursor
                            cursorByReport[Int?.none] = nil
                        }
                    }
                    currentReportID = id
                case 0x9: state.reportCount = Int(rawData)
                default: break
                }

            case 2: // Local
                switch itemTag {
                case 0x0: state.usages.append(Int(rawData))
                case 0x1: state.usageMin = Int(rawData)
                case 0x2: state.usageMax = Int(rawData)
                default: break
                }

            default: break
            }
        }

        // Build a candidate layout per input report and keep the one
        // with the richest control set, so a pad whose descriptor also
        // declares battery / sensor / vendor input reports decodes the
        // gamepad report and ignores the rest.
        var best: ControllerProfile.GenericLayout? = nil
        var bestScore = -1
        for (key, flds) in fieldsByReport {
            guard let layout = buildLayout(from: flds,
                                           reportID: key,
                                           totalBits: cursorByReport[key] ?? 0) else { continue }
            let score = layout.buttonBitOffsets.count
                + layout.axisByteOffsets.count * 2
                + layout.triggerByteOffsets.count
                + (layout.hatByteOffset != nil ? 2 : 0)
            if score > bestScore {
                bestScore = score
                best = layout
            }
        }
        return best
    }

    // MARK: - Field aggregation

    private struct Field {
        let bitOffset: Int
        let bitSize: Int
        let usagePage: Int
        let usage: Int
        let logicalMin: Int
        let logicalMax: Int
    }

    private static func buildLayout(from fields: [Field],
                                    reportID: Int?,
                                    totalBits: Int) -> ControllerProfile.GenericLayout? {
        var buttons: [Int] = []
        // Triples kept together so per-axis width / signedness survive
        // the sort. Earlier versions stored single width/signed values
        // and the LAST axis won, which scrambled mixed 8/16-bit pads.
        var axesAggregated: [(byte: Int, width: Int, signed: Bool, usage: Int)] = []
        var triggers: [Int] = []
        var hatBit: Int? = nil
        var hatMin: Int = 0

        for field in fields {
            switch field.usagePage {
            case 0x09: // Button
                // Buttons are 1 bit each. The bitOffset is the offset
                // of the button in the report.
                if field.bitSize == 1 {
                    buttons.append(field.bitOffset)
                }
            case 0x01: // Generic Desktop
                switch field.usage {
                case 0x30, 0x31, 0x32, 0x33, 0x34, 0x35: // X, Y, Z, Rx, Ry, Rz
                    if field.bitOffset % 8 == 0 && field.bitSize % 8 == 0 {
                        // Trust logicalMin only when the declared range is
                        // sane. Cheap encoder boards (DragonRise and kin)
                        // ship inverted or degenerate min/max; treating
                        // those as signed produced garbage axes, so they
                        // degrade to unsigned-centred instead.
                        let saneRange = field.logicalMin < field.logicalMax
                        axesAggregated.append((
                            byte: field.bitOffset / 8,
                            width: field.bitSize / 8,
                            signed: saneRange && field.logicalMin < 0,
                            usage: field.usage
                        ))
                    }
                case 0x36, 0x37: // Slider, Dial - treat as trigger
                    if field.bitOffset % 8 == 0 && field.bitSize == 8 {
                        triggers.append(field.bitOffset / 8)
                    }
                case 0x39: // Hat switch
                    // Accept 4-bit AND 8-bit hats: some pads declare the hat as
                    // a full byte (0-7/8 in the low nibble, padding above). The
                    // decoder's windowed read masks with 0x0F, so an 8-bit hat
                    // decodes correctly from the same bitOffset; rejecting it
                    // left the D-pad completely dead on those controllers.
                    if field.bitSize == 4 || field.bitSize == 8 {
                        // Keep the absolute bit offset (hats often sit in
                        // the high nibble after 12 buttons) plus the
                        // declared logical minimum: many pads use 1..8
                        // with 0 as null, and assuming 0 = North both
                        // rotated every direction 45 degrees and decoded
                        // the resting state as a held North.
                        hatBit = field.bitOffset
                        hatMin = (0...1).contains(field.logicalMin) ? field.logicalMin : 0
                    }
                default: break
                }
            default: break
            }
        }

        // Only return a layout if we have at least the basics.
        guard !buttons.isEmpty || !axesAggregated.isEmpty else { return nil }

        let sortedAxes = axesAggregated.sorted { $0.byte < $1.byte }
        let axisOffsets = sortedAxes.map(\.byte)
        let axisWidths = sortedAxes.map(\.width)
        let axisSigned = sortedAxes.map(\.signed)
        let axisUsages = sortedAxes.map(\.usage)

        return ControllerProfile.GenericLayout(
            buttonBitOffsets: buttons.sorted(),
            axisByteOffsets: axisOffsets,
            axisByteWidths: axisWidths,
            axisIsSignedFlags: axisSigned,
            axisUsages: axisUsages,
            hatByteOffset: hatBit.map { $0 / 8 },
            triggerByteOffsets: triggers.sorted(),
            reportSize: (totalBits + 7) / 8,
            hasReportID: reportID != nil,
            hatBitOffset: hatBit,
            hatLogicalMin: hatMin,
            reportID: reportID
        )
    }

    // MARK: - Parse state

    private struct ParseState {
        var usagePage: Int = 0
        var usages: [Int] = []
        var usageMin: Int = 0
        var usageMax: Int = 0
        var logicalMin: Int = 0
        var logicalMax: Int = 0
        var reportSize: Int = 0
        var reportCount: Int = 0

        /// Usage assigned to the nth entry in a multi-count INPUT item.
        /// HID lets you either list explicit usages (one per entry) or
        /// give a usage range; we pick whichever was set most recently.
        func usage(forIndex n: Int) -> Int {
            if !usages.isEmpty {
                return usages[min(n, usages.count - 1)]
            }
            if usageMin != 0 || usageMax != 0 {
                return usageMin + n
            }
            return 0
        }

        mutating func clearLocals() {
            usages.removeAll(keepingCapacity: true)
            usageMin = 0
            usageMax = 0
        }
    }
}
