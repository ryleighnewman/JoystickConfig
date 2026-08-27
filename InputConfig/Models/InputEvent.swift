import Foundation

/// Represents a joystick input event type
enum InputType: String, Codable, CaseIterable, Identifiable {
    case button = "btn"
    case axis = "axi"
    case hat = "hat"
    /// Multi-touch trackpad surface on DualSense / DualShock 4. Reports
    /// per-frame X/Y deltas while a finger is in contact.
    case touchpad = "tpd"
    /// Tap on a user-defined region of the touchpad. Behaves like a button:
    /// pressed while any finger is inside the region, released on exit.
    case touchpadRegion = "tpr"
    /// Motion sensors (gyroscope + accelerometer). Behaves like a half-axis:
    /// tilt forward on the X axis yields a positive value, tilt backward
    /// yields a negative value. Available on controllers whose `motion`
    /// property is non-nil (DualSense, DualShock 4, Switch Pro, Joy-Con).
    case motion = "mtn"
    /// Key on an external keyboard (anything reported through IOHIDManager
    /// as a Generic Desktop / Keyboard usage). Behaves like a button; the
    /// HID usage code is stored in `index`.
    case extKey = "ekb"
    /// Button or axis on an external mouse. `extMouseKind` discriminates
    /// between button, scroll, and motion sub-roles. Motion / scroll
    /// behave as half-axes; button behaves like a button.
    case extMouse = "ems"
    /// A user-defined rectangular zone on the Mac display, evaluated
    /// against the cursor's current position. Same model as
    /// `.touchpadRegion` but the "finger" is the mouse cursor -
    /// lets a Mac trackpad / mouse user reuse the region-binding
    /// workflow without DualSense hardware.
    case cursorRegion = "crg"
    /// A user-defined rectangular zone on a joystick stick's X/Y
    /// plane. Lets the user bind diagonal/quadrant deflections
    /// directly (e.g. "stick pushed to upper-right corner") instead
    /// of having to combine separate axis + or axis - half-bindings.
    /// Index = stick index (0 = left, 1 = right).
    case stickRegion = "srg"
    /// Quick gesture on the controller's touchpad surface: two-finger
    /// tap, two-finger swipes, etc. Stored discriminator is in
    /// `touchpadGestureKind`. Behaves like a button - fires for one
    /// poll frame when the gesture is recognised.
    case touchpadGesture = "tpg"
    /// A message from an external MIDI device (keyboard, pad controller,
    /// knob box). Notes and pads behave like buttons; CC knobs, pitch
    /// bend, and aftertouch behave like analog axes. `index` carries the
    /// note or CC number, `midiChannel` the 1-16 channel (nil = any),
    /// and `midiKind` which message family it is.
    case midi = "mid"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .button: return "Button"
        case .axis: return "Axis"
        case .hat: return "Hat"
        case .touchpad: return "Touchpad"
        case .touchpadRegion: return "Touchpad Region"
        case .motion: return "Motion"
        case .extKey: return "Keyboard Key"
        case .extMouse: return "Mouse"
        case .cursorRegion: return "Cursor Region"
        case .stickRegion: return "Stick Region"
        case .touchpadGesture: return "Touchpad Gesture"
        case .midi: return "MIDI"
        }
    }
}

/// Recognised gesture kinds for an `.touchpadGesture` input. Detected
/// by `TouchpadService`'s gesture state machine - the model just stores
/// the discriminator.
enum TouchpadGestureKind: String, Codable, CaseIterable, Identifiable {
    /// Two fingers touch and lift within ~250 ms with very little
    /// movement on either contact. The most useful "modifier" gesture
    /// because it's instantly recognisable and doesn't conflict with
    /// scrolling / region taps.
    case twoFingerTap

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .twoFingerTap: return "Two-finger tap"
        }
    }
}

