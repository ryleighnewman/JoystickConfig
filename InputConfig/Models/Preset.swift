import Foundation

/// Per-preset light-bar color override. Stored as 0-255 RGB so it
/// round-trips through JSON without floating-point precision drift.
struct RGBLightColor: Codable, Hashable {
    var r: UInt8
    var g: UInt8
    var b: UInt8

    /// Helpers for SwiftUI's Color <-> bytes round-trip.
    var floatR: Float { Float(r) / 255 }
    var floatG: Float { Float(g) / 255 }
    var floatB: Float { Float(b) / 255 }

    init(r: UInt8, g: UInt8, b: UInt8) {
        self.r = r; self.g = g; self.b = b
    }

    init(floatR: Float, floatG: Float, floatB: Float) {
        self.r = UInt8(max(0, min(255, Int(floatR * 255))))
        self.g = UInt8(max(0, min(255, Int(floatG * 255))))
        self.b = UInt8(max(0, min(255, Int(floatB * 255))))
    }
}

/// Sensitivity curve for analog inputs
enum SensitivityCurve: String, Codable, CaseIterable, Identifiable {
    case linear = "linear"
    case exponential = "exponential"
    case aggressive = "aggressive"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .linear: return "Linear"
        case .exponential: return "Smooth"
        case .aggressive: return "Aggressive"
        }
    }

    func apply(_ value: Float) -> Float {
        switch self {
        case .linear: return value
        case .exponential: return value * value * (value > 0 ? 1 : -1)
        case .aggressive:
            let sign: Float = value >= 0 ? 1 : -1
            let abs = abs(value)
            return sign * sqrt(abs)
        }
    }
}

/// How a macro step treats its action: a full press-and-release tap (the
/// default), a press that stays held while later steps run, or the release
/// of an earlier held step. Hold and release kinds let one macro produce
/// chords like Cmd+C: Cmd hold down, C tap, Cmd release.
enum MacroStepKind: String, Codable, CaseIterable, Identifiable {
    case tap
    case down
    case up
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .tap: return "Tap"
        case .down: return "Hold down"
        case .up: return "Release"
        }
    }
}

/// A single step in a macro sequence
struct MacroStep: Identifiable, Codable, Hashable {
    let id: UUID
    var action: OutputAction      // What to do
    var delayMs: Int              // Delay BEFORE this step in milliseconds
    var holdMs: Int               // How long to hold (for press actions)
    var eventKind: MacroStepKind? // nil decodes as .tap, so old presets are unchanged

    init(action: OutputAction, delayMs: Int = 50, holdMs: Int = 50,
         eventKind: MacroStepKind? = nil) {
        self.id = UUID()
        self.action = action
        self.delayMs = delayMs
        self.holdMs = holdMs
        self.eventKind = eventKind
    }
}

/// Destination for spoken feedback when a binding fires
enum SpeechDestination: String, Codable, CaseIterable, Identifiable {
    case mac = "mac"
    case controller = "controller"
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .mac: return "Mac Speakers"
        case .controller: return "Controller Speaker"
        }
    }
}

/// A single input-to-output binding
struct BindingModel: Identifiable, Codable, Hashable {
    let id: UUID
    var input: InputEvent
    var outputs: [OutputAction]

    // Advanced options
    var deadzone: Float?         // Inner axis deadzone (0.0-0.9), nil = use default 0.25
                                 // Magnitudes below this are treated as zero.
    var outerDeadzone: Float?    // Optional outer/saturation deadzone (0.1-1.0). When set,
                                 // magnitudes ABOVE this clamp to full output. The active
                                 // range becomes [inner, outer] mapped linearly to [0, 1].
    var invertAxis: Bool?        // Invert axis direction
    var toggleMode: Bool?        // Toggle on/off instead of hold
    var turboEnabled: Bool?      // Rapid fire mode
    var turboRate: Int?          // Turbo presses per second (default 10)
    var sensitivityCurve: SensitivityCurve?  // Response curve for analog inputs
    var repeatCount: Int?        // Times to repeat outputs (nil or <= 1 fires once; > 1 repeats that many times)
    var repeatDelayMs: Int?      // Delay between repeats in ms (default 100)

    // Variable sensitivity: scale output magnitude by axis depth (0 to 1).
    // When false, the configured speed/value is used at full magnitude after the deadzone.
    var variableSensitivity: Bool?

    // Feedback options
    var hapticEnabled: Bool?     // Vibrate the controller when this binding fires
    var hapticIntensity: Float?  // 0.0 to 1.0, default 0.6
    var speechEnabled: Bool?     // Speak a phrase when this binding fires
    var speechText: String?      // Phrase to speak (defaults to the input name)
    var speechDestination: SpeechDestination?  // Where to play the speech

    // Macro sequence (overrides outputs when set)
    var macroSteps: [MacroStep]?

