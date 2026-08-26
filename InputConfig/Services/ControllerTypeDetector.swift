import Foundation
import GameController

/// Identifies the brand and family of a connected controller from the
/// information exposed by GameController. Used to display familiar button
/// labels (Nintendo, PlayStation, Xbox layouts) and to drive controller-
/// specific help links.
enum ControllerBrand: String, CaseIterable {
    case dualSense       // PS5 DualSense and DualSense Edge
    case dualShock4      // PS4 DualShock 4
    case xbox            // Xbox One, Series S/X, Elite
    case switchPro       // Nintendo Switch Pro Controller
    case joyConLeft      // Single Joy-Con (left)
    case joyConRight     // Single Joy-Con (right)
    case joyConPair      // Two Joy-Cons fused as one virtual controller (iOS 16+/macOS 13+)
    case stadia          // Google Stadia controller
    case eightBitDo      // 8BitDo Pro 2, Ultimate, SN30, etc. in Apple mode
    case steamController // Valve Steam Controller (read via raw HID, NOT MFi)
    case mfiGeneric      // Generic MFi gamepad
    case unknown

    var displayName: String {
        switch self {
        case .dualSense:   return "DualSense"
        case .dualShock4:  return "DualShock 4"
        case .xbox:        return "Xbox"
        case .switchPro:   return "Switch Pro"
        case .joyConLeft:  return "Joy-Con (L)"
        case .joyConRight: return "Joy-Con (R)"
        case .joyConPair:  return "Joy-Con Pair"
        case .stadia:      return "Stadia"
        case .eightBitDo:  return "8BitDo"
        case .steamController: return "Steam Controller"
        case .mfiGeneric:  return "Generic Gamepad"
        case .unknown:     return "Controller"
        }
    }

    /// The hardware manufacturer (who makes the device), as opposed to
    /// `displayName` which is the product/model line. Shown in the
    /// controller info popover's "Brand" row - a DualSense's brand is
    /// Sony, not "DualSense".
    var manufacturer: String {
        switch self {
        case .dualSense, .dualShock4:               return "Sony"
        case .xbox:                                 return "Microsoft"
        case .switchPro, .joyConLeft,
             .joyConRight, .joyConPair:             return "Nintendo"
        case .stadia:                               return "Google"
        case .eightBitDo:                           return "8BitDo"
        case .steamController:                      return "Valve"
        case .mfiGeneric:                           return "MFi"
        case .unknown:                              return "Unknown"
        }
    }

    /// Has a customizable RGB light bar (Sony controllers only).
    var hasLightBar: Bool {
        switch self {
        case .dualSense, .dualShock4: return true
        default: return false
        }
    }

    /// Has a clickable touchpad surface (Sony controllers only).
    var hasTouchpad: Bool {
        switch self {
        case .dualSense, .dualShock4: return true
        default: return false
        }
    }

    /// Has gyro / accelerometer motion sensors.
    var hasMotion: Bool {
        switch self {
        case .dualSense, .dualShock4, .switchPro,
             .joyConLeft, .joyConRight, .joyConPair: return true
        default: return false
        }
    }

    /// Has adaptive (resistive) triggers (DualSense only).
    var hasAdaptiveTriggers: Bool { self == .dualSense }

    /// Short human summary of the controller's special capabilities, for the
    /// Smart Preset Maker so it only surfaces options the hardware supports.
    var capabilitySummary: String {
        var caps: [String] = []
        if hasLightBar { caps.append("light bar") }
        if hasTouchpad { caps.append("touchpad") }
        if hasMotion { caps.append("motion / gyro") }
        if hasAdaptiveTriggers { caps.append("adaptive triggers") }
        return caps.isEmpty ? "standard buttons & sticks" : caps.joined(separator: " · ")
    }

    /// Whether the four face buttons use Nintendo naming (B/A/Y/X) instead
    /// of the PlayStation/Xbox style (A/B/X/Y).
    var usesNintendoLayout: Bool {
        switch self {
        case .switchPro, .joyConLeft, .joyConRight, .joyConPair:
            return true
        default:
            return false
        }
    }

    /// Whether this is a single Joy-Con (which has a unique button layout
    /// since it is only half of a normal controller).
    var isSingleJoyCon: Bool {
        switch self {
        case .joyConLeft, .joyConRight: return true
        default: return false
        }
    }
}