/// Which family of MIDI message an `.midi` input listens for.
enum MIDIInputKind: String, Codable, CaseIterable, Identifiable {
    /// Note on / off. Fires like a button while the key or pad is held.
    case note
    /// Control Change (knobs, sliders, sustain pedals, mod wheel).
    /// Continuous, so it can drive an axis as well as a threshold.
    case cc
    /// Pitch bend wheel. Centre-detented, so it reads as a bipolar axis.
    case pitchBend
    /// Program Change - fires momentarily like a button press.
    case programChange
    /// Channel aftertouch (pressure applied after the key is down).
    case aftertouch

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .note:          return "Note"
        case .cc:            return "Control Change"
        case .pitchBend:     return "Pitch Bend"
        case .programChange: return "Program Change"
        case .aftertouch:    return "Aftertouch"
        }
    }

    /// True when the message carries a continuous value that can drive an
    /// analog output (mouse motion, scroll) rather than only a press.
    var isContinuous: Bool {
        switch self {
        case .cc, .pitchBend, .aftertouch: return true
        case .note, .programChange:        return false
        }
    }

    /// True when the message has a per-message number (note number, CC
    /// number). Pitch bend and aftertouch are per-channel, so their
    /// number field is unused.
    var usesNumber: Bool {
        switch self {
        case .note, .cc, .programChange: return true
        case .pitchBend, .aftertouch:    return false
        }
    }
}

/// How a `.midi` Control Change binding interprets the knob or slider.
/// Only meaningful when `midiKind == .cc`; every other message family
/// ignores it.
enum MIDICCMode: String, Codable, CaseIterable, Identifiable {
    /// The 1.2 behaviour and the default: fires like a switch once the
    /// value passes the halfway point. Right for sustain pedals and
    /// on/off style CCs.
    case threshold
    /// Speed-from-centre: the knob's centre (64) is zero, distance from
    /// centre sets the output speed, side sets the direction, and the
    /// binding's deadzone keeps it silent near centre. Behaves like an
    /// analog stick axis, including variable-speed mouse and scroll.
    case centered
    /// Relative nudges: each turn fires the outputs as short pulses,
    /// clockwise for the + direction and counterclockwise for -. Built
    /// for volume-up/down, brightness, and stepped scrolling.
    case relative

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .threshold: return "Switch (past halfway)"
        case .centered:  return "Dial (speed from centre)"
        case .relative:  return "Turn (nudge per step)"
        }
    }

    /// Short badge used inside the row's display name.
    var badge: String? {
        switch self {
        case .threshold: return nil
        case .centered:  return "Dial"
        case .relative:  return "Turn"
        }
    }
}

/// Sub-role of an `.extMouse` input. Maps the same physical mouse onto
/// multiple bindable sources without exploding the InputType enum.
enum ExtMouseKind: String, Codable, CaseIterable, Identifiable {
    case button
    case moveX
    case moveY
    case scrollX
    case scrollY
    /// Force Touch trackpad pressure as a threshold input: fires while the
    /// press force is past the threshold. Mac trackpads report continuous
    /// pressure through NSEvent while pressed.
    case pressure
    /// Force Click (pressure stage 2): the deliberate deep press.
    case deepPress

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .button:  return "Button"
        case .moveX:   return "Move X"
        case .moveY:   return "Move Y"
        case .scrollX: return "Scroll X"
        case .scrollY: return "Scroll Y"
        case .pressure: return "Pressure (Force Touch)"
        case .deepPress: return "Deep Press"
        }
    }
}

