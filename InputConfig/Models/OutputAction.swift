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
    /// Absolute system volume: the Mac's output level follows the bound
    /// input's position 1-to-1. Built for continuous sources - a MIDI
    /// knob, the pitch wheel, aftertouch, or a controller trigger. Unlike
    /// the volume KEYS, which nudge in steps, this is a fader.
    case absoluteVolume = "avl"
    /// A named system function: volume nudges, media keys, brightness,
    /// Mission Control, lock screen, a Siri Shortcut, opening an app or
    /// URL. Fires on press; the specific function lives in
    /// `systemActionKind` with an optional string parameter in `text`.
    case systemAction = "sys"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .key: return "Keyboard Key"
        case .typeText: return "Type Text"
        case .appAction: return "App Action"
        case .absoluteVolume: return "System Volume (follows input)"
        case .systemAction: return "System Function"
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

/// A system-level function a binding can trigger. Grouped for the picker:
/// sound, media, display, Mac shortcuts, and automation. The three
/// automation kinds carry a string parameter (shortcut name, app name or
/// path, URL) in the output's `text` field.
enum SystemActionKind: String, Codable, CaseIterable, Identifiable {
    // Sound
    case volumeUp = "vup"
    case volumeDown = "vdn"
    case muteToggle = "mut"
    // Media
    case playPause = "ply"
    case nextTrack = "nxt"
    case previousTrack = "prv"
    // Display
    case brightnessUp = "bup"
    case brightnessDown = "bdn"
    // Mac
    case missionControl = "mct"
    case launchpad = "lpd"
    case spotlight = "spt"
    case lockScreen = "lck"
    case screenshotMenu = "scr"
    // Automation
    case runShortcut = "sct"
    case openApp = "opa"
    case openURL = "our"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .volumeUp: return "Volume Up"
        case .volumeDown: return "Volume Down"
        case .muteToggle: return "Mute / Unmute"
        case .playPause: return "Play / Pause"
        case .nextTrack: return "Next Track"
        case .previousTrack: return "Previous Track"
        case .brightnessUp: return "Brightness Up"
        case .brightnessDown: return "Brightness Down"
        case .missionControl: return "Mission Control"
        case .launchpad: return "Launchpad"
        case .spotlight: return "Spotlight Search"
        case .lockScreen: return "Lock Screen"
        case .screenshotMenu: return "Screenshot Menu"
        case .runShortcut: return "Run Siri Shortcut"
        case .openApp: return "Open App"
        case .openURL: return "Open URL"
        }
    }

    /// True when the kind needs a user-supplied string parameter.
    var needsParameter: Bool {
        switch self {
        case .runShortcut, .openApp, .openURL: return true
        default: return false
        }
    }

    var iconName: String {
        switch self {
        case .volumeUp: return "speaker.plus.fill"
        case .volumeDown: return "speaker.minus.fill"
        case .muteToggle: return "speaker.slash.fill"
        case .playPause: return "playpause.fill"
        case .nextTrack: return "forward.fill"
        case .previousTrack: return "backward.fill"
        case .brightnessUp: return "sun.max.fill"
        case .brightnessDown: return "sun.min.fill"
        case .missionControl: return "rectangle.3.group.fill"
        case .launchpad: return "square.grid.3x3.fill"
        case .spotlight: return "magnifyingglass"
        case .lockScreen: return "lock.fill"
        case .screenshotMenu: return "camera.viewfinder"
        case .runShortcut: return "sparkles.rectangle.stack.fill"
        case .openApp: return "arrow.up.forward.app.fill"
        case .openURL: return "safari.fill"
        }
    }

    /// Section header the kind appears under in the output picker.
    var category: String {
        switch self {
        case .volumeUp, .volumeDown, .muteToggle: return "Sound"
        case .playPause, .nextTrack, .previousTrack: return "Media"
        case .brightnessUp, .brightnessDown: return "Display"
        case .missionControl, .launchpad, .spotlight, .lockScreen, .screenshotMenu: return "Mac"
        case .runShortcut, .openApp, .openURL: return "Automation"
        }
    }

    /// Picker order, grouped by category.
    static let grouped: [(category: String, kinds: [SystemActionKind])] = [
        ("Sound", [.volumeUp, .volumeDown, .muteToggle]),
        ("Media", [.playPause, .nextTrack, .previousTrack]),
        ("Display", [.brightnessUp, .brightnessDown]),
        ("Mac", [.missionControl, .launchpad, .spotlight, .lockScreen, .screenshotMenu]),
        ("Automation", [.runShortcut, .openApp, .openURL]),
    ]
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

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .activatePreset: return "Activate Preset"
        case .nextPreset: return "Next Preset"
        case .previousPreset: return "Previous Preset"
        case .deactivate: return "Deactivate"
        case .togglePauseOutputs: return "Pause / Resume Outputs"
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

    /// Which system function a .systemAction output performs. The
    /// parameter for Run Shortcut / Open App / Open URL rides in `text`.
    var systemActionKind: SystemActionKind?

    init(type: OutputType, keyCode: Int? = nil, mouseButtonIndex: Int? = nil,
         mouseAxis: MouseAxis? = nil, mouseDirection: MouseDirection? = nil, speed: Int? = nil,
         midiNote: Int? = nil, midiVelocity: Int? = nil,
         midiCCNumber: Int? = nil, midiCCValue: Int? = nil,
         midiChannel: Int? = nil,
         midiProgramNumber: Int? = nil,
         midiTransport: MIDITransport? = nil,
         text: String? = nil,
         appActionKind: AppActionKind? = nil,
         targetPresetID: UUID? = nil,
         systemActionKind: SystemActionKind? = nil) {
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
        self.systemActionKind = systemActionKind
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
        case .absoluteVolume:
            return "System Volume"
        case .systemAction:
            guard let kind = systemActionKind else { return "System Function" }
            if kind.needsParameter, let t = text, !t.isEmpty {
                let preview = t.count > 18 ? String(t.prefix(18)) + "..." : t
                return "\(kind.displayName): \(preview)"
            }
            return kind.displayName
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
        case .absoluteVolume:
            return "avl"
        case .systemAction:
            let kind = (systemActionKind ?? .playPause).rawValue
            if let t = text, !t.isEmpty {
                let encoded = t.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
                return "sys \(kind) \(encoded)"
            }
            return "sys \(kind)"
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
        case "avl":
            return OutputAction(type: .absoluteVolume)
        case "sys":
            guard parts.count >= 2, let kind = SystemActionKind(rawValue: parts[1]) else { return nil }
            let param = parts.count >= 3 ? parts[2].removingPercentEncoding : nil
            return OutputAction(type: .systemAction, text: param, systemActionKind: kind)
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
        case systemActionKind
    }
}