    /// When true, releasing the input stops the rest of a running macro
    /// chain and releases any held steps. nil decodes as false.
    var macroInterruptOnRelease: Bool?

    // Tap-vs-hold: when set, holding the input past holdThresholdMs fires
    // these outputs (released when the input releases); letting go sooner
    // fires `outputs` as a quick tap instead. nil keeps the plain immediate
    // behavior with zero added latency.
    var holdOutputs: [OutputAction]?
    var holdThresholdMs: Int?

    // Double-tap: when set, two presses inside doubleTapWindowMs fire these
    // outputs; a single tap fires `outputs` once the window lapses.
    var doubleTapOutputs: [OutputAction]?
    var doubleTapWindowMs: Int?

    /// Short, human-readable note describing what this binding does, shown in
    /// the editor row beneath the mapping (e.g. "Jump", "Sprint / hold to run").
    /// The Smart Preset Maker fills this in per-binding from the preset profile
    /// so every row explains itself, instead of one giant info dump on the
    /// preset's notes box. Optional + synthesized Codable means older preset
    /// files (no "note" key) decode with nil, so existing user presets that
    /// people created or edited are never lost on upgrade.
    var note: String?

    init(input: InputEvent, outputs: [OutputAction] = []) {
        self.id = UUID()
        self.input = input
        self.outputs = outputs
    }

    init(id: UUID = UUID(), input: InputEvent, outputs: [OutputAction],
         deadzone: Float? = nil, outerDeadzone: Float? = nil, invertAxis: Bool? = nil, toggleMode: Bool? = nil,
         turboEnabled: Bool? = nil, turboRate: Int? = nil, sensitivityCurve: SensitivityCurve? = nil,
         repeatCount: Int? = nil, repeatDelayMs: Int? = nil,
         variableSensitivity: Bool? = nil,
         hapticEnabled: Bool? = nil, hapticIntensity: Float? = nil,
         speechEnabled: Bool? = nil, speechText: String? = nil,
         speechDestination: SpeechDestination? = nil,
         macroSteps: [MacroStep]? = nil,
         macroInterruptOnRelease: Bool? = nil,
         holdOutputs: [OutputAction]? = nil,
         holdThresholdMs: Int? = nil,
         doubleTapOutputs: [OutputAction]? = nil,
         doubleTapWindowMs: Int? = nil,
         note: String? = nil) {
        self.id = id
        self.input = input
        self.outputs = outputs
        self.deadzone = deadzone
        self.outerDeadzone = outerDeadzone
        self.invertAxis = invertAxis
        self.toggleMode = toggleMode
        self.turboEnabled = turboEnabled
        self.turboRate = turboRate
        self.sensitivityCurve = sensitivityCurve
        self.repeatCount = repeatCount
        self.repeatDelayMs = repeatDelayMs
        self.variableSensitivity = variableSensitivity
        self.hapticEnabled = hapticEnabled
        self.hapticIntensity = hapticIntensity
        self.speechEnabled = speechEnabled
        self.speechText = speechText
        self.speechDestination = speechDestination
        self.macroSteps = macroSteps
        self.macroInterruptOnRelease = macroInterruptOnRelease
        self.holdOutputs = holdOutputs
        self.holdThresholdMs = holdThresholdMs
        self.doubleTapOutputs = doubleTapOutputs
        self.doubleTapWindowMs = doubleTapWindowMs
        self.note = note
    }

    /// Full-fidelity copy with a fresh identity. The plain
    /// `BindingModel(input:outputs:)` initializer zeroes every advanced
    /// field (deadzone, curve, toggle, turbo, repeat, haptics, speech,
    /// macro steps, note), which silently downgraded duplicated rows.
    func duplicated() -> BindingModel {
        BindingModel(id: UUID(), input: input, outputs: outputs,
                     deadzone: deadzone, outerDeadzone: outerDeadzone, invertAxis: invertAxis,
                     toggleMode: toggleMode, turboEnabled: turboEnabled, turboRate: turboRate,
                     sensitivityCurve: sensitivityCurve,
                     repeatCount: repeatCount, repeatDelayMs: repeatDelayMs,
                     variableSensitivity: variableSensitivity,
                     hapticEnabled: hapticEnabled, hapticIntensity: hapticIntensity,
                     speechEnabled: speechEnabled, speechText: speechText,
                     speechDestination: speechDestination,
                     macroSteps: macroSteps,
                     macroInterruptOnRelease: macroInterruptOnRelease,
                     holdOutputs: holdOutputs,
                     holdThresholdMs: holdThresholdMs,
                     doubleTapOutputs: doubleTapOutputs,
                     doubleTapWindowMs: doubleTapWindowMs,
                     note: note)
    }
}