/// Which motion-sensor channel a `.motion` input reads.
///
///   .gyroX        - rotation around the controller's X axis (pitch up/down)
///   .gyroY        - rotation around the Y axis (yaw left/right)
///   .gyroZ        - rotation around the Z axis (roll left/right)
///   .accelX/Y/Z   - linear acceleration on the matching axis (gravity removed)
///   .rollAngle    - absolute attitude roll (Euler)
///   .pitchAngle   - absolute attitude pitch
///   .yawAngle     - absolute attitude yaw
enum MotionChannel: String, Codable, CaseIterable, Identifiable {
    case gyroX
    case gyroY
    case gyroZ
    case accelX
    case accelY
    case accelZ
    case rollAngle
    case pitchAngle
    case yawAngle

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .gyroX:      return "Gyro X"
        case .gyroY:      return "Gyro Y"
        case .gyroZ:      return "Gyro Z"
        case .accelX:     return "Accel X"
        case .accelY:     return "Accel Y"
        case .accelZ:     return "Accel Z"
        case .rollAngle:  return "Roll angle"
        case .pitchAngle: return "Pitch angle"
        case .yawAngle:   return "Yaw angle"
        }
    }

    /// Fuller description used in the dropdown menu so the picker
    /// label stays short but the menu items remain self-explanatory.
    var menuDescription: String {
        switch self {
        case .gyroX:      return "Gyro X (pitch rate)"
        case .gyroY:      return "Gyro Y (yaw rate)"
        case .gyroZ:      return "Gyro Z (roll rate)"
        default:          return displayName
        }
    }
}

/// Which axis of the touchpad surface the binding follows. X moves horizontal,
/// Y moves vertical. Combined with `AxisDirection` to pick a half-axis.
enum TouchpadAxis: String, Codable, CaseIterable, Identifiable {
    case x = "x"
    case y = "y"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .x: return "X (left/right)"
        case .y: return "Y (up/down)"
        }
    }
}

/// Direction for axis inputs
enum AxisDirection: String, Codable, CaseIterable, Identifiable {
    case positive = "+"
    case negative = "-"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .positive: return "+"
        case .negative: return "-"
        }
    }
}

/// Direction for hat (D-pad) inputs
enum HatDirection: String, Codable, CaseIterable, Identifiable {
    case up = "U"
    case right = "R"
    case down = "D"
    case left = "L"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .up: return "Up"
        case .right: return "Right"
        case .down: return "Down"
        case .left: return "Left"
        }
    }
}

/// Represents a specific joystick input (button press, axis movement, or hat direction)
struct InputEvent: Codable, Hashable, Identifiable {
    var id: String { serialized }

    var type: InputType
    var index: Int
    var axisDirection: AxisDirection?
    var hatDirection: HatDirection?
    /// Touchpad finger index (0 = primary, 1 = secondary). Only valid for `.touchpad`.
    var touchpadFinger: Int?
    /// Touchpad axis (X or Y). Only valid for `.touchpad`.
    var touchpadAxis: TouchpadAxis?
    /// ID of the user-defined touchpad region. Only valid for `.touchpadRegion`.
    /// Serialized as a hex UUID string in the binding JSON.
    var touchpadRegionID: UUID?
    /// ID of the user-defined cursor region. Only valid for `.cursorRegion`.
    /// Same on-disk format as `touchpadRegionID` - kept on a separate
    /// field so the two region kinds don't collide in tooling.
    var cursorRegionID: UUID?
    /// Recognised touchpad gesture (two-finger tap, etc.). Only valid
    /// for `.touchpadGesture`. Stored as the raw enum string in JSON
    /// so older saves without the field decode as nil.
    var touchpadGestureKind: TouchpadGestureKind?
    /// Motion-sensor channel for `.motion` inputs.
    var motionChannel: MotionChannel?
    /// Stable ID of the external keyboard / mouse the binding listens to.
    /// `nil` means "any" matching device. Only valid for `.extKey` /
    /// `.extMouse`. Serialized as "any" when nil to keep the binding
    /// string portable across machines.
    var extDeviceID: String?
    /// Sub-role for `.extMouse` inputs.
    var extMouseKind: ExtMouseKind?
    /// ID of the user-defined stick region. Only valid for `.stickRegion`.
    /// Same on-disk format as `touchpadRegionID`; the stickIndex (left
    /// vs right stick) is carried in the InputEvent's `index` field.
    var stickRegionID: UUID?
    /// Which MIDI message family this input listens for. Only valid for
    /// `.midi`.
    var midiKind: MIDIInputKind?
    /// MIDI channel 1-16, or nil for "any channel". Only valid for `.midi`.
    var midiChannel: Int?
    /// Stable ID of the MIDI source endpoint this binding listens to.
    /// nil means "any connected MIDI device", which is the friendly
    /// default: a preset keeps working when the user plugs in a
    /// different keyboard. Only valid for `.midi`.
    var midiDeviceID: String?
    /// Knob interpretation for `.cc` bindings. nil decodes as
    /// `.threshold`, so presets saved before this field existed keep
    /// their exact behaviour.
    var midiCCMode: MIDICCMode?
    /// Turn-mode sensitivity: raw CC units of travel per nudge. nil means
    /// the default of 4 (a full knob sweep is about 32 nudges). Smaller
    /// is finer. Only meaningful when `midiCCMode == .relative`.
    var midiTurnStep: Int?