enum ControllerTypeDetector {
    /// Inspect a GCController and return our best guess at its brand. Apple
    /// surfaces brand information through `vendorName` and `productCategory`,
    /// neither of which is fully standardized, so we match on substrings.
    ///
    /// On macOS 13+ Apple's GameController framework exposes the Switch Pro
    /// Controller and Joy-Cons as MFi-compatible extended gamepads with
    /// product categories that include "Joy-Con" or "Switch". Stadia, 8BitDo,
    /// and Xbox controllers identify similarly. For anything that does not
    /// match a known brand we fall back to `.mfiGeneric` so the UI still
    /// renders sensible labels.
    static func detect(_ controller: GCController) -> ControllerBrand {
        let category = (controller.productCategory).lowercased()
        let vendor = (controller.vendorName ?? "").lowercased()
        let combined = "\(vendor) \(category)"

        // Nintendo Switch family
        if combined.contains("joy-con") || combined.contains("joycon") {
            if combined.contains("(l)") || combined.contains("left") {
                return .joyConLeft
            } else if combined.contains("(r)") || combined.contains("right") {
                return .joyConRight
            } else if combined.contains("pair") || combined.contains("combined") {
                return .joyConPair
            }
            // If we cannot determine left/right, fall through to pair as the
            // closest catch-all.
            return .joyConPair
        }

        if combined.contains("switch pro") || combined.contains("pro controller") ||
           combined.contains("nintendo") {
            return .switchPro
        }

        // PlayStation family
        if combined.contains("dualsense") || combined.contains("dual sense") {
            return .dualSense
        }
        if combined.contains("dualshock") || combined.contains("ds4") || combined.contains("wireless controller") && combined.contains("sony") {
            return .dualShock4
        }

        // Xbox family
        if combined.contains("xbox") || combined.contains("xinput") {
            return .xbox
        }

        // 8BitDo
        if combined.contains("8bitdo") || combined.contains("8-bit") {
            return .eightBitDo
        }

        // Google Stadia
        if combined.contains("stadia") {
            return .stadia
        }

        // Anything else that conforms to GCExtendedGamepad is a generic MFi controller.
        if controller.extendedGamepad != nil {
            return .mfiGeneric
        }
        return .unknown
    }

    /// Friendly text describing a logical button index for display in the
    /// editor. Index numbers match the convention used everywhere else in
    /// the app:
    ///   0 = A / Cross
    ///   1 = B / Circle
    ///   2 = X / Square
    ///   3 = Y / Triangle
    static func buttonLabel(_ index: Int, brand: ControllerBrand) -> String {
        switch (brand, index) {
        // Nintendo flips A and B, and X and Y, relative to the rest of the
        // industry. We surface the physical names of the buttons so the user
        // does not have to mentally translate.
        case (.switchPro, 0), (.joyConPair, 0), (.joyConRight, 0): return "B"
        case (.switchPro, 1), (.joyConPair, 1), (.joyConRight, 1): return "A"
        case (.switchPro, 2), (.joyConPair, 2), (.joyConRight, 2): return "Y"
        case (.switchPro, 3), (.joyConPair, 3), (.joyConRight, 3): return "X"

        // Left Joy-Con has the directional pad in place of the face buttons,
        // so its "0..3" buttons are the d-pad directions when used solo.
        case (.joyConLeft, 0): return "Down"
        case (.joyConLeft, 1): return "Right"
        case (.joyConLeft, 2): return "Left"
        case (.joyConLeft, 3): return "Up"

        // PlayStation naming
        case (.dualSense, 0), (.dualShock4, 0): return "Cross"
        case (.dualSense, 1), (.dualShock4, 1): return "Circle"
        case (.dualSense, 2), (.dualShock4, 2): return "Square"
        case (.dualSense, 3), (.dualShock4, 3): return "Triangle"

        // Xbox and everything else use A/B/X/Y
        default:
            switch index {
            case 0: return "A"
            case 1: return "B"
            case 2: return "X"
            case 3: return "Y"
            case 4: return "LB / L1"
            case 5: return "RB / R1"
            case 6: return "LT / L2"
            case 7: return "RT / R2"
            case 8: return "Select / Share"
            case 9: return "Start / Options"
            case 10: return "Home"
            case 11: return "L3"
            case 12: return "R3"
            case 13: return "Touchpad"
            case 14: return "Create / Share"
            case 15: return "Microphone / Mute"
            case 16: return "Left Paddle"
            case 17: return "Right Paddle"
            case 18: return "Paddle 3"
            case 19: return "Paddle 4"
            case 20: return "FN 1 / Left Function"
            case 21: return "FN 2 / Right Function"
            default: return "Button \(index)"
            }
        }
    }
}
