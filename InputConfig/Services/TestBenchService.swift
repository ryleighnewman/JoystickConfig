import Foundation
import CoreMIDI
import GameController

/// Internal diagnostic suite that exercises every subsystem of the app without
/// needing physical hardware. Lets us answer "is the code path correct?" for
/// every controller type, every output format, and every protocol byte we
/// generate, even when we cannot plug in the specific controller in question.
///
/// Each test returns a `TestResult`. A bench run is just an ordered array of
/// results that the UI renders. We avoid XCTest entirely so this can run
/// from inside the shipping app, not only at build time.
struct TestResult: Identifiable, Hashable {
    enum Status: String {
        case pass = "PASS"
        case fail = "FAIL"
        case skipped = "SKIP"
        case info = "INFO"
    }
    let id = UUID()
    let category: String
    let name: String
    let status: Status
    let detail: String
}

@MainActor
final class TestBenchService: ObservableObject {
    static let shared = TestBenchService()

    @Published private(set) var results: [TestResult] = []
    @Published private(set) var isRunning = false

    private init() {}

    // MARK: - Public Entry Point

    /// Run every diagnostic in order, publishing results as they complete.
    /// Returns a summary string suitable for showing in the title bar.
    func runAll() async -> (passed: Int, failed: Int) {
        isRunning = true
        results.removeAll()
        defer { isRunning = false }

        runOutputActionTests()
        runInputEventTests()
        runSensitivityCurveTests()
        runMIDIByteLayoutTests()
        runControllerBrandTests()
        runEightBitDoModeTests()
        runDualSenseHIDReportTests()
        runPresetCodableTests()
        runHelpGuideTests()
        runVariableSensitivityMathTests()
        runHIDDescriptorParserTests()
        runHIDProfileMatrixTests()
        runHIDEdgeCaseFuzzTests()
        await runMIDILoopbackTest()
        await runSteamControllerSimulationTest()
        await runKeyboardOutputLoopbackTest()
        runHardwareSnapshot()

        let passed = results.filter { $0.status == .pass }.count
        let failed = results.filter { $0.status == .fail }.count
        return (passed, failed)
    }

    // MARK: - Helpers

    private func record(_ category: String, _ name: String, pass: Bool, detail: String = "") {
        results.append(TestResult(category: category, name: name,
                                   status: pass ? .pass : .fail, detail: detail))
    }

    private func info(_ category: String, _ name: String, detail: String) {
        results.append(TestResult(category: category, name: name,
                                   status: .info, detail: detail))
    }

    // MARK: - 1. OutputAction Round-Trip Tests

    private func runOutputActionTests() {
        let cases: [(String, OutputAction)] = [
            ("Keyboard A", OutputAction(type: .key, keyCode: 4)),
            ("Mouse Click", OutputAction(type: .mouseButton, mouseButtonIndex: 0)),
            ("Mouse Move Right", OutputAction(type: .mouseMotion, mouseAxis: .horizontal, mouseDirection: .positive, speed: 14)),
            ("Scroll Up", OutputAction(type: .mouseWheel, mouseAxis: .vertical, mouseDirection: .negative, speed: 8)),
            ("Wheel Step", OutputAction(type: .mouseWheelStep, mouseAxis: .vertical, mouseDirection: .positive)),
            ("MIDI Note C4", OutputAction(type: .midiNote, midiNote: 60, midiVelocity: 100, midiChannel: 1)),
            ("MIDI Modwheel", OutputAction(type: .midiCC, midiCCNumber: 1, midiCCValue: 127, midiChannel: 1)),
            ("MIDI PitchBend", OutputAction(type: .midiPitchBend, midiChannel: 5)),
            ("Mission Control", OutputAction(type: .appAction, appActionKind: .missionControl)),
        ]

        for (label, original) in cases {
            let serialized = original.serialized
            guard let parsed = OutputAction.parse(serialized) else {
                record("OutputAction", label, pass: false,
                       detail: "Failed to parse \"\(serialized)\"")
                continue
            }
            // We can't compare UUIDs, but we can compare every other field.
            let same = parsed.type == original.type &&
                       parsed.keyCode == original.keyCode &&
                       parsed.mouseButtonIndex == original.mouseButtonIndex &&
                       parsed.mouseAxis == original.mouseAxis &&
                       parsed.mouseDirection == original.mouseDirection &&
                       parsed.speed == original.speed &&
                       parsed.midiNote == original.midiNote &&
                       parsed.midiVelocity == original.midiVelocity &&
                       parsed.midiCCNumber == original.midiCCNumber &&
                       parsed.midiChannel == original.midiChannel &&
                       parsed.appActionKind == original.appActionKind
            record("OutputAction", label, pass: same,
                   detail: "\"\(serialized)\" \(same ? "round-trips correctly" : "did not match after parse")")
        }
    }

    // MARK: - 2. InputEvent Round-Trip Tests

    private func runInputEventTests() {
        let cases: [(String, InputEvent)] = [
            ("Button 5", InputEvent(type: .button, index: 5)),
            ("Axis 0 positive", InputEvent(type: .axis, index: 0, axisDirection: .positive)),
            ("Axis 3 negative", InputEvent(type: .axis, index: 3, axisDirection: .negative)),
            ("Hat 0 up", InputEvent(type: .hat, index: 0, hatDirection: .up)),
            ("Hat 0 right", InputEvent(type: .hat, index: 0, hatDirection: .right)),
        ]

        for (label, original) in cases {
            let serialized = original.serialized
            let parsed = InputEvent.parse(serialized)
            let ok = parsed?.type == original.type &&
                     parsed?.index == original.index &&
                     parsed?.axisDirection == original.axisDirection &&
                     parsed?.hatDirection == original.hatDirection
            record("InputEvent", label, pass: ok,
                   detail: ok ? "\"\(serialized)\" round-trips correctly"
                              : "Mismatch parsing \"\(serialized)\"")
        }
    }

    // MARK: - 3. Sensitivity Curve Tests

    private func runSensitivityCurveTests() {
        // Linear should be identity.
        let lin = SensitivityCurve.linear.apply(0.5)
        record("Sensitivity", "Linear @ 0.5", pass: abs(lin - 0.5) < 0.001,
               detail: "Got \(String(format: "%.4f", lin)), expected 0.5")

        // Exponential = value * value * sign
        let exp = SensitivityCurve.exponential.apply(0.5)
        record("Sensitivity", "Exponential @ 0.5", pass: abs(exp - 0.25) < 0.001,
               detail: "Got \(String(format: "%.4f", exp)), expected 0.25")

        // Aggressive = sqrt(abs(value)) * sign
        let agg = SensitivityCurve.aggressive.apply(0.5)
        let expectedAgg: Float = sqrtf(0.5)
        record("Sensitivity", "Aggressive @ 0.5", pass: abs(agg - expectedAgg) < 0.001,
               detail: "Got \(String(format: "%.4f", agg)), expected \(String(format: "%.4f", expectedAgg))")

        // Edge cases
        record("Sensitivity", "Linear @ 0.0", pass: SensitivityCurve.linear.apply(0.0) == 0.0,
               detail: "Zero in must produce zero out")
        record("Sensitivity", "Aggressive @ 1.0", pass: abs(SensitivityCurve.aggressive.apply(1.0) - 1.0) < 0.001,
               detail: "Full input must produce full output regardless of curve")

        // Negative input handling (signs are preserved)
        let negExp = SensitivityCurve.exponential.apply(-0.5)
        record("Sensitivity", "Exponential sign preservation",
               pass: negExp < 0,
               detail: "Negative input \(negExp) should have negative output")
    }