/// Kind of input device a slot represents. Drives the Live Visualizer
/// layout: a slot whose `inputKind = .keyboard` swaps the controller
/// widgets for a keyboard-style chip layout, etc. `.auto` (default for
/// existing presets) infers from the bindings' type majority.
enum SlotInputKind: String, Codable, Hashable, CaseIterable {
    case auto       // pick layout from the bindings' types
    case controller // game controller widgets
    case keyboard   // bound-keys chip map
    case touchpad   // touchpad surface + regions + finger trails
    case mouse      // bound mouse buttons / axes
    case midi       // MIDI instrument: keys, knobs, wheels, event log
}

/// A joystick mapping group (one physical controller's bindings)
struct JoystickMapping: Identifiable, Codable, Hashable {
    let id: UUID
    var tag: String
    var bindings: [BindingModel]
    var isExpanded: Bool
    /// Optional user-provided name for this joystick slot, e.g.
    /// "Player 1 - Steve's controller". When set, takes priority over
    /// the auto-derived controller product name in the UI. nil = fall
    /// back to the connected controller's product name (e.g. "DualSense
    /// Wireless Controller") or "Joystick #N" if no controller is bound
    /// to that slot. Stored separately from `tag` (which is a free-form
    /// description / comment).
    var customName: String?
    /// Kind of input device this slot represents. Picking a keyboard /
    /// mouse / specific controller from the slot menu sets this so the
    /// Live Visualizer can swap to the matching layout. Defaults to
    /// `.auto` so existing preset files decode unchanged.
    var inputKind: SlotInputKind = .auto

    init(tag: String = "", bindings: [BindingModel] = [], isExpanded: Bool = true,
         customName: String? = nil, inputKind: SlotInputKind = .auto) {
        self.id = UUID()
        self.tag = tag
        self.bindings = bindings
        self.isExpanded = isExpanded
        self.customName = customName
        self.inputKind = inputKind
    }

    enum CodingKeys: String, CodingKey {
        case id, tag, bindings, isExpanded, customName, inputKind
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.tag = try c.decode(String.self, forKey: .tag)
        self.bindings = try c.decode([BindingModel].self, forKey: .bindings)
        self.isExpanded = try c.decode(Bool.self, forKey: .isExpanded)
        self.customName = try c.decodeIfPresent(String.self, forKey: .customName)
        self.inputKind = try c.decodeIfPresent(SlotInputKind.self, forKey: .inputKind) ?? .auto
    }
}

/// Per-preset automation: side effects that fire on preset activation
/// (auto-open an app) plus cursor utilities that only apply while the
/// preset is running (confine, recenter, hide). Lives on the preset so
/// each game / workflow gets its own choices; global Settings stays
/// out of the way.
struct PresetAutomation: Codable, Hashable {
    /// Posix path or bundle identifier of an app to launch when the
    /// preset activates. Empty string = no auto-launch. Examples:
    /// "/Applications/Steam.app", "com.valvesoftware.steam".
    var launchAppPath: String = ""
    /// Optional URL to open after launching the app (e.g. a steam://
    /// link to start a specific game). Empty = nothing.
    var launchURL: String = ""

    /// Confine the cursor away from screen edges while this preset
    /// runs. Same behaviour as the global CursorGuard toggle, just
    /// preset-scoped.
    var confineCursor: Bool = false
    var confineBufferPx: Double = 24

    /// Periodically warp the cursor back to the centre of its screen.
    var autoRecenterCursor: Bool = false
    var autoRecenterIntervalMs: Double = 500

    /// Hide the OS cursor for the duration of the preset.
    var hideCursorWhileActive: Bool = false

    /// Cursor sensitivity multiplier applied to mouse-move outputs the
    /// preset fires (independent of macOS pointer-speed slider).
    var sensitivityMultiplier: Double = 1.0

    /// Bundle identifiers of apps that automatically activate this preset
    /// when one of them comes to the front (gated by the global toggle in
    /// Settings). Optional, not defaulted, so preset files saved before
    /// this field existed decode unchanged.
    var autoActivateBundleIDs: [String]?
}

extension PresetAutomation {
    enum CodingKeys: String, CodingKey {
        case launchAppPath, launchURL, confineCursor, confineBufferPx
        case autoRecenterCursor, autoRecenterIntervalMs, hideCursorWhileActive
        case sensitivityMultiplier, autoActivateBundleIDs
    }