    var displayName: String {
        switch type {
        case .button:
            return "Button \(index)"
        case .axis:
            let dir = axisDirection?.displayName ?? "+"
            return "Axis \(index) \(dir)"
        case .hat:
            let dir = hatDirection?.displayName ?? "Up"
            return "Hat \(index) \(dir)"
        case .touchpad:
            let finger = (touchpadFinger ?? 0) + 1
            let axis = touchpadAxis?.rawValue.uppercased() ?? "X"
            let dir = axisDirection?.displayName ?? "+"
            return "Touchpad F\(finger) \(axis) \(dir)"
        case .touchpadRegion:
            // The region name lives in TouchpadService; we resolve it where
            // we have access (BindingRowView). The serialized id is enough
            // for storage but not human-friendly, so just show "Region".
            return "Touchpad Region"
        case .motion:
            let ch = motionChannel?.displayName ?? "Motion"
            let dir = axisDirection?.displayName ?? "+"
            return "\(ch) \(dir)"
        case .extKey:
            return "Key \(index)"
        case .extMouse:
            let kind = extMouseKind?.displayName ?? "Button"
            switch extMouseKind ?? .button {
            case .button:
                return "Mouse Button \(index)"
            case .moveX, .moveY, .scrollX, .scrollY:
                let dir = axisDirection?.displayName ?? "+"
                return "Mouse \(kind) \(dir)"
            case .pressure:
                return "Trackpad Pressure"
            case .deepPress:
                return "Trackpad Deep Press"
            }
        case .cursorRegion:
            // Like `.touchpadRegion`, the human name lives in the
            // CursorRegionService and is resolved in the binding row.
            return "Cursor Region"
        case .stickRegion:
            let stick = index == 1 ? "Right" : "Left"
            return "\(stick) Stick Region"
        case .touchpadGesture:
            return touchpadGestureKind?.displayName ?? "Touchpad Gesture"
        case .midi:
            let kind = midiKind ?? .note
            let chan = midiChannel.map { "ch\($0)" } ?? "any ch"
            switch kind {
            case .note:
                return "MIDI \(MIDIService.noteName(index)) (\(chan))"
            case .cc:
                let dir = axisDirection.map { " \($0.displayName)" } ?? ""
                let mode = (midiCCMode?.badge).map { " \($0)" } ?? ""
                return "MIDI CC \(index)\(mode)\(dir) (\(chan))"
            case .programChange:
                return "MIDI Program \(index) (\(chan))"
            case .pitchBend:
                let dir = axisDirection.map { " \($0.displayName)" } ?? ""
                return "MIDI Pitch Bend\(dir) (\(chan))"
            case .aftertouch:
                return "MIDI Aftertouch (\(chan))"
            }
        }
    }