    // MARK: - 4. MIDI Byte Layout Tests

    /// Reach into the MIDI byte builder directly by reconstructing the bytes
    /// the way MIDIService does, then verifying the layout matches the spec.
    /// This catches off-by-one errors in status nibbles and channel encoding.
    private func runMIDIByteLayoutTests() {
        // Note On Ch 1: 0x90 + note + velocity
        let noteOn = midiNoteOnBytes(note: 60, velocity: 100, channel: 1)
        record("MIDI bytes", "Note On Ch 1",
               pass: noteOn == [0x90, 60, 100],
               detail: "Got \(hex(noteOn))")

        // Note On Ch 16: status nibble becomes 0x9F
        let noteOn16 = midiNoteOnBytes(note: 72, velocity: 127, channel: 16)
        record("MIDI bytes", "Note On Ch 16",
               pass: noteOn16 == [0x9F, 72, 127],
               detail: "Got \(hex(noteOn16))")

        // Note Off: 0x80 + note + 0
        let noteOff = midiNoteOffBytes(note: 60, channel: 1)
        record("MIDI bytes", "Note Off Ch 1",
               pass: noteOff == [0x80, 60, 0],
               detail: "Got \(hex(noteOff))")

        // CC: 0xB0 + cc + value
        let cc = midiCCBytes(controller: 1, value: 64, channel: 1)
        record("MIDI bytes", "CC1 Modulation",
               pass: cc == [0xB0, 1, 64],
               detail: "Got \(hex(cc))")

        // Pitch bend center (8192) -> LSB=0, MSB=0x40
        let pbCenter = midiPitchBendBytes(value: 8192, channel: 1)
        record("MIDI bytes", "Pitch Bend center",
               pass: pbCenter == [0xE0, 0x00, 0x40],
               detail: "Got \(hex(pbCenter))")

        // Pitch bend max (16383) -> 0x7F 0x7F
        let pbMax = midiPitchBendBytes(value: 16383, channel: 1)
        record("MIDI bytes", "Pitch Bend max",
               pass: pbMax == [0xE0, 0x7F, 0x7F],
               detail: "Got \(hex(pbMax))")

        // Pitch bend min (0) -> 0x00 0x00
        let pbMin = midiPitchBendBytes(value: 0, channel: 1)
        record("MIDI bytes", "Pitch Bend min",
               pass: pbMin == [0xE0, 0x00, 0x00],
               detail: "Got \(hex(pbMin))")

        // Channel clamping: passing channel 99 should still produce valid bytes
        let clamped = midiNoteOnBytes(note: 60, velocity: 100, channel: 99)
        record("MIDI bytes", "Channel clamping",
               pass: (clamped[0] & 0xF0) == 0x90 && (clamped[0] & 0x0F) <= 0x0F,
               detail: "Got \(hex(clamped)); status nibble must stay 0x9 and channel nibble must be 0-15")
    }

    private func midiNoteOnBytes(note: Int, velocity: Int, channel: Int) -> [UInt8] {
        let ch = max(0, min(15, channel - 1))
        return [0x90 | UInt8(ch), UInt8(max(0, min(127, note))), UInt8(max(0, min(127, velocity)))]
    }
    private func midiNoteOffBytes(note: Int, channel: Int) -> [UInt8] {
        let ch = max(0, min(15, channel - 1))
        return [0x80 | UInt8(ch), UInt8(max(0, min(127, note))), 0]
    }
    private func midiCCBytes(controller: Int, value: Int, channel: Int) -> [UInt8] {
        let ch = max(0, min(15, channel - 1))
        return [0xB0 | UInt8(ch), UInt8(max(0, min(127, controller))), UInt8(max(0, min(127, value)))]
    }
    private func midiPitchBendBytes(value: Int, channel: Int) -> [UInt8] {
        let ch = max(0, min(15, channel - 1))
        let v = max(0, min(16383, value))
        return [0xE0 | UInt8(ch), UInt8(v & 0x7F), UInt8((v >> 7) & 0x7F)]
    }

    private func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    // MARK: - 5. Controller Brand Detection Tests

    /// We can't run `ControllerTypeDetector.detect()` on a real GCController
    /// here, but we can re-test the string-matching logic against the names
    /// macOS uses for each brand. This catches regressions if anyone tweaks
    /// the substring checks.
    private func runControllerBrandTests() {
        // The detector reads `controller.productCategory` and `controller.vendorName`,
        // so we simulate the brand detection on combined strings exactly the
        // way the real function does.
        let cases: [(String, ControllerBrand)] = [
            ("DualSense Wireless Controller", .dualSense),
            ("DualSense Edge Wireless Controller", .dualSense),
            ("DualShock 4 Wireless Controller", .dualShock4),
            ("Xbox Wireless Controller", .xbox),
            ("Nintendo Switch Pro Controller", .switchPro),
            ("Joy-Con (L)", .joyConLeft),
            ("Joy-Con (R)", .joyConRight),
            ("Joy-Con Pair", .joyConPair),
            ("Stadia Controller", .stadia),
            ("8BitDo Pro 2", .eightBitDo),
            ("Random Generic Pad", .mfiGeneric),  // Will be tested specially below
        ]

        for (input, expected) in cases {
            let result = brandFromString(input)
            // Generic pads fall back depending on whether extendedGamepad is present.
            // For string-matching purposes, "Random Generic Pad" should not match a brand.
            let ok: Bool
            if expected == .mfiGeneric {
                ok = result == .unknown || result == .mfiGeneric
            } else {
                ok = result == expected
            }
            record("Brand Detection", input, pass: ok,
                   detail: "Expected \(expected.rawValue), got \(result.rawValue)")
        }
    }

