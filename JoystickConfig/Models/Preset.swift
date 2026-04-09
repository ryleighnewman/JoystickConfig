import Foundation

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

/// A single step in a macro sequence
struct MacroStep: Identifiable, Codable, Hashable {
    let id: UUID
    var action: OutputAction      // What to do
    var delayMs: Int              // Delay BEFORE this step in milliseconds
    var holdMs: Int               // How long to hold (for press actions)

    init(action: OutputAction, delayMs: Int = 50, holdMs: Int = 50) {
        self.id = UUID()
        self.action = action
        self.delayMs = delayMs
        self.holdMs = holdMs
    }
}

/// A single input-to-output binding
struct BindingModel: Identifiable, Codable, Hashable {
    let id: UUID
    var input: InputEvent
    var outputs: [OutputAction]

    // Advanced options
    var deadzone: Float?         // Custom axis deadzone (0.0-0.9), nil = use default 0.25
    var invertAxis: Bool?        // Invert axis direction
    var toggleMode: Bool?        // Toggle on/off instead of hold
    var turboEnabled: Bool?      // Rapid fire mode
    var turboRate: Int?          // Turbo presses per second (default 10)
    var sensitivityCurve: SensitivityCurve?  // Response curve for analog inputs
    var repeatCount: Int?        // Number of times to repeat outputs (nil = 1, 0 = infinite while held)
    var repeatDelayMs: Int?      // Delay between repeats in ms (default 100)

    // Macro sequence (overrides outputs when set)
    var macroSteps: [MacroStep]?

    init(input: InputEvent, outputs: [OutputAction] = []) {
        self.id = UUID()
        self.input = input
        self.outputs = outputs
    }

    init(id: UUID = UUID(), input: InputEvent, outputs: [OutputAction],
         deadzone: Float? = nil, invertAxis: Bool? = nil, toggleMode: Bool? = nil,
         turboEnabled: Bool? = nil, turboRate: Int? = nil, sensitivityCurve: SensitivityCurve? = nil,
         repeatCount: Int? = nil, repeatDelayMs: Int? = nil, macroSteps: [MacroStep]? = nil) {
        self.id = id
        self.input = input
        self.outputs = outputs
        self.deadzone = deadzone
        self.invertAxis = invertAxis
        self.toggleMode = toggleMode
        self.turboEnabled = turboEnabled
        self.turboRate = turboRate
        self.sensitivityCurve = sensitivityCurve
        self.repeatCount = repeatCount
        self.repeatDelayMs = repeatDelayMs
        self.macroSteps = macroSteps
    }
}

/// A joystick mapping group (one physical controller's bindings)
struct JoystickMapping: Identifiable, Codable, Hashable {
    let id: UUID
    var tag: String
    var bindings: [BindingModel]
    var isExpanded: Bool

    init(tag: String = "", bindings: [BindingModel] = [], isExpanded: Bool = true) {
        self.id = UUID()
        self.tag = tag
        self.bindings = bindings
        self.isExpanded = isExpanded
    }

    enum CodingKeys: String, CodingKey {
        case id, tag, bindings, isExpanded
    }
}

/// A complete preset containing name, tag, and joystick mappings
struct Preset: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var tag: String
    var joysticks: [JoystickMapping]
    var filename: String
    var isActive: Bool
    var createdAt: Date
    var modifiedAt: Date

    init(name: String = "New Preset", tag: String = "No tag", joysticks: [JoystickMapping] = [],
         filename: String = "", isActive: Bool = false) {
        self.id = UUID()
        self.name = name
        self.tag = tag
        self.joysticks = joysticks
        self.filename = filename.isEmpty ? Preset.generateFilename() : filename
        self.isActive = isActive
        self.createdAt = Date()
        self.modifiedAt = Date()
    }

    static func generateFilename() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HH-mm-ss"
        return formatter.string(from: Date()) + ".json"
    }

    /// Sort all bindings in all joystick groups alphabetically by input type then index
    mutating func sortBindings() {
        for i in joysticks.indices {
            joysticks[i].bindings.sort { a, b in
                let typeOrder: [InputType: Int] = [.button: 0, .axis: 1, .hat: 2]
                let aType = typeOrder[a.input.type] ?? 0
                let bType = typeOrder[b.input.type] ?? 0
                if aType != bType { return aType < bType }
                return a.input.index < b.input.index
            }
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

                // Sort bindings by type then index
                bindings.sort { a, b in
                    let typeOrder: [InputType: Int] = [.button: 0, .axis: 1, .hat: 2]
                    let aType = typeOrder[a.input.type] ?? 0
                    let bType = typeOrder[b.input.type] ?? 0
                    if aType != bType { return aType < bType }
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
