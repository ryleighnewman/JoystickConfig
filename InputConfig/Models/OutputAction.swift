import Foundation

/// Represents an output action type
enum OutputType: String, Codable, CaseIterable, Identifiable {
    case key = "key"
    case mouseButton = "mbt"
    case mouseMotion = "mou"
    case mouseWheel = "whe"
    case mouseWheelStep = "whs"
    case midiNote = "mni"
    case midiCC = "mcc"
    case midiPitchBend = "mpb"
    case midiProgramChange = "mpc"
    case midiTransport = "mtr"
    case typeText = "txt"
    case appAction = "app"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .key: return "Keyboard Key"
        case .typeText: return "Type Text"
        case .appAction: return "App Action"
        case .mouseButton: return "Mouse Button"
        case .mouseMotion: return "Mouse Motion"
        case .mouseWheel: return "Mouse Wheel"
        case .mouseWheelStep: return "Mouse Wheel Step"
        case .midiNote: return "MIDI Note"
        case .midiCC: return "MIDI CC (Control Change)"
        case .midiPitchBend: return "MIDI Pitch Bend"
        case .midiProgramChange: return "MIDI Program Change"
        case .midiTransport: return "MIDI Transport"
        }
    }

    var isMIDI: Bool {
        switch self {
        case .midiNote, .midiCC, .midiPitchBend, .midiProgramChange, .midiTransport: return true
        default: return false
        }
    }
}

/// Which MIDI real-time transport message to send. The DAW typically responds
/// by playing, stopping, or continuing playback at its current position.
enum MIDITransport: String, Codable, CaseIterable, Identifiable {
    case start = "start"
    case stop = "stop"
    case `continue` = "continue"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .start: return "Start"
        case .stop: return "Stop"
        case .continue: return "Continue"
        }
    }

    /// The MIDI real-time status byte for this transport message.
    var statusByte: UInt8 {
        switch self {
        case .start: return 0xFA
        case .stop: return 0xFC
        case .continue: return 0xFB
        }
    }
}

/// Mouse motion / wheel axis
enum MouseAxis: Int, Codable, CaseIterable {
    case horizontal = 0
    case vertical = 1

    var displayName: String {
        switch self {
        case .horizontal: return "Horizontal"
        case .vertical: return "Vertical"
        }
    }
}

/// Mouse motion / wheel direction
enum MouseDirection: String, Codable, CaseIterable {
    case positive = "+"
    case negative = "-"

    var displayName: String {
        switch self {
        case .positive: return "+"
        case .negative: return "-"
        }
    }

    /// For mouse motion display
    func axisDirectionName(axis: MouseAxis) -> String {
        switch (axis, self) {
        case (.vertical, .negative): return "Up"
        case (.horizontal, .positive): return "Right"
        case (.vertical, .positive): return "Down"
        case (.horizontal, .negative): return "Left"
        }
    }
}

/// Represents a single output action (keyboard key, mouse button, mouse movement, MIDI message, etc.)
/// Internal app actions a binding can trigger: runtime control of InputConfig
/// itself from the controller. The escape hatch matters most for users who
/// cannot reach the menu bar or a keyboard chord mid-session.
enum AppActionKind: String, Codable, CaseIterable, Identifiable {
    case activatePreset = "act"
    case nextPreset = "next"
    case previousPreset = "prev"
    case deactivate = "off"
    case togglePauseOutputs = "pause"
    case missionControl = "mission"
    case selectionScreenshotToClipboard = "captureSelectionClipboard"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .activatePreset: return "Activate Preset"
        case .nextPreset: return "Next Preset"
        case .previousPreset: return "Previous Preset"
        case .deactivate: return "Deactivate"
        case .togglePauseOutputs: return "Pause / Resume Outputs"
        case .missionControl: return "Mission Control"
        case .selectionScreenshotToClipboard: return "Selection Screenshot to Clipboard"
        }
    }
}

struct OutputAction: Codable, Hashable, Identifiable {
    let id: UUID

    var type: OutputType
    var keyCode: Int?
    var mouseButtonIndex: Int?
    var mouseAxis: MouseAxis?
    var mouseDirection: MouseDirection?
    var speed: Int?

    // MIDI-specific fields (only used when type is one of the MIDI cases).
    // midiNote/midiCC values are 0-127. midiChannel is 1-16 (stored as 0-15
    // internally to match the MIDI spec).
    var midiNote: Int?         // 0-127, e.g. 60 = middle C
    var midiVelocity: Int?     // 0-127
    var midiCCNumber: Int?     // 0-127, e.g. 1 = modulation, 7 = volume, 11 = expression
    var midiCCValue: Int?      // 0-127 (used for fixed-value CC presses; variable axes drive it dynamically)
    var midiChannel: Int?      // 1-16 (defaults to 1 if nil)
    var midiProgramNumber: Int?  // 0-127, used for Program Change messages
    var midiTransport: MIDITransport?  // Start, Stop, Continue for transport bindings