    /// Serialize to the original Joystick Mapper format: "btn 0", "axi 1 +", "hat 0 U",
    /// plus our extension: "tpd <finger 0|1> <axis x|y> <dir + or ->".
    var serialized: String {
        switch type {
        case .button:
            return "btn \(index)"
        case .axis:
            return "axi \(index) \(axisDirection?.rawValue ?? "+")"
        case .hat:
            return "hat \(index) \(hatDirection?.rawValue ?? "U")"
        case .touchpad:
            let finger = touchpadFinger ?? 0
            let axis = touchpadAxis?.rawValue ?? "x"
            let dir = axisDirection?.rawValue ?? "+"
            return "tpd \(finger) \(axis) \(dir)"
        case .touchpadRegion:
            // Region UUIDs are stored as 32-char lowercase hex (no dashes)
            // to keep the binding key short. Missing IDs serialize to all-zeros.
            let raw = (touchpadRegionID ?? UUID(uuid: (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)))
                .uuidString.lowercased().replacingOccurrences(of: "-", with: "")
            return "tpr \(raw)"
        case .motion:
            let ch = motionChannel?.rawValue ?? "gyroY"
            let dir = axisDirection?.rawValue ?? "+"
            return "mtn \(ch) \(dir)"
        case .extKey:
            // "ekb <hid_code> <deviceID|any>"
            let dev = extDeviceID ?? "any"
            return "ekb \(index) \(dev)"
        case .extMouse:
            // "ems <kind> <indexOrZero> <dir> <deviceID|any>"
            let kind = (extMouseKind ?? .button).rawValue
            let dir = axisDirection?.rawValue ?? "+"
            let dev = extDeviceID ?? "any"
            return "ems \(kind) \(index) \(dir) \(dev)"
        case .cursorRegion:
            // "crg <32-char hex UUID>" - same format as .touchpadRegion's
            // "tpr" entry but lives in a separate namespace so the two
            // can't be confused at parse time.
            let raw = (cursorRegionID ?? UUID(uuid: (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)))
                .uuidString.lowercased().replacingOccurrences(of: "-", with: "")
            return "crg \(raw)"
        case .stickRegion:
            // "srg <stickIndex> <32-char hex UUID>"
            let raw = (stickRegionID ?? UUID(uuid: (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)))
                .uuidString.lowercased().replacingOccurrences(of: "-", with: "")
            return "srg \(index) \(raw)"
        case .touchpadGesture:
            // "tpg <kind>" e.g. "tpg twoFingerTap"
            return "tpg \(touchpadGestureKind?.rawValue ?? "twoFingerTap")"
        case .midi:
            // "mid <kind> <number> <channel|any> <dir> <deviceID|any>"
            // e.g. "mid note 60 any + any", "mid cc 74 1 + any"
            let kind = (midiKind ?? .note).rawValue
            let chan = midiChannel.map(String.init) ?? "any"
            let dir = axisDirection?.rawValue ?? "+"
            let dev = midiDeviceID ?? "any"
            // The mode token is appended only for non-default modes so the
            // serialized keys of every pre-existing binding stay identical.
            if let mode = midiCCMode, mode != .threshold {
                return "mid \(kind) \(index) \(chan) \(dir) \(dev) \(mode.rawValue)"
            }
            return "mid \(kind) \(index) \(chan) \(dir) \(dev)"
        }
    }