    /// Lenient decode: each field falls back to its default when missing.
    /// Swift's synthesized Decodable emits `decode` (not decodeIfPresent) for
    /// non-optional stored properties and throws keyNotFound on an absent key,
    /// which would take the whole Preset decode down and silently drop the
    /// preset from the sidebar. Adding one new automation field in a future
    /// build must never vanish a user's existing presets. Matches DriveConfig.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        var a = PresetAutomation()
        a.launchAppPath = try c.decodeIfPresent(String.self, forKey: .launchAppPath) ?? a.launchAppPath
        a.launchURL = try c.decodeIfPresent(String.self, forKey: .launchURL) ?? a.launchURL
        a.confineCursor = try c.decodeIfPresent(Bool.self, forKey: .confineCursor) ?? a.confineCursor
        a.confineBufferPx = try c.decodeIfPresent(Double.self, forKey: .confineBufferPx) ?? a.confineBufferPx
        a.autoRecenterCursor = try c.decodeIfPresent(Bool.self, forKey: .autoRecenterCursor) ?? a.autoRecenterCursor
        a.autoRecenterIntervalMs = try c.decodeIfPresent(Double.self, forKey: .autoRecenterIntervalMs) ?? a.autoRecenterIntervalMs
        a.hideCursorWhileActive = try c.decodeIfPresent(Bool.self, forKey: .hideCursorWhileActive) ?? a.hideCursorWhileActive
        a.sensitivityMultiplier = try c.decodeIfPresent(Double.self, forKey: .sensitivityMultiplier) ?? a.sensitivityMultiplier
        a.autoActivateBundleIDs = try c.decodeIfPresent([String].self, forKey: .autoActivateBundleIDs) ?? a.autoActivateBundleIDs
        self = a
    }
}

/// A complete preset containing name, tag, and joystick mappings
/// One-stick "drive" mapping: turns a single analog stick into a full
/// vehicle control scheme the way a power wheelchair drives from one
/// joystick. Stick X steers, stick Y is throttle forward and brake back,
/// and a gesture (snapping the stick to the back wall a few times) shifts
/// between Drive and Reverse. Output is keyboard + mouse, so variable
/// throttle on a binary key is produced by fast on/off pulsing (PWM): the
/// further you push, the larger the share of each pulse cycle the key is
/// held, which most keyboard-driveable games read as proportional speed.
///
/// Every field has a default so older preset files (which have no
/// `driveConfig` key at all) decode cleanly.
struct DriveConfig: Codable, Hashable {
    /// Master switch. When false the engine ignores the whole block.
    var enabled: Bool = false
    /// Controller slot (0-3) the drive stick lives on.
    var slot: Int = 0
    /// Axis indices on that controller: X steers, Y is throttle/brake.
    var steerAxis: Int = 0
    var throttleAxis: Int = 1
    /// Some sticks report "up" as negative; flip per stick.
    var invertSteer: Bool = false
    var invertThrottle: Bool = false
    /// Center deadzone applied to both axes (0-1).
    var deadzone: Double = 0.12

    enum SteerMode: String, Codable, CaseIterable, Identifiable {
        case mouse, keys
        var id: String { rawValue }
        var displayName: String { self == .mouse ? "Mouse (analog)" : "Keys (A / D)" }
    }
    /// Steering output: analog mouse-X (smooth) or left/right keys (pulsed).
    var steerMode: SteerMode = .mouse
    /// Mouse pixels per frame at full lock when steerMode == .mouse.
    var steerMouseSpeed: Double = 18
    /// HID usage codes for key steering (default A / D).
    var steerLeftKey: Int = 4
    var steerRightKey: Int = 7

    /// HID usage codes for motion. Default W accelerate, S brake.
    var accelKey: Int = 26
    var brakeKey: Int = 22
    /// Key used to move while in Reverse gear. Defaults to the brake key
    /// (S), which many games treat as reverse once stopped.
    var reverseKey: Int = 22
    /// Response curve exponent for throttle (1 = linear, >1 = gentler off
    /// center for fine low-speed control).
    var throttleCurve: Double = 1.0
    /// Response curve exponent for steering (1 = linear, >1 = gentle center,
    /// progressive lock toward the edges).
    var steerCurve: Double = 1.0
    /// When true the throttle axis is a unipolar trigger that rests at one
    /// end (its whole range maps to forward; there is no backward, so the
    /// reverse gesture is disabled). When false it is a centered stick.
    var throttleIsTrigger: Bool = false
    /// Optional active slow-down: while the stick sits centered in Drive,
    /// hold the brake lightly so the vehicle decelerates instead of coasting,
    /// the way a power wheelchair stops when you release the stick. Off by
    /// default. `coastBrakeStrength` is the held brake duty (0-1).
    var coastBrake: Bool = false
    var coastBrakeStrength: Double = 0.5
    /// PWM cycle length in poll ticks (at 120 Hz, 6 ticks = 20 Hz pulsing).
    var pwmPeriodTicks: Int = 6

    /// Reverse gesture: snap the stick fully back `reverseTapCount` times
    /// within `reverseWindowMs` to shift into Reverse; push fully forward to
    /// shift back to Drive. `gestureThreshold` is the fraction of full
    /// deflection that counts as hitting the "wall".
    var reverseGestureEnabled: Bool = true
    var reverseTapCount: Int = 2
    var reverseWindowMs: Int = 700
    var gestureThreshold: Double = 0.85
}