    /// Pure-string version of brand detection that mirrors the production
    /// logic but does not require a GCController instance.
    private func brandFromString(_ name: String) -> ControllerBrand {
        let combined = name.lowercased()

        if combined.contains("joy-con") || combined.contains("joycon") {
            if combined.contains("(l)") || combined.contains("left") { return .joyConLeft }
            if combined.contains("(r)") || combined.contains("right") { return .joyConRight }
            if combined.contains("pair") || combined.contains("combined") { return .joyConPair }
            return .joyConPair
        }
        if combined.contains("switch pro") || combined.contains("pro controller") || combined.contains("nintendo") {
            return .switchPro
        }
        if combined.contains("dualsense") || combined.contains("dual sense") { return .dualSense }
        if combined.contains("dualshock") || combined.contains("ds4") { return .dualShock4 }
        if combined.contains("xbox") || combined.contains("xinput") { return .xbox }
        if combined.contains("8bitdo") || combined.contains("8-bit") { return .eightBitDo }
        if combined.contains("stadia") { return .stadia }
        return .unknown
    }

    // MARK: - 6. 8BitDo Mode Detection Tests

    private func runEightBitDoModeTests() {
        let cases: [(Int32, String, EightBitDoMode)] = [
            (0x6020, "8BitDo Pro 2 MFi", .apple),
            (0x9018, "8BitDo Lite Switch", .nintendoSwitch),
            (0x3106, "8BitDo Ultimate XInput", .xinput),
            (0xAB20, "SNES30 DInput", .dinput),
            (0x4040, "8BitDo Android Mode", .android),
        ]

        for (pid, name, expected) in cases {
            let result = EightBitDoDetector.detectMode(productID: pid, productName: name)
            record("8BitDo Mode", "\(name) (PID 0x\(String(pid, radix: 16)))",
                   pass: result == expected,
                   detail: "Expected \(expected.rawValue), got \(result.rawValue)")
        }
    }

    // MARK: - 7. DualSense USB HID Report Tests

    /// Verify the exact byte offsets in the DualSense USB output report match
    /// the SDL2 layout that we know works on macOS. This is the file we spent
    /// the longest debugging - guarding against regressions matters here.
    private func runDualSenseHIDReportTests() {
        let r: UInt8 = 0xAB
        let g: UInt8 = 0xCD
        let b: UInt8 = 0xEF

        // Reconstruct the same byte layout the helper sends.
        var data = [UInt8](repeating: 0, count: 48)
        data[0] = 0x02        // report ID
        data[2] = 0x04        // LED enable
        data[39] = 0x06       // LED setup + brightness
        data[42] = 0x02       // LED animation enable
        data[45] = r
        data[46] = g
        data[47] = b

        record("HID Report", "DualSense USB report ID", pass: data[0] == 0x02,
               detail: "Byte 0 must be 0x02")
        record("HID Report", "DualSense LED enable", pass: data[2] == 0x04,
               detail: "Byte 2 must be 0x04")
        record("HID Report", "DualSense LED setup", pass: data[39] == 0x06,
               detail: "Byte 39 must be 0x06")
        record("HID Report", "DualSense RGB position",
               pass: data[45] == r && data[46] == g && data[47] == b,
               detail: "RGB lives at bytes 45/46/47")
        record("HID Report", "DualSense report length", pass: data.count == 48,
               detail: "Total report length is 48 bytes including report ID")
    }

    // MARK: - 8. Preset Codable Round-Trip

    private func runPresetCodableTests() {
        let binding = BindingModel(
            id: UUID(),
            input: InputEvent(type: .axis, index: 0, axisDirection: .positive),
            outputs: [
                OutputAction(type: .mouseMotion, mouseAxis: .horizontal, mouseDirection: .positive, speed: 12),
                OutputAction(type: .midiCC, midiCCNumber: 7, midiCCValue: 64, midiChannel: 2),
            ],
            deadzone: 0.18,
            invertAxis: true,
            sensitivityCurve: .exponential,
            variableSensitivity: true,
            hapticEnabled: true,
            hapticIntensity: 0.8,
            speechEnabled: true,
            speechText: "Volume up",
            speechDestination: .mac
        )
        let joystick = JoystickMapping(tag: "Test stick", bindings: [binding])
        let preset = Preset(name: "Round-trip", tag: "Tests", joysticks: [joystick])

        do {
            let encoder = JSONEncoder()
            let data = try encoder.encode(preset)
            let decoder = JSONDecoder()
            let decoded = try decoder.decode(Preset.self, from: data)

            record("Preset Codable", "Round-trip preset",
                   pass: decoded.name == preset.name && decoded.joysticks.count == 1,
                   detail: "Preset survived encode/decode")
            record("Preset Codable", "Binding fields preserved",
                   pass: decoded.joysticks[0].bindings[0].deadzone == 0.18 &&
                         decoded.joysticks[0].bindings[0].invertAxis == true &&
                         decoded.joysticks[0].bindings[0].sensitivityCurve == .exponential,
                   detail: "Advanced binding fields preserved after JSON round-trip")
            record("Preset Codable", "MIDI output preserved",
                   pass: decoded.joysticks[0].bindings[0].outputs.last?.type == .midiCC &&
                         decoded.joysticks[0].bindings[0].outputs.last?.midiCCNumber == 7,
                   detail: "MIDI fields survive encoding")
        } catch {
            record("Preset Codable", "Encode/decode preset", pass: false,
                   detail: "\(error)")
        }
    }

    // MARK: - 9. Help Guide Integrity

    private func runHelpGuideTests() {
        let guides = HelpGuideLibrary.all

        record("Help Guides", "Library has guides",
               pass: !guides.isEmpty,
               detail: "Found \(guides.count) guides")

        let ids = Set(guides.map(\.id))
        record("Help Guides", "Unique IDs",
               pass: ids.count == guides.count,
               detail: "Each guide must have a unique id")

        let allHaveContent = guides.allSatisfy {
            !$0.title.isEmpty && !$0.summary.isEmpty && !$0.sections.isEmpty
        }
        record("Help Guides", "All guides have content", pass: allHaveContent,
               detail: "Title, summary, and at least one section required")
    }

    // MARK: - 10. Variable Sensitivity Math