    /// Parse from serialized format
    static func parse(_ string: String) -> InputEvent? {
        let parts = string.split(separator: " ").map(String.init)
        guard parts.count >= 2 else { return nil }

        switch parts[0] {
        case "btn":
            guard let index = Int(parts[1]) else { return nil }
            return InputEvent(type: .button, index: index)
        case "axi":
            guard parts.count >= 3, let index = Int(parts[1]) else { return nil }
            let dir = AxisDirection(rawValue: parts[2]) ?? .positive
            return InputEvent(type: .axis, index: index, axisDirection: dir)
        case "hat":
            guard parts.count >= 3, let index = Int(parts[1]) else { return nil }
            let dir = HatDirection(rawValue: parts[2]) ?? .up
            return InputEvent(type: .hat, index: index, hatDirection: dir)
        case "tpd":
            guard parts.count >= 4,
                  let finger = Int(parts[1]),
                  let axis = TouchpadAxis(rawValue: parts[2]) else { return nil }
            let dir = AxisDirection(rawValue: parts[3]) ?? .positive
            return InputEvent(type: .touchpad, index: finger,
                              axisDirection: dir,
                              touchpadFinger: finger,
                              touchpadAxis: axis)
        case "tpr":
            guard parts.count >= 2 else { return nil }
            // Restore canonical UUID format from the 32-char compact form.
            let raw = parts[1]
            guard raw.count == 32 else { return nil }
            let dashed = "\(raw.prefix(8))-\(raw.dropFirst(8).prefix(4))-\(raw.dropFirst(12).prefix(4))-\(raw.dropFirst(16).prefix(4))-\(raw.dropFirst(20).prefix(12))"
            guard let uuid = UUID(uuidString: dashed.uppercased()) else { return nil }
            return InputEvent(type: .touchpadRegion, index: 0,
                              touchpadRegionID: uuid)
        case "mtn":
            guard parts.count >= 3,
                  let channel = MotionChannel(rawValue: parts[1]) else { return nil }
            let dir = AxisDirection(rawValue: parts[2]) ?? .positive
            return InputEvent(type: .motion, index: 0,
                              axisDirection: dir,
                              motionChannel: channel)
        case "ekb":
            // "ekb <hid_code> <deviceID|any>"
            guard parts.count >= 3, let code = Int(parts[1]) else { return nil }
            let device = parts[2] == "any" ? nil : parts[2]
            return InputEvent(type: .extKey, index: code, extDeviceID: device)
        case "ems":
            // "ems <kind> <indexOrZero> <dir> <deviceID|any>"
            guard parts.count >= 5,
                  let kind = ExtMouseKind(rawValue: parts[1]),
                  let idx = Int(parts[2]) else { return nil }
            let dir = AxisDirection(rawValue: parts[3]) ?? .positive
            let device = parts[4] == "any" ? nil : parts[4]
            return InputEvent(type: .extMouse, index: idx,
                              axisDirection: dir,
                              extDeviceID: device,
                              extMouseKind: kind)
        case "crg":
            // "crg <32-char hex UUID>"
            guard parts.count >= 2 else { return nil }
            let raw = parts[1]
            guard raw.count == 32 else { return nil }
            let dashed = "\(raw.prefix(8))-\(raw.dropFirst(8).prefix(4))-\(raw.dropFirst(12).prefix(4))-\(raw.dropFirst(16).prefix(4))-\(raw.dropFirst(20).prefix(12))"
            guard let uuid = UUID(uuidString: dashed.uppercased()) else { return nil }
            return InputEvent(type: .cursorRegion, index: 0,
                              cursorRegionID: uuid)
        case "srg":
            // "srg <stickIndex> <32-char hex UUID>"
            guard parts.count >= 3,
                  let stickIdx = Int(parts[1]) else { return nil }
            let raw = parts[2]
            guard raw.count == 32 else { return nil }
            let dashed = "\(raw.prefix(8))-\(raw.dropFirst(8).prefix(4))-\(raw.dropFirst(12).prefix(4))-\(raw.dropFirst(16).prefix(4))-\(raw.dropFirst(20).prefix(12))"
            guard let uuid = UUID(uuidString: dashed.uppercased()) else { return nil }
            return InputEvent(type: .stickRegion, index: stickIdx,
                              stickRegionID: uuid)
        case "tpg":
            // "tpg <kind>" e.g. "tpg twoFingerTap"
            guard parts.count >= 2,
                  let kind = TouchpadGestureKind(rawValue: parts[1]) else { return nil }
            return InputEvent(type: .touchpadGesture, index: 0,
                              touchpadGestureKind: kind)
        case "mid":
            // "mid <kind> <number> <channel|any> <dir> <deviceID|any>"
            guard parts.count >= 3,
                  let kind = MIDIInputKind(rawValue: parts[1]),
                  let number = Int(parts[2]) else { return nil }
            let channel: Int? = parts.count > 3 ? Int(parts[3]) : nil
            let dir: AxisDirection = (parts.count > 4
                ? AxisDirection(rawValue: parts[4]) : nil) ?? .positive
            let device: String? = (parts.count > 5 && parts[5] != "any") ? parts[5] : nil
            let ccMode: MIDICCMode? = parts.count > 6 ? MIDICCMode(rawValue: parts[6]) : nil
            return InputEvent(type: .midi, index: number,
                              axisDirection: dir,
                              midiKind: kind,
                              midiChannel: channel,
                              midiDeviceID: device,
                              midiCCMode: ccMode)
        default:
            return nil
        }
    }