extension DriveConfig {
    enum CodingKeys: String, CodingKey {
        case enabled, slot, steerAxis, throttleAxis, invertSteer, invertThrottle
        case deadzone, steerMode, steerMouseSpeed, steerLeftKey, steerRightKey
        case accelKey, brakeKey, reverseKey, throttleCurve, pwmPeriodTicks
        case reverseGestureEnabled, reverseTapCount, reverseWindowMs, gestureThreshold
        case steerCurve, throttleIsTrigger, coastBrake, coastBrakeStrength
    }

    /// Lenient decode: every field falls back to its default when missing.
    /// Without this, a present-but-partial `driveConfig` object (hand-edited
    /// file or a forward/backward schema change) would throw and take the
    /// whole Preset decode down with it, silently dropping the preset. The
    /// default `init()` (all defaults) and memberwise init stay available
    /// because this lives in an extension. Matches the rest of the model.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        var d = DriveConfig()
        d.enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        d.slot = try c.decodeIfPresent(Int.self, forKey: .slot) ?? d.slot
        d.steerAxis = try c.decodeIfPresent(Int.self, forKey: .steerAxis) ?? d.steerAxis
        d.throttleAxis = try c.decodeIfPresent(Int.self, forKey: .throttleAxis) ?? d.throttleAxis
        d.invertSteer = try c.decodeIfPresent(Bool.self, forKey: .invertSteer) ?? d.invertSteer
        d.invertThrottle = try c.decodeIfPresent(Bool.self, forKey: .invertThrottle) ?? d.invertThrottle
        d.deadzone = try c.decodeIfPresent(Double.self, forKey: .deadzone) ?? d.deadzone
        d.steerMode = try c.decodeIfPresent(SteerMode.self, forKey: .steerMode) ?? d.steerMode
        d.steerMouseSpeed = try c.decodeIfPresent(Double.self, forKey: .steerMouseSpeed) ?? d.steerMouseSpeed
        d.steerLeftKey = try c.decodeIfPresent(Int.self, forKey: .steerLeftKey) ?? d.steerLeftKey
        d.steerRightKey = try c.decodeIfPresent(Int.self, forKey: .steerRightKey) ?? d.steerRightKey
        d.accelKey = try c.decodeIfPresent(Int.self, forKey: .accelKey) ?? d.accelKey
        d.brakeKey = try c.decodeIfPresent(Int.self, forKey: .brakeKey) ?? d.brakeKey
        d.reverseKey = try c.decodeIfPresent(Int.self, forKey: .reverseKey) ?? d.reverseKey
        d.throttleCurve = try c.decodeIfPresent(Double.self, forKey: .throttleCurve) ?? d.throttleCurve
        d.pwmPeriodTicks = try c.decodeIfPresent(Int.self, forKey: .pwmPeriodTicks) ?? d.pwmPeriodTicks
        d.reverseGestureEnabled = try c.decodeIfPresent(Bool.self, forKey: .reverseGestureEnabled) ?? d.reverseGestureEnabled
        d.reverseTapCount = try c.decodeIfPresent(Int.self, forKey: .reverseTapCount) ?? d.reverseTapCount
        d.reverseWindowMs = try c.decodeIfPresent(Int.self, forKey: .reverseWindowMs) ?? d.reverseWindowMs
        d.gestureThreshold = try c.decodeIfPresent(Double.self, forKey: .gestureThreshold) ?? d.gestureThreshold
        d.steerCurve = try c.decodeIfPresent(Double.self, forKey: .steerCurve) ?? d.steerCurve
        d.throttleIsTrigger = try c.decodeIfPresent(Bool.self, forKey: .throttleIsTrigger) ?? d.throttleIsTrigger
        d.coastBrake = try c.decodeIfPresent(Bool.self, forKey: .coastBrake) ?? d.coastBrake
        d.coastBrakeStrength = try c.decodeIfPresent(Double.self, forKey: .coastBrakeStrength) ?? d.coastBrakeStrength
        self = d
    }
}