    /// Literal text typed when a .typeText output fires (press only).
    var text: String?

    /// Which internal app action a .appAction output performs, and the
    /// preset it targets when the kind is .activatePreset.
    var appActionKind: AppActionKind?
    var targetPresetID: UUID?

    init(type: OutputType, keyCode: Int? = nil, mouseButtonIndex: Int? = nil,
         mouseAxis: MouseAxis? = nil, mouseDirection: MouseDirection? = nil, speed: Int? = nil,
         midiNote: Int? = nil, midiVelocity: Int? = nil,
         midiCCNumber: Int? = nil, midiCCValue: Int? = nil,
         midiChannel: Int? = nil,
         midiProgramNumber: Int? = nil,
         midiTransport: MIDITransport? = nil,
         text: String? = nil,
         appActionKind: AppActionKind? = nil,
         targetPresetID: UUID? = nil) {
        self.id = UUID()
        self.type = type
        self.keyCode = keyCode
        self.mouseButtonIndex = mouseButtonIndex
        self.mouseAxis = mouseAxis
        self.mouseDirection = mouseDirection
        self.speed = speed
        self.midiNote = midiNote
        self.midiVelocity = midiVelocity
        self.midiCCNumber = midiCCNumber
        self.midiCCValue = midiCCValue
        self.midiChannel = midiChannel
        self.midiProgramNumber = midiProgramNumber
        self.midiTransport = midiTransport
        self.text = text
        self.appActionKind = appActionKind
        self.targetPresetID = targetPresetID
    }

    var displayName: String {
        switch type {
        case .key:
            if let code = keyCode {
                return KeyCodeMap.name(for: code)
            }
            return "Key"
        case .mouseButton:
            if let btn = mouseButtonIndex {
                switch btn {
                case 0: return "Mouse Click"
                case 1: return "Right Click"
                case 2: return "Middle Click"
                default: return "Mouse \(btn)"
                }
            }
            return "Mouse Button"
        case .mouseMotion:
            if let axis = mouseAxis, let dir = mouseDirection {
                let dirName = dir.axisDirectionName(axis: axis)
                let spd = speed ?? 6
                return "Mouse \(dirName) (\(spd)x)"
            }
            return "Mouse Motion"
        case .mouseWheel:
            if let axis = mouseAxis, let dir = mouseDirection {
                let dirName = dir.axisDirectionName(axis: axis)
                let spd = speed ?? 6
                return "Scroll \(dirName) (\(spd)x)"
            }
            return "Mouse Wheel"
        case .mouseWheelStep:
            if let axis = mouseAxis, let dir = mouseDirection {
                let dirName = dir.axisDirectionName(axis: axis)
                return "Scroll Step \(dirName)"
            }
            return "Mouse Wheel Step"
        case .midiNote:
            let note = midiNote ?? 60
            let ch = midiChannel ?? 1
            return "MIDI \(MIDIService.noteName(note)) · ch \(ch)"
        case .midiCC:
            let cc = midiCCNumber ?? 1
            let ch = midiChannel ?? 1
            return "MIDI CC \(cc) · ch \(ch)"
        case .midiPitchBend:
            let ch = midiChannel ?? 1
            return "MIDI Pitch Bend · ch \(ch)"
        case .midiProgramChange:
            let prog = midiProgramNumber ?? 0
            let ch = midiChannel ?? 1
            return "MIDI Program \(prog) · ch \(ch)"
        case .midiTransport:
            return "MIDI \(midiTransport?.displayName ?? "Start")"
        case .typeText:
            let t = text ?? ""
            if t.isEmpty { return "Type Text" }
            let preview = t.count > 18 ? String(t.prefix(18)) + "..." : t
            return "Type \"\(preview)\""
        case .appAction:
            return appActionKind?.displayName ?? "App Action"
        }
    }

    /// Serialize to original format: "key 26", "mbt 0", "mou 1 - 11", "whe 0 + 6", "whs 1 +"
    var serialized: String {
        switch type {
        case .key:
            return "key \(keyCode ?? 0)"
        case .mouseButton:
            return "mbt \(mouseButtonIndex ?? 0)"
        case .mouseMotion:
            let a = mouseAxis?.rawValue ?? 0
            let d = mouseDirection?.rawValue ?? "+"
            let s = speed ?? 6
            return "mou \(a) \(d) \(s)"
        case .mouseWheel:
            let a = mouseAxis?.rawValue ?? 0
            let d = mouseDirection?.rawValue ?? "+"
            let s = speed ?? 6
            return "whe \(a) \(d) \(s)"
        case .mouseWheelStep:
            let a = mouseAxis?.rawValue ?? 0
            let d = mouseDirection?.rawValue ?? "+"
            return "whs \(a) \(d)"
        case .midiNote:
            return "mni \(midiNote ?? 60) \(midiVelocity ?? 100) \(midiChannel ?? 1)"
        case .midiCC:
            return "mcc \(midiCCNumber ?? 1) \(midiCCValue ?? 127) \(midiChannel ?? 1)"
        case .midiPitchBend:
            return "mpb \(midiChannel ?? 1)"
        case .midiProgramChange:
            return "mpc \(midiProgramNumber ?? 0) \(midiChannel ?? 1)"
        case .midiTransport:
            return "mtr \(midiTransport?.rawValue ?? "start")"
        case .typeText:
            // Percent-encode so the space-delimited token format survives
            // arbitrary text (including spaces and quotes).
            let encoded = (text ?? "").addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
            return "txt \(encoded)"
        case .appAction:
            let kind = (appActionKind ?? .togglePauseOutputs).rawValue
            if appActionKind == .activatePreset, let target = targetPresetID {
                return "app \(kind) \(target.uuidString)"
            }
            return "app \(kind)"
        }
    }

