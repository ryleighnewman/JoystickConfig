import Foundation

/// Maps HID usage codes to human-readable key names
/// Based on the original Joystick Mapper's key code table
struct KeyCodeMap {
    struct KeyEntry: Identifiable {
        let id: Int
        let code: Int
        let name: String
        let group: String

        init(code: Int, name: String, group: String) {
            self.id = code
            self.code = code
            self.name = name
            self.group = group
        }
    }

    static let allKeys: [KeyEntry] = {
        var keys: [KeyEntry] = []

        // Letter Keys
        let letters = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
        for (i, char) in letters.enumerated() {
            keys.append(KeyEntry(code: 4 + i, name: String(char), group: "Letter Keys"))
        }

        // Number Keys
        for i in 1...9 {
            keys.append(KeyEntry(code: 29 + i, name: "\(i)", group: "Number Keys"))
        }
        keys.append(KeyEntry(code: 39, name: "0", group: "Number Keys"))

        // Other Characters
        keys.append(contentsOf: [
            KeyEntry(code: 45, name: "-", group: "Other Characters"),
            KeyEntry(code: 46, name: "=", group: "Other Characters"),
            KeyEntry(code: 47, name: "[", group: "Other Characters"),
            KeyEntry(code: 48, name: "]", group: "Other Characters"),
            KeyEntry(code: 49, name: "\\", group: "Other Characters"),
            KeyEntry(code: 50, name: "#", group: "Other Characters"),
            KeyEntry(code: 51, name: ";", group: "Other Characters"),
            KeyEntry(code: 52, name: "'", group: "Other Characters"),
            KeyEntry(code: 53, name: "`", group: "Other Characters"),
            KeyEntry(code: 54, name: ",", group: "Other Characters"),
            KeyEntry(code: 55, name: ".", group: "Other Characters"),
            KeyEntry(code: 56, name: "/", group: "Other Characters"),
        ])

        // Arrow Keys
        keys.append(contentsOf: [
            KeyEntry(code: 79, name: "Right", group: "Arrow Keys"),
            KeyEntry(code: 80, name: "Left", group: "Arrow Keys"),
            KeyEntry(code: 81, name: "Down", group: "Arrow Keys"),
            KeyEntry(code: 82, name: "Up", group: "Arrow Keys"),
        ])

        // Modifier Keys
        keys.append(contentsOf: [
            KeyEntry(code: 227, name: "Command (Left)", group: "Modifier Keys"),
            KeyEntry(code: 231, name: "Command (Right)", group: "Modifier Keys"),
            KeyEntry(code: 225, name: "Shift (Left)", group: "Modifier Keys"),
            KeyEntry(code: 229, name: "Shift (Right)", group: "Modifier Keys"),
            KeyEntry(code: 226, name: "Alt / Option (Left)", group: "Modifier Keys"),
            KeyEntry(code: 230, name: "Alt / Option (Right)", group: "Modifier Keys"),
            KeyEntry(code: 224, name: "Ctrl (Left)", group: "Modifier Keys"),
            KeyEntry(code: 228, name: "Ctrl (Right)", group: "Modifier Keys"),
        ])

        // Other Keys
        keys.append(contentsOf: [
            KeyEntry(code: 44, name: "Space", group: "Other Keys"),
            KeyEntry(code: 40, name: "Return", group: "Other Keys"),
            KeyEntry(code: 41, name: "Escape", group: "Other Keys"),
            KeyEntry(code: 42, name: "Backspace", group: "Other Keys"),
            KeyEntry(code: 43, name: "Tab", group: "Other Keys"),
            KeyEntry(code: 73, name: "Insert", group: "Other Keys"),
            KeyEntry(code: 74, name: "Home", group: "Other Keys"),
            KeyEntry(code: 75, name: "PageUp", group: "Other Keys"),
            KeyEntry(code: 76, name: "Delete", group: "Other Keys"),
            KeyEntry(code: 77, name: "End", group: "Other Keys"),
            KeyEntry(code: 78, name: "PageDown", group: "Other Keys"),
            KeyEntry(code: 57, name: "Caps Lock", group: "Other Keys"),
            KeyEntry(code: 70, name: "PrintScreen", group: "Other Keys"),
            KeyEntry(code: 101, name: "Application", group: "Other Keys"),
        ])

        // Function Keys
        for i in 1...12 {
            keys.append(KeyEntry(code: 57 + i, name: "F\(i)", group: "Function Keys"))
        }
        for i in 13...24 {
            keys.append(KeyEntry(code: 91 + i, name: "F\(i)", group: "Function Keys"))
        }

        // Keypad Keys
        keys.append(contentsOf: [
            KeyEntry(code: 83, name: "Numlock", group: "Keypad Keys"),
            KeyEntry(code: 84, name: "Keypad /", group: "Keypad Keys"),
            KeyEntry(code: 85, name: "Keypad *", group: "Keypad Keys"),
            KeyEntry(code: 86, name: "Keypad -", group: "Keypad Keys"),
            KeyEntry(code: 87, name: "Keypad +", group: "Keypad Keys"),
            KeyEntry(code: 88, name: "Keypad Enter", group: "Keypad Keys"),
            KeyEntry(code: 89, name: "Keypad 1", group: "Keypad Keys"),
            KeyEntry(code: 90, name: "Keypad 2", group: "Keypad Keys"),
            KeyEntry(code: 91, name: "Keypad 3", group: "Keypad Keys"),
            KeyEntry(code: 92, name: "Keypad 4", group: "Keypad Keys"),
            KeyEntry(code: 93, name: "Keypad 5", group: "Keypad Keys"),
            KeyEntry(code: 94, name: "Keypad 6", group: "Keypad Keys"),
            KeyEntry(code: 95, name: "Keypad 7", group: "Keypad Keys"),
            KeyEntry(code: 96, name: "Keypad 8", group: "Keypad Keys"),
            KeyEntry(code: 97, name: "Keypad 9", group: "Keypad Keys"),
            KeyEntry(code: 98, name: "Keypad 0", group: "Keypad Keys"),
            KeyEntry(code: 99, name: "Keypad .", group: "Keypad Keys"),
            KeyEntry(code: 103, name: "Keypad =", group: "Keypad Keys"),
            KeyEntry(code: 133, name: "Keypad ,", group: "Keypad Keys"),
        ])

        // Special / Media Keys
        keys.append(contentsOf: [
            KeyEntry(code: 71, name: "Brightness Down", group: "Special Keys"),
            KeyEntry(code: 72, name: "Brightness Up", group: "Special Keys"),
            KeyEntry(code: 303, name: "Dashboard/Launchpad", group: "Special Keys"),
            KeyEntry(code: 304, name: "Mission Control", group: "Special Keys"),
            KeyEntry(code: 305, name: "Keyboard Light Down", group: "Special Keys"),
            KeyEntry(code: 306, name: "Keyboard Light Up", group: "Special Keys"),
            KeyEntry(code: 307, name: "Rewind Track", group: "Special Keys"),
            KeyEntry(code: 308, name: "Play Audio Track", group: "Special Keys"),
            KeyEntry(code: 309, name: "Fast Forward Track", group: "Special Keys"),
            KeyEntry(code: 310, name: "Mute Sound", group: "Special Keys"),
            KeyEntry(code: 311, name: "Volume Up", group: "Special Keys"),
            KeyEntry(code: 312, name: "Volume Down", group: "Special Keys"),
            KeyEntry(code: 313, name: "Eject", group: "Special Keys"),
        ])

        return keys
    }()