struct Preset: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var tag: String
    var joysticks: [JoystickMapping]
    var filename: String
    var isActive: Bool
    var createdAt: Date
    var modifiedAt: Date
    /// Optional group this preset belongs to in the sidebar. `nil` means
    /// the preset shows in the default "Ungrouped" section. Codable safe -
    /// older preset files without this key just decode with `nil` here.
    var groupID: UUID?
    /// Free-form per-preset notes shown on the detail page. Stays empty
    /// unless the user writes something. Codable-optional so older preset
    /// files decode without the field.
    var notes: String = ""
    /// RGB light-bar color override stored as 0-255 components. When non-nil
    /// the mapping engine paints the controller's light bar with this color
    /// while the preset is active, and reverts to the slot's general color
    /// when the preset stops. Optional so older files decode cleanly.
    var lightBarColor: RGBLightColor?
    /// Brightness override applied alongside `lightBarColor` (0 = off,
    /// 1 = dim, 2 = bright). nil = inherit the slot's current brightness.
    var lightBarBrightness: Int?

    /// Per-preset automation: cursor confine + recenter, hide cursor,
    /// auto-open an application on activate. Lives on the preset (not
    /// global Settings) because these are inherently per-game choices -
    /// the cursor confinement for an FPS preset shouldn't follow you
    /// into a desktop-tool preset. Optional so older preset files
    /// decode cleanly with defaults.
    var automation: PresetAutomation = PresetAutomation()

    /// One-stick driving scheme for this preset. nil / disabled for the
    /// vast majority of presets; opt-in per game. Optional so older preset
    /// files decode cleanly.
    var driveConfig: DriveConfig?

    init(name: String = "New Preset", tag: String = "No tag", joysticks: [JoystickMapping] = [],
         filename: String = "", isActive: Bool = false, groupID: UUID? = nil) {
        self.id = UUID()
        self.name = name
        self.tag = tag
        self.joysticks = joysticks
        self.filename = filename.isEmpty ? Preset.generateFilename() : filename
        self.isActive = isActive
        self.createdAt = Date()
        self.modifiedAt = Date()
        self.groupID = groupID
    }

    enum CodingKeys: String, CodingKey {
        case id, name, tag, joysticks, filename, isActive, createdAt, modifiedAt
        case groupID, notes, lightBarColor, lightBarBrightness, automation, driveConfig
    }

    /// Custom Codable init so older preset files without `notes`,
    /// `lightBarColor`, or `lightBarBrightness` keys still decode cleanly
    /// (the synthesized Codable would otherwise require every key).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.name = try c.decode(String.self, forKey: .name)
        self.tag = try c.decode(String.self, forKey: .tag)
        self.joysticks = try c.decode([JoystickMapping].self, forKey: .joysticks)
        self.filename = try c.decode(String.self, forKey: .filename)
        self.isActive = try c.decode(Bool.self, forKey: .isActive)
        self.createdAt = try c.decode(Date.self, forKey: .createdAt)
        self.modifiedAt = try c.decode(Date.self, forKey: .modifiedAt)
        self.groupID = try c.decodeIfPresent(UUID.self, forKey: .groupID)
        self.notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        self.lightBarColor = try c.decodeIfPresent(RGBLightColor.self, forKey: .lightBarColor)
        self.lightBarBrightness = try c.decodeIfPresent(Int.self, forKey: .lightBarBrightness)
        self.automation = try c.decodeIfPresent(PresetAutomation.self, forKey: .automation)
            ?? PresetAutomation()
        self.driveConfig = try c.decodeIfPresent(DriveConfig.self, forKey: .driveConfig)
    }

    static func generateFilename() -> String {
        // Use a fresh UUID so two presets generated in the same second can't
        // collide on disk. Previously the format was "yyyyMMdd_HH-mm-ss.json",
        // which clobbered all-but-the-last-seeded preset during fresh-install
        // seeding (22 presets land within the same second).
        return UUID().uuidString + ".json"
    }

    /// Sort all bindings in all joystick groups alphabetically by
    /// input type then index. Every InputType must appear in the
    /// type-order table so new input categories (motion, touchpad,
    /// external key/mouse, cursor region, MIDI) don't all silently
    /// collapse to `0` and intermix with buttons in the editor list.
    /// Whether activating this preset produces any output: it has at least
    /// one binding, or one-stick driving is enabled. Menu-bar activation and
    /// the engine both gate on this, so a pure drive preset stays reachable.
    var isRunnable: Bool {
        joysticks.contains { !$0.bindings.isEmpty } || driveConfig?.enabled == true
    }

    mutating func sortBindings() {
        for i in joysticks.indices {
            joysticks[i].bindings.sort { a, b in
                let aType = Self.sortOrder(for: a.input.type)
                let bType = Self.sortOrder(for: b.input.type)
                if aType != bType { return aType < bType }
                return a.input.index < b.input.index
            }
        }
    }

    /// Authoritative type-sort order. Every InputType case is listed
    /// so the comparator never falls through to a default of 0.
    private static func sortOrder(for type: InputType) -> Int {
        switch type {
        case .button:          return 0
        case .axis:            return 1
        case .hat:             return 2
        case .touchpad:        return 3
        case .touchpadRegion:  return 4
        case .touchpadGesture: return 5
        case .motion:          return 6
        case .extKey:          return 7
        case .extMouse:        return 8
        case .cursorRegion:    return 9
        case .stickRegion:     return 10
        case .midi:            return 11
        }
    }
}

// MARK: - Legacy Format Support (Joystick Mapper JSON)

extension Preset {
    /// Parse from legacy Joystick Mapper JSON format
    static func fromLegacyJSON(_ data: Data, filename: String = "") -> Preset? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let name = json["name"] as? String ?? "Imported Preset"
        let tag = json["tag"] as? String ?? "No tag"

        var joystickMappings: [JoystickMapping] = []