    static func button(_ index: Int) -> InputEvent {
        InputEvent(type: .button, index: index)
    }

    static func axis(_ index: Int, direction: AxisDirection) -> InputEvent {
        InputEvent(type: .axis, index: index, axisDirection: direction)
    }

    static func hat(_ index: Int, direction: HatDirection) -> InputEvent {
        InputEvent(type: .hat, index: index, hatDirection: direction)
    }

    static func touchpad(finger: Int, axis: TouchpadAxis, direction: AxisDirection) -> InputEvent {
        InputEvent(type: .touchpad, index: finger,
                   axisDirection: direction,
                   touchpadFinger: finger,
                   touchpadAxis: axis)
    }

    static func touchpadRegion(_ id: UUID) -> InputEvent {
        InputEvent(type: .touchpadRegion, index: 0, touchpadRegionID: id)
    }

    static func cursorRegion(_ id: UUID) -> InputEvent {
        InputEvent(type: .cursorRegion, index: 0, cursorRegionID: id)
    }

    static func stickRegion(stickIndex: Int, id: UUID) -> InputEvent {
        InputEvent(type: .stickRegion, index: stickIndex, stickRegionID: id)
    }

    static func touchpadGesture(_ kind: TouchpadGestureKind) -> InputEvent {
        InputEvent(type: .touchpadGesture, index: 0, touchpadGestureKind: kind)
    }

    static func motion(_ channel: MotionChannel, direction: AxisDirection) -> InputEvent {
        InputEvent(type: .motion, index: 0,
                   axisDirection: direction, motionChannel: channel)
    }

    /// A MIDI input. `number` is the note or CC number (ignored for pitch
    /// bend and aftertouch, which are per-channel). `channel` nil means any.
    static func midi(_ kind: MIDIInputKind,
                     number: Int,
                     channel: Int? = nil,
                     direction: AxisDirection = .positive,
                     deviceID: String? = nil,
                     ccMode: MIDICCMode? = nil) -> InputEvent {
        InputEvent(type: .midi, index: number,
                   axisDirection: direction,
                   midiKind: kind,
                   midiChannel: channel,
                   midiDeviceID: deviceID,
                   midiCCMode: ccMode)
    }

    static func extKey(hidCode: Int, deviceID: String? = nil) -> InputEvent {
        InputEvent(type: .extKey, index: hidCode, extDeviceID: deviceID)
    }

    static func extMouseButton(_ button: Int, deviceID: String? = nil) -> InputEvent {
        InputEvent(type: .extMouse, index: button,
                   extDeviceID: deviceID, extMouseKind: .button)
    }

    static func extMouseMotion(_ kind: ExtMouseKind,
                               direction: AxisDirection,
                               deviceID: String? = nil) -> InputEvent {
        InputEvent(type: .extMouse, index: 0,
                   axisDirection: direction,
                   extDeviceID: deviceID,
                   extMouseKind: kind)
    }
}