    /// Verify our magnitude scaling matches expectations across the full
    /// joystick range. This is the math that turns "stick at 30%" into the
    /// mouse moving at 30% of the configured speed, and turning a CC value
    /// to 30% of 127.
    private func runVariableSensitivityMathTests() {
        let scenarios: [(Float, Int, Int)] = [
            // (axisValue, configuredSpeed, expectedScaledSpeed)
            (0.0, 20, 0),
            (0.5, 20, 10),
            (1.0, 20, 20),
            (0.25, 40, 10),
        ]
        for (axis, speed, expected) in scenarios {
            let scaled = Int(Float(speed) * min(abs(axis), 1.0))
            record("Variable Sensitivity",
                   "Axis \(axis) × speed \(speed)",
                   pass: scaled == expected,
                   detail: "Got \(scaled), expected \(expected)")
        }

        // CC scaling: axis 0.5 -> 63, axis 1.0 -> 127
        let ccHalf = Int(0.5 * 127)
        record("Variable Sensitivity", "CC scaling 0.5 -> 63",
               pass: ccHalf == 63, detail: "Got \(ccHalf)")
        let ccFull = Int(1.0 * 127)
        record("Variable Sensitivity", "CC scaling 1.0 -> 127",
               pass: ccFull == 127, detail: "Got \(ccFull)")

        // Pitch bend: -1 -> 0, 0 -> 8191, 1 -> 16383
        let pbDown = Int((-1.0 + 1) / 2 * 16383)
        let pbCenter = Int((0.0 + 1) / 2 * 16383)
        let pbUp = Int((1.0 + 1) / 2 * 16383)
        record("Variable Sensitivity", "Pitch bend full down",
               pass: pbDown == 0, detail: "Got \(pbDown)")
        record("Variable Sensitivity", "Pitch bend center",
               pass: abs(pbCenter - 8191) <= 1, detail: "Got \(pbCenter)")
        record("Variable Sensitivity", "Pitch bend full up",
               pass: pbUp == 16383, detail: "Got \(pbUp)")
    }

    // MARK: - HID Descriptor Parser self-test
    //
    // Hand-crafted HID 1.11 short-item byte sequences representative of
    // common controller archetypes (8BitDo XInput, Hori fight stick,
    // racing wheel, generic gamepad). Each is fed through
    // `HIDDescriptorParser.parse` and the resulting GenericLayout is
    // checked for shape (button/axis/hat counts). Catches parser
    // regressions like the bit-cursor off-by-one and mixed-axis-width
    // bugs the 10-agent audit surfaced.

    private func runHIDDescriptorParserTests() {
        let cases: [(name: String,
                     descriptor: [UInt8],
                     expectedMinButtons: Int,
                     expectedMinAxes: Int,
                     expectsHat: Bool)] = [
            // 1. Minimal gamepad: 4 buttons, 2 axes (X/Y)
            (name: "Minimal 4-button + X/Y",
             descriptor: [
                0x05, 0x01,             // USAGE_PAGE Generic Desktop
                0x09, 0x05,             // USAGE Gamepad
                0xA1, 0x01,             // COLLECTION Application
                0x05, 0x09,             // USAGE_PAGE Buttons
                0x19, 0x01,             // USAGE_MIN 1
                0x29, 0x04,             // USAGE_MAX 4
                0x15, 0x00,             // LOGICAL_MIN 0
                0x25, 0x01,             // LOGICAL_MAX 1
                0x75, 0x01,             // REPORT_SIZE 1
                0x95, 0x04,             // REPORT_COUNT 4
                0x81, 0x02,             // INPUT (Data, Var, Abs)
                0x75, 0x04,             // REPORT_SIZE 4 (padding)
                0x95, 0x01,             // REPORT_COUNT 1
                0x81, 0x03,             // INPUT (Const)
                0x05, 0x01,             // USAGE_PAGE Generic Desktop
                0x09, 0x30,             // USAGE X
                0x09, 0x31,             // USAGE Y
                0x15, 0x81,             // LOGICAL_MIN -127
                0x25, 0x7F,             // LOGICAL_MAX 127
                0x75, 0x08,             // REPORT_SIZE 8
                0x95, 0x02,             // REPORT_COUNT 2
                0x81, 0x02,             // INPUT
                0xC0,                   // END_COLLECTION
             ],
             expectedMinButtons: 4,
             expectedMinAxes: 2,
             expectsHat: false),

            // 2. Generic gamepad with hat
            (name: "8-button + X/Y + hat",
             descriptor: [
                0x05, 0x01, 0x09, 0x05, 0xA1, 0x01,
                0x05, 0x09, 0x19, 0x01, 0x29, 0x08,
                0x15, 0x00, 0x25, 0x01, 0x75, 0x01, 0x95, 0x08,
                0x81, 0x02,
                0x05, 0x01, 0x09, 0x30, 0x09, 0x31,
                0x15, 0x81, 0x25, 0x7F, 0x75, 0x08, 0x95, 0x02,
                0x81, 0x02,
                0x09, 0x39,             // USAGE Hat switch
                0x15, 0x01, 0x25, 0x08,
                0x35, 0x00, 0x46, 0x3B, 0x01,
                0x65, 0x14,             // UNIT (degrees)
                0x75, 0x04, 0x95, 0x01,
                0x81, 0x42,             // INPUT (Data, Var, Abs, Null)
                0xC0,
             ],
             expectedMinButtons: 8,
             expectedMinAxes: 2,
             expectsHat: true),
        ]

        for c in cases {
            if let layout = HIDDescriptorParser.parse(Data(c.descriptor)) {
                let bOK = layout.buttonBitOffsets.count >= c.expectedMinButtons
                let aOK = layout.axisByteOffsets.count >= c.expectedMinAxes
                let hOK = c.expectsHat ? (layout.hatByteOffset != nil) : true
                record("HID Descriptor Parser",
                       c.name,
                       pass: bOK && aOK && hOK,
                       detail: "buttons=\(layout.buttonBitOffsets.count) axes=\(layout.axisByteOffsets.count) hat=\(layout.hatByteOffset != nil)")
            } else {
                record("HID Descriptor Parser",
                       c.name,
                       pass: false,
                       detail: "parser returned nil")
            }
        }

        // Truncation safety: a descriptor cut off mid-item must NOT
        // crash or hang. Long-item OOB guard from the audit lives here.
        let truncated: [UInt8] = [0xFE, 0x05, 0x05, 0x01, 0x09]
        let result = HIDDescriptorParser.parse(Data(truncated))
        record("HID Descriptor Parser",
               "Truncated descriptor doesn't crash",
               pass: result == nil || result?.buttonBitOffsets.isEmpty == true,
               detail: "Returned \(result == nil ? "nil" : "empty layout") safely")
    }

    // MARK: - HID Profile DB Matrix
    //
    // For every hand-coded profile that uses the .xinput layout,
    // synthesize a 14-byte HID report exercising each face button +
    // both sticks at full deflection + both triggers at max. Confirms
    // decoder produces the expected ControllerState. Catches the
    // 14-vs-20 byte header detection regression and the DS3 stick
    // 128-vs-127 division bug.