    /// Parse from serialized format
    static func parse(_ string: String) -> OutputAction? {
        let parts = string.split(separator: " ").map(String.init)
        guard !parts.isEmpty else { return nil }

        switch parts[0] {
        case "key":
            guard parts.count >= 2, let code = Int(parts[1]) else { return nil }
            return OutputAction(type: .key, keyCode: code)
        case "mbt":
            guard parts.count >= 2, let btn = Int(parts[1]) else { return nil }
            return OutputAction(type: .mouseButton, mouseButtonIndex: btn)
        case "mou":
            guard parts.count >= 3,
                  let axisVal = Int(parts[1]),
                  let axis = MouseAxis(rawValue: axisVal) else { return nil }
            let dir = MouseDirection(rawValue: parts[2]) ?? .positive
            let spd = parts.count >= 4 ? Int(parts[3]) : nil
            return OutputAction(type: .mouseMotion, mouseAxis: axis, mouseDirection: dir, speed: spd)
        case "whe":
            guard parts.count >= 3,
                  let axisVal = Int(parts[1]),
                  let axis = MouseAxis(rawValue: axisVal) else { return nil }
            let dir = MouseDirection(rawValue: parts[2]) ?? .positive
            let spd = parts.count >= 4 ? Int(parts[3]) : nil
            return OutputAction(type: .mouseWheel, mouseAxis: axis, mouseDirection: dir, speed: spd)
        case "whs":
            guard parts.count >= 3,
                  let axisVal = Int(parts[1]),
                  let axis = MouseAxis(rawValue: axisVal) else { return nil }
            let dir = MouseDirection(rawValue: parts[2]) ?? .positive
            return OutputAction(type: .mouseWheelStep, mouseAxis: axis, mouseDirection: dir)
        case "mni":
            // mni <note> <velocity> <channel>
            guard parts.count >= 4,
                  let note = Int(parts[1]),
                  let vel = Int(parts[2]),
                  let ch = Int(parts[3]) else { return nil }
            return OutputAction(type: .midiNote, midiNote: note, midiVelocity: vel, midiChannel: ch)
        case "mcc":
            // mcc <ccNumber> <ccValue> <channel>
            guard parts.count >= 4,
                  let cc = Int(parts[1]),
                  let val = Int(parts[2]),
                  let ch = Int(parts[3]) else { return nil }
            return OutputAction(type: .midiCC, midiCCNumber: cc, midiCCValue: val, midiChannel: ch)
        case "mpb":
            // mpb <channel>
            guard parts.count >= 2, let ch = Int(parts[1]) else { return nil }
            return OutputAction(type: .midiPitchBend, midiChannel: ch)
        case "mpc":
            // mpc <program> <channel>
            guard parts.count >= 3,
                  let prog = Int(parts[1]),
                  let ch = Int(parts[2]) else { return nil }
            return OutputAction(type: .midiProgramChange, midiChannel: ch, midiProgramNumber: prog)
        case "mtr":
            // mtr <start|stop|continue>
            guard parts.count >= 2 else { return nil }
            let t = MIDITransport(rawValue: parts[1]) ?? .start
            return OutputAction(type: .midiTransport, midiTransport: t)
        case "txt":
            // txt <percent-encoded text>
            let decoded = parts.count >= 2 ? (parts[1].removingPercentEncoding ?? "") : ""
            return OutputAction(type: .typeText, text: decoded)
        case "app":
            // app <kind> [<target preset uuid>]
            guard parts.count >= 2, let kind = AppActionKind(rawValue: parts[1]) else { return nil }
            let target = parts.count >= 3 ? UUID(uuidString: parts[2]) : nil
            return OutputAction(type: .appAction, appActionKind: kind, targetPresetID: target)
        default:
            return nil
        }
    }

    // Custom coding to handle UUID stability
    enum CodingKeys: String, CodingKey {
        case id, type, keyCode, mouseButtonIndex, mouseAxis, mouseDirection, speed
        case midiNote, midiVelocity, midiCCNumber, midiCCValue, midiChannel
        case midiProgramNumber, midiTransport
        case text
        case appActionKind, targetPresetID
    }
}