    /// All unique group names in order
    static let groups: [String] = {
        var seen = Set<String>()
        var result: [String] = []
        for key in allKeys {
            if !seen.contains(key.group) {
                seen.insert(key.group)
                result.append(key.group)
            }
        }
        return result
    }()

    /// Keys grouped by category
    static let keysByGroup: [String: [KeyEntry]] = {
        Dictionary(grouping: allKeys, by: { $0.group })
    }()

    private static let codeToName: [Int: String] = {
        Dictionary(uniqueKeysWithValues: allKeys.map { ($0.code, $0.name) })
    }()

    static func name(for code: Int) -> String {
        codeToName[code] ?? "Key \(code)"
    }

    static func code(for name: String) -> Int? {
        allKeys.first(where: { $0.name == name })?.code
    }

    /// HID usage code to macOS virtual key code mapping (for CGEvent)
    /// This maps the HID codes used in presets to the macOS virtual key codes needed for CGEvent
    static let hidToVirtualKeyCode: [Int: Int] = [
        4: 0x00,   // A
        5: 0x0B,   // B
        6: 0x08,   // C
        7: 0x02,   // D
        8: 0x0E,   // E
        9: 0x03,   // F
        10: 0x05,  // G
        11: 0x04,  // H
        12: 0x22,  // I
        13: 0x26,  // J
        14: 0x28,  // K
        15: 0x25,  // L
        16: 0x2E,  // M
        17: 0x2D,  // N
        18: 0x1F,  // O
        19: 0x23,  // P
        20: 0x0C,  // Q
        21: 0x0F,  // R
        22: 0x01,  // S
        23: 0x11,  // T
        24: 0x20,  // U
        25: 0x09,  // V
        26: 0x0D,  // W
        27: 0x07,  // X
        28: 0x10,  // Y
        29: 0x06,  // Z
        30: 0x12,  // 1
        31: 0x13,  // 2
        32: 0x14,  // 3
        33: 0x15,  // 4
        34: 0x17,  // 5
        35: 0x16,  // 6
        36: 0x1A,  // 7
        37: 0x1C,  // 8
        38: 0x19,  // 9
        39: 0x1D,  // 0
        40: 0x24,  // Return
        41: 0x35,  // Escape
        42: 0x33,  // Backspace
        43: 0x30,  // Tab
        44: 0x31,  // Space
        45: 0x1B,  // -
        46: 0x18,  // =
        47: 0x21,  // [
        48: 0x1E,  // ]
        49: 0x2A,  // backslash
        51: 0x29,  // ;
        52: 0x27,  // '
        53: 0x32,  // `
        54: 0x2B,  // ,
        55: 0x2F,  // .
        56: 0x2C,  // /
        57: 0x39,  // Caps Lock
        58: 0x7A,  // F1
        59: 0x78,  // F2
        60: 0x63,  // F3
        61: 0x76,  // F4
        62: 0x60,  // F5
        63: 0x61,  // F6
        64: 0x62,  // F7
        65: 0x64,  // F8
        66: 0x65,  // F9
        67: 0x6D,  // F10
        68: 0x67,  // F11
        69: 0x6F,  // F12
        74: 0x73,  // Home
        75: 0x74,  // PageUp
        76: 0x75,  // Delete (forward)
        77: 0x77,  // End
        78: 0x79,  // PageDown
        79: 0x7C,  // Right
        80: 0x7B,  // Left
        81: 0x7D,  // Down
        82: 0x7E,  // Up
        224: 0x3B, // Ctrl Left
        225: 0x38, // Shift Left
        226: 0x3A, // Option Left
        227: 0x37, // Command Left
        228: 0x3E, // Ctrl Right
        229: 0x3C, // Shift Right
        230: 0x3D, // Option Right
        231: 0x36, // Command Right
    ]
}