        if let joysticks = json["joysticks"] as? [[String: Any]] {
            for joystick in joysticks {
                let joyTag = joystick["tag"] as? String ?? ""
                var bindings: [BindingModel] = []

                if let binds = joystick["binds"] as? [String: [String]] {
                    for (inputStr, outputStrs) in binds {
                        guard let input = InputEvent.parse(inputStr) else { continue }
                        let outputs = outputStrs.compactMap { OutputAction.parse($0) }
                        bindings.append(BindingModel(input: input, outputs: outputs))
                    }
                }

                // Sort bindings by type then index. Uses the same
                // authoritative order as sortBindings() so legacy
                // import doesn't end up with a different layout than
                // the editor would have produced.
                bindings.sort { a, b in
                    let aOrder = Self.sortOrder(for: a.input.type)
                    let bOrder = Self.sortOrder(for: b.input.type)
                    if aOrder != bOrder { return aOrder < bOrder }
                    return a.input.index < b.input.index
                }

                joystickMappings.append(JoystickMapping(tag: joyTag, bindings: bindings))
            }
        }

        return Preset(name: name, tag: tag, joysticks: joystickMappings, filename: filename)
    }

    /// Export to legacy Joystick Mapper JSON format
    func toLegacyJSON() -> Data? {
        var root: [String: Any] = [
            "name": name,
            "tag": tag,
        ]

        var joystickArray: [[String: Any]] = []
        for joystick in joysticks {
            var bindsDict: [String: [String]] = [:]

            for binding in joystick.bindings {
                let key = binding.input.serialized
                let values = binding.outputs.map { $0.serialized }
                if bindsDict[key] != nil {
                    bindsDict[key]?.append(contentsOf: values)
                } else {
                    bindsDict[key] = values
                }
            }

            joystickArray.append([
                "tag": joystick.tag,
                "binds": bindsDict,
            ])
        }

        root["joysticks"] = joystickArray

        return try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    }
}

// MARK: - Controller Type Conversion

/// Known controller types for preset conversion
enum ControllerType: String, CaseIterable, Identifiable {
    case xbox360 = "Xbox 360"
    case xboxOne = "Xbox One"
    case xboxSeries = "Xbox Series"
    case ps3 = "PS3"
    case ps4 = "PS4"
    case ps5 = "PS5"
    case switchPro = "Switch Pro"
    case generic = "Generic"

    var id: String { rawValue }

    /// Standard button/axis mapping for this controller type.
    /// Uses GCController extended gamepad indices.
    var standardMapping: [String: String] {
        let keys = ["a", "b", "x", "y", "lb", "rb", "lt", "rt",
                     "lclick", "rclick", "back", "start", "home",
                     "dpad_up", "dpad_down", "dpad_left", "dpad_right",
                     "ls_up", "ls_down", "ls_left", "ls_right",
                     "rs_up", "rs_down", "rs_left", "rs_right"]

        let values: [String]
        switch self {
        case .xbox360:
            values = ["btn 0", "btn 1", "btn 2", "btn 3",
                      "btn 4", "btn 5", "axi 4 +", "axi 5 +",
                      "btn 11", "btn 12", "btn 8", "btn 9", "btn 10",
                      "hat 0 U", "hat 0 D", "hat 0 L", "hat 0 R",
                      "axi 1 -", "axi 1 +", "axi 0 -", "axi 0 +",
                      "axi 3 -", "axi 3 +", "axi 2 -", "axi 2 +"]
        case .xboxOne, .xboxSeries:
            values = ["btn 0", "btn 1", "btn 2", "btn 3",
                      "btn 4", "btn 5", "axi 4 +", "axi 5 +",
                      "btn 11", "btn 12", "btn 8", "btn 9", "btn 10",
                      "hat 0 U", "hat 0 D", "hat 0 L", "hat 0 R",
                      "axi 1 -", "axi 1 +", "axi 0 -", "axi 0 +",
                      "axi 3 -", "axi 3 +", "axi 2 -", "axi 2 +"]
        case .ps3:
            values = ["btn 0", "btn 1", "btn 2", "btn 3",
                      "btn 4", "btn 5", "axi 4 +", "axi 5 +",
                      "btn 11", "btn 12", "btn 8", "btn 9", "btn 10",
                      "hat 0 U", "hat 0 D", "hat 0 L", "hat 0 R",
                      "axi 1 -", "axi 1 +", "axi 0 -", "axi 0 +",
                      "axi 3 -", "axi 3 +", "axi 2 -", "axi 2 +"]
        case .ps4, .ps5:
            // PS layout: Cross=btn0, Circle=btn1, Square=btn2, Triangle=btn3
            values = ["btn 0", "btn 1", "btn 2", "btn 3",
                      "btn 4", "btn 5", "axi 4 +", "axi 5 +",
                      "btn 11", "btn 12", "btn 8", "btn 9", "btn 10",
                      "hat 0 U", "hat 0 D", "hat 0 L", "hat 0 R",
                      "axi 1 -", "axi 1 +", "axi 0 -", "axi 0 +",
                      "axi 3 -", "axi 3 +", "axi 2 -", "axi 2 +"]
        case .switchPro:
            // Switch: B=btn0(confirm), A=btn1(cancel), Y=btn2, X=btn3
            values = ["btn 1", "btn 0", "btn 3", "btn 2",
                      "btn 4", "btn 5", "axi 4 +", "axi 5 +",
                      "btn 11", "btn 12", "btn 8", "btn 9", "btn 10",
                      "hat 0 U", "hat 0 D", "hat 0 L", "hat 0 R",
                      "axi 1 -", "axi 1 +", "axi 0 -", "axi 0 +",
                      "axi 3 -", "axi 3 +", "axi 2 -", "axi 2 +"]
        case .generic:
            values = ["btn 0", "btn 1", "btn 2", "btn 3",
                      "btn 4", "btn 5", "axi 4 +", "axi 5 +",
                      "btn 11", "btn 12", "btn 8", "btn 9", "btn 10",
                      "hat 0 U", "hat 0 D", "hat 0 L", "hat 0 R",
                      "axi 1 -", "axi 1 +", "axi 0 -", "axi 0 +",
                      "axi 3 -", "axi 3 +", "axi 2 -", "axi 2 +"]
        }

        var mapping: [String: String] = [:]
        for (key, value) in zip(keys, values) {
            mapping[key] = value
        }
        return mapping
    }

