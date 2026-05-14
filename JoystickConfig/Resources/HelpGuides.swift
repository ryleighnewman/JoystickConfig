import Foundation

/// A single help guide that walks the user through one topic.
/// Add new guides to `HelpGuideLibrary.all` to make them appear in the Help panel.
struct HelpGuide: Identifiable, Hashable {
    let id: String
    let title: String
    let category: String
    let summary: String
    let sections: [HelpSection]
}

/// A section inside a help guide. Each section has a heading and a body that
/// can mix paragraphs and numbered steps.
struct HelpSection: Hashable {
    let heading: String
    let body: String
    let steps: [String]

    init(heading: String, body: String = "", steps: [String] = []) {
        self.heading = heading
        self.body = body
        self.steps = steps
    }
}

/// Library of all available help guides. Add new entries here.
enum HelpGuideLibrary {
    static let all: [HelpGuide] = [
        accessControllerProfile,
        connectingControllers,
        accessibilityPermission,
        variableSensitivity,
        hapticFeedback,
        speechFeedback,
        lightBar,
    ]

    // MARK: - Guides

    static let accessControllerProfile = HelpGuide(
        id: "access-controller-profile",
        title: "Access Controller Sends No Input",
        category: "Troubleshooting",
        summary: "If your PlayStation Access Controller is connected but no buttons are working, the cause is almost always a profile configuration on the controller itself, not the controller being broken.",
        sections: [
            HelpSection(
                heading: "Why this happens",
                body: "The Access Controller can hold up to three on-device profiles. If the current profile was set up on a PlayStation console to leave some or all buttons unmapped, those buttons will not transmit input to a connected Mac. The controller is working correctly. It is just sending nothing because the profile says to send nothing."
            ),
            HelpSection(
                heading: "How to fix it",
                steps: [
                    "Look at the profile light on the front of the Access Controller. The current profile is the one that is lit.",
                    "Press the profile button to cycle between the three available profiles. The light will move to indicate which profile is active.",
                    "After each switch, try pressing a button in JoystickConfig's input scanner to see if it now registers.",
                    "If none of the three profiles produce input, plug the controller into a PlayStation 5, open the Accessibility settings for the Access Controller, and confirm that at least one profile has buttons assigned. You can also restore the default profile from that menu.",
                    "Once the profile is configured, unplug the controller from the PS5 and reconnect it to your Mac. JoystickConfig should now receive input."
                ]
            ),
            HelpSection(
                heading: "Tip",
                body: "If you switch between PS5 and Mac use, keep one profile set up for full input so the controller is always usable on Mac without reconfiguring it."
            ),
        ]
    )

    static let connectingControllers = HelpGuide(
        id: "connecting-controllers",
        title: "Connecting a Controller",
        category: "Getting Started",
        summary: "Most game controllers connect to a Mac in one of two ways. Pick the method that matches your hardware.",
        sections: [
            HelpSection(
                heading: "USB-C cable",
                body: "Plug the controller into your Mac with a USB-C cable. Most modern controllers, including the DualSense, DualSense Edge, and Xbox controllers, work this way without any setup. If JoystickConfig does not detect it, click Refresh Controllers in the controller chip popover."
            ),
            HelpSection(
                heading: "Bluetooth",
                steps: [
                    "Put the controller into pairing mode. On a DualSense, hold the PS and Create buttons together until the light bar starts flashing.",
                    "On your Mac, open System Settings > Bluetooth.",
                    "Wait for the controller to appear in the list of nearby devices and click Connect.",
                    "Once paired, JoystickConfig should detect it within a few seconds."
                ]
            ),
            HelpSection(
                heading: "If the controller does not appear",
                body: "Disconnect from any other paired device first. Controllers can only be paired with one device at a time, so if it is still paired to a PlayStation or Xbox, unpair it there first."
            ),
        ]
    )

