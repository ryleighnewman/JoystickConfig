import Foundation

/// Represents a joystick input event type
enum InputType: String, Codable, CaseIterable, Identifiable {
    case button = "btn"
    case axis = "axi"
    case hat = "hat"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .button: return "Button"
        case .axis: return "Axis"
        case .hat: return "Hat"
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
        }
    }

    /// Serialize to the original Joystick Mapper format: "btn 0", "axi 1 +", "hat 0 U"
    var serialized: String {
        switch type {
        case .button:
            return "btn \(index)"
        case .axis:
            return "axi \(index) \(axisDirection?.rawValue ?? "+")"
        case .hat:
            return "hat \(index) \(hatDirection?.rawValue ?? "U")"
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
}