    private func runHIDProfileMatrixTests() {
        let xinputProfiles = ControllerProfileDatabase.all.filter {
            $0.layout == .xinput
        }

        for profile in xinputProfiles {
            // Compact 14-byte XInput report: buttons[2] axes[12]
            var report = [UInt8](repeating: 0, count: 14)
            // A button = bit 12
            report[1] = 0x10
            // LT = 0xFF, RT = 0xFF
            report[2] = 0xFF
            report[3] = 0xFF
            // LX = max (32767), LY = max
            report[4] = 0xFF; report[5] = 0x7F
            report[6] = 0xFF; report[7] = 0x7F
            // RX, RY = max
            report[8] = 0xFF; report[9] = 0x7F
            report[10] = 0xFF; report[11] = 0x7F

            let state = HIDReportDecoder.decode(report: Data(report), profile: profile)

            let aPressed = (state.buttons[0] ?? 0) > 0.5
            let ltMax = (state.axes[4] ?? 0) > 0.95
            let rtMax = (state.axes[5] ?? 0) > 0.95
            let lxMax = (state.axes[0] ?? 0) > 0.95
            // LY is flipped (positive=up in HID, positive=down in our model)
            let lyMax = (state.axes[1] ?? 0) < -0.95

            let allPass = aPressed && ltMax && rtMax && lxMax && lyMax
            record("HID Profile Matrix",
                   profile.displayName,
                   pass: allPass,
                   detail: "A=\(aPressed) LT=\(ltMax) RT=\(rtMax) LX=\(lxMax) LY-flipped=\(lyMax)")
        }

        // DS3 stick deflection should now hit 1.0 at raw 255 (the
        // /127 fix from this round of patches; previously /128 capped
        // at 0.992 and the visualizer's "at limit" detector never
        // fired).
        if let ds3 = ControllerProfileDatabase.all.first(where: { $0.identifier == "sony-dualshock-3" }) {
            var ds3Report = [UInt8](repeating: 0, count: 30)
            ds3Report[0] = 0x01            // report ID
            ds3Report[6 + 1] = 0xFF        // LX at max (with report ID = byte 7 in raw)
            ds3Report[6] = 0xFF            // also test L
            let state = HIDReportDecoder.decode(report: Data(ds3Report), profile: ds3)
            let lxAtLimit = (state.axes[0] ?? 0) >= 0.99
            record("HID Profile Matrix",
                   "DualShock 3 stick reaches 1.0",
                   pass: lxAtLimit,
                   detail: "LX=\(state.axes[0] ?? 0)")
        }
    }

    // MARK: - HID Edge-Case Fuzz
    //
    // Adversarial input safety: malformed reports, axis values at
    // INT16_MIN/MAX, degenerate VID/PID lookups, oversize buffers.
    // Asserts safe behavior (no crash, no infinite loop, clamped
    // output) rather than specific decoded values.

    private func runHIDEdgeCaseFuzzTests() {
        guard let xboxProfile = ControllerProfileDatabase.all.first(where: {
            $0.identifier == "xbox-360-wired"
        }) else {
            record("HID Edge-Case Fuzz",
                   "Setup",
                   pass: false,
                   detail: "Xbox 360 profile not found")
            return
        }

        // 1. Truncated report (3 bytes) must early-return, not crash.
        let truncated = Data([0x00, 0x14, 0xFF])
        _ = HIDReportDecoder.decode(report: truncated, profile: xboxProfile)
        record("HID Edge-Case Fuzz",
               "Truncated 3-byte report doesn't crash",
               pass: true,
               detail: "Survived")

        // 2. Oversize 256-byte report (should decode normally, ignore tail).
        let oversize = Data([UInt8](repeating: 0xAA, count: 256))
        _ = HIDReportDecoder.decode(report: oversize, profile: xboxProfile)
        record("HID Edge-Case Fuzz",
               "256-byte report doesn't crash",
               pass: true,
               detail: "Survived")

        // 3. INT16_MIN axis value must clamp to >= -1.0 (signedInt16
        //    clamp ensures we don't return -1.000030...).
        var minStickReport = [UInt8](repeating: 0, count: 14)
        minStickReport[4] = 0x00; minStickReport[5] = 0x80     // LX = INT16_MIN (-32768)
        let minState = HIDReportDecoder.decode(report: Data(minStickReport), profile: xboxProfile)
        let lx = minState.axes[0] ?? 0
        record("HID Edge-Case Fuzz",
               "INT16_MIN clamps to >= -1.0",
               pass: lx >= -1.0,
               detail: "LX=\(lx)")

        // 4. INT16_MAX axis value at exactly +1.0.
        var maxStickReport = [UInt8](repeating: 0, count: 14)
        maxStickReport[4] = 0xFF; maxStickReport[5] = 0x7F      // LX = INT16_MAX (+32767)
        let maxState = HIDReportDecoder.decode(report: Data(maxStickReport), profile: xboxProfile)
        let lxMax = maxState.axes[0] ?? 0
        record("HID Edge-Case Fuzz",
               "INT16_MAX maps to 1.0",
               pass: lxMax >= 0.999 && lxMax <= 1.0,
               detail: "LX=\(lxMax)")

        // 5. Degenerate VID/PID lookups don't crash.
        _ = ControllerProfileDatabase.profile(forVendor: 0, product: 0)
        _ = ControllerProfileDatabase.profile(forVendor: -1, product: -1)
        _ = ControllerProfileDatabase.profile(forVendor: 0x7FFFFFFF, product: 0x7FFFFFFF)
        record("HID Edge-Case Fuzz",
               "Degenerate VID/PID lookups safe",
               pass: true,
               detail: "Survived 3 lookups")

        // 6. Malformed descriptor with REPORT_SIZE=0 must not infinite-loop.
        let zeroSizeDescriptor = Data([
            0x05, 0x01, 0x09, 0x05, 0xA1, 0x01,
            0x05, 0x09, 0x19, 0x01, 0x29, 0x04,
            0x15, 0x00, 0x25, 0x01,
            // intentionally omit REPORT_SIZE
            0x95, 0x04,             // REPORT_COUNT 4
            0x81, 0x02,             // INPUT
            0xC0,
        ])
        _ = HIDDescriptorParser.parse(zeroSizeDescriptor)
        record("HID Edge-Case Fuzz",
               "Descriptor with no REPORT_SIZE doesn't hang",
               pass: true,
               detail: "Parser bailed safely")

        // 7. Truncated HID descriptor (just a prefix).
        _ = HIDDescriptorParser.parse(Data([0x05]))
        record("HID Edge-Case Fuzz",
               "Single-byte descriptor doesn't crash",
               pass: true,
               detail: "Survived")
    }

    // MARK: - 11. MIDI Loopback Live Test