    static let accessibilityPermission = HelpGuide(
        id: "accessibility-permission",
        title: "Granting Accessibility Permission",
        category: "Getting Started",
        summary: "After connecting a controller and activating a preset, you may notice your inputs are not reaching other apps. macOS requires explicit permission to post keyboard and mouse events.",
        sections: [
            HelpSection(
                heading: "How to grant permission",
                steps: [
                    "Open System Settings.",
                    "Go to Privacy & Security > Accessibility.",
                    "Click the + button below the list of apps.",
                    "Navigate to JoystickConfig in your Applications folder and add it.",
                    "Make sure the toggle next to JoystickConfig is on.",
                    "Return to JoystickConfig and try your controller input again."
                ]
            ),
            HelpSection(
                heading: "If inputs still are not working",
                body: "Quit and reopen JoystickConfig after granting permission. If you previously installed an older version, remove the old entry from the Accessibility list and add the current build again."
            ),
        ]
    )

    static let variableSensitivity = HelpGuide(
        id: "variable-sensitivity",
        title: "Variable Sensitivity",
        category: "Bindings",
        summary: "Joystick and trigger inputs send a continuous value, not just on or off. Variable Sensitivity uses that depth to scale the output, so a small tilt produces small movement and a full push produces full movement.",
        sections: [
            HelpSection(
                heading: "How it works",
                body: "When Variable Sensitivity is on, mouse movement and scroll speed are multiplied by how far the joystick or trigger is pushed. The result feels closer to a real mouse or trackpad than a fixed-speed binding."
            ),
            HelpSection(
                heading: "Where to find it",
                steps: [
                    "Open a preset in the editor.",
                    "Expand the Options section of any binding that maps from an axis or trigger.",
                    "Toggle Variable Sensitivity on or off.",
                    "Optionally pick a sensitivity curve: Linear feels direct, Smooth gives finer control near the center, Aggressive ramps quickly to full speed."
                ]
            ),
        ]
    )

    static let hapticFeedback = HelpGuide(
        id: "haptic-feedback",
        title: "Haptic Feedback",
        category: "Bindings",
        summary: "Some controllers can vibrate when a binding fires. This is useful for confirming a button press without looking, especially when the binding is mapped to a non-obvious key or macro.",
        sections: [
            HelpSection(
                heading: "Supported controllers",
                body: "DualSense, DualSense Edge, and a few other controllers with full Core Haptics support will vibrate. Controllers with only basic rumble motors are silently skipped."
            ),
            HelpSection(
                heading: "Enabling it",
                steps: [
                    "Edit a preset and expand the Options for the binding.",
                    "Turn on Vibrate on press.",
                    "Adjust the intensity slider to your preference. Lower values feel like a tap; higher values feel like a thump."
                ]
            ),
        ]
    )

    static let speechFeedback = HelpGuide(
        id: "speech-feedback",
        title: "Spoken Feedback",
        category: "Bindings",
        summary: "Each binding can speak a custom phrase when it fires. The phrase plays through the Mac speakers, or through the controller speaker if your audio output is routed there.",
        sections: [
            HelpSection(
                heading: "Setting up a spoken phrase",
                steps: [
                    "Edit a preset and expand the Options for the binding.",
                    "Turn on Speak on press.",
                    "Type the phrase you want to hear. Leaving it blank will speak the input name.",
                    "Choose the destination. Mac plays through your current audio output. Controller routes through the controller speaker when your Mac is set to use it."
                ]
            ),
            HelpSection(
                heading: "Routing audio to the controller speaker",
                body: "Open System Settings > Sound, then under Output pick your controller from the list. Audio from JoystickConfig will then play through the controller speaker."
            ),
        ]
    )

    static let lightBar = HelpGuide(
        id: "light-bar",
        title: "Light Bar Customization",
        category: "Hardware",
        summary: "DualSense and DualShock 4 controllers have a programmable RGB light bar. Click the controller chip at the top of the preset sidebar to open the color picker.",
        sections: [
            HelpSection(
                heading: "Picking a color",
                steps: [
                    "Click the controller chip in the sidebar.",
                    "Pick a preset color, or expand the Custom Color row to use the full color picker.",
                    "Use the brightness control to set Off, Dim, or Bright.",
                    "Use the RGB Cycle button if you want the light bar to cycle through hues continuously."
                ]
            ),
            HelpSection(
                heading: "Why the light flickers when changing colors",
                body: "JoystickConfig briefly resets the controller connection to send the new color. This takes about a second. Once the color is applied, the connection returns to normal."
            ),
        ]
    )
}