    /// Convert a preset from this controller type to another
    static func convert(preset: Preset, from source: ControllerType, to destination: ControllerType) -> Preset {
        let sourceMap = source.standardMapping
        let destMap = destination.standardMapping

        // Build reverse map: source input string -> standard key
        var reverseSource: [String: String] = [:]
        for (key, value) in sourceMap {
            reverseSource[value] = key
        }

        var converted = preset
        converted.name = preset.name
        converted.tag = "\(destination.rawValue) (converted from \(source.rawValue))"

        for i in converted.joysticks.indices {
            var newBindings: [BindingModel] = []
            for binding in converted.joysticks[i].bindings {
                let inputStr = binding.input.serialized
                if let standardKey = reverseSource[inputStr],
                   let destInputStr = destMap[standardKey],
                   let newInput = InputEvent.parse(destInputStr) {
                    newBindings.append(BindingModel(input: newInput, outputs: binding.outputs))
                } else {
                    // Keep unmapped bindings as-is
                    newBindings.append(binding)
                }
            }
            converted.joysticks[i].bindings = newBindings
        }

        return converted
    }
}


// MARK: - Preset Group

/// A user-named group of presets shown as a collapsible section in the
/// sidebar. Groups live in their own JSON file alongside the presets
/// directory so multiple presets can share a group without each preset
/// owning the metadata redundantly.
struct PresetGroup: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var sortOrder: Int
    var isExpanded: Bool
    /// User-pickable tint for the folder row in the sidebar. Stored as a
    /// stable name (matches `PresetGroup.colorOptions`) so it survives
    /// app updates and SwiftUI palette changes. nil means no tint, which
    /// renders as the neutral default.
    var color: String?
    /// Optional parent folder, enabling folders-inside-folders. nil means the
    /// folder is top-level. `sortOrder` orders siblings within the same
    /// parent. Optional + lenient Codable so older saves (no `parentID`)
    /// load as flat top-level folders, exactly as before.
    var parentID: UUID?

    init(id: UUID = UUID(), name: String, sortOrder: Int = 0,
         isExpanded: Bool = true, color: String? = nil, parentID: UUID? = nil) {
        self.id = id
        self.name = name
        self.sortOrder = sortOrder
        self.isExpanded = isExpanded
        self.color = color
        self.parentID = parentID
    }

    /// Lenient Codable so older saves (which don't have a `color` or
    /// `parentID` key) still load. New saves write them when set.
    enum CodingKeys: String, CodingKey {
        case id, name, sortOrder, isExpanded, color, parentID
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.name = try c.decode(String.self, forKey: .name)
        self.sortOrder = (try? c.decode(Int.self, forKey: .sortOrder)) ?? 0
        self.isExpanded = (try? c.decode(Bool.self, forKey: .isExpanded)) ?? true
        self.color = try? c.decode(String.self, forKey: .color)
        self.parentID = try? c.decode(UUID.self, forKey: .parentID)
    }

    /// Palette of named colors the user can pick from. Each entry maps
    /// to a SwiftUI Color via `PresetGroup.color(named:)`. Kept in the
    /// model so the picker UI doesn't need its own hard-coded list.
    static let colorOptions: [String] = [
        "blue", "purple", "pink", "red", "orange",
        "yellow", "green", "teal", "indigo", "brown"
    ]
}