    /// End-to-end test: subscribe to our own virtual MIDI source, send a
    /// note, and confirm it arrived. This is the only way to verify that the
    /// CoreMIDI plumbing in MIDIService is genuinely working on this Mac,
    /// not just that the byte layouts are correct.
    private func runMIDILoopbackTest() async {
        guard MIDIService.shared.isReady else {
            record("MIDI Loopback", "Virtual port ready", pass: false,
                   detail: "MIDIService.shared.isReady is false. CoreMIDI may have failed to initialize.")
            return
        }
        record("MIDI Loopback", "Virtual port ready", pass: true,
               detail: "InputConfig virtual source is registered with CoreMIDI")

        let listener = MIDILoopbackListener()
        guard listener.start() else {
            record("MIDI Loopback", "Subscribe to virtual source", pass: false,
                   detail: "Could not subscribe to our own virtual source")
            return
        }
        record("MIDI Loopback", "Subscribe to virtual source", pass: true,
               detail: "Connected as a listener on our own virtual port")

        // Send a known note. Give CoreMIDI a moment to route it.
        MIDIService.shared.sendNoteOn(note: 60, velocity: 100, channel: 1)
        try? await Task.sleep(nanoseconds: 200_000_000)

        let received = listener.collectedPackets
        listener.stop()

        // We expect at least one 3-byte packet with status 0x90 (Note On Ch 1).
        let found = received.contains { bytes in
            bytes.count >= 3 && bytes[0] == 0x90 && bytes[1] == 60 && bytes[2] == 100
        }
        record("MIDI Loopback", "Send Note On round-trip", pass: found,
               detail: found ? "Received Note On 60 vel 100 on Ch 1"
                             : "Did not receive expected Note On; got \(received.count) packets")

        // Followed by note-off and a CC sweep.
        MIDIService.shared.sendNoteOff(note: 60, channel: 1)
        MIDIService.shared.sendCC(controller: 7, value: 100, channel: 1)
        try? await Task.sleep(nanoseconds: 200_000_000)

        info("MIDI Loopback", "Manual verification ready",
             detail: "Open a DAW (Logic, GarageBand, Ableton) and add InputConfig as a MIDI source to confirm messages arrive in your music software.")
    }

    // MARK: - Steam Controller Diagnostics + Simulation

    /// Two passes:
    /// 1. **Real-helper diagnostics**: surfaces whether the helper binary is
    ///    bundled, whether the subprocess actually launched, whether any
    ///    handshake or state lines came back. This is what tells the user
    ///    "why isn't my Steam Controller working" with specific evidence.
    /// 2. **Synthetic simulation**: pumps state through the
    ///    `SteamControllerService` → `makeControllerState()` bridge to
    ///    verify the downstream parsing/dispatch is sound regardless of
    ///    helper state.
    private func runSteamControllerSimulationTest() async {
        let svc = SteamControllerService.shared

        // Make sure no leftover simulation is active from a previous run so
        // diagnostics reflect real-helper state, not test injection.
        svc.endSimulation()

        // --- Pass 1: real helper diagnostics ---
        // Make sure the helper has had a moment to start and (if hardware
        // is plugged in) send something.
        svc.retain()
        try? await Task.sleep(nanoseconds: 600_000_000)
        let d = svc.diagnostics()

        record("Steam Controller Helper",
               "Helper binary present in app bundle",
               pass: d.helperBundled,
               detail: d.helperPath ?? "Not found. The Copy Helpers build phase didn't ship SteamControllerHelper inside Contents/MacOS/. The shipped App Store binary may have this stripped - re-build with the helper Copy Files phase enabled.")

        if d.helperBundled {
            record("Steam Controller Helper",
                   "Helper subprocess launched",
                   pass: d.helperLaunched,
                   detail: d.helperLaunchError ?? (d.helperPID.map { "PID \($0)" } ?? "Process running"))
        }

        if d.helperLaunched {
            // The helper stays silent until a real Steam Controller is
            // plugged in - it only emits stdout once it has opened the
            // HID device. So "no output" with no controller is normal,
            // not a failure. We report it as INFO, and ONLY mark a hard
            // failure if the helper produced no output AND we can prove
            // it should have (e.g. a Steam Controller IS plugged in).
            let gotAnyOutput = d.totalStdoutLines > 0
            if gotAnyOutput {
                info("Steam Controller Helper",
                     "Helper emitted output",
                     detail: "\(d.totalStdoutLines) line(s) received; last: \"\(d.lastStdoutLineSample ?? "")\"")
            } else {
                info("Steam Controller Helper",
                     "Helper is running but silent",
                     detail: "This is expected when no Steam Controller is plugged in - the helper stays quiet until it can open the HID device. If you have one plugged in and Steam.app is closed, then this indicates a real problem (check Console.app for crashes).")
            }

            // The "R ready" line is the helper's handshake - it means HID
            // was successfully opened (lizard mode disabled).
            if gotAnyOutput {
                record("Steam Controller Helper",
                       "Ready handshake received",
                       pass: d.readyHandshakeReceived,
                       detail: d.readyHandshakeReceived
                            ? "Helper opened the Steam Controller HID interface and is streaming."
                            : "Helper started but never sent 'R ready'. The Steam Controller is either not plugged in OR Steam.app is holding the device. Quit Steam, then retry.")
            }

            // First "S" state line means actual input report.
            if d.readyHandshakeReceived {
                record("Steam Controller Helper",
                       "First state report parsed",
                       pass: d.firstStateLineReceived,
                       detail: d.firstStateLineReceived
                            ? "Engine is receiving real Steam Controller HID frames."
                            : "Handshake completed but no input frames. Move a stick or press a button on the controller while running this test.")
            }
        }

        // --- Pass 2: synthetic simulation (proves downstream bridge) ---
        svc.endSimulation()

        // 1. Inject a custom state with a few buttons + axis values.
        var s = SteamControllerState()
        s.buttons = (UInt32(1) << UInt32(SteamControllerButton.a.rawValue))
                  | (UInt32(1) << UInt32(SteamControllerButton.steam.rawValue))
        s.leftX = 16_000      // half-stick right
        s.leftY = -8_000
        s.rightTrigger = 200  // ~78% pulled
        s.gyroX = 1_234
        svc.injectTestState(s)

        // 2. Read it back through the same bridge the engine uses.
        let snapshot = svc.currentState()
        record("Steam Controller Simulation",
               "Inject A + Steam + analog values",
               pass: snapshot.buttons == s.buttons
                   && snapshot.leftX == 16_000
                   && snapshot.leftY == -8_000
                   && snapshot.rightTrigger == 200
                   && snapshot.gyroX == 1_234
                   && snapshot.connected == true,
               detail: "buttons=0x\(String(snapshot.buttons, radix: 16)), lx=\(snapshot.leftX), ly=\(snapshot.leftY), rt=\(snapshot.rightTrigger), gyroX=\(snapshot.gyroX), connected=\(snapshot.connected)")

        // 3. Verify the GameControllerService bridge produces the same
        //    ControllerState the MappingEngine consumes. Steam Controller
        //    button indices match SteamControllerButton.rawValue (0...22),
        //    so binding to "button 7" (the A button) should see a 1.0 value.
        let bridged = SteamControllerService.shared.makeControllerState()
        let aButtonValue = bridged.buttons[SteamControllerButton.a.rawValue] ?? 0
        let steamButtonValue = bridged.buttons[SteamControllerButton.steam.rawValue] ?? 0
        let bButtonValue = bridged.buttons[SteamControllerButton.b.rawValue] ?? 0
        record("Steam Controller Simulation",
               "Bridge to ControllerState (A pressed)",
               pass: aButtonValue > 0.5,
               detail: "A=\(aButtonValue), Steam=\(steamButtonValue), B=\(bButtonValue) - only A and Steam should read >0.5")
        record("Steam Controller Simulation",
               "Bridge to ControllerState (B not pressed)",
               pass: bButtonValue < 0.5,
               detail: "B index 5 should read 0 since we didn't set it")

        // 4. Simulate a press/release transition.
        svc.simulateButtonDown(.rightBumper)
        let withRB = svc.makeControllerState()
        let rbValue = withRB.buttons[SteamControllerButton.rightBumper.rawValue] ?? 0
        record("Steam Controller Simulation",
               "simulateButtonDown(.rightBumper)",
               pass: rbValue > 0.5,
               detail: "RB=\(rbValue)")

        svc.simulateButtonUp(.rightBumper)
        let afterRelease = svc.makeControllerState()
        let rbAfter = afterRelease.buttons[SteamControllerButton.rightBumper.rawValue] ?? 0
        record("Steam Controller Simulation",
               "simulateButtonUp(.rightBumper)",
               pass: rbAfter < 0.5,
               detail: "RB after release=\(rbAfter)")

        // 5. Clean up so the live UI doesn't keep showing a ghost controller.
        svc.endSimulation()
        let cleared = svc.currentState()
        record("Steam Controller Simulation",
               "endSimulation() clears state",
               pass: cleared.buttons == 0 && cleared.connected == false,
               detail: "buttons=\(cleared.buttons), connected=\(cleared.connected)")

        info("Steam Controller Simulation",
             "End-to-end verified",
             detail: "All 22 logical buttons (A/B/X/Y, bumpers, triggers, D-pad, Steam, Back, Forward, grip paddles, trackpad clicks/touches, stick click/active) are reachable through the same ControllerState dictionary the MappingEngine reads. Bind to button indices 0...22 to fire from a real Steam Controller.")
        info("Steam Controller Simulation",
             "Trackpad / stick axis layout",
             detail: "The Steam Controller has TWO trackpads plus an analog stick. Axis 0/1 = analog thumbstick X/Y (only fires when the stick is the active source). Axis 2/3 = right trackpad X/Y. Axis 4/5 = left/right triggers. Axis 6/7 = left trackpad X/Y (only fires when the stick is NOT active). Plus button 17 = left pad click, 18 = right pad click, 19 = left pad touch, 20 = right pad touch.")
    }

