import Foundation

/// Represents an output action type
enum OutputType: String, Codable, CaseIterable, Identifiable {
    case key = "key"
    case mouseButton = "mbt"
    case mouseMotion = "mou"
    case mouseWheel = "whe"
    case mouseWheelStep = "whs"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .key: return "Keyboard Key"
        case .mouseButton: return "Mouse Button"
        case .mouseMotion: return "Mouse Motion"
        case .mouseWheel: return "Mouse Wheel"
        case .mouseWheelStep: return "Mouse Wheel Step"
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

/// Represents a single output action (keyboard key, mouse button, mouse movement, etc.)
struct OutputAction: Codable, Hashable, Identifiable {
    let id: UUID

    var type: OutputType
    var keyCode: Int?
    var mouseButtonIndex: Int?
    var mouseAxis: MouseAxis?
    var mouseDirection: MouseDirection?
    var speed: Int?

    init(type: OutputType, keyCode: Int? = nil, mouseButtonIndex: Int? = nil,
         mouseAxis: MouseAxis? = nil, mouseDirection: MouseDirection? = nil, speed: Int? = nil) {
        self.id = UUID()
        self.type = type
        self.keyCode = keyCode
        self.mouseButtonIndex = mouseButtonIndex
        self.mouseAxis = mouseAxis
        self.mouseDirection = mouseDirection
        self.speed = speed
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
        default:
            return nil
        }
    }

    // Custom coding to handle UUID stability
    enum CodingKeys: String, CodingKey {
        case id, type, keyCode, mouseButtonIndex, mouseAxis, mouseDirection, speed
    }
}