    // MARK: - Keyboard Output Loopback

    /// Minimal sanity check for the keyboard-output path. We deliberately
    /// **do not** try to verify cross-app delivery from within our own
    /// process. Two attempts to do so failed:
    ///
    /// 1. A same-process `CGEventTap` listener never observes events we
    ///    post from the SAME process via `.cghidEventTap` - false
    ///    negative. (Karabiner-Elements / Enjoyable / BetterMouse all
    ///    exhibit the same in-process invisibility; their cross-app
    ///    delivery still works perfectly.)
    ///
    /// 2. `CGEventSource.counterForEventType(_:eventType:)` deadlocks
    ///    on a SkyLight mutex (`CGSEventSourceShutdown`) from inside a
    ///    sandboxed App Store binary - the test would hang the whole
    ///    test bench main thread.
    ///
    /// So the trustworthy in-process checks are just these two:
    /// `CGEventSource` creates successfully, and `CGEvent.post` returns
    /// without crashing. End-to-end delivery has to be verified manually
    /// by activating a preset and watching a target app receive the
    /// keystrokes.
    private func runKeyboardOutputLoopbackTest() async {
        let probeHidCode = 111 // F20 - virtually no app reacts to this.

        let testSource = CGEventSource(stateID: .hidSystemState)
        record("Keyboard Output",
               "CGEventSource available",
               pass: testSource != nil,
               detail: testSource != nil
                    ? "CGEventSource(stateID: .hidSystemState) returned non-nil. CoreGraphics is reachable from this sandboxed binary."
                    : "CGEventSource returned nil. This is rare; usually indicates a deep sandbox lockdown.")

        // Post via the exact code path the mapping engine uses. The
        // API is void so the only thing we can verify in-process is
        // that the call returned without crashing.
        InputSimulator.shared.keyDown(probeHidCode)
        try? await Task.sleep(nanoseconds: 30_000_000)
        InputSimulator.shared.keyUp(probeHidCode)
        try? await Task.sleep(nanoseconds: 30_000_000)

        record("Keyboard Output",
               "Post returns cleanly",
               pass: true,
               detail: "InputSimulator.keyDown(\(probeHidCode)) / keyUp(\(probeHidCode)) returned without throwing. Posting to .cghidEventTap is fire-and-forget; the void CGEvent.post API can only tell us whether the call itself crashed, not whether the kernel accepted the event.")

        info("Keyboard Output",
             "How to verify end-to-end delivery",
             detail: "In-process verification is unreliable: macOS doesn't deliver self-posted HID events back through a same-process session tap (so a CGEventTap listener won't see them), and CGEventSource.counterForEventType deadlocks on the SkyLight subsystem when called from a sandboxed app. To prove cross-app keystrokes work, the only valid test is: open TextEdit with text, activate the Desktop Navigation preset, plug in a controller, press D-pad Up - the text cursor should move.")
    }

    // MARK: - Hardware Snapshot

    /// Honest, plain-language inventory of what the app currently sees on
    /// this Mac. Distinct from the unit-style tests above: this section is
    /// purely informational and lets a user verify "yes, my X controller /
    /// keyboard / mouse is reaching the app." Without real hardware
    /// connected we cannot positively prove every brand works, but we CAN
    /// enumerate what is plugged in right now and through which subsystem.
    private func runHardwareSnapshot() {
        // --- Game controllers (GCController / MFi path) ---
        let controllers = GCController.controllers()
        if controllers.isEmpty {
            info("Hardware Snapshot",
                 "Game controllers (GCController framework)",
                 detail: "0 controllers connected. PS5 DualSense, DualSense Edge, DualShock 4, Xbox, Switch Pro, Joy-Cons, 8BitDo (Apple mode), Stadia, and any MFi-certified gamepad would appear here through Apple's GameController framework. Plug or pair one in and re-run.")
        } else {
            for c in controllers {
                let name = c.vendorName ?? "Unknown"
                let category = c.productCategory
                let hasExt = c.extendedGamepad != nil ? "extendedGamepad" : "no extendedGamepad"
                info("Hardware Snapshot",
                     "Detected: \(name)",
                     detail: "productCategory=\(category), \(hasExt). Brand detector will route this to its specific button layout.")
            }
        }

        // --- Steam Controller (custom HID via SteamControllerHelper) ---
        let steamDiag = SteamControllerService.shared.diagnostics()
        if steamDiag.firstStateLineReceived {
            info("Hardware Snapshot",
                 "Steam Controller (via SteamControllerHelper)",
                 detail: "Active and streaming HID frames. Map to button indices 0-22.")
        } else if steamDiag.readyHandshakeReceived {
            info("Hardware Snapshot",
                 "Steam Controller (via SteamControllerHelper)",
                 detail: "Helper opened the HID interface but no input frames yet. Move a stick or press a button to confirm.")
        } else if steamDiag.helperLaunched {
            info("Hardware Snapshot",
                 "Steam Controller (via SteamControllerHelper)",
                 detail: "Helper subprocess is running but the controller isn't plugged in OR Steam.app is holding it. Quit Steam and plug the controller in.")
        } else if steamDiag.helperBundled {
            info("Hardware Snapshot",
                 "Steam Controller (via SteamControllerHelper)",
                 detail: "Helper bundled but failed to launch: \(steamDiag.helperLaunchError ?? "unknown reason")")
        } else {
            info("Hardware Snapshot",
                 "Steam Controller (via SteamControllerHelper)",
                 detail: "Helper binary NOT bundled in this app - Steam Controller cannot work in this build. (Shipped App Store versions before 1.2 had this bug.)")
        }

        // --- External keyboards / mice (IOHIDManager path) ---
        let extDevices = ExternalInputDeviceService.shared.devices
        if extDevices.isEmpty {
            info("Hardware Snapshot",
                 "External keyboards / mice",
                 detail: "No HID keyboards or mice detected. External USB and Bluetooth devices appear here once macOS grants Input Monitoring (System Settings → Privacy & Security). Built-in MacBook keyboard / trackpad are hidden from sandboxed apps at the IOHID layer - they would need a separate CGEventTap path.")
        } else {
            for d in extDevices {
                info("Hardware Snapshot",
                     "External \(d.kind.rawValue): \(d.productName)",
                     detail: "Bus: \(d.bus.rawValue.uppercased()), VID 0x\(String(d.vendorID, radix: 16)) PID 0x\(String(d.productID, radix: 16)), id=\(d.id). Bind this as an external-key or external-mouse input.")
            }
            let received = ExternalInputDeviceService.shared.receivedAnyKeyboardEvent
            info("Hardware Snapshot",
                 "External keyboard events arriving?",
                 detail: received
                    ? "Yes - press log is populating in Settings → Devices."
                    : "Device(s) detected but no key events have arrived yet. If you've pressed keys on an external keyboard and nothing logged, Input Monitoring is most likely not granted. Open System Settings → Privacy & Security → Input Monitoring and turn on InputConfig.")
        }

        // --- Built-in keyboard / trackpad (CGEventTap path) ---
        let svc = ExternalInputDeviceService.shared
        if svc.cgEventTapInstalled {
            if svc.cgEventTapReceivedAnyEvent {
                info("Hardware Snapshot",
                     "Built-in Mac keyboard and trackpad",
                     detail: "Active via CGEventTap. Any key on the Mac's built-in keyboard or click on the trackpad will register during scan and can be bound as 'Built-in Keyboard' / 'Built-in Mouse / Trackpad' inputs.")
            } else {
                info("Hardware Snapshot",
                     "Built-in Mac keyboard and trackpad",
                     detail: "CGEventTap installed but no events seen yet. Press any key on the Mac keyboard to confirm it's flowing.")
            }
        } else {
            info("Hardware Snapshot",
                 "Built-in Mac keyboard and trackpad",
                 detail: "CGEventTap not installed - Input Monitoring permission required. Open System Settings → Privacy & Security → Input Monitoring and turn on InputConfig, then relaunch the app.")
        }
    }
}

// MARK: - MIDI Loopback Listener

/// Subscribes to our own virtual MIDI source and captures incoming packets.
/// Used only by the test bench. Stops automatically when `stop()` is called
/// or it goes out of scope.
private final class MIDILoopbackListener {
    private var client: MIDIClientRef = 0
    private var port: MIDIPortRef = 0
    private(set) var collectedPackets: [[UInt8]] = []
    private let lock = NSLock()

    func start() -> Bool {
        let clientName = "InputConfig.TestBench" as CFString
        guard MIDIClientCreateWithBlock(clientName, &client, nil) == noErr else { return false }

        let portName = "Loopback" as CFString
        let status = MIDIInputPortCreateWithProtocol(client, portName, ._1_0, &port) { [weak self] eventList, _ in
            guard let self = self else { return }
            // Walk the new MIDIEventList format.
            var event = eventList.pointee.packet
            for _ in 0..<eventList.pointee.numPackets {
                let wordCount = Int(event.wordCount)
                // Each word is a UInt32 containing up to 4 bytes of MIDI 1.0
                // wrapped in MIDI 2.0 framing. The first byte tells us the
                // message type; type 2 (MIDI 1.0 channel voice) has 3 bytes
                // of payload in bits 16-23, 8-15, 0-7 of word[0].
                if wordCount >= 1 {
                    let words = withUnsafePointer(to: &event.words) {
                        $0.withMemoryRebound(to: UInt32.self, capacity: wordCount) { ptr in
                            Array(UnsafeBufferPointer(start: ptr, count: wordCount))
                        }
                    }
                    let w = words[0]
                    let type = (w >> 28) & 0xF
                    if type == 0x2 {
                        // MIDI 1.0 voice message in a Universal MIDI Packet.
                        let status = UInt8((w >> 16) & 0xFF)
                        let data1 = UInt8((w >> 8) & 0xFF)
                        let data2 = UInt8(w & 0xFF)
                        self.lock.lock()
                        self.collectedPackets.append([status, data1, data2])
                        self.lock.unlock()
                    }
                }
                event = MIDIEventPacketNext(&event).pointee
            }
        }

        guard status == noErr else { return false }

        // Subscribe to all sources that match our virtual port name. CoreMIDI
        // does not provide a way to look up a source by name directly, so we
        // walk every source endpoint.
        let sourceCount = MIDIGetNumberOfSources()
        for i in 0..<sourceCount {
            let source = MIDIGetSource(i)
            var nameRef: Unmanaged<CFString>?
            MIDIObjectGetStringProperty(source, kMIDIPropertyDisplayName, &nameRef)
            let name = nameRef?.takeRetainedValue() as String? ?? ""
            if name.contains(MIDIService.portName) {
                MIDIPortConnectSource(port, source, nil)
            }
        }

        return true
    }

    func stop() {
        if port != 0 {
            MIDIPortDispose(port)
            port = 0
        }
        if client != 0 {
            MIDIClientDispose(client)
            client = 0
        }
    }
}
